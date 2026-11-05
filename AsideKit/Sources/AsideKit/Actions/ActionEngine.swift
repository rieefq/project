import Foundation

/// Runs tool calls safely: prepare → policy → (confirmation) → dedupe → execute → journal.
///
/// The engine never reports success it didn't observe. A tool's `execute` must return
/// `.completed` only after the underlying service confirmed the change.
public actor ActionEngine {
    public nonisolated let registry: ToolRegistry
    private let policy: PolicyEngine
    public nonisolated let journal: ActionJournal
    private let authenticator: DeviceAuthenticator?

    private struct Pending {
        var prepared: PreparedCall
        var request: ConfirmationRequest
        var context: ExecutionContext
    }

    private var pending: [String: Pending] = [:]
    /// Results of recent executions, keyed by idempotency key.
    private var recentResults: [String: (date: Date, turnID: String?, result: ActionResult)] = [:]

    public var dedupeWindow: TimeInterval = 90
    public var executionTimeout: TimeInterval = 20
    public var undoWindow: TimeInterval = 15 * 60

    public init(registry: ToolRegistry, journal: ActionJournal, authenticator: DeviceAuthenticator?, policy: PolicyEngine = PolicyEngine()) {
        self.registry = registry
        self.journal = journal
        self.authenticator = authenticator
        self.policy = policy
    }

    // MARK: Perform

    public func perform(_ call: ToolCall, context: ExecutionContext) async -> ToolOutcome {
        guard let handler = registry.handler(named: call.name) else {
            return .failed(ToolFailure(.unsupported, message: "I can't do that yet.", detail: "Unknown tool \(call.name)"))
        }
        let preparation = await handler.prepare(call, in: context)
        let prepared: PreparedCall
        switch preparation {
        case .outcome(let outcome):
            if case .failed(let failure) = outcome {
                await journal.record(JournalEntry(date: context.now, toolName: call.name, capability: handler.spec.capability,
                                                  origin: call.origin, status: .failed, summary: "Couldn't \(handler.spec.name)",
                                                  idempotencyKey: PreparedCall.key(for: call), turnID: call.turnID, failure: failure.detail))
            }
            return outcome
        case .ready(let ready):
            prepared = ready
        }

        switch policy.decide(prepared, spec: handler.spec, context: context) {
        case .deny(let message):
            await journal.record(JournalEntry(date: context.now, toolName: call.name, capability: handler.spec.capability,
                                              origin: call.origin, status: .declined, summary: "Refused \(call.name)",
                                              idempotencyKey: prepared.idempotencyKey, turnID: call.turnID, failure: message))
            return .failed(ToolFailure(.denied, message: message))
        case .confirm(let strength) where !context.isConfirmed:
            let details = prepared.confirmation ?? ConfirmationDetails(
                title: handler.spec.capability.displayName,
                consequence: "This will \(call.name.replacingOccurrences(of: "_", with: " ")).",
                prompt: "Should I go ahead?")
            let request = ConfirmationRequest(
                call: prepared.call, title: details.title, subject: details.subject, detail: details.detail,
                consequence: details.consequence, prompt: details.prompt, confirmLabel: details.confirmLabel,
                strength: max(strength, details.minimumStrength), isDestructive: details.isDestructive,
                expiresAt: context.now.addingTimeInterval(120))
            pending[request.id] = Pending(prepared: prepared, request: request, context: context)
            return .needsConfirmation(request)
        default:
            break
        }

        return await run(prepared, handler: handler, context: context)
    }

    // MARK: Confirmation

    public func confirm(_ requestID: String, now: Date) async -> ToolOutcome {
        guard let entry = pending.removeValue(forKey: requestID) else {
            return .failed(ToolFailure(.notFound, message: "That request expired. Ask me again?"))
        }
        guard now <= entry.request.expiresAt else {
            return .failed(ToolFailure(.timeout, message: "That request expired. Ask me again?"))
        }
        if entry.request.strength == .deviceAuthentication {
            guard let authenticator, await authenticator.authenticate(reason: entry.request.title) else {
                return .failed(ToolFailure(.denied, message: "I couldn't verify it's you, so I didn't do it."))
            }
        }
        guard let handler = registry.handler(named: entry.prepared.call.name) else {
            return .failed(ToolFailure(.unsupported, message: "I can't do that yet."))
        }
        var context = entry.context
        context.isConfirmed = true
        context.now = now
        return await run(entry.prepared, handler: handler, context: context)
    }

    public func decline(_ requestID: String, now: Date) async {
        guard let entry = pending.removeValue(forKey: requestID) else { return }
        await journal.record(JournalEntry(date: now, toolName: entry.prepared.call.name, capability: registry.handler(named: entry.prepared.call.name)?.spec.capability ?? .system,
                                          origin: entry.prepared.call.origin, status: .declined,
                                          summary: "You declined: \(entry.request.title)", idempotencyKey: entry.prepared.idempotencyKey,
                                          turnID: entry.prepared.call.turnID))
    }

    public func pendingRequest(_ id: String) -> ConfirmationRequest? { pending[id]?.request }

    public func discardAllPending() { pending.removeAll() }

    // MARK: Undo

    /// Reverses the most recent undoable action.
    public func undoLast(context: ExecutionContext) async -> ToolOutcome {
        guard let entry = await journal.lastUndoable(before: context.now, within: undoWindow), let plan = entry.undo else {
            return .failed(ToolFailure(.notFound, message: "There's nothing recent for me to undo."))
        }
        return await undo(entry: entry, plan: plan, context: context)
    }

    /// Reverses a specific journal entry (used by the Activity view).
    public func undo(entryID: String, context: ExecutionContext) async -> ToolOutcome {
        let recent = await journal.recent(limit: 500)
        guard let entry = recent.first(where: { $0.id == entryID }), entry.isUndoable, let plan = entry.undo else {
            return .failed(ToolFailure(.notFound, message: "That can't be undone anymore."))
        }
        return await undo(entry: entry, plan: plan, context: context)
    }

    private func undo(entry: JournalEntry, plan: UndoPlan, context: ExecutionContext) async -> ToolOutcome {
        var undoContext = context
        undoContext.origin = .undo
        undoContext.isConfirmed = true
        let call = ToolCall(name: plan.toolName, arguments: plan.arguments, origin: .undo, turnID: entry.turnID)
        let outcome = await perform(call, context: undoContext)
        if case .completed(var result) = outcome {
            await journal.update(entry.id, status: .undone)
            recentResults[entry.idempotencyKey] = nil
            result.speech = SpeechPlan(minimal: "Undone.", balanced: "Okay, I \(plan.pastTense).", detailed: "Okay, I \(plan.pastTense).")
            result.undo = nil
            result.earcon = .cancelled
            return .completed(result)
        }
        return outcome
    }

    // MARK: Execution

    private func run(_ prepared: PreparedCall, handler: any ToolHandler, context: ExecutionContext) async -> ToolOutcome {
        let key = prepared.idempotencyKey
        if let recent = recentResults[key], context.now.timeIntervalSince(recent.date) < dedupeWindow,
           recent.turnID == prepared.call.turnID || prepared.dedupeAcrossTurns, prepared.risk > .read {
            var result = recent.result
            result.speech = SpeechPlan(minimal: "Already done.", balanced: "That's already done.", detailed: "That's already done — I won't do it twice.")
            result.undo = nil
            await journal.record(JournalEntry(date: context.now, toolName: prepared.call.name, capability: handler.spec.capability,
                                              origin: prepared.call.origin, status: .deduplicated, summary: "Skipped duplicate: \(result.summary)",
                                              idempotencyKey: key, turnID: prepared.call.turnID))
            return .completed(result)
        }

        let timeout = executionTimeout
        let outcome: ToolOutcome = await withTaskGroup(of: ToolOutcome?.self) { group in
            group.addTask { await handler.execute(prepared, in: context) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            return .failed(ToolFailure(.timeout,
                                       message: prepared.risk > .read
                                           ? "That's taking too long, and I'm not sure it went through. Want me to check?"
                                           : "That's taking too long. Try again in a moment?",
                                       detail: "\(prepared.call.name) timed out after \(Int(timeout))s", isRetryable: true))
        }

        switch outcome {
        case .completed(let result):
            if prepared.risk > .read {
                recentResults[key] = (context.now, prepared.call.turnID, result)
                await journal.record(JournalEntry(date: context.now, toolName: prepared.call.name, capability: handler.spec.capability,
                                                  origin: prepared.call.origin, status: .completed, summary: result.summary,
                                                  undo: result.undo, referent: result.referent, idempotencyKey: key,
                                                  turnID: prepared.call.turnID))
            }
        case .failed(let failure):
            await journal.record(JournalEntry(date: context.now, toolName: prepared.call.name, capability: handler.spec.capability,
                                              origin: prepared.call.origin, status: .failed, summary: "Couldn't complete \(prepared.call.name)",
                                              idempotencyKey: key, turnID: prepared.call.turnID, failure: failure.detail))
        default:
            break
        }
        pruneRecent(now: context.now)
        return outcome
    }

    private func pruneRecent(now: Date) {
        recentResults = recentResults.filter { now.timeIntervalSince($0.value.date) < dedupeWindow * 2 }
    }
}

import Foundation

// MARK: - Save

public struct SaveNoteTool: ToolHandler {
    let memory: MemoryStore

    public init(memory: MemoryStore) { self.memory = memory }

    public var spec: ToolSpec {
        ToolSpec(
            name: "save_note",
            description: "Save something for the user to recall later: a note, a fact, a preference or a commitment. Set user_asked=true only when the user explicitly asked you to note or remember it; otherwise the user is asked first.",
            inputSchema: Schema.object([
                "text": Schema.string("What to keep, phrased as a standalone statement, e.g. \"The gate code is 4412\"."),
                "kind": Schema.string("Type of memory.", enum: ["note", "fact", "preference", "commitment"]),
                "user_asked": Schema.boolean("True if the user explicitly asked to note or remember this."),
            ], required: ["text", "kind", "user_asked"]),
            capability: .memory, risk: .reversible)
    }

    public func prepare(_ call: ToolCall, in context: ExecutionContext) async -> Preparation {
        guard context.preferences.memoryEnabled else {
            return .outcome(.failed(ToolFailure(.denied, message: "Memory is turned off. You can turn it on in Aside's settings.")))
        }
        guard let text = call.arguments["text"]?.nonEmptyString else {
            return .outcome(.needsInfo(SlotRequest(prompt: "What should I note?", parameter: "text", kind: .text, call: call)))
        }
        let explicit = call.arguments["user_asked"]?.boolValue == true && context.origin != .cloudModel
            || call.arguments["user_asked"]?.boolValue == true && Self.userAskedExplicitly(context.utterance)
        if !explicit {
            switch context.preferences.learningMode {
            case .explicitOnly:
                return .outcome(.failed(ToolFailure(.denied, message: "I only remember things when you ask me to.")))
            case .askFirst:
                let shifted = PerspectiveShifter.secondPerson(text.lowercasedFirst)
                return .ready(PreparedCall(call: call.with("source", "confirmed"), risk: .reversible,
                                           confirmation: ConfirmationDetails(title: "Remember this?", detail: text, consequence: "Saved on this device. You can review or delete it anytime.",
                                                                             prompt: "Want me to remember that \(shifted)?", confirmLabel: "Remember", minimumStrength: .voice)))
            }
        }
        return .ready(PreparedCall(call: call.with("source", "explicit"), risk: .reversible, dedupeAcrossTurns: true))
    }

    /// Cloud models can claim the user asked; double-check the user's words.
    static func userAskedExplicitly(_ utterance: String?) -> Bool {
        guard let lower = utterance?.lowercased() else { return false }
        return ["remember", "note", "write down", "jot", "keep in mind", "don't forget", "save"].contains { lower.contains($0) }
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let arguments = prepared.call.arguments
        let text = arguments["text"]?.nonEmptyString ?? ""
        let kind = MemoryItem.Kind(rawValue: arguments["kind"]?.stringValue ?? "note") ?? .note
        let source: MemoryItem.Source = arguments["source"]?.stringValue == "confirmed" ? .confirmed : .explicit
        let item = await memory.add(text, kind: kind, source: source, now: context.now)
        let speech: SpeechPlan
        switch kind {
        case .note: speech = SpeechPlan(minimal: "Noted.", balanced: "Noted.", detailed: "Noted: \(PerspectiveShifter.secondPerson(text)).")
        case .fact: speech = SpeechPlan(minimal: "Got it.", balanced: "Got it, I'll remember that.", detailed: "Got it — I'll remember that \(PerspectiveShifter.secondPerson(text.lowercasedFirst)).")
        case .preference: speech = SpeechPlan(minimal: "Got it.", balanced: "Got it, I'll keep that in mind.", detailed: "Okay, I'll remember that \(PerspectiveShifter.secondPerson(text.lowercasedFirst)).")
        case .commitment: speech = SpeechPlan(minimal: "Noted.", balanced: "Noted.", detailed: "Noted that \(PerspectiveShifter.secondPerson(text.lowercasedFirst)).")
        }
        var followUp: FollowUpOffer?
        if kind == .commitment, context.preferences.proactiveSuggestions {
            followUp = FollowUpOffer(prompt: "Want a reminder for that?", toolName: "create_reminder", arguments: ["title": .string(text)])
        }
        return .completed(ActionResult(
            summary: "Saved \(kind.rawValue): \(text)",
            speech: speech,
            undo: UndoPlan(toolName: "forget", arguments: ["id": .string(item.id)], pastTense: "forgot it"),
            referent: Referent(kind: kind == .note ? .note : .memory, id: item.id, title: text),
            data: ["id": .string(item.id), "kind": .string(kind.rawValue)],
            earcon: .success, followUp: followUp))
    }
}

// MARK: - Recall

public struct RecallTool: ToolHandler {
    let memory: MemoryStore

    public init(memory: MemoryStore) { self.memory = memory }

    public var spec: ToolSpec {
        ToolSpec(
            name: "recall",
            description: "Search what the user asked Aside to note or remember. Use before saying you don't know something personal (codes, where they parked, people's preferences).",
            inputSchema: Schema.object([
                "query": Schema.string("What to look for."),
                "about_user": Schema.boolean("Summarize everything remembered about the user."),
            ]),
            capability: .memory, risk: .read)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let arguments = prepared.call.arguments
        if arguments["about_user"]?.boolValue == true {
            let items = await memory.all()
            guard !items.isEmpty else {
                return .completed(ActionResult(summary: "Nothing remembered", speech: SpeechPlan("You haven't asked me to remember anything yet."), earcon: .none))
            }
            let shown = items.filter { !$0.isSensitive }.prefix(4).map { PerspectiveShifter.secondPerson($0.text.lowercasedFirst) }
            let count = items.count
            let lead = count == 1 ? "I have one thing saved" : "I have \(context.formatter.count(count)) things saved"
            let speech = shown.isEmpty ? "\(lead). You can review them in Aside's settings." : "\(lead), including that \(context.formatter.list(Array(shown))). You can review all of it in settings."
            return .completed(ActionResult(summary: "Summarized \(count) memories", speech: SpeechPlan(speech),
                                           card: .list(ListCard(heading: "Remembered", symbol: "brain", items: items.prefix(8).map(\.text))),
                                           data: ["items": .array(items.prefix(20).map { .string($0.text) })], earcon: .none, isPersonal: true))
        }
        let query = arguments["query"]?.stringValue ?? ""
        let matches = await memory.search(query, limit: 3, now: context.now)
        guard let best = matches.first, best.score >= 0.5 else {
            return .failed(ToolFailure(.notFound, message: "I don't have anything saved about that.", detail: "no memory match for \(query)"))
        }
        await memory.markUsed(matches.map(\.item.id), now: context.now)
        var text = PerspectiveShifter.secondPerson(best.item.text)
        if text.hasSuffix(".") { text.removeLast() }
        let answer = best.item.kind == .note ? "You noted that \(text.lowercasedFirst)." : "\(text.capitalizedFirst)."
        return .completed(ActionResult(
            summary: "Recalled: \(best.item.text)",
            speech: SpeechPlan(minimal: text.capitalizedFirst + ".", balanced: answer, detailed: answer + " You saved that \(context.formatter.day(best.item.createdAt))."),
            referent: Referent(kind: .memory, id: best.item.id, title: best.item.text),
            data: ["matches": .array(matches.map { .string($0.item.text) })],
            earcon: .none, isPersonal: true))
    }
}

// MARK: - Forget

public struct ForgetTool: ToolHandler {
    let memory: MemoryStore

    public init(memory: MemoryStore) { self.memory = memory }

    public var spec: ToolSpec {
        ToolSpec(
            name: "forget",
            description: "Delete something Aside remembers, by words or id, the last thing saved, or everything (needs device authentication).",
            inputSchema: Schema.object([
                "query": Schema.string("Words describing what to forget."),
                "id": Schema.string("Memory id, if known."),
                "last": Schema.boolean("Forget the most recently saved item."),
                "all": Schema.boolean("Forget everything Aside remembers."),
            ]),
            capability: .memory, risk: .reversible)
    }

    public func prepare(_ call: ToolCall, in context: ExecutionContext) async -> Preparation {
        let arguments = call.arguments
        if arguments["all"]?.boolValue == true {
            let count = await memory.all().count
            guard count > 0 else { return .outcome(.completed(ActionResult(summary: "Nothing to forget", speech: SpeechPlan("There's nothing saved."), earcon: .none))) }
            return .ready(PreparedCall(call: call, risk: .consequential, confirmation: ConfirmationDetails(
                title: "Forget everything", subject: "\(count) saved item\(count == 1 ? "" : "s")",
                consequence: "Permanently deletes all notes, facts and preferences Aside remembers on this device.",
                prompt: "Forget all \(count) things I remember? This can't be undone.", confirmLabel: "Forget All",
                isDestructive: true, minimumStrength: .deviceAuthentication)))
        }
        if let id = arguments["id"]?.nonEmptyString {
            guard await memory.item(id) != nil else { return .outcome(.failed(ToolFailure(.notFound, message: "That's already gone."))) }
            return .ready(PreparedCall(call: call, risk: .reversible))
        }
        if arguments["last"]?.boolValue == true || arguments["query"]?.nonEmptyString == nil {
            if let referent = context.lastReferent, referent.kind == .memory || referent.kind == .note {
                return .ready(PreparedCall(call: call.with("id", .string(referent.id)), risk: .reversible))
            }
            guard let latest = await memory.all().first else { return .outcome(.failed(ToolFailure(.notFound, message: "There's nothing saved."))) }
            return .ready(PreparedCall(call: call.with("id", .string(latest.id)), risk: .reversible))
        }
        let query = arguments["query"]?.stringValue ?? ""
        let matches = await memory.search(query, limit: 4, now: context.now).filter { $0.score >= 0.5 }
        switch matches.count {
        case 0:
            return .outcome(.failed(ToolFailure(.notFound, message: "I don't have anything saved about \(query).")))
        case 1:
            return .ready(PreparedCall(call: call.with("id", .string(matches[0].item.id)), risk: .reversible))
        default:
            if matches[0].score >= 1.0 && matches[1].score < 1.0 {
                return .ready(PreparedCall(call: call.with("id", .string(matches[0].item.id)), risk: .reversible))
            }
            let options = matches.prefix(3).map { ChoiceOption(label: $0.item.text, value: .string($0.item.id)) }
            return .outcome(.needsChoice(ChoiceRequest(prompt: "Which one? \(context.formatter.list(options.map { "“\($0.label.spokenPrefix(words: 6))”" }, conjunction: "or"))",
                                                       options: Array(options), parameter: "id", call: call)))
        }
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let arguments = prepared.call.arguments
        if arguments["all"]?.boolValue == true {
            let count = await memory.all().count
            await memory.removeAll()
            return .completed(ActionResult(summary: "Forgot all \(count) memories", speech: SpeechPlan("Done. I've forgotten everything you asked me to remember."),
                                           data: ["forgotten": .number(Double(count))], earcon: .success))
        }
        guard let id = arguments["id"]?.nonEmptyString, let removed = await memory.remove(id) else {
            return .failed(ToolFailure(.notFound, message: "That's already gone."))
        }
        return .completed(ActionResult(
            summary: "Forgot: \(removed.text)",
            speech: SpeechPlan(minimal: "Forgotten.", balanced: "Okay, I've forgotten that.", detailed: "Okay, I've forgotten that \(PerspectiveShifter.secondPerson(removed.text.lowercasedFirst))."),
            undo: UndoPlan(toolName: "restore_memory", arguments: ["id": .string(removed.id), "text": .string(removed.text), "kind": .string(removed.kind.rawValue),
                                                                  "created": .string(ISO8601DateFormatter().string(from: removed.createdAt)),
                                                                  "sensitive": .bool(removed.isSensitive)],
                           pastTense: "restored it"),
            data: ["forgotten": .string(removed.id)], earcon: .success))
    }
}

/// Internal tool used to undo a "forget".
public struct RestoreMemoryTool: ToolHandler {
    let memory: MemoryStore

    public init(memory: MemoryStore) { self.memory = memory }

    public var spec: ToolSpec {
        ToolSpec(name: "restore_memory", description: "Restore a forgotten memory (internal).",
                 inputSchema: Schema.object(["id": Schema.string("id")]), capability: .memory, risk: .reversible, exposedToModels: false)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let arguments = prepared.call.arguments
        guard let id = arguments["id"]?.nonEmptyString, let text = arguments["text"]?.nonEmptyString else {
            return .failed(ToolFailure(.invalidArguments, message: "I couldn't restore that."))
        }
        let created = arguments["created"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) } ?? context.now
        let item = MemoryItem(id: id, kind: MemoryItem.Kind(rawValue: arguments["kind"]?.stringValue ?? "note") ?? .note, text: text,
                              createdAt: created, source: .explicit, isSensitive: arguments["sensitive"]?.boolValue ?? false)
        await memory.restore(item)
        return .completed(ActionResult(summary: "Restored: \(text)", speech: SpeechPlan("Restored."), data: ["id": .string(id)], earcon: .success))
    }
}

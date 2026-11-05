import Foundation

public struct ActiveTimer: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var label: String?
    public var duration: TimeInterval
    public var fireDate: Date
    public var createdAt: Date

    public func remaining(at now: Date) -> TimeInterval { max(0, fireDate.timeIntervalSince(now)) }
}

/// Keeps track of running timers. Each timer is a scheduled local notification, so it
/// fires even if Aside isn't running.
public actor TimerCenter {
    private let scheduler: NotificationScheduler
    private let store: PersistentStore?
    private let key = "timers.v1"
    private var timers: [ActiveTimer] = []
    private var loaded = false

    public init(scheduler: NotificationScheduler, store: PersistentStore?) {
        self.scheduler = scheduler
        self.store = store
    }

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        if let store, let data = try? await store.load(key),
           let decoded = try? StoreCoding.decoder().decode([ActiveTimer].self, from: data) {
            timers = decoded
        }
    }

    private func persist() async {
        guard let store, let data = try? StoreCoding.encoder().encode(timers) else { return }
        try? await store.save(data, for: key)
    }

    public func access() async -> AccessState { await scheduler.access() }
    public func requestAccess() async -> AccessState { await scheduler.requestAccess() }

    public func start(duration: TimeInterval, label: String?, now: Date, spokenDuration: String) async throws -> ActiveTimer {
        await ensureLoaded()
        let timer = ActiveTimer(id: Identifier.make("timer"), label: label, duration: duration,
                                fireDate: now.addingTimeInterval(duration), createdAt: now)
        try await scheduler.schedule(notification(for: timer, spokenDuration: spokenDuration))
        timers.append(timer)
        await persist()
        return timer
    }

    public func active(now: Date) async -> [ActiveTimer] {
        await ensureLoaded()
        let before = timers.count
        timers.removeAll { $0.fireDate <= now }
        if timers.count != before { await persist() }
        return timers.sorted { $0.fireDate < $1.fireDate }
    }

    @discardableResult
    public func cancel(id: String) async -> ActiveTimer? {
        await ensureLoaded()
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return nil }
        let timer = timers.remove(at: index)
        await scheduler.cancel(ids: [timer.id])
        await persist()
        return timer
    }

    public func reschedule(id: String, duration: TimeInterval, now: Date, spokenDuration: String) async throws -> ActiveTimer? {
        await ensureLoaded()
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return nil }
        await scheduler.cancel(ids: [id])
        timers[index].duration = duration
        timers[index].fireDate = now.addingTimeInterval(duration)
        try await scheduler.schedule(notification(for: timers[index], spokenDuration: spokenDuration))
        await persist()
        return timers[index]
    }

    private func notification(for timer: ActiveTimer, spokenDuration: String) -> LocalNotification {
        let title = timer.label.map { "\($0.capitalizedFirst) timer" } ?? "Timer"
        return LocalNotification(id: timer.id, title: title, body: "\(spokenDuration.capitalizedFirst) — time's up.", fireDate: timer.fireDate,
                                 category: "timer", isTimeSensitive: true, userInfo: ["timer": timer.id])
    }
}

private func timerAccess(_ center: TimerCenter, _ call: ToolCall) async -> ToolOutcome? {
    var state = await center.access()
    if state == .notDetermined { state = await center.requestAccess() }
    guard state.isUsable else {
        return .needsPermission(PermissionRequest(capability: .timers, state: state,
                                                  explanation: "Timers need notifications turned on so I can alert you, even if I'm closed.",
                                                  call: call))
    }
    return nil
}

private func timerName(_ timer: ActiveTimer) -> String {
    timer.label.map { "your \($0.lowercasedFirst) timer" } ?? "your timer"
}

// MARK: - Start

public struct StartTimerTool: ToolHandler {
    let center: TimerCenter

    public init(center: TimerCenter) { self.center = center }

    public var spec: ToolSpec {
        ToolSpec(
            name: "start_timer",
            description: "Start a countdown timer that alerts the user when it ends. Use for durations (\"10 minutes\"), not clock times (use create_reminder for those).",
            inputSchema: Schema.object([
                "seconds": Schema.number("Timer length in seconds."),
                "duration": Schema.string("Timer length as the user said it, e.g. \"an hour and a half\"."),
                "label": Schema.string("Optional name, e.g. \"pasta\"."),
            ]),
            capability: .timers, risk: .reversible)
    }

    static func seconds(from arguments: JSONValue) -> Double? {
        if let text = arguments["duration"]?.nonEmptyString, let parsed = DurationParser.parseWhole(Utterance(text).norms) ?? DurationParser.parse(Utterance(text).norms, at: 0)?.duration {
            return parsed.approximateSeconds
        }
        if let seconds = arguments["seconds"]?.doubleValue, seconds > 0 { return seconds }
        return nil
    }

    public func prepare(_ call: ToolCall, in context: ExecutionContext) async -> Preparation {
        guard let seconds = Self.seconds(from: call.arguments) else {
            return .outcome(.needsInfo(SlotRequest(prompt: "For how long?", parameter: "duration", kind: .duration, call: call)))
        }
        guard seconds >= 1, seconds <= 24 * 3_600 else {
            return .outcome(.failed(ToolFailure(.invalidArguments, message: "Timers can run from a second up to a day. For longer, I can set a reminder.")))
        }
        if let blocked = await timerAccess(center, call) { return .outcome(blocked) }
        let label = call.arguments["label"]?.nonEmptyString
        return .ready(PreparedCall(call: call.with("seconds", .number(seconds)), risk: .reversible,
                                   idempotencyKey: "start_timer:\(Int(seconds)):\(label?.lowercased() ?? "")"))
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let seconds = prepared.call.arguments["seconds"]?.doubleValue ?? 60
        let label = prepared.call.arguments["label"]?.nonEmptyString
        let spoken = context.formatter.duration(seconds)
        do {
            let timer = try await center.start(duration: seconds, label: label, now: context.now, spokenDuration: spoken)
            let named = label.map { "\($0.capitalizedFirst) timer, " } ?? ""
            return .completed(ActionResult(
                summary: "Started a \(spoken) timer" + (label.map { " for \($0)" } ?? ""),
                speech: SpeechPlan(minimal: "\(spoken.capitalizedFirst).",
                                   balanced: label == nil ? "\(spoken.capitalizedFirst), starting now." : "\(named)\(spoken).",
                                   detailed: "\(named.isEmpty ? "Timer" : named)set for \(spoken). It'll go off at \(context.formatter.time(timer.fireDate))."),
                card: .status(StatusCard(symbol: "timer", title: label.map { "\($0.capitalizedFirst) · \(spoken)" } ?? spoken.capitalizedFirst,
                                         detail: "Ends at \(context.formatter.time(timer.fireDate))", tone: .success)),
                undo: UndoPlan(toolName: "cancel_timer", arguments: ["id": .string(timer.id)], pastTense: "cancelled the timer"),
                referent: Referent(kind: .timer, id: timer.id, title: label ?? "timer", date: timer.fireDate, hasTime: true),
                data: ["id": .string(timer.id), "ends": .string(ISODates.string(timer.fireDate, timeZone: context.temporal.timeZone))],
                earcon: .success))
        } catch {
            return .failed(ToolFailure(.service, message: "I couldn't start the timer.", detail: "\(error)", isRetryable: true))
        }
    }
}

// MARK: - List

public struct ListTimersTool: ToolHandler {
    let center: TimerCenter

    public init(center: TimerCenter) { self.center = center }

    public var spec: ToolSpec {
        ToolSpec(name: "list_timers", description: "Report running timers and how much time is left.",
                 inputSchema: Schema.object([:]), capability: .timers, risk: .read)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let timers = await center.active(now: context.now)
        let formatter = context.formatter
        guard !timers.isEmpty else {
            return .completed(ActionResult(summary: "No timers running", speech: SpeechPlan("No timers are running."), data: ["timers": []], earcon: .none))
        }
        func left(_ timer: ActiveTimer) -> String {
            let remaining = timer.remaining(at: context.now)
            return remaining < 60 ? "\(Int(remaining.rounded())) seconds" : formatter.duration((remaining / 60).rounded() * 60)
        }
        let speech: String
        if timers.count == 1 {
            let timer = timers[0]
            speech = "\(left(timer).capitalizedFirst) left on \(timerName(timer))."
        } else {
            let parts = timers.prefix(4).map { "\(($0.label ?? "one").capitalizedFirst) has \(left($0))" }
            speech = "You have \(formatter.count(timers.count)) timers. " + formatter.list(parts) + "."
        }
        return .completed(ActionResult(
            summary: "Reported \(timers.count) timers",
            speech: SpeechPlan(speech),
            card: .list(ListCard(heading: "Timers", symbol: "timer", items: timers.map { "\($0.label?.capitalizedFirst ?? "Timer") — \(left($0)) left" })),
            data: ["timers": .array(timers.map { timer -> JSONValue in
                ["id": .string(timer.id), "label": JSONValue(timer.label), "seconds_left": .number(timer.remaining(at: context.now).rounded())]
            })],
            earcon: .none))
    }
}

// MARK: - Cancel

public struct CancelTimerTool: ToolHandler {
    let center: TimerCenter

    public init(center: TimerCenter) { self.center = center }

    public var spec: ToolSpec {
        ToolSpec(name: "cancel_timer", description: "Cancel a running timer by label or id, or all timers.",
                 inputSchema: Schema.object([
                    "id": Schema.string("Timer id, if known."),
                    "label": Schema.string("Timer name, e.g. \"pasta\"."),
                    "all": Schema.boolean("Cancel every running timer."),
                 ]),
                 capability: .timers, risk: .reversible)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let arguments = prepared.call.arguments
        let timers = await center.active(now: context.now)
        guard !timers.isEmpty else {
            return .completed(ActionResult(summary: "No timers to cancel", speech: SpeechPlan("There's no timer running."), earcon: .none))
        }
        var targets: [ActiveTimer]
        if arguments["all"]?.boolValue == true {
            targets = timers
        } else if let id = arguments["id"]?.nonEmptyString {
            targets = timers.filter { $0.id == id }
        } else if let label = arguments["label"]?.nonEmptyString {
            targets = TitleMatch.best(timers, query: label, title: { $0.label ?? "" })
        } else if timers.count == 1 {
            targets = timers
        } else if let referent = context.lastReferent, referent.kind == .timer, let match = timers.first(where: { $0.id == referent.id }) {
            targets = [match]
        } else {
            let options = timers.prefix(4).map { ChoiceOption(label: $0.label?.capitalizedFirst ?? context.formatter.duration($0.duration) + " timer", value: .string($0.id)) }
            return .needsChoice(ChoiceRequest(prompt: "Which timer — \(context.formatter.list(options.map(\.label), conjunction: "or"))?",
                                              options: Array(options), parameter: "id", call: prepared.call))
        }
        guard !targets.isEmpty else {
            return .failed(ToolFailure(.notFound, message: "I couldn't find that timer."))
        }
        for timer in targets { await center.cancel(id: timer.id) }
        let single = targets.count == 1 ? targets[0] : nil
        var undo: UndoPlan?
        if let single {
            let remaining = single.remaining(at: context.now)
            var undoArguments: JSONValue = ["seconds": .number(remaining.rounded())]
            if let label = single.label { undoArguments["label"] = .string(label) }
            undo = UndoPlan(toolName: "start_timer", arguments: undoArguments, pastTense: "restarted the timer")
        }
        return .completed(ActionResult(
            summary: "Cancelled \(targets.count) timer(s)",
            speech: SpeechPlan(minimal: "Cancelled.", balanced: targets.count == 1 ? "Cancelled \(timerName(targets[0]))." : "Cancelled all \(context.formatter.count(targets.count)) timers.",
                               detailed: nil),
            undo: undo, data: ["cancelled": .array(targets.map { .string($0.id) })], earcon: .cancelled))
    }
}

// MARK: - Update

public struct UpdateTimerTool: ToolHandler {
    let center: TimerCenter

    public init(center: TimerCenter) { self.center = center }

    public var spec: ToolSpec {
        ToolSpec(name: "update_timer", description: "Change the length of a running timer (restarts it with the new length), e.g. for \"make it 20 minutes\".",
                 inputSchema: Schema.object([
                    "id": Schema.string("Timer id; omit for the timer just discussed."),
                    "seconds": Schema.number("New length in seconds."),
                    "duration": Schema.string("New length as spoken."),
                 ]),
                 capability: .timers, risk: .reversible)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        guard let seconds = StartTimerTool.seconds(from: prepared.call.arguments) else {
            return .needsInfo(SlotRequest(prompt: "For how long?", parameter: "duration", kind: .duration, call: prepared.call))
        }
        let timers = await center.active(now: context.now)
        let id = prepared.call.arguments["id"]?.nonEmptyString
            ?? (context.lastReferent?.kind == .timer ? context.lastReferent?.id : nil)
            ?? (timers.count == 1 ? timers[0].id : nil)
        guard let id, let existing = timers.first(where: { $0.id == id }) else {
            return .failed(ToolFailure(.notFound, message: "I couldn't find a running timer to change."))
        }
        let spoken = context.formatter.duration(seconds)
        do {
            guard let updated = try await center.reschedule(id: id, duration: seconds, now: context.now, spokenDuration: spoken) else {
                return .failed(ToolFailure(.notFound, message: "That timer already finished."))
            }
            return .completed(ActionResult(
                summary: "Changed timer to \(spoken)",
                speech: SpeechPlan(minimal: "\(spoken.capitalizedFirst).", balanced: "Okay, \(spoken) — starting now.", detailed: nil),
                undo: UndoPlan(toolName: "update_timer", arguments: ["id": .string(id), "seconds": .number(existing.remaining(at: context.now).rounded())],
                               pastTense: "put the timer back"),
                referent: Referent(kind: .timer, id: updated.id, title: updated.label ?? "timer", date: updated.fireDate, hasTime: true),
                data: ["id": .string(updated.id)], earcon: .success))
        } catch {
            return .failed(ToolFailure(.service, message: "I couldn't change the timer.", detail: "\(error)", isRetryable: true))
        }
    }
}

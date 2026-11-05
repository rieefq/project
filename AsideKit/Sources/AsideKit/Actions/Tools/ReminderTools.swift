import Foundation

private func reminderAccess(_ service: RemindersService, _ call: ToolCall) async -> ToolOutcome? {
    await Access.ensure(.reminders, call: call, current: { await service.access() }, request: { await service.requestAccess() })
}

/// Phrase like "on December 5th" or "tomorrow at 9 AM" for a reminder.
func reminderWhenPhrase(_ date: Date, hasTime: Bool, context: ExecutionContext) -> String {
    context.formatter.when(date, includeTime: hasTime)
}

// MARK: - Create

public struct CreateReminderTool: ToolHandler {
    let service: RemindersService

    public init(service: RemindersService) { self.service = service }

    public var spec: ToolSpec {
        ToolSpec(
            name: "create_reminder",
            description: "Create a reminder in the user's Reminders. Use for anything the user wants to be reminded of or not forget, with or without a time. Returns the saved reminder.",
            inputSchema: Schema.object([
                "title": Schema.string("What to remind the user about, in their words, e.g. \"change my toothbrush\"."),
                "when": Schema.when,
                "due_iso": Schema.dueISO,
                "notes": Schema.string("Optional extra details."),
            ], required: ["title"]),
            capability: .reminders, risk: .reversible)
    }

    public func prepare(_ call: ToolCall, in context: ExecutionContext) async -> Preparation {
        guard let title = call.arguments["title"]?.nonEmptyString else {
            return .outcome(.needsInfo(SlotRequest(prompt: "What should I remind you about?", parameter: "title", kind: .text, call: call)))
        }
        if let blocked = await reminderAccess(service, call) { return .outcome(blocked) }
        var normalized = call.with("title", .string(title.capitalizedFirst))
        switch ResolvedWhen.from(call.arguments, context: context) {
        case .none:
            break
        case .some(.none):
            return .outcome(.needsInfo(SlotRequest(prompt: "When should I remind you?", parameter: "when", kind: .dateTime, call: call.with("when", nil))))
        case .some(.some(let when)):
            if when.isInPast {
                return .outcome(.needsInfo(SlotRequest(prompt: "That time has already passed. When should I remind you?", parameter: "when",
                                                       kind: .dateTime, call: call.with("when", nil).with("due_iso", nil))))
            }
            normalized = normalized
                .with("resolved_due", .string(ISODates.string(when.date, timeZone: context.temporal.timeZone)))
                .with("has_time", .bool(when.hasTime))
        }
        return .ready(PreparedCall(call: normalized, risk: .reversible,
                                   idempotencyKey: "create_reminder:\(title.lowercased()):\(normalized.arguments["resolved_due"]?.stringValue ?? "-")",
                                   dedupeAcrossTurns: true))
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let arguments = prepared.call.arguments
        let title = arguments["title"]?.nonEmptyString ?? "Reminder"
        var draft = ReminderDraft(title: title, notes: arguments["notes"]?.nonEmptyString)
        var when: ResolvedWhen?
        if case .some(.some(let resolved)) = ResolvedWhen.from(arguments, context: context) {
            when = resolved
            draft.due = resolved.date
            // Always alert at a concrete time; `hasTime` only changes how the time is spoken.
            draft.hasTime = true
            draft.recurrence = resolved.recurrence
        }
        do {
            let record = try await service.create(draft)
            let spokenTitle = PerspectiveShifter.secondPerson(record.title.lowercasedFirst).spokenPrefix(words: 10)
            var balanced: String
            var minimal: String
            var detailed: String
            if let due = record.due, let when {
                let phrase = reminderWhenPhrase(due, hasTime: when.hasTime, context: context)
                let recurrenceText = record.recurrence.map { " " + RecurrenceText.describe($0, context: context) } ?? ""
                if let rule = record.recurrence {
                    balanced = "Okay, I'll remind you to \(spokenTitle) \(RecurrenceText.describe(rule, context: context))\(when.hasTime ? " at \(context.formatter.time(due))" : "")."
                    minimal = "Done — \(RecurrenceText.describe(rule, context: context))."
                } else {
                    balanced = "Okay, I'll remind you to \(spokenTitle) \(phrase)."
                    minimal = "Got it, \(phrase)."
                }
                let fullDate = context.formatter.when(due, includeTime: true, includeWeekday: true)
                detailed = when.isOffset
                    ? "Okay, I'll remind you to \(spokenTitle) \(when.phrase ?? phrase) — that's \(fullDate)\(recurrenceText)."
                    : "Okay, I'll remind you to \(spokenTitle) \(fullDate)\(recurrenceText)."
                if when.isOffset && !when.hasTime && record.recurrence == nil {
                    // "in 30 days" → mention the date, it's useful.
                    balanced = "Okay, I'll remind you to \(spokenTitle) \(phrase)."
                }
            } else {
                balanced = "Added \u{201C}\(record.title)\u{201D} to your reminders."
                minimal = "Added."
                detailed = "Added \u{201C}\(record.title)\u{201D} to your reminders, with no due date."
            }
            let card = Card.status(StatusCard(symbol: "checklist", title: record.title,
                                              detail: record.due.map { context.formatter.when($0, includeTime: true, includeWeekday: true).capitalizedFirst },
                                              tone: .success))
            return .completed(ActionResult(
                summary: "Created reminder “\(record.title)”" + (record.due.map { " due \(ISODates.string($0, timeZone: context.temporal.timeZone))" } ?? " with no due date"),
                speech: SpeechPlan(minimal: minimal, balanced: balanced, detailed: detailed),
                card: card,
                undo: UndoPlan(toolName: "delete_reminder", arguments: ["id": .string(record.id), "quiet": true], pastTense: "removed that reminder"),
                referent: Referent(kind: .reminder, id: record.id, title: record.title, date: record.due, hasTime: when?.hasTime ?? false),
                data: ["id": .string(record.id), "title": .string(record.title),
                       "due": record.due.map { .string(ISODates.string($0, timeZone: context.temporal.timeZone)) } ?? .null],
                earcon: .success))
        } catch {
            return .failed(ToolFailure(.service, message: "I couldn't save that reminder.", detail: "\(error)", isRetryable: true))
        }
    }
}

enum RecurrenceText {
    static func describe(_ rule: RecurrenceRule, context: ExecutionContext) -> String {
        let names = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        switch rule.frequency {
        case .daily:
            return rule.interval == 1 ? "every day" : "every \(rule.interval) days"
        case .weekly:
            if rule.weekdays == [2, 3, 4, 5, 6] { return "every weekday" }
            if Set(rule.weekdays) == [1, 7] { return "every weekend" }
            if !rule.weekdays.isEmpty {
                let days = rule.weekdays.compactMap { (1...7).contains($0) ? names[$0] : nil }
                let list = context.formatter.list(days)
                return rule.interval == 2 ? "every other \(list)" : "every \(list)"
            }
            return rule.interval == 1 ? "every week" : "every \(rule.interval) weeks"
        case .monthly:
            return rule.interval == 1 ? "every month" : "every \(rule.interval) months"
        case .yearly:
            return "every year"
        }
    }
}

// MARK: - List

public struct ListRemindersTool: ToolHandler {
    let service: RemindersService

    public init(service: RemindersService) { self.service = service }

    public var spec: ToolSpec {
        ToolSpec(
            name: "list_reminders",
            description: "List the user's incomplete reminders, optionally due within a period (\"today\", \"this week\") or matching words.",
            inputSchema: Schema.object([
                "when": Schema.string("Optional period, e.g. \"today\", \"tomorrow\", \"this week\"."),
                "search": Schema.string("Optional words to match in reminder titles."),
            ]),
            capability: .reminders, risk: .read)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        if let blocked = await reminderAccess(service, prepared.call) { return blocked }
        let arguments = prepared.call.arguments
        var query = ReminderQuery(limit: 50)
        var periodPhrase: String?
        if let when = arguments["when"]?.nonEmptyString, let parsed = context.parser.parse(when, purpose: .query), let end = parsed.end {
            query.dueBefore = end
            periodPhrase = when.lowercased()
        }
        do {
            var reminders = try await service.reminders(matching: query)
            if let search = arguments["search"]?.nonEmptyString {
                reminders = TitleMatch.best(reminders, query: search, title: \.title, threshold: 0.4)
            }
            reminders.sort { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            let formatter = context.formatter
            let scope = periodPhrase.map { " \($0.hasPrefix("today") || $0.hasPrefix("tomorrow") ? "for " + $0 : $0)" } ?? ""
            guard !reminders.isEmpty else {
                return .completed(ActionResult(summary: "No reminders\(scope)", speech: SpeechPlan("You don't have any reminders\(scope)."),
                                               data: ["reminders": []], earcon: .none, isPersonal: true))
            }
            let spokenItems = reminders.prefix(5).map { reminder -> String in
                var item = reminder.title.lowercasedFirst
                if let due = reminder.due, reminder.hasTime {
                    item += context.temporal.calendar.isDate(due, inSameDayAs: context.now) ? " at \(formatter.time(due))" : " \(formatter.when(due, includeTime: false))"
                }
                return item
            }
            let count = reminders.count
            let lead = count == 1 ? "You have one reminder\(scope): " : "You have \(formatter.count(count)) reminders\(scope)"
            let balanced: String
            if count == 1 {
                balanced = lead + spokenItems[0] + "."
            } else if count <= 5 {
                balanced = lead + ": " + formatter.list(spokenItems) + "."
            } else {
                balanced = lead + ". The first few are " + formatter.list(Array(spokenItems.prefix(3))) + "."
            }
            let card = Card.list(ListCard(heading: "Reminders\(scope.isEmpty ? "" : " ·" + scope)", symbol: "checklist",
                                          items: reminders.prefix(8).map { reminder in
                                              reminder.title + (reminder.due.map { " — " + formatter.when($0, includeTime: reminder.hasTime) } ?? "")
                                          }))
            return .completed(ActionResult(
                summary: "Listed \(count) reminders",
                speech: SpeechPlan(minimal: count == 1 ? spokenItems[0].capitalizedFirst + "." : "\(formatter.count(count).capitalizedFirst) reminders: " + formatter.list(Array(spokenItems.prefix(3))) + ".",
                                   balanced: balanced, detailed: balanced),
                card: card,
                data: ["reminders": .array(reminders.prefix(20).map { reminder -> JSONValue in
                    ["id": .string(reminder.id), "title": .string(reminder.title),
                     "due": reminder.due.map { .string(ISODates.string($0, timeZone: context.temporal.timeZone)) } ?? .null]
                })],
                earcon: .none, isPersonal: true))
        } catch {
            return .failed(ToolFailure(.service, message: "I couldn't read your reminders.", detail: "\(error)", isRetryable: true))
        }
    }
}

// MARK: - Find helper

private func findReminder(_ service: RemindersService, arguments: JSONValue, context: ExecutionContext, call: ToolCall,
                          includeCompleted: Bool = false) async -> Lookup<ReminderRecord> {
    let reminders: [ReminderRecord]
    do {
        reminders = try await service.reminders(matching: ReminderQuery(includeCompleted: includeCompleted, limit: 500))
    } catch {
        return .outcome(.failed(ToolFailure(.service, message: "I couldn't read your reminders.", detail: "\(error)", isRetryable: true)))
    }
    if let id = arguments["id"]?.nonEmptyString {
        if let match = reminders.first(where: { $0.id == id }) { return .found(match) }
        return .outcome(.failed(ToolFailure(.notFound, message: "I couldn't find that reminder anymore.")))
    }
    let search = arguments["search"]?.nonEmptyString
    if search == nil, let referent = context.lastReferent, referent.kind == .reminder,
       let match = reminders.first(where: { $0.id == referent.id }) {
        return .found(match)
    }
    guard let search else {
        return .outcome(.needsInfo(SlotRequest(prompt: "Which reminder?", parameter: "search", kind: .text, call: call)))
    }
    let matches = TitleMatch.best(reminders, query: search, title: \.title)
    switch matches.count {
    case 0:
        return .outcome(.failed(ToolFailure(.notFound, message: "I couldn't find a reminder about \(search).")))
    case 1:
        return .found(matches[0])
    default:
        let options = matches.prefix(4).map { reminder in
            ChoiceOption(label: reminder.title, detail: reminder.due.map { context.formatter.when($0, includeTime: reminder.hasTime) }, value: .string(reminder.id))
        }
        return .outcome(.needsChoice(ChoiceRequest(prompt: "Which one — \(context.formatter.list(options.map(\.label), conjunction: "or"))?",
                                                   options: Array(options), parameter: "id", call: call)))
    }
}

// MARK: - Complete

public struct CompleteReminderTool: ToolHandler {
    let service: RemindersService

    public init(service: RemindersService) { self.service = service }

    public var spec: ToolSpec {
        ToolSpec(
            name: "complete_reminder",
            description: "Mark a reminder as done (or not done with completed=false). Identify it by id or by words from its title.",
            inputSchema: Schema.object([
                "id": Schema.string("Reminder id, if known."),
                "search": Schema.string("Words from the reminder's title."),
                "completed": Schema.boolean("false to reopen a completed reminder. Defaults to true."),
            ]),
            capability: .reminders, risk: .reversible)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        if let blocked = await reminderAccess(service, prepared.call) { return blocked }
        let completed = prepared.call.arguments["completed"]?.boolValue ?? true
        switch await findReminder(service, arguments: prepared.call.arguments, context: context, call: prepared.call, includeCompleted: !completed) {
        case .outcome(let outcome):
            return outcome
        case .found(let reminder):
            do {
                let updated = try await service.setCompleted(id: reminder.id, completed)
                let spoken = PerspectiveShifter.secondPerson(updated.title.lowercasedFirst).spokenPrefix(words: 8)
                return .completed(ActionResult(
                    summary: completed ? "Completed reminder “\(updated.title)”" : "Reopened reminder “\(updated.title)”",
                    speech: SpeechPlan(minimal: completed ? "Done." : "Reopened.",
                                       balanced: completed ? "Marked \(spoken) as done." : "Okay, \(spoken) is back on your list.",
                                       detailed: completed ? "Marked “\(updated.title)” as done." : "Okay, I reopened “\(updated.title)”."),
                    undo: UndoPlan(toolName: "complete_reminder", arguments: ["id": .string(updated.id), "completed": .bool(!completed)],
                                   pastTense: completed ? "put it back on your list" : "marked it done again"),
                    referent: Referent(kind: .reminder, id: updated.id, title: updated.title, date: updated.due, hasTime: updated.hasTime),
                    data: ["id": .string(updated.id), "completed": .bool(completed)], earcon: .success))
            } catch {
                return .failed(ToolFailure(.service, message: "I couldn't update that reminder.", detail: "\(error)", isRetryable: true))
            }
        }
    }
}

// MARK: - Update

public struct UpdateReminderTool: ToolHandler {
    let service: RemindersService

    public init(service: RemindersService) { self.service = service }

    public var spec: ToolSpec {
        ToolSpec(
            name: "update_reminder",
            description: "Change a reminder's title or time. Use for corrections like \"change it to tomorrow\". Identify it by id or title words; omit both to use the reminder just discussed.",
            inputSchema: Schema.object([
                "id": Schema.string("Reminder id, if known."),
                "search": Schema.string("Words from the reminder's current title."),
                "title": Schema.string("New title."),
                "when": Schema.when,
                "due_iso": Schema.dueISO,
            ]),
            capability: .reminders, risk: .reversible)
    }

    public func prepare(_ call: ToolCall, in context: ExecutionContext) async -> Preparation {
        if call.arguments["title"]?.nonEmptyString == nil && call.arguments["when"]?.nonEmptyString == nil && call.arguments["due_iso"]?.nonEmptyString == nil {
            return .outcome(.needsInfo(SlotRequest(prompt: "What should I change it to?", parameter: "when", kind: .dateTime, call: call)))
        }
        if case .some(.some(let when)) = ResolvedWhen.from(call.arguments, context: context), when.isInPast {
            return .outcome(.needsInfo(SlotRequest(prompt: "That time has already passed. When should it be?", parameter: "when", kind: .dateTime, call: call.with("when", nil))))
        }
        return .ready(PreparedCall(call: call, risk: .reversible))
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        if let blocked = await reminderAccess(service, prepared.call) { return blocked }
        let arguments = prepared.call.arguments
        switch await findReminder(service, arguments: arguments, context: context, call: prepared.call) {
        case .outcome(let outcome):
            return outcome
        case .found(let reminder):
            var patch = ReminderPatch()
            if let title = arguments["title"]?.nonEmptyString { patch.title = title.capitalizedFirst }
            var newWhen: ResolvedWhen?
            switch ResolvedWhen.from(arguments, context: context) {
            case .some(.some(let when)):
                var date = when.date
                // "change it to tomorrow" keeps the original time of day.
                if !when.hasTime, let old = reminder.due, reminder.hasTime {
                    let calendar = context.temporal.calendar
                    date = context.parser.at(date, hour: calendar.component(.hour, from: old), minute: calendar.component(.minute, from: old))
                }
                patch.due = .some(date)
                patch.hasTime = true
                if when.recurrence != nil { patch.recurrence = .some(when.recurrence) }
                newWhen = ResolvedWhen(date: date, hasTime: when.hasTime || reminder.hasTime, recurrence: when.recurrence, isInPast: false, phrase: when.phrase, isOffset: when.isOffset)
            case .some(.none):
                return .needsInfo(SlotRequest(prompt: "Sorry, when should it be?", parameter: "when", kind: .dateTime, call: prepared.call.with("when", nil)))
            case .none:
                break
            }
            do {
                let updated = try await service.update(id: reminder.id, with: patch)
                var undoArguments: JSONValue = ["id": .string(reminder.id), "title": .string(reminder.title)]
                if let oldDue = reminder.due { undoArguments["due_iso"] = .string(ISODates.string(oldDue, timeZone: context.temporal.timeZone)) }
                let speech: SpeechPlan
                if let newWhen, let due = updated.due {
                    let phrase = context.formatter.when(due, includeTime: newWhen.hasTime)
                    speech = SpeechPlan(minimal: "Moved to \(phrase).", balanced: "Okay, moved it to \(phrase).",
                                        detailed: "Okay, “\(updated.title)” is now \(context.formatter.when(due, includeTime: true, includeWeekday: true)).")
                } else {
                    speech = SpeechPlan(minimal: "Renamed.", balanced: "Okay, it's now “\(updated.title)”.", detailed: "Okay, I renamed it to “\(updated.title)”.")
                }
                return .completed(ActionResult(
                    summary: "Updated reminder “\(updated.title)”" + (updated.due.map { " due \(ISODates.string($0, timeZone: context.temporal.timeZone))" } ?? ""),
                    speech: speech,
                    undo: UndoPlan(toolName: "update_reminder", arguments: undoArguments, pastTense: "changed it back"),
                    referent: Referent(kind: .reminder, id: updated.id, title: updated.title, date: updated.due, hasTime: newWhen?.hasTime ?? updated.hasTime),
                    data: ["id": .string(updated.id), "title": .string(updated.title),
                           "due": updated.due.map { .string(ISODates.string($0, timeZone: context.temporal.timeZone)) } ?? .null],
                    earcon: .success))
            } catch {
                return .failed(ToolFailure(.service, message: "I couldn't change that reminder.", detail: "\(error)", isRetryable: true))
            }
        }
    }
}

// MARK: - Delete

public struct DeleteReminderTool: ToolHandler {
    let service: RemindersService

    public init(service: RemindersService) { self.service = service }

    public var spec: ToolSpec {
        ToolSpec(
            name: "delete_reminder",
            description: "Delete a reminder. Identify it by id or title words; omit both for the reminder just discussed. Asks the user to confirm when matched by words.",
            inputSchema: Schema.object([
                "id": Schema.string("Reminder id, if known."),
                "search": Schema.string("Words from the reminder's title."),
            ]),
            capability: .reminders, risk: .reversible)
    }

    public func prepare(_ call: ToolCall, in context: ExecutionContext) async -> Preparation {
        if let blocked = await reminderAccess(service, call) { return .outcome(blocked) }
        switch await findReminder(service, arguments: call.arguments, context: context, call: call) {
        case .outcome(let outcome):
            return .outcome(outcome)
        case .found(let reminder):
            let resolved = call.with("id", .string(reminder.id)).with("search", nil)
            let quiet = call.arguments["quiet"]?.boolValue == true || context.origin == .undo
            let byReference = call.arguments["id"] != nil || (call.arguments["search"] == nil && context.lastReferent?.id == reminder.id)
            let confirmation: ConfirmationDetails? = (quiet || byReference) ? nil : ConfirmationDetails(
                title: "Delete reminder", subject: reminder.title,
                detail: reminder.due.map { context.formatter.when($0, includeTime: reminder.hasTime).capitalizedFirst },
                consequence: "Removes it from Reminders.",
                prompt: "Delete the reminder “\(reminder.title)”?", confirmLabel: "Delete", isDestructive: true, minimumStrength: .voice)
            return .ready(PreparedCall(call: resolved.with("quiet", .bool(quiet)), risk: .reversible, confirmation: confirmation))
        }
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        guard let id = prepared.call.arguments["id"]?.nonEmptyString else {
            return .failed(ToolFailure(.invalidArguments, message: "Which reminder should I delete?"))
        }
        let existing = try? await service.reminders(matching: ReminderQuery(includeCompleted: true, limit: 500)).first { $0.id == id }
        do {
            try await service.delete(id: id)
            var undo: UndoPlan?
            if let existing {
                var arguments: JSONValue = ["title": .string(existing.title)]
                if let due = existing.due { arguments["due_iso"] = .string(ISODates.string(due, timeZone: context.temporal.timeZone)) }
                if let notes = existing.notes { arguments["notes"] = .string(notes) }
                undo = UndoPlan(toolName: "create_reminder", arguments: arguments, pastTense: "put the reminder back")
            }
            let title = existing?.title ?? "the reminder"
            return .completed(ActionResult(summary: "Deleted reminder “\(title)”",
                                           speech: SpeechPlan(minimal: "Deleted.", balanced: "Deleted it.", detailed: "Deleted “\(title)”."),
                                           undo: undo, data: ["deleted": .string(id)], earcon: .success))
        } catch {
            return .failed(ToolFailure(.service, message: "I couldn't delete that reminder.", detail: "\(error)", isRetryable: true))
        }
    }
}

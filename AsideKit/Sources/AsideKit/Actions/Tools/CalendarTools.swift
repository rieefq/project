import Foundation

private func calendarAccess(_ service: CalendarService, _ call: ToolCall) async -> ToolOutcome? {
    await Access.ensure(.calendar, call: call, current: { await service.access() }, request: { await service.requestAccess() })
}

private func eventData(_ event: EventRecord, _ context: ExecutionContext) -> JSONValue {
    var data: JSONValue = [
        "id": .string(event.id), "title": .string(event.title),
        "start": .string(ISODates.string(event.start, timeZone: context.temporal.timeZone)),
        "end": .string(ISODates.string(event.end, timeZone: context.temporal.timeZone)),
        "all_day": .bool(event.isAllDay), "attendees": .number(Double(event.attendeeCount)),
    ]
    if let location = event.location { data["location"] = .string(location) }
    return data
}

// MARK: - Schedule

public struct GetScheduleTool: ToolHandler {
    let service: CalendarService

    public init(service: CalendarService) { self.service = service }

    public var spec: ToolSpec {
        ToolSpec(
            name: "get_schedule",
            description: "Read the user's calendar: events in a period (default: the rest of today), the next event, or whether they're free at a time.",
            inputSchema: Schema.object([
                "when": Schema.string("Period or time, e.g. \"tomorrow\", \"this afternoon\", \"Friday at 3\", \"this week\"."),
                "search": Schema.string("Optional words to match in event titles, e.g. \"dentist\"."),
                "next": Schema.boolean("Only the next upcoming (matching) event."),
                "availability": Schema.boolean("Answer whether the user is free during `when`."),
            ]),
            capability: .calendar, risk: .read)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        if let blocked = await calendarAccess(service, prepared.call) { return blocked }
        let arguments = prepared.call.arguments
        let formatter = context.formatter
        let calendar = context.temporal.calendar
        let search = arguments["search"]?.nonEmptyString

        do {
            // Next event
            if arguments["next"]?.boolValue == true {
                let horizon = DateInterval(start: context.now, end: context.now.addingTimeInterval(14 * 86_400))
                var events = try await service.events(in: horizon).filter { !$0.isAllDay && $0.end > context.now }
                if let search { events = TitleMatch.best(events, query: search, title: \.title, threshold: 0.4) }
                events.sort { $0.start < $1.start }
                guard let next = events.first else {
                    let what = search.map { "nothing about \($0)" } ?? "nothing"
                    return .completed(ActionResult(summary: "No upcoming events", speech: SpeechPlan("There's \(what) on your calendar in the next two weeks."),
                                                   earcon: .none, isPersonal: true))
                }
                let inProgress = next.start <= context.now
                let when = inProgress ? "happening now" : formatter.when(next.start, includeTime: true)
                var balanced = "\(next.title.capitalizedFirst), \(when)"
                if !inProgress, next.start.timeIntervalSince(context.now) < 3 * 3_600 {
                    balanced += " — in \(formatter.duration((next.start.timeIntervalSince(context.now) / 60).rounded() * 60))"
                }
                if let location = next.location, !location.isEmpty { balanced += ", at \(location.spokenPrefix(words: 6))" }
                balanced += "."
                return .completed(ActionResult(
                    summary: "Next event: \(next.title)",
                    speech: SpeechPlan(minimal: "\(next.title.capitalizedFirst), \(when).", balanced: balanced, detailed: balanced),
                    card: .agenda(AgendaCard(heading: "Next", items: [AgendaCard.Item(time: formatter.when(next.start, includeTime: true).capitalizedFirst,
                                                                                    title: next.title, detail: next.location)])),
                    referent: Referent(kind: .event, id: next.id, title: next.title, date: next.start, hasTime: true),
                    data: eventData(next, context), earcon: .none, isPersonal: true))
            }

            // Interval
            var interval = DateInterval(start: context.now, end: calendar.startOfDay(for: context.parser.addDays(1, to: context.now)))
            var periodPhrase = "today"
            var explicitPeriod = false
            if let when = arguments["when"]?.nonEmptyString, let parsed = context.parser.parse(when, purpose: .query), let range = parsed.interval {
                interval = range
                periodPhrase = when.lowercased().replacingOccurrences(of: "on ", with: "")
                explicitPeriod = true
            }
            if interval.end <= context.now {
                // A past window ("this morning" at 3pm) — still answer about it.
            } else if interval.start < context.now && calendar.isDate(interval.start, inSameDayAs: context.now) && !explicitPeriod {
                interval = DateInterval(start: context.now, end: interval.end)
            }
            var events = try await service.events(in: interval)
            if let search { events = TitleMatch.best(events, query: search, title: \.title, threshold: 0.4) }
            events.sort { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }

            if arguments["availability"]?.boolValue == true {
                let busy = events.filter { !$0.isAllDay }
                if busy.isEmpty {
                    return .completed(ActionResult(summary: "Free \(periodPhrase)", speech: SpeechPlan("You're free \(periodPhrase)."),
                                                   data: ["free": true], earcon: .none, isPersonal: true))
                }
                let conflicts = busy.prefix(2).map { "\($0.title.lowercasedFirst) at \(formatter.time($0.start))" }
                return .completed(ActionResult(summary: "Busy \(periodPhrase)",
                                               speech: SpeechPlan("No — you have \(formatter.list(Array(conflicts)))."),
                                               data: ["free": false, "events": .array(busy.map { eventData($0, context) })],
                                               earcon: .none, isPersonal: true))
            }

            guard !events.isEmpty else {
                var speech = explicitPeriod ? "Nothing on your calendar \(periodPhrase)." : "Nothing else on your calendar today."
                if !explicitPeriod {
                    // Look ahead so "what's on my calendar" late in the day is still useful.
                    let tomorrow = DateInterval(start: calendar.startOfDay(for: context.parser.addDays(1, to: context.now)),
                                                end: calendar.startOfDay(for: context.parser.addDays(2, to: context.now)))
                    if let first = try await service.events(in: tomorrow).filter({ !$0.isAllDay }).sorted(by: { $0.start < $1.start }).first {
                        speech += " Tomorrow starts with \(first.title.lowercasedFirst) at \(formatter.time(first.start))."
                    }
                }
                return .completed(ActionResult(summary: "No events \(periodPhrase)", speech: SpeechPlan(speech), data: ["events": []],
                                               earcon: .none, isPersonal: true))
            }

            let multiDay = interval.duration > 86_400 + 3_600
            func describe(_ event: EventRecord) -> String {
                if event.isAllDay { return "\(event.title.lowercasedFirst) all day" + (multiDay ? " \(formatter.day(event.start))" : "") }
                let time = multiDay ? formatter.when(event.start, includeTime: true).replacingOccurrences(of: "on ", with: "") : formatter.time(event.start)
                return "\(event.title.lowercasedFirst) at \(time)"
            }
            let count = events.count
            let header = explicitPeriod ? periodPhrase.capitalizedFirst : "Today"
            let balanced: String
            if count == 1 {
                balanced = "\(header) you have \(describe(events[0]))."
            } else if count <= 4 {
                balanced = "\(header) you have \(formatter.count(count)) things: \(formatter.list(events.map(describe)))."
            } else {
                let timed = events.filter { !$0.isAllDay }
                let firstTimed = timed.first.map(describe) ?? describe(events[0])
                let last = timed.last.map { " The last one ends at \(formatter.time($0.end))." } ?? ""
                balanced = "\(header) you have \(count) events, starting with \(firstTimed).\(last)"
            }
            let minimal = count == 1 ? describe(events[0]).capitalizedFirst + "." : "\(formatter.count(count).capitalizedFirst) events, first \(describe(events[0]))."
            let card = Card.agenda(AgendaCard(heading: header, items: events.prefix(8).map { event in
                AgendaCard.Item(time: event.isAllDay ? "All day" : (multiDay ? formatter.when(event.start, includeTime: true).replacingOccurrences(of: "on ", with: "").capitalizedFirst : formatter.time(event.start)),
                                title: event.title, detail: event.location)
            }))
            return .completed(ActionResult(
                summary: "Read \(count) events for \(periodPhrase)",
                speech: SpeechPlan(minimal: minimal, balanced: balanced, detailed: balanced),
                card: card,
                referent: count == 1 ? Referent(kind: .event, id: events[0].id, title: events[0].title, date: events[0].start, hasTime: !events[0].isAllDay) : nil,
                data: ["events": .array(events.prefix(25).map { eventData($0, context) })],
                earcon: .none, isPersonal: true))
        } catch {
            return .failed(ToolFailure(.service, message: "I couldn't read your calendar.", detail: "\(error)", isRetryable: true))
        }
    }
}

// MARK: - Create

public struct CreateEventTool: ToolHandler {
    let service: CalendarService

    public init(service: CalendarService) { self.service = service }

    public var spec: ToolSpec {
        ToolSpec(
            name: "create_event",
            description: "Add an event to the user's own calendar. Does not invite anyone.",
            inputSchema: Schema.object([
                "title": Schema.string("Event title."),
                "when": Schema.when,
                "start_iso": Schema.string("Optional ISO 8601 local start, used only if `when` can't be interpreted."),
                "duration_minutes": Schema.number("Length in minutes. Defaults to 60."),
                "location": Schema.string("Optional location."),
                "all_day": Schema.boolean("All-day event."),
            ], required: ["title"]),
            capability: .calendar, risk: .reversible)
    }

    public func prepare(_ call: ToolCall, in context: ExecutionContext) async -> Preparation {
        guard let title = call.arguments["title"]?.nonEmptyString else {
            return .outcome(.needsInfo(SlotRequest(prompt: "What's the event called?", parameter: "title", kind: .text, call: call)))
        }
        if let blocked = await calendarAccess(service, call) { return .outcome(blocked) }
        switch ResolvedWhen.from(call.arguments, context: context) {
        case .none, .some(.none):
            return .outcome(.needsInfo(SlotRequest(prompt: "When is it?", parameter: "when", kind: .dateTime, call: call.with("when", nil))))
        case .some(.some(let when)):
            if when.isInPast {
                return .outcome(.needsInfo(SlotRequest(prompt: "That time has passed. When is it?", parameter: "when", kind: .dateTime, call: call.with("when", nil))))
            }
            let normalized = call.with("title", .string(title.capitalizedFirst))
                .with("resolved_start", .string(ISODates.string(when.date, timeZone: context.temporal.timeZone)))
            return .ready(PreparedCall(call: normalized, risk: .reversible,
                                       idempotencyKey: "create_event:\(title.lowercased()):\(ISODates.string(when.date, timeZone: context.temporal.timeZone))",
                                       dedupeAcrossTurns: true))
        }
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let arguments = prepared.call.arguments
        guard let startText = arguments["resolved_start"]?.stringValue,
              let start = ISODates.parse(startText, timeZone: context.temporal.timeZone)?.date else {
            return .failed(ToolFailure(.invalidArguments, message: "I didn't catch when that is."))
        }
        let title = arguments["title"]?.nonEmptyString ?? "Event"
        let allDay = arguments["all_day"]?.boolValue ?? false
        let minutes = arguments["duration_minutes"]?.doubleValue ?? 60
        let calendar = context.temporal.calendar
        let eventStart = allDay ? calendar.startOfDay(for: start) : start
        let end = allDay ? context.parser.addDays(1, to: eventStart) : eventStart.addingTimeInterval(max(5, minutes) * 60)
        do {
            let conflicts = (try? await service.events(in: DateInterval(start: eventStart, end: end)))?.filter { !$0.isAllDay } ?? []
            let event = try await service.create(EventDraft(title: title, start: eventStart, end: end, isAllDay: allDay,
                                                            location: arguments["location"]?.nonEmptyString))
            let when = allDay ? context.formatter.when(eventStart, includeTime: false) : context.formatter.when(eventStart, includeTime: true)
            var balanced = "Added \(title.lowercasedFirst) \(when)."
            if let conflict = conflicts.first { balanced += " Heads up, it overlaps with \(conflict.title.lowercasedFirst)." }
            return .completed(ActionResult(
                summary: "Created event “\(event.title)” at \(ISODates.string(event.start, timeZone: context.temporal.timeZone))",
                speech: SpeechPlan(minimal: conflicts.isEmpty ? "Added." : "Added — it overlaps with \(conflicts[0].title.lowercasedFirst).",
                                   balanced: balanced,
                                   detailed: balanced.replacingOccurrences(of: when, with: context.formatter.when(eventStart, includeTime: !allDay, includeWeekday: true))),
                card: .agenda(AgendaCard(heading: "Added", items: [AgendaCard.Item(time: when.capitalizedFirst, title: event.title, detail: event.location)])),
                undo: UndoPlan(toolName: "delete_event", arguments: ["id": .string(event.id), "quiet": true], pastTense: "removed the event"),
                referent: Referent(kind: .event, id: event.id, title: event.title, date: event.start, hasTime: !allDay),
                data: eventData(event, context), earcon: .success))
        } catch {
            return .failed(ToolFailure(.service, message: "I couldn't add that to your calendar.", detail: "\(error)", isRetryable: true))
        }
    }
}

// MARK: - Find helper

private func findEvent(_ service: CalendarService, arguments: JSONValue, context: ExecutionContext, call: ToolCall) async -> Lookup<EventRecord> {
    let window = DateInterval(start: context.parser.addDays(-1, to: context.now), end: context.parser.addDays(60, to: context.now))
    let events: [EventRecord]
    do { events = try await service.events(in: window) } catch {
        return .outcome(.failed(ToolFailure(.service, message: "I couldn't read your calendar.", detail: "\(error)", isRetryable: true)))
    }
    if let id = arguments["id"]?.nonEmptyString {
        if let match = events.first(where: { $0.id == id }) { return .found(match) }
        return .outcome(.failed(ToolFailure(.notFound, message: "I couldn't find that event anymore.")))
    }
    if arguments["search"]?.nonEmptyString == nil, let referent = context.lastReferent, referent.kind == .event,
       let match = events.first(where: { $0.id == referent.id }) {
        return .found(match)
    }
    guard let search = arguments["search"]?.nonEmptyString else {
        return .outcome(.needsInfo(SlotRequest(prompt: "Which event?", parameter: "search", kind: .text, call: call)))
    }
    let upcoming = events.filter { $0.end > context.now }
    let matches = TitleMatch.best(upcoming, query: search, title: \.title).sorted { $0.start < $1.start }
    switch matches.count {
    case 0: return .outcome(.failed(ToolFailure(.notFound, message: "I couldn't find \(search) on your calendar.")))
    case 1: return .found(matches[0])
    default:
        let options = matches.prefix(3).map { ChoiceOption(label: $0.title, detail: context.formatter.when($0.start, includeTime: !$0.isAllDay), value: .string($0.id)) }
        return .outcome(.needsChoice(ChoiceRequest(prompt: "Which one — \(context.formatter.list(options.map { "\($0.label) \($0.detail ?? "")" }, conjunction: "or"))?",
                                                   options: Array(options), parameter: "id", call: call)))
    }
}

// MARK: - Update

public struct UpdateEventTool: ToolHandler {
    let service: CalendarService

    public init(service: CalendarService) { self.service = service }

    public var spec: ToolSpec {
        ToolSpec(
            name: "update_event",
            description: "Move or rename an event on the user's calendar. Events with other attendees need the user's confirmation because attendees are notified.",
            inputSchema: Schema.object([
                "id": Schema.string("Event id, if known."),
                "search": Schema.string("Words from the event title."),
                "when": Schema.string("New start, e.g. \"tomorrow at 4\"."),
                "start_iso": Schema.string("Optional ISO 8601 local start, used only if `when` can't be interpreted."),
                "title": Schema.string("New title."),
                "duration_minutes": Schema.number("New length in minutes."),
            ]),
            capability: .calendar, risk: .reversible)
    }

    public func prepare(_ call: ToolCall, in context: ExecutionContext) async -> Preparation {
        if let blocked = await calendarAccess(service, call) { return .outcome(blocked) }
        switch await findEvent(service, arguments: call.arguments, context: context, call: call) {
        case .outcome(let outcome):
            return .outcome(outcome)
        case .found(let event):
            var resolved = call.with("id", .string(event.id)).with("search", nil)
            var newStart: Date?
            if case .some(.some(let when)) = ResolvedWhen.from(call.arguments, context: context) {
                var date = when.date
                if !when.hasTime {
                    let calendar = context.temporal.calendar
                    date = context.parser.at(date, hour: calendar.component(.hour, from: event.start), minute: calendar.component(.minute, from: event.start))
                }
                newStart = date
                resolved = resolved.with("resolved_start", .string(ISODates.string(date, timeZone: context.temporal.timeZone)))
            }
            let risk: RiskTier = event.attendeeCount > 0 ? .consequential : .reversible
            let change = newStart.map { "Moves it to \(context.formatter.when($0, includeTime: true))" } ?? "Renames it"
            let details = ConfirmationDetails(
                title: "Change event", subject: event.title,
                detail: newStart.map { context.formatter.when($0, includeTime: true, includeWeekday: true).capitalizedFirst },
                consequence: "\(change). \(event.attendeeCount) attendee\(event.attendeeCount == 1 ? "" : "s") will be notified.",
                prompt: "\(event.title) has other people on it — they'll be notified. Make the change?", confirmLabel: "Update")
            return .ready(PreparedCall(call: resolved, risk: risk, confirmation: event.attendeeCount > 0 ? details : nil))
        }
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let arguments = prepared.call.arguments
        guard let id = arguments["id"]?.nonEmptyString,
              case .found(let event) = await findEvent(service, arguments: ["id": .string(id)], context: context, call: prepared.call) else {
            return .failed(ToolFailure(.notFound, message: "I couldn't find that event anymore."))
        }
        var patch = EventPatch()
        if let title = arguments["title"]?.nonEmptyString { patch.title = title }
        if let startText = arguments["resolved_start"]?.stringValue, let start = ISODates.parse(startText, timeZone: context.temporal.timeZone)?.date {
            patch.start = start
            let length = arguments["duration_minutes"]?.doubleValue.map { $0 * 60 } ?? event.end.timeIntervalSince(event.start)
            patch.end = start.addingTimeInterval(length)
        } else if let minutes = arguments["duration_minutes"]?.doubleValue {
            patch.end = event.start.addingTimeInterval(minutes * 60)
        }
        do {
            let updated = try await service.update(id: id, with: patch)
            let when = context.formatter.destination(updated.start, includeTime: !updated.isAllDay)
            var undoArguments: JSONValue = ["id": .string(id), "title": .string(event.title),
                                            "start_iso": .string(ISODates.string(event.start, timeZone: context.temporal.timeZone))]
            undoArguments["duration_minutes"] = .number(event.end.timeIntervalSince(event.start) / 60)
            return .completed(ActionResult(
                summary: "Updated event “\(updated.title)” to \(ISODates.string(updated.start, timeZone: context.temporal.timeZone))",
                speech: SpeechPlan(minimal: "Moved.", balanced: patch.start != nil ? "Moved \(updated.title.lowercasedFirst) to \(when)." : "Updated \(updated.title.lowercasedFirst).",
                                   detailed: nil),
                undo: event.attendeeCount == 0 ? UndoPlan(toolName: "update_event", arguments: undoArguments, pastTense: "moved it back") : nil,
                referent: Referent(kind: .event, id: updated.id, title: updated.title, date: updated.start, hasTime: !updated.isAllDay),
                data: eventData(updated, context), earcon: .success))
        } catch {
            return .failed(ToolFailure(.service, message: "I couldn't change that event.", detail: "\(error)", isRetryable: true))
        }
    }
}

// MARK: - Delete

public struct DeleteEventTool: ToolHandler {
    let service: CalendarService

    public init(service: CalendarService) { self.service = service }

    public var spec: ToolSpec {
        ToolSpec(
            name: "delete_event",
            description: "Delete an event from the user's calendar. Always confirms with the user first unless it was just created by mistake.",
            inputSchema: Schema.object([
                "id": Schema.string("Event id, if known."),
                "search": Schema.string("Words from the event title."),
            ]),
            capability: .calendar, risk: .consequential)
    }

    public func prepare(_ call: ToolCall, in context: ExecutionContext) async -> Preparation {
        if let blocked = await calendarAccess(service, call) { return .outcome(blocked) }
        switch await findEvent(service, arguments: call.arguments, context: context, call: call) {
        case .outcome(let outcome):
            return .outcome(outcome)
        case .found(let event):
            let resolved = call.with("id", .string(event.id)).with("search", nil)
            // Undoing something Aside just created doesn't need a second confirmation.
            if call.arguments["quiet"]?.boolValue == true && context.origin == .undo {
                return .ready(PreparedCall(call: resolved, risk: .reversible))
            }
            let attendees = event.attendeeCount > 0 ? " Attendees will be told it's cancelled." : ""
            let details = ConfirmationDetails(
                title: "Delete event", subject: event.title,
                detail: context.formatter.when(event.start, includeTime: !event.isAllDay, includeWeekday: true).capitalizedFirst,
                consequence: "Removes it from your calendar.\(attendees)",
                prompt: "Delete \(event.title.lowercasedFirst) \(context.formatter.when(event.start, includeTime: !event.isAllDay))?",
                confirmLabel: "Delete", isDestructive: true, minimumStrength: .tap)
            return .ready(PreparedCall(call: resolved, risk: event.attendeeCount > 0 ? .consequential : .reversible,
                                       confirmation: event.attendeeCount > 0 ? details : ConfirmationDetails(
                                        title: details.title, subject: details.subject, detail: details.detail, consequence: details.consequence,
                                        prompt: details.prompt, confirmLabel: details.confirmLabel, isDestructive: true, minimumStrength: .voice)))
        }
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        guard let id = prepared.call.arguments["id"]?.nonEmptyString,
              case .found(let event) = await findEvent(service, arguments: ["id": .string(id)], context: context, call: prepared.call) else {
            return .failed(ToolFailure(.notFound, message: "I couldn't find that event anymore."))
        }
        do {
            try await service.delete(id: id)
            var undo: UndoPlan?
            if event.attendeeCount == 0 {
                var arguments: JSONValue = ["title": .string(event.title),
                                            "start_iso": .string(ISODates.string(event.start, timeZone: context.temporal.timeZone)),
                                            "duration_minutes": .number(event.end.timeIntervalSince(event.start) / 60),
                                            "all_day": .bool(event.isAllDay)]
                if let location = event.location { arguments["location"] = .string(location) }
                undo = UndoPlan(toolName: "create_event", arguments: arguments, pastTense: "put the event back")
            }
            return .completed(ActionResult(summary: "Deleted event “\(event.title)”",
                                           speech: SpeechPlan(minimal: "Deleted.", balanced: "Deleted \(event.title.lowercasedFirst).", detailed: nil),
                                           undo: undo, data: ["deleted": .string(id)], earcon: .success))
        } catch {
            return .failed(ToolFailure(.service, message: "I couldn't delete that event.", detail: "\(error)", isRetryable: true))
        }
    }
}

import EventKit
import Foundation
import AsideKit

/// Shared EventKit store. EventKit objects stay inside these adapters.
final class EventStoreProvider: @unchecked Sendable {
    static let shared = EventStoreProvider()
    let store = EKEventStore()
}

private func accessState(_ status: EKAuthorizationStatus) -> AccessState {
    switch status {
    case .fullAccess: return .granted
    case .notDetermined: return .notDetermined
    case .writeOnly, .denied, .restricted: return .denied
    @unknown default: return .denied
    }
}

// MARK: - Reminders

final class EventKitReminders: RemindersService, @unchecked Sendable {
    private var store: EKEventStore { EventStoreProvider.shared.store }

    func access() async -> AccessState { accessState(EKEventStore.authorizationStatus(for: .reminder)) }

    func requestAccess() async -> AccessState {
        _ = try? await store.requestFullAccessToReminders()
        return await access()
    }

    func create(_ draft: ReminderDraft) async throws -> ReminderRecord {
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due = draft.due {
            reminder.dueDateComponents = components(for: due, includeTime: draft.hasTime)
            if draft.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        if let rule = draft.recurrence { reminder.addRecurrenceRule(Self.rule(rule)) }
        try store.save(reminder, commit: true)
        return record(reminder)
    }

    func update(id: String, with patch: ReminderPatch) async throws -> ReminderRecord {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ToolFailure(.notFound, message: "I couldn't find that reminder anymore.")
        }
        if let title = patch.title { reminder.title = title }
        if let due = patch.due {
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
            if let due {
                let hasTime = patch.hasTime ?? true
                reminder.dueDateComponents = components(for: due, includeTime: hasTime)
                if hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
            } else {
                reminder.dueDateComponents = nil
            }
        }
        if let recurrence = patch.recurrence {
            reminder.recurrenceRules?.forEach { reminder.removeRecurrenceRule($0) }
            if let recurrence { reminder.addRecurrenceRule(Self.rule(recurrence)) }
        }
        try store.save(reminder, commit: true)
        return record(reminder)
    }

    func setCompleted(id: String, _ completed: Bool) async throws -> ReminderRecord {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ToolFailure(.notFound, message: "I couldn't find that reminder anymore.")
        }
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
        return record(reminder)
    }

    func delete(id: String) async throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }

    func reminders(matching query: ReminderQuery) async throws -> [ReminderRecord] {
        let predicate: NSPredicate
        if query.includeCompleted {
            predicate = store.predicateForReminders(in: nil)
        } else {
            predicate = store.predicateForIncompleteReminders(withDueDateStarting: query.dueAfter, ending: query.dueBefore, calendars: nil)
        }
        let records: [ReminderRecord] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let mapped = (reminders ?? []).map { self.record($0) }
                continuation.resume(returning: mapped)
            }
        }
        var result = records
        if let text = query.text?.lowercased(), !text.isEmpty {
            result = result.filter { $0.title.lowercased().contains(text) }
        }
        return Array(result.prefix(query.limit))
    }

    // MARK: Mapping

    private func components(for date: Date, includeTime: Bool) -> DateComponents {
        var calendar = Calendar.current
        calendar.timeZone = .current
        var components = calendar.dateComponents(includeTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: date)
        components.timeZone = .current
        return components
    }

    private func record(_ reminder: EKReminder) -> ReminderRecord {
        let components = reminder.dueDateComponents
        let due = components.flatMap { Calendar.current.date(from: $0) }
        return ReminderRecord(id: reminder.calendarItemIdentifier, title: reminder.title ?? "", notes: reminder.notes, due: due,
                              hasTime: components?.hour != nil, isCompleted: reminder.isCompleted, listName: reminder.calendar?.title,
                              recurrence: reminder.recurrenceRules?.first.flatMap(Self.recurrence))
    }

    static func rule(_ rule: RecurrenceRule) -> EKRecurrenceRule {
        switch rule.frequency {
        case .daily:
            return EKRecurrenceRule(recurrenceWith: .daily, interval: rule.interval, end: nil)
        case .weekly:
            let days = rule.weekdays.compactMap { EKWeekday(rawValue: $0) }.map { EKRecurrenceDayOfWeek($0) }
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: rule.interval, daysOfTheWeek: days.isEmpty ? nil : days,
                                    daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
        case .monthly:
            return EKRecurrenceRule(recurrenceWith: .monthly, interval: rule.interval, end: nil)
        case .yearly:
            return EKRecurrenceRule(recurrenceWith: .yearly, interval: rule.interval, end: nil)
        }
    }

    static func recurrence(_ rule: EKRecurrenceRule) -> RecurrenceRule? {
        let weekdays = rule.daysOfTheWeek?.map { $0.dayOfTheWeek.rawValue } ?? []
        switch rule.frequency {
        case .daily: return RecurrenceRule(frequency: .daily, interval: rule.interval)
        case .weekly: return RecurrenceRule(frequency: .weekly, interval: rule.interval, weekdays: weekdays)
        case .monthly: return RecurrenceRule(frequency: .monthly, interval: rule.interval)
        case .yearly: return RecurrenceRule(frequency: .yearly, interval: rule.interval)
        @unknown default: return nil
        }
    }
}

// MARK: - Calendar

final class EventKitCalendar: CalendarService, @unchecked Sendable {
    private var store: EKEventStore { EventStoreProvider.shared.store }

    func access() async -> AccessState { accessState(EKEventStore.authorizationStatus(for: .event)) }

    func requestAccess() async -> AccessState {
        _ = try? await store.requestFullAccessToEvents()
        return await access()
    }

    func events(in interval: DateInterval) async throws -> [EventRecord] {
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate).map(record)
    }

    func create(_ draft: EventDraft) async throws -> EventRecord {
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.location = draft.location
        event.notes = draft.notes
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        return record(event)
    }

    func update(id: String, with patch: EventPatch) async throws -> EventRecord {
        guard let event = store.event(withIdentifier: id) else {
            throw ToolFailure(.notFound, message: "I couldn't find that event anymore.")
        }
        if let title = patch.title { event.title = title }
        if let start = patch.start { event.startDate = start }
        if let end = patch.end { event.endDate = end }
        if let location = patch.location { event.location = location }
        try store.save(event, span: .thisEvent, commit: true)
        return record(event)
    }

    func delete(id: String) async throws {
        guard let event = store.event(withIdentifier: id) else { return }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    private func record(_ event: EKEvent) -> EventRecord {
        let others = (event.attendees ?? []).filter { !$0.isCurrentUser }.count
        return EventRecord(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Event", start: event.startDate, end: event.endDate,
                           isAllDay: event.isAllDay, location: event.location, calendarName: event.calendar?.title, attendeeCount: others)
    }
}

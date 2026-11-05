import Foundation
@testable import AsideKit

/// Thursday, November 5, 2026, 2:30 PM in Los Angeles.
let referenceNow: Date = {
    var components = DateComponents()
    components.year = 2026; components.month = 11; components.day = 5; components.hour = 14; components.minute = 30
    return testCalendar.date(from: components)!
}()

let testCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    calendar.locale = Locale(identifier: "en_US")
    calendar.firstWeekday = 1
    return calendar
}()

let testTemporal = TemporalContext(calendar: testCalendar, locale: Locale(identifier: "en_US"))

func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year; components.month = month; components.day = day; components.hour = hour; components.minute = minute
    return testCalendar.date(from: components)!
}

func testContext(now: Date = referenceNow, origin: CallOrigin = .fastPath, preferences: Preferences = Preferences(),
                 referent: Referent? = nil, utterance: String? = nil) -> ExecutionContext {
    ExecutionContext(now: now, temporal: testTemporal, preferences: preferences, device: DeviceContext(platform: .macOS),
                     origin: origin, lastReferent: referent, utterance: utterance)
}

// MARK: - Services

actor FakeReminders: RemindersService {
    var items: [ReminderRecord] = []
    var state: AccessState = .granted
    var failNextCreate = false
    private var counter = 0

    func access() async -> AccessState { state }
    func requestAccess() async -> AccessState { state == .notDetermined ? .granted : state }

    func create(_ draft: ReminderDraft) async throws -> ReminderRecord {
        if failNextCreate { failNextCreate = false; throw ToolFailure(.service, message: "boom") }
        counter += 1
        let record = ReminderRecord(id: "rem\(counter)", title: draft.title, notes: draft.notes, due: draft.due, hasTime: draft.hasTime,
                                    recurrence: draft.recurrence)
        items.append(record)
        return record
    }

    func update(id: String, with patch: ReminderPatch) async throws -> ReminderRecord {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw ToolFailure(.notFound, message: "missing") }
        if let title = patch.title { items[index].title = title }
        if let due = patch.due { items[index].due = due }
        if let hasTime = patch.hasTime { items[index].hasTime = hasTime }
        return items[index]
    }

    func setCompleted(id: String, _ completed: Bool) async throws -> ReminderRecord {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw ToolFailure(.notFound, message: "missing") }
        items[index].isCompleted = completed
        return items[index]
    }

    func delete(id: String) async throws {
        items.removeAll { $0.id == id }
    }

    func reminders(matching query: ReminderQuery) async throws -> [ReminderRecord] {
        items.filter { (query.includeCompleted || !$0.isCompleted) && (query.dueBefore == nil || ($0.due ?? .distantPast) < query.dueBefore!) }
    }

    func setState(_ newState: AccessState) { state = newState }
    func setFailNextCreate() { failNextCreate = true }
}

actor FakeCalendar: CalendarService {
    var events: [EventRecord] = []
    private var counter = 0

    init(events: [EventRecord] = []) { self.events = events }

    func access() async -> AccessState { .granted }
    func requestAccess() async -> AccessState { .granted }
    func events(in interval: DateInterval) async throws -> [EventRecord] {
        events.filter { $0.end > interval.start && $0.start < interval.end }
    }
    func create(_ draft: EventDraft) async throws -> EventRecord {
        counter += 1
        let event = EventRecord(id: "evt\(counter)", title: draft.title, start: draft.start, end: draft.end, isAllDay: draft.isAllDay, location: draft.location)
        events.append(event)
        return event
    }
    func update(id: String, with patch: EventPatch) async throws -> EventRecord {
        guard let index = events.firstIndex(where: { $0.id == id }) else { throw ToolFailure(.notFound, message: "missing") }
        if let title = patch.title { events[index].title = title }
        if let start = patch.start { events[index].start = start }
        if let end = patch.end { events[index].end = end }
        return events[index]
    }
    func delete(id: String) async throws { events.removeAll { $0.id == id } }
}

actor FakeScheduler: NotificationScheduler {
    var scheduled: [LocalNotification] = []
    func access() async -> AccessState { .granted }
    func requestAccess() async -> AccessState { .granted }
    func schedule(_ notification: LocalNotification) async throws { scheduled.append(notification) }
    func cancel(ids: [String]) async { scheduled.removeAll { ids.contains($0.id) } }
}

actor FakeMusic: MusicService {
    nonisolated let provider: MusicProvider
    var played: [MusicRequest] = []
    var commands: [PlaybackCommand] = []
    var playing: NowPlaying?

    init(provider: MusicProvider) { self.provider = provider }

    func access() async -> AccessState { .granted }
    func requestAccess() async -> AccessState { .granted }
    func play(_ request: MusicRequest) async throws -> PlaybackResult {
        played.append(request)
        playing = NowPlaying(title: request.query.isEmpty ? "Your Mix" : request.query.capitalized, subtitle: "Artist", provider: provider, isPlaying: true)
        return PlaybackResult(title: playing!.title, subtitle: "Artist", kind: request.kind, provider: provider)
    }
    func control(_ command: PlaybackCommand) async throws {
        commands.append(command)
        if command == .pause { playing?.isPlaying = false }
        if command == .resume { playing?.isPlaying = true }
    }
    func nowPlaying() async -> NowPlaying? { playing }
}

actor FakeContacts: ContactsService {
    let contacts: [ContactMatch]
    init(_ contacts: [ContactMatch]) { self.contacts = contacts }
    func access() async -> AccessState { .granted }
    func requestAccess() async -> AccessState { .granted }
    func find(_ name: String) async throws -> [ContactMatch] {
        let lower = name.lowercased()
        return contacts.filter { $0.name.lowercased().contains(lower) || $0.relation?.lowercased() == lower }
    }
}

actor FakeCommunication: CommunicationService {
    var composed: [MessageDraft] = []
    var calls: [ContactHandle] = []
    var result: ComposeResult = .sent
    func canSendMessages() async -> Bool { true }
    func composeMessage(_ draft: MessageDraft) async -> ComposeResult { composed.append(draft); return result }
    func placeCall(to handle: ContactHandle) async throws { calls.append(handle) }
}

final class FakeAuthenticator: DeviceAuthenticator, @unchecked Sendable {
    var answer = true
    var asked = 0
    func authenticate(reason: String) async -> Bool { asked += 1; return answer }
}

// MARK: - Speech I/O

@MainActor
final class FakeSpeechInput: SpeechInput {
    var handler: (@MainActor (SpeechInputEvent) -> Void)?
    var isCapturing = false
    var turns = 0
    var starts = 0

    func start(locale: Locale, events: @escaping @MainActor (SpeechInputEvent) -> Void) async throws {
        handler = events
        isCapturing = true
        starts += 1
    }
    func beginTurn() { turns += 1 }
    func stop() { isCapturing = false }

    func say(_ text: String) {
        handler?(.voiceActivity(true))
        handler?(.transcript(text, isFinal: true))
        handler?(.voiceActivity(false))
    }
}

@MainActor
final class FakeSpeechOutput: SpeechOutput {
    var spoken: [String] = []
    var isSpeaking = false
    var level: Float = 0
    var stops = 0
    var onUtteranceStart: (@MainActor (String) -> Void)?
    /// When true, speech "plays" until `stop()` (to test interruptions).
    var holdUntilStopped = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enqueue(_ utterance: SpokenUtterance) {
        spoken.append(utterance.text)
        if holdUntilStopped { isSpeaking = true }
        onUtteranceStart?(utterance.text)
    }
    func waitUntilFinished() async {
        guard holdUntilStopped, isSpeaking else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func stop() {
        stops += 1
        isSpeaking = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    func pause() {}
    func resume() {}
    func duck(_ ducked: Bool) {}
}

@MainActor
final class FakeEarcons: EarconPlayer {
    var played: [Earcon] = []
    func play(_ earcon: Earcon) { played.append(earcon) }
}

/// A scripted reasoner that issues one tool call and then replies.
actor ScriptedReasoner: Reasoner {
    var script: [(ToolCall?, String)]
    var turns: [String] = []
    var lastOutcome: ToolOutcome?

    init(script: [(ToolCall?, String)]) { self.script = script }

    func respond(to turn: ReasonerTurn, tools: [ToolSpec], executor: ToolExecutor,
                 events: @escaping @Sendable (ReasonerEvent) async -> Void) async throws -> ReasonerResult {
        turns.append(turn.utterance)
        guard !script.isEmpty else { return ReasonerResult(text: "", toolsUsed: []) }
        let (call, reply) = script.removeFirst()
        var used: [String] = []
        if let call {
            used.append(call.name)
            await events(.toolStarted(name: call.name))
            lastOutcome = await executor.resolve(call, externalContent: false)
        }
        if !reply.isEmpty { await events(.speech(reply)) }
        return ReasonerResult(text: reply, toolsUsed: used)
    }

    func reset() async { turns.removeAll() }
}

/// Polls until `condition` holds (or fails after `timeout`).
@MainActor
func eventually(timeout: TimeInterval = 3, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

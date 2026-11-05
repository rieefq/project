import Foundation

/// Decides whether Aside may speak up on its own.
///
/// Proactivity is a privilege, not a feature to maximize: a small daily budget, quiet
/// hours, no repeats, and backing off for good when the user ignores a kind of nudge.
public actor ProactivityLedger {
    public enum Decision: Sendable, Hashable {
        case allowed
        /// Allowed later (after quiet hours).
        case deferred(until: Date)
        case suppressed(String)
    }

    struct State: Codable {
        var sent: [Date] = []
        var sentKeys: [String: Date] = [:]
        var dismissals: [String: Int] = [:]
    }

    private let store: PersistentStore?
    private let key = "proactivity.v1"
    private var state = State()
    private var loaded = false

    public init(store: PersistentStore?) {
        self.store = store
    }

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        if let store, let data = try? await store.load(key), let decoded = try? StoreCoding.decoder().decode(State.self, from: data) {
            state = decoded
        }
    }

    private func persist() async {
        guard let store, let data = try? StoreCoding.encoder().encode(state) else { return }
        try? await store.save(data, for: key)
    }

    /// - Parameter kind: category of nudge ("commitment-followup", "day-preview"); repeated dismissals silence it.
    public func decide(kind: String, key itemKey: String, at date: Date, preferences: Preferences, calendar: Calendar) async -> Decision {
        await ensureLoaded()
        guard preferences.proactiveSuggestions else { return .suppressed("Proactive suggestions are off.") }
        if (state.dismissals[kind] ?? 0) >= 3 { return .suppressed("You've dismissed these before.") }
        if state.sentKeys[itemKey] != nil { return .suppressed("Already sent.") }
        let dayStart = calendar.startOfDay(for: date)
        let today = state.sent.filter { $0 >= dayStart }.count
        if today >= preferences.maxProactiveNotificationsPerDay { return .suppressed("Daily limit reached.") }
        let hour = calendar.component(.hour, from: date)
        let quietStart = preferences.quietHoursStart, quietEnd = preferences.quietHoursEnd
        let inQuiet = quietStart > quietEnd ? (hour >= quietStart || hour < quietEnd) : (hour >= quietStart && hour < quietEnd)
        if inQuiet {
            var resume = calendar.date(bySettingHour: quietEnd, minute: 0, second: 0, of: date) ?? date
            if resume <= date { resume = calendar.date(byAdding: .day, value: 1, to: resume) ?? resume }
            return .deferred(until: resume)
        }
        return .allowed
    }

    public func recordSent(key itemKey: String, at date: Date) async {
        await ensureLoaded()
        state.sent.append(date)
        state.sent = state.sent.filter { date.timeIntervalSince($0) < 7 * 86_400 }
        state.sentKeys[itemKey] = date
        await persist()
    }

    public func recordDismissed(kind: String) async {
        await ensureLoaded()
        state.dismissals[kind, default: 0] += 1
        await persist()
    }

    public func recordEngaged(kind: String) async {
        await ensureLoaded()
        state.dismissals[kind] = 0
        await persist()
    }

    public func reset() async {
        state = State()
        loaded = true
        await persist()
    }
}

/// The platform services Aside can use on this device. Missing ones simply mean the
/// matching tools aren't offered.
public struct AsideServices: Sendable {
    public var reminders: (any RemindersService)?
    public var calendar: (any CalendarService)?
    public var notifications: (any NotificationScheduler)?
    public var music: [any MusicService]
    public var weather: (any WeatherService)?
    public var places: (any PlacesService)?
    public var contacts: (any ContactsService)?
    public var communication: (any CommunicationService)?

    public init(reminders: (any RemindersService)? = nil, calendar: (any CalendarService)? = nil, notifications: (any NotificationScheduler)? = nil,
                music: [any MusicService] = [], weather: (any WeatherService)? = nil, places: (any PlacesService)? = nil,
                contacts: (any ContactsService)? = nil, communication: (any CommunicationService)? = nil) {
        self.reminders = reminders
        self.calendar = calendar
        self.notifications = notifications
        self.music = music
        self.weather = weather
        self.places = places
        self.contacts = contacts
        self.communication = communication
    }
}

/// Assembles the tool set from available services.
public enum Toolbox {
    public struct Assembly: Sendable {
        public var registry: ToolRegistry
        public var timers: TimerCenter?
        public var music: MusicRouter?
        public var engineHandle: EngineHandle
    }

    public static func assemble(services: AsideServices, memory: MemoryStore, preferences: PreferencesStore, store: PersistentStore?) -> Assembly {
        var tools: [any ToolHandler] = [GetTimeTool(), CalculateTool()]
        if let reminders = services.reminders {
            tools += [CreateReminderTool(service: reminders), ListRemindersTool(service: reminders), CompleteReminderTool(service: reminders),
                      UpdateReminderTool(service: reminders), DeleteReminderTool(service: reminders)]
        }
        if let calendar = services.calendar {
            tools += [GetScheduleTool(service: calendar), CreateEventTool(service: calendar), UpdateEventTool(service: calendar), DeleteEventTool(service: calendar)]
        }
        var timers: TimerCenter?
        if let notifications = services.notifications {
            let center = TimerCenter(scheduler: notifications, store: store)
            timers = center
            tools += [StartTimerTool(center: center), ListTimersTool(center: center), CancelTimerTool(center: center), UpdateTimerTool(center: center)]
        }
        var music: MusicRouter?
        if !services.music.isEmpty {
            let router = MusicRouter(services.music)
            music = router
            tools += [PlayMusicTool(router: router), ControlPlaybackTool(router: router), NowPlayingTool(router: router)]
        }
        if let weather = services.weather { tools.append(GetWeatherTool(service: weather)) }
        if let places = services.places {
            tools += [FindPlacesTool(service: places), TravelTimeTool(service: places), OpenDirectionsTool(service: places)]
        }
        if let contacts = services.contacts, let communication = services.communication {
            tools += [SendMessageTool(contacts: contacts, communication: communication), CallContactTool(contacts: contacts, communication: communication)]
        }
        tools += [SaveNoteTool(memory: memory), RecallTool(memory: memory), ForgetTool(memory: memory), RestoreMemoryTool(memory: memory),
                  SetPreferenceTool(preferences: preferences)]
        let handle = EngineHandle()
        tools.append(UndoTool(handle: handle))
        return Assembly(registry: ToolRegistry(tools), timers: timers, music: music, engineHandle: handle)
    }
}

import Foundation

// Service protocols are the seam between Aside's logic and the operating system.
// The apps implement them with EventKit, MusicKit, WeatherKit, MapKit, Contacts and
// friends; tests implement them with in-memory fakes. Everything above this line of
// abstraction — parsing, policy, phrasing, undo, journaling — is shared and tested.

// MARK: Reminders

public struct ReminderDraft: Sendable, Hashable {
    public var title: String
    public var notes: String?
    public var due: Date?
    public var hasTime: Bool
    public var recurrence: RecurrenceRule?
    public var listName: String?

    public init(title: String, notes: String? = nil, due: Date? = nil, hasTime: Bool = false, recurrence: RecurrenceRule? = nil, listName: String? = nil) {
        self.title = title
        self.notes = notes
        self.due = due
        self.hasTime = hasTime
        self.recurrence = recurrence
        self.listName = listName
    }
}

public struct ReminderRecord: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var notes: String?
    public var due: Date?
    public var hasTime: Bool
    public var isCompleted: Bool
    public var listName: String?
    public var recurrence: RecurrenceRule?

    public init(id: String, title: String, notes: String? = nil, due: Date? = nil, hasTime: Bool = false, isCompleted: Bool = false,
                listName: String? = nil, recurrence: RecurrenceRule? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.due = due
        self.hasTime = hasTime
        self.isCompleted = isCompleted
        self.listName = listName
        self.recurrence = recurrence
    }
}

public struct ReminderPatch: Sendable, Hashable {
    public var title: String?
    /// `.some(nil)` clears the due date.
    public var due: Date??
    public var hasTime: Bool?
    public var recurrence: RecurrenceRule??

    public init(title: String? = nil, due: Date?? = nil, hasTime: Bool? = nil, recurrence: RecurrenceRule?? = nil) {
        self.title = title
        self.due = due
        self.hasTime = hasTime
        self.recurrence = recurrence
    }
}

public struct ReminderQuery: Sendable, Hashable {
    public var text: String?
    public var dueAfter: Date?
    public var dueBefore: Date?
    public var includeCompleted: Bool
    public var limit: Int

    public init(text: String? = nil, dueAfter: Date? = nil, dueBefore: Date? = nil, includeCompleted: Bool = false, limit: Int = 50) {
        self.text = text
        self.dueAfter = dueAfter
        self.dueBefore = dueBefore
        self.includeCompleted = includeCompleted
        self.limit = limit
    }
}

public protocol RemindersService: Sendable {
    func access() async -> AccessState
    func requestAccess() async -> AccessState
    func create(_ draft: ReminderDraft) async throws -> ReminderRecord
    func update(id: String, with patch: ReminderPatch) async throws -> ReminderRecord
    func setCompleted(id: String, _ completed: Bool) async throws -> ReminderRecord
    func delete(id: String) async throws
    func reminders(matching query: ReminderQuery) async throws -> [ReminderRecord]
}

// MARK: Calendar

public struct EventRecord: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var calendarName: String?
    /// Number of other attendees. Events with attendees involve other people.
    public var attendeeCount: Int

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil,
                calendarName: String? = nil, attendeeCount: Int = 0) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.calendarName = calendarName
        self.attendeeCount = attendeeCount
    }
}

public struct EventDraft: Sendable, Hashable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil, notes: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
    }
}

public struct EventPatch: Sendable, Hashable {
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var location: String?

    public init(title: String? = nil, start: Date? = nil, end: Date? = nil, location: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
    }
}

public protocol CalendarService: Sendable {
    func access() async -> AccessState
    func requestAccess() async -> AccessState
    func events(in interval: DateInterval) async throws -> [EventRecord]
    func create(_ draft: EventDraft) async throws -> EventRecord
    func update(id: String, with patch: EventPatch) async throws -> EventRecord
    func delete(id: String) async throws
}

// MARK: Notifications

public struct LocalNotification: Sendable, Hashable {
    public var id: String
    public var title: String
    public var body: String
    public var fireDate: Date
    public var category: String
    public var isTimeSensitive: Bool
    public var userInfo: [String: String]

    public init(id: String, title: String, body: String, fireDate: Date, category: String, isTimeSensitive: Bool = false, userInfo: [String: String] = [:]) {
        self.id = id
        self.title = title
        self.body = body
        self.fireDate = fireDate
        self.category = category
        self.isTimeSensitive = isTimeSensitive
        self.userInfo = userInfo
    }
}

public protocol NotificationScheduler: Sendable {
    func access() async -> AccessState
    func requestAccess() async -> AccessState
    func schedule(_ notification: LocalNotification) async throws
    func cancel(ids: [String]) async
}

/// Plays the sound for a timer that finishes while Aside is in the foreground.
public protocol TimerAlerting: Sendable {
    func timerFinished(label: String?) async
}

// MARK: Music

public enum MusicKind: String, Sendable, Codable, Hashable, CaseIterable {
    case song, artist, album, playlist, genre, any
}

public struct MusicRequest: Sendable, Hashable {
    public var query: String
    public var kind: MusicKind
    public var shuffle: Bool

    public init(query: String, kind: MusicKind = .any, shuffle: Bool = false) {
        self.query = query
        self.kind = kind
        self.shuffle = shuffle
    }
}

public struct PlaybackResult: Sendable, Hashable {
    public var title: String
    public var subtitle: String?
    public var kind: MusicKind
    public var provider: MusicProvider

    public init(title: String, subtitle: String? = nil, kind: MusicKind, provider: MusicProvider) {
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.provider = provider
    }
}

public enum PlaybackCommand: String, Sendable, Codable, Hashable, CaseIterable {
    case pause, resume, next, previous
}

public struct NowPlaying: Sendable, Hashable {
    public var title: String
    public var subtitle: String?
    public var provider: MusicProvider
    public var isPlaying: Bool

    public init(title: String, subtitle: String?, provider: MusicProvider, isPlaying: Bool) {
        self.title = title
        self.subtitle = subtitle
        self.provider = provider
        self.isPlaying = isPlaying
    }
}

public protocol MusicService: Sendable {
    var provider: MusicProvider { get }
    func access() async -> AccessState
    func requestAccess() async -> AccessState
    func play(_ request: MusicRequest) async throws -> PlaybackResult
    func control(_ command: PlaybackCommand) async throws
    func nowPlaying() async -> NowPlaying?
}

// MARK: Weather

public struct CurrentConditions: Sendable, Hashable, Codable {
    public var temperatureCelsius: Double
    public var apparentCelsius: Double?
    public var condition: String
    public var symbol: String

    public init(temperatureCelsius: Double, apparentCelsius: Double? = nil, condition: String, symbol: String) {
        self.temperatureCelsius = temperatureCelsius
        self.apparentCelsius = apparentCelsius
        self.condition = condition
        self.symbol = symbol
    }
}

public struct DailyForecast: Sendable, Hashable, Codable {
    public var date: Date
    public var highCelsius: Double
    public var lowCelsius: Double
    public var condition: String
    public var symbol: String
    /// 0...1
    public var precipitationChance: Double
    public var precipitationKind: String?

    public init(date: Date, highCelsius: Double, lowCelsius: Double, condition: String, symbol: String, precipitationChance: Double, precipitationKind: String? = nil) {
        self.date = date
        self.highCelsius = highCelsius
        self.lowCelsius = lowCelsius
        self.condition = condition
        self.symbol = symbol
        self.precipitationChance = precipitationChance
        self.precipitationKind = precipitationKind
    }
}

public struct HourlyForecast: Sendable, Hashable, Codable {
    public var date: Date
    public var temperatureCelsius: Double
    public var precipitationChance: Double
    public var condition: String

    public init(date: Date, temperatureCelsius: Double, precipitationChance: Double, condition: String) {
        self.date = date
        self.temperatureCelsius = temperatureCelsius
        self.precipitationChance = precipitationChance
        self.condition = condition
    }
}

public struct WeatherReport: Sendable, Hashable {
    public var placeName: String
    public var current: CurrentConditions?
    public var daily: [DailyForecast]
    public var hourly: [HourlyForecast]
    /// Required data-provider attribution text.
    public var attribution: String?

    public init(placeName: String, current: CurrentConditions?, daily: [DailyForecast], hourly: [HourlyForecast], attribution: String?) {
        self.placeName = placeName
        self.current = current
        self.daily = daily
        self.hourly = hourly
        self.attribution = attribution
    }
}

public protocol WeatherProvider: Sendable {
    func access() async -> AccessState
    func requestAccess() async -> AccessState
    /// Weather for a named place, or the current location when `place` is nil.
    func report(for place: String?) async throws -> WeatherReport
}

// MARK: Places

public struct Place: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var address: String?
    public var latitude: Double
    public var longitude: Double
    public var distanceMeters: Double?
    public var phone: String?

    public init(id: String, name: String, address: String?, latitude: Double, longitude: Double, distanceMeters: Double? = nil, phone: String? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMeters = distanceMeters
        self.phone = phone
    }
}

public enum TravelMode: String, Sendable, Codable, Hashable, CaseIterable {
    case driving, walking, transit
}

public struct TravelEstimate: Sendable, Hashable {
    public var place: Place
    public var mode: TravelMode
    public var seconds: Double
    public var distanceMeters: Double?

    public init(place: Place, mode: TravelMode, seconds: Double, distanceMeters: Double?) {
        self.place = place
        self.mode = mode
        self.seconds = seconds
        self.distanceMeters = distanceMeters
    }
}

public protocol PlacesService: Sendable {
    func access() async -> AccessState
    func requestAccess() async -> AccessState
    func search(_ query: String) async throws -> [Place]
    func travel(to place: Place, mode: TravelMode) async throws -> TravelEstimate
    func openDirections(to place: Place, mode: TravelMode) async throws
}

// MARK: Contacts & communication

public struct ContactHandle: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable { case phone, email }

    public var kind: Kind
    public var value: String
    public var label: String?

    public init(kind: Kind, value: String, label: String? = nil) {
        self.kind = kind
        self.value = value
        self.label = label
    }
}

public struct ContactMatch: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var handles: [ContactHandle]
    /// Relationship the user's card records, e.g. "mother".
    public var relation: String?

    public init(id: String, name: String, handles: [ContactHandle], relation: String? = nil) {
        self.id = id
        self.name = name
        self.handles = handles
        self.relation = relation
    }

    public var primaryPhone: ContactHandle? {
        handles.first { $0.kind == .phone && ($0.label?.lowercased().contains("mobile") ?? false) }
            ?? handles.first { $0.kind == .phone }
    }
}

public protocol ContactsService: Sendable {
    func access() async -> AccessState
    func requestAccess() async -> AccessState
    func find(_ name: String) async throws -> [ContactMatch]
}

public struct MessageDraft: Sendable, Hashable {
    public var recipient: ContactMatch
    public var handle: ContactHandle
    public var body: String

    public init(recipient: ContactMatch, handle: ContactHandle, body: String) {
        self.recipient = recipient
        self.handle = handle
        self.body = body
    }
}

public enum ComposeResult: Sendable, Hashable {
    /// The user sent it from the system sheet.
    case sent
    /// The user cancelled in the system sheet.
    case cancelled
    /// The sheet was presented; the platform doesn't report the outcome.
    case handedOff
    case failed(String)
}

public protocol CommunicationService: Sendable {
    func canSendMessages() async -> Bool
    /// Presents the platform's own compose sheet, pre-filled. The user sends it — Aside never sends silently.
    func composeMessage(_ draft: MessageDraft) async -> ComposeResult
    /// Starts a call through the platform, which asks the user to confirm.
    func placeCall(to handle: ContactHandle) async throws
}

// MARK: Authentication & location

public protocol DeviceAuthenticator: Sendable {
    /// Face ID / Touch ID / passcode / Mac login password.
    func authenticate(reason: String) async -> Bool
}

/// Rough location context for prompts (city-level only).
public protocol LocationContextProvider: Sendable {
    func approximateLocality() async -> String?
}

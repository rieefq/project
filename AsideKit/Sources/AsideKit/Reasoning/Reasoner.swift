import Foundation

/// Runs a tool call to completion on behalf of a model, including any confirmation,
/// clarification or permission step with the user. Returns only final outcomes
/// (`.completed` or `.failed`).
public protocol ToolExecutor: Sendable {
    func resolve(_ call: ToolCall, externalContent: Bool) async -> ToolOutcome
}

/// What a model needs to know about the current turn.
public struct ReasonerTurn: Sendable {
    public var utterance: String
    public var context: ExecutionContext
    public var memories: [MemoryItem]
    public var locality: String?
    public var turnID: String

    public init(utterance: String, context: ExecutionContext, memories: [MemoryItem], locality: String?, turnID: String) {
        self.utterance = utterance
        self.context = context
        self.memories = memories
        self.locality = locality
        self.turnID = turnID
    }
}

public enum ReasonerEvent: Sendable {
    /// A speakable chunk of the reply, emitted as soon as it's complete.
    case speech(String)
    /// The model started using a tool (for "what are you doing?" and the presence state).
    case toolStarted(name: String)
    /// Web sources the answer drew on.
    case sources([SourcesCard.Source])
}

public struct ReasonerResult: Sendable {
    public var text: String
    public var toolsUsed: [String]
    public var refused: Bool

    public init(text: String, toolsUsed: [String], refused: Bool = false) {
        self.text = text
        self.toolsUsed = toolsUsed
        self.refused = refused
    }
}

public enum ReasonerError: Error, Sendable, Hashable {
    case notConfigured
    case offline
    case unauthorized
    case rateLimited
    case unavailable(String)
    case badResponse(String)
    case cancelled

    /// What to say when this happens.
    public var spokenMessage: String {
        switch self {
        case .notConfigured: return "I need a cloud connection set up for that. You can add one in Aside's settings."
        case .offline: return "I can't reach the internet right now, so I can't help with that one."
        case .unauthorized: return "My cloud connection isn't authorized. Check the account in Aside's settings."
        case .rateLimited: return "I'm getting too many requests right now. Try again in a moment."
        case .unavailable: return "My cloud service isn't responding right now. Try again in a moment."
        case .badResponse: return "Something went wrong on my end. Try asking again?"
        case .cancelled: return ""
        }
    }
}

/// A model that can hold a conversation and use tools.
public protocol Reasoner: Sendable {
    func respond(to turn: ReasonerTurn, tools: [ToolSpec], executor: ToolExecutor,
                 events: @escaping @Sendable (ReasonerEvent) async -> Void) async throws -> ReasonerResult
    /// Starts a fresh conversation (after a session ends).
    func reset() async
}

/// Maps an utterance to a local tool call using an on-device model. Implemented in the
/// apps with Apple's Foundation Models framework; nothing leaves the device.
public protocol LocalIntentModel: Sendable {
    var isAvailable: Bool { get async }
    func interpret(_ utterance: String, context: ExecutionContext) async -> IntentFrame?
}

/// The on-device model's structured reading of a request. Field values are the user's
/// own words; Aside's parsers do all date arithmetic.
public struct IntentFrame: Sendable, Hashable {
    public enum Action: String, Sendable, CaseIterable {
        case createReminder = "create_reminder"
        case listReminders = "list_reminders"
        case getSchedule = "get_schedule"
        case createEvent = "create_event"
        case startTimer = "start_timer"
        case playMusic = "play_music"
        case controlPlayback = "control_playback"
        case getWeather = "get_weather"
        case sendMessage = "send_message"
        case callContact = "call_contact"
        case findPlaces = "find_places"
        case travelTime = "get_travel_time"
        case saveNote = "save_note"
        case recall
        case none
    }

    public var action: Action
    /// Main subject: reminder/event title, music query, place, note text, recipient.
    public var subject: String?
    /// When, in the user's words.
    public var when: String?
    /// Secondary detail: message body, duration, music service, playback action.
    public var detail: String?

    public init(action: Action, subject: String? = nil, when: String? = nil, detail: String? = nil) {
        self.action = action
        self.subject = subject
        self.when = when
        self.detail = detail
    }

    /// Converts the frame into a tool call the engine understands, or nil when incomplete.
    public func toolCall(turnID: String) -> ToolCall? {
        func clean(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
                  !["none", "null", "n/a", "nil"].contains(trimmed.lowercased()) else { return nil }
            return trimmed
        }
        let subject = clean(self.subject)
        let when = clean(self.when)
        let detail = clean(self.detail)
        var arguments: JSONValue = [:]
        switch action {
        case .none:
            return nil
        case .createReminder:
            guard let subject else { return nil }
            arguments = ["title": .string(subject)]
            if let when { arguments["when"] = .string(when) }
        case .listReminders:
            if let when { arguments["when"] = .string(when) }
        case .getSchedule:
            if let when { arguments["when"] = .string(when) }
            if let subject { arguments["search"] = .string(subject) }
        case .createEvent:
            guard let subject, let when else { return nil }
            arguments = ["title": .string(subject), "when": .string(when)]
        case .startTimer:
            guard let duration = detail ?? when ?? subject, DurationParser.parse(Utterance(duration).norms, at: 0) != nil else { return nil }
            arguments = ["duration": .string(duration)]
            if let subject, subject != duration { arguments["label"] = .string(subject) }
        case .playMusic:
            arguments = ["query": .string(subject ?? ""), "kind": "any"]
            if let provider = detail.flatMap({ MusicProvider(argument: $0) }) {
                arguments["provider"] = .string(provider == .spotify ? "spotify" : "apple_music")
            }
        case .controlPlayback:
            guard let detail, PlaybackCommand(rawValue: detail.lowercased()) != nil else { return nil }
            arguments = ["action": .string(detail.lowercased())]
        case .getWeather:
            if let subject { arguments["place"] = .string(subject) }
            if let when { arguments["when"] = .string(when) }
        case .sendMessage:
            guard let subject else { return nil }
            arguments = ["recipient": .string(subject)]
            if let detail { arguments["body"] = .string(detail) }
        case .callContact:
            guard let subject else { return nil }
            arguments = ["recipient": .string(subject)]
        case .findPlaces:
            guard let subject else { return nil }
            arguments = ["query": .string(subject)]
        case .travelTime:
            guard let subject else { return nil }
            arguments = ["destination": .string(subject)]
        case .saveNote:
            guard let subject else { return nil }
            arguments = ["text": .string(subject), "kind": "note", "user_asked": true]
        case .recall:
            guard let subject else { return nil }
            arguments = ["query": .string(subject), "fallthrough": true]
        }
        return ToolCall(name: action.rawValue, arguments: arguments, origin: .onDeviceModel, turnID: turnID)
    }
}

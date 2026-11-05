import Foundation

/// How much Aside says.
public enum Verbosity: String, Sendable, Codable, CaseIterable, Hashable {
    /// Sounds and a word or two. Silence when the result is self-evident.
    case minimal
    /// Short, complete sentences. The default.
    case balanced
    /// Fuller explanations.
    case detailed

    public var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .balanced: return "Balanced"
        case .detailed: return "Detailed"
        }
    }
}

/// When personal details may be spoken aloud.
public enum SpeechPrivacy: String, Sendable, Codable, CaseIterable, Hashable {
    /// Speak everything.
    case always
    /// Speak personal details (names, event titles, notes) only through headphones;
    /// on a speaker, give a summary and show the details.
    case headphonesForPersonal
    /// Never speak; show text and use sounds. ("Discreet")
    case discreet

    public var displayName: String {
        switch self {
        case .always: return "Always speak"
        case .headphonesForPersonal: return "Personal details only on headphones"
        case .discreet: return "Discreet (no speech)"
        }
    }
}

/// Tone presets. Personality is expressed through wording and timing, never by pretending to be human.
public enum Personality: String, Sendable, Codable, CaseIterable, Hashable {
    case warm, crisp, playful

    public var displayName: String {
        switch self {
        case .warm: return "Warm"
        case .crisp: return "Crisp"
        case .playful: return "Playful"
        }
    }

    var promptDescription: String {
        switch self {
        case .warm: return "Warm and calm. Friendly without being chatty. Natural contractions."
        case .crisp: return "Crisp and efficient. As few words as possible. No pleasantries."
        case .playful: return "Light and quick-witted, with an occasional gentle bit of humor. Never at the expense of clarity."
        }
    }
}

/// Which model may reason about a request.
public enum ReasoningMode: String, Sendable, Codable, CaseIterable, Hashable {
    /// Only on-device understanding; nothing leaves the device.
    case onDeviceOnly
    /// On-device first; cloud for open questions and multi-step requests.
    case hybrid

    public var displayName: String {
        switch self {
        case .onDeviceOnly: return "On this device only"
        case .hybrid: return "On device, with cloud for harder requests"
        }
    }
}

/// How to treat preferences Aside notices but wasn't told to remember.
public enum LearningMode: String, Sendable, Codable, CaseIterable, Hashable {
    /// Only remember what the user explicitly asks Aside to remember.
    case explicitOnly
    /// Ask before remembering something noticed.
    case askFirst

    public var displayName: String {
        switch self {
        case .explicitOnly: return "Only when I ask"
        case .askFirst: return "Ask before remembering"
        }
    }
}

/// All user preferences. Sensible defaults mean nothing needs configuring before first use.
public struct Preferences: Sendable, Codable, Hashable {
    // Voice & personality
    public var voiceIdentifier: String?
    public var speechRate: Double = 0.52
    public var speechVolume: Double = 1.0
    public var personality: Personality = .warm
    public var verbosity: Verbosity = .balanced
    public var speechPrivacy: SpeechPrivacy = .always
    public var customInstructions: String = ""
    public var preferredName: String?

    // Interaction
    public var showLiveCaption: Bool = true
    public var playEarcons: Bool = true
    /// Keep listening after Aside asks a question.
    public var autoListenAfterQuestions: Bool = true
    /// Stay in conversation until dismissed (instead of one request per activation).
    public var conversationMode: Bool = false
    public var allowInterruptions: Bool = true

    // Reasoning
    public var reasoningMode: ReasoningMode = .hybrid
    public var cloudModel: String = "claude-opus-5-5"
    public var allowWebSearch: Bool = true
    public var useOnDeviceModel: Bool = true

    // Memory
    public var memoryEnabled: Bool = true
    public var learningMode: LearningMode = .askFirst

    // Proactivity
    public var proactiveSuggestions: Bool = true
    public var maxProactiveNotificationsPerDay: Int = 3
    public var quietHoursStart: Int = 22
    public var quietHoursEnd: Int = 7

    // Integrations
    public var preferredMusicProvider: MusicProvider?
    public var temporalDefaults = TemporalDefaults()
    public var usesMetricUnits: Bool?

    // Activity
    public var journalRetentionDays: Int = 30

    public init() {}

    public static let `default` = Preferences()
}

public enum MusicProvider: String, Sendable, Codable, CaseIterable, Hashable {
    case appleMusic, spotify

    public var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }
}

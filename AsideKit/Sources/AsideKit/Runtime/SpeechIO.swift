import Foundation

/// Events from the speech recognizer and audio front end.
public enum SpeechInputEvent: Sendable, Hashable {
    /// Text heard in the current turn so far (finalized + volatile).
    case transcript(String, isFinal: Bool)
    /// Voice activity from the audio level detector.
    case voiceActivity(Bool)
    /// Smoothed microphone level, 0…1.
    case level(Float)
    /// The audio route changed (headphones connected, Bluetooth, etc.).
    case routeChanged(privateAudio: Bool)
    /// Capture stopped because of the system (a call, Siri, another app) or an error.
    case interrupted(SpeechInputFailure)
}

public enum SpeechInputFailure: Error, Sendable, Hashable {
    case microphoneDenied
    case recognizerUnavailable(String)
    case audioFailure(String)
    case systemInterruption

    public var spokenMessage: String {
        switch self {
        case .microphoneDenied: return "I need microphone access to hear you. You can allow it in Settings."
        case .recognizerUnavailable: return "Speech recognition isn't available right now."
        case .audioFailure: return "Something went wrong with the microphone."
        case .systemInterruption: return ""
        }
    }
}

/// Microphone + recognizer. One capture session spans a conversation (so interruptions
/// work while Aside speaks); `beginTurn()` starts a fresh transcript within it.
@MainActor
public protocol SpeechInput: AnyObject {
    /// Starts capturing. Events arrive until `stop()`.
    func start(locale: Locale, events: @escaping @MainActor (SpeechInputEvent) -> Void) async throws
    /// Clears the transcript so the next words start a new turn.
    func beginTurn()
    /// Stops capturing and turns the microphone off.
    func stop()
    var isCapturing: Bool { get }
}

public struct SpokenUtterance: Sendable, Hashable {
    public var text: String
    public var rate: Double
    public var volume: Double
    public var voiceIdentifier: String?

    public init(text: String, rate: Double, volume: Double, voiceIdentifier: String?) {
        self.text = text
        self.rate = rate
        self.volume = volume
        self.voiceIdentifier = voiceIdentifier
    }
}

/// Speech synthesis. Utterances are queued and played in order.
@MainActor
public protocol SpeechOutput: AnyObject {
    func enqueue(_ utterance: SpokenUtterance)
    /// Suspends until everything queued has played (or speech was stopped).
    func waitUntilFinished() async
    func stop()
    func pause()
    func resume()
    /// Temporarily lowers volume while checking whether the user is interrupting.
    func duck(_ ducked: Bool)
    var isSpeaking: Bool { get }
    /// Current output level 0…1 for the presence animation.
    var level: Float { get }
    /// Called when each queued utterance starts playing.
    var onUtteranceStart: (@MainActor (String) -> Void)? { get set }
}

@MainActor
public protocol EarconPlayer: AnyObject {
    func play(_ earcon: Earcon)
}

/// How the user summoned Aside.
public enum ActivationSource: String, Sendable, Hashable {
    /// Keyboard shortcut held down: listen until released.
    case pushToTalk
    /// Keyboard shortcut tapped, menu bar click, on-screen tap: listen until the user stops talking.
    case tap
    /// App Intent, Action button, Control Center, Siri hand-off.
    case systemIntent
    /// Notification action ("Reply" to a follow-up).
    case notification
}

import Foundation

/// Decides when the user has finished speaking.
///
/// A fixed silence timeout either cuts people off mid-thought or makes every answer
/// feel slow. Aside adapts: a complete, confidently-parsed command ends quickly; a
/// sentence that trails off on "and", "to" or "at" gets more room; nothing heard yet
/// gets a generous start window.
public struct Endpointer: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Silence before ending a normal utterance.
        public var baseSilence: TimeInterval = 0.8
        /// Silence when the transcript already parses as a complete command.
        public var completeSilence: TimeInterval = 0.5
        /// Silence when the transcript ends on a connective ("remind me to…").
        public var danglingSilence: TimeInterval = 1.7
        /// How long to wait for the first word before giving up quietly.
        public var initialTimeout: TimeInterval = 6.0
        /// Hard cap on a single utterance.
        public var maximumDuration: TimeInterval = 30.0

        public init() {}
    }

    public enum Decision: Sendable, Hashable {
        case keepListening
        /// End of turn: process what was heard.
        case endOfTurn
        /// Nothing was said; close quietly.
        case noSpeech
    }

    public var configuration: Configuration
    public private(set) var startedAt: Date
    public private(set) var lastActivityAt: Date?
    public private(set) var transcript: String = ""
    public private(set) var isSpeechActive = false
    /// Set by the caller when the current transcript is a complete, high-confidence command.
    public var transcriptLooksComplete = false

    static let danglingWords: Set<String> = [
        "to", "and", "at", "the", "for", "about", "with", "my", "a", "an", "of", "in", "on", "but", "or", "so",
        "that", "is", "be", "remind", "set", "text", "tell", "call", "play", "add", "put", "by", "from", "into",
        "this", "next", "every", "me", "um", "uh", "like", "then", "if", "when", "because", "saying", "says",
    ]

    public init(configuration: Configuration = Configuration(), startedAt: Date) {
        self.configuration = configuration
        self.startedAt = startedAt
    }

    /// Voice activity from the audio front end.
    public mutating func voiceActivity(_ active: Bool, at time: Date) {
        if active || isSpeechActive { lastActivityAt = time }
        isSpeechActive = active
    }

    /// A new partial or final transcript.
    public mutating func transcriptChanged(_ text: String, at time: Date) {
        if text != transcript {
            transcript = text
            lastActivityAt = time
        }
    }

    /// The silence the current transcript deserves.
    public var requiredSilence: TimeInterval {
        let words = Utterance(transcript).norms
        guard let last = words.last else { return configuration.baseSilence }
        if Self.danglingWords.contains(last) { return configuration.danglingSilence }
        if transcriptLooksComplete { return configuration.completeSilence }
        return configuration.baseSilence
    }

    public func decide(at time: Date) -> Decision {
        if time.timeIntervalSince(startedAt) >= configuration.maximumDuration {
            return transcript.isEmpty ? .noSpeech : .endOfTurn
        }
        guard let lastActivityAt else {
            return time.timeIntervalSince(startedAt) >= configuration.initialTimeout ? .noSpeech : .keepListening
        }
        if isSpeechActive { return .keepListening }
        if transcript.trimmingCharacters(in: .whitespaces).isEmpty {
            // Noise but no words: give the full initial window.
            return time.timeIntervalSince(startedAt) >= configuration.initialTimeout ? .noSpeech : .keepListening
        }
        return time.timeIntervalSince(lastActivityAt) >= requiredSilence ? .endOfTurn : .keepListening
    }
}

/// Rejects recognizer output that is really Aside hearing itself.
///
/// Acoustic echo cancellation removes most of the agent's own voice from the
/// microphone, but not all of it on every speaker. While Aside talks, partial
/// transcripts that are mostly words Aside is currently saying are ignored, so only
/// genuine interruptions stop it.
public struct EchoGuard: Sendable {
    private var spokenWords: [String] = []

    public init() {}

    public mutating func speaking(_ text: String) {
        spokenWords.append(contentsOf: Utterance(text).norms)
        if spokenWords.count > 120 { spokenWords.removeFirst(spokenWords.count - 120) }
    }

    public mutating func reset() { spokenWords.removeAll() }

    /// Fraction of heard words that appear in what Aside is saying.
    public func echoRatio(of heard: String) -> Double {
        let words = Utterance(heard).norms
        guard !words.isEmpty, !spokenWords.isEmpty else { return 0 }
        let spoken = Set(spokenWords)
        let matches = words.filter { spoken.contains($0) }.count
        return Double(matches) / Double(words.count)
    }

    /// True when `heard` should count as the user interrupting.
    public func isGenuineInterruption(_ heard: String) -> Bool {
        let utterance = Utterance(heard)
        if let command = ControlCommandParser.parse(utterance) {
            switch command {
            case .stop, .cancel, .dismiss, .hold, .setDiscreet: return echoRatio(of: heard) < 1 || utterance.count == 1
            default: break
            }
        }
        guard utterance.count >= 2 else { return false }
        return echoRatio(of: heard) < 0.6
    }
}

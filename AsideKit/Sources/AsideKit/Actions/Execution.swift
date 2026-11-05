import Foundation

public enum PlatformKind: String, Sendable, Codable, Hashable {
    case macOS, iOS
}

/// Device facts that change what is appropriate (speaking aloud, unlocking, connectivity).
public struct DeviceContext: Sendable, Hashable {
    public var platform: PlatformKind
    public var isLocked: Bool
    public var usesPrivateAudio: Bool
    public var isOnline: Bool

    public init(platform: PlatformKind, isLocked: Bool = false, usesPrivateAudio: Bool = false, isOnline: Bool = true) {
        self.platform = platform
        self.isLocked = isLocked
        self.usesPrivateAudio = usesPrivateAudio
        self.isOnline = isOnline
    }
}

/// Everything a tool needs to know about the moment it runs in.
public struct ExecutionContext: Sendable {
    public var now: Date
    public var temporal: TemporalContext
    public var preferences: Preferences
    public var device: DeviceContext
    public var origin: CallOrigin
    public var isConfirmed: Bool
    /// What "it" refers to right now.
    public var lastReferent: Referent?
    /// The user's words for this turn.
    public var utterance: String?
    /// Text from outside the user (e.g. web results) entered this turn.
    public var turnHasExternalContent: Bool

    public init(now: Date, temporal: TemporalContext, preferences: Preferences, device: DeviceContext, origin: CallOrigin,
                isConfirmed: Bool = false, lastReferent: Referent? = nil, utterance: String? = nil, turnHasExternalContent: Bool = false) {
        self.now = now
        self.temporal = temporal
        self.preferences = preferences
        self.device = device
        self.origin = origin
        self.isConfirmed = isConfirmed
        self.lastReferent = lastReferent
        self.utterance = utterance
        self.turnHasExternalContent = turnHasExternalContent
    }

    public var formatter: SpokenFormatter { SpokenFormatter(context: temporal, now: now) }

    public var parser: TemporalParser {
        TemporalParser(calendar: temporal.calendar, now: now, defaults: preferences.temporalDefaults, locale: temporal.locale)
    }

    public var usesMetric: Bool {
        if let explicit = preferences.usesMetricUnits { return explicit }
        return temporal.locale.measurementSystem != .us
    }
}

/// Human-readable description shown before a consequential action runs.
public struct ConfirmationDetails: Sendable, Hashable {
    public var title: String
    public var subject: String?
    public var detail: String?
    public var consequence: String
    public var prompt: String
    public var confirmLabel: String
    public var isDestructive: Bool
    public var minimumStrength: ConfirmationStrength

    public init(title: String, subject: String? = nil, detail: String? = nil, consequence: String, prompt: String,
                confirmLabel: String = "Confirm", isDestructive: Bool = false, minimumStrength: ConfirmationStrength = .tap) {
        self.title = title
        self.subject = subject
        self.detail = detail
        self.consequence = consequence
        self.prompt = prompt
        self.confirmLabel = confirmLabel
        self.isDestructive = isDestructive
        self.minimumStrength = minimumStrength
    }
}

/// A validated, normalized call that is ready to run once policy allows it.
public struct PreparedCall: Sendable {
    public var call: ToolCall
    public var risk: RiskTier
    public var confirmation: ConfirmationDetails?
    /// Calls with the same key within the dedupe window are not executed twice.
    public var idempotencyKey: String
    /// The platform shows its own approval UI (message compose sheet, call prompt).
    public var platformConfirms: Bool
    /// Deduplicate across separate turns too (creations), not only within one turn.
    public var dedupeAcrossTurns: Bool

    public init(call: ToolCall, risk: RiskTier, confirmation: ConfirmationDetails? = nil, idempotencyKey: String? = nil,
                platformConfirms: Bool = false, dedupeAcrossTurns: Bool = false) {
        self.call = call
        self.risk = risk
        self.confirmation = confirmation
        self.idempotencyKey = idempotencyKey ?? PreparedCall.key(for: call)
        self.platformConfirms = platformConfirms
        self.dedupeAcrossTurns = dedupeAcrossTurns
    }

    public static func key(for call: ToolCall) -> String {
        "\(call.name):\(call.arguments.serializedString)"
    }
}

public enum Preparation: Sendable {
    case ready(PreparedCall)
    case outcome(ToolOutcome)
}

/// A capability Aside can perform. Tools validate in `prepare` (so confirmations show
/// resolved, exact details) and act in `execute`.
public protocol ToolHandler: Sendable {
    var spec: ToolSpec { get }
    func prepare(_ call: ToolCall, in context: ExecutionContext) async -> Preparation
    func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome
}

extension ToolHandler {
    public func prepare(_ call: ToolCall, in context: ExecutionContext) async -> Preparation {
        .ready(PreparedCall(call: call, risk: spec.risk))
    }
}

/// The set of tools available on this device.
public struct ToolRegistry: Sendable {
    private let handlers: [String: any ToolHandler]
    private let order: [String]

    public init(_ handlers: [any ToolHandler]) {
        var map: [String: any ToolHandler] = [:]
        for handler in handlers { map[handler.spec.name] = handler }
        self.handlers = map
        self.order = map.keys.sorted()
    }

    public func handler(named name: String) -> (any ToolHandler)? { handlers[name] }

    /// Deterministic order keeps model requests byte-stable for prompt caching.
    public var specs: [ToolSpec] { order.compactMap { handlers[$0]?.spec } }

    public var modelSpecs: [ToolSpec] { specs.filter(\.exposedToModels) }

    public func contains(_ name: String) -> Bool { handlers[name] != nil }
}

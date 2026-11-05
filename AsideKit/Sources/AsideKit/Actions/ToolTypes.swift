import Foundation

// MARK: - Risk & capability

/// How consequential an action is. The tier decides whether Aside may act directly.
public enum RiskTier: Int, Sendable, Comparable, Codable {
    /// Reads information only (schedule, weather, notes).
    case read = 0
    /// Changes the user's own data in an undoable way (reminders, timers, notes, playback).
    case reversible = 1
    /// Affects other people or can't be cleanly undone (messages, calls, invitations, deletions).
    case consequential = 2
    /// Money, publishing, account changes. Not performed in this version.
    case restricted = 3

    public static func < (lhs: RiskTier, rhs: RiskTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How the user must approve a consequential action.
public enum ConfirmationStrength: Int, Sendable, Hashable, Codable, Comparable {
    /// A spoken "yes" is enough (low-stakes clarifications such as "should I remember that?").
    case voice = 0
    /// The user must tap Confirm on the card, or approve in the platform's own sheet.
    case tap = 1
    /// Face ID / Touch ID / passcode. Voice is never treated as authentication.
    case deviceAuthentication = 2

    public static func < (lhs: ConfirmationStrength, rhs: ConfirmationStrength) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A functional area, used for permissions, settings and disclosure.
public enum Capability: String, Sendable, Codable, CaseIterable, Hashable {
    case reminders, calendar, timers, music, weather, places, contacts, messages, phone, memory, knowledge, system

    public var displayName: String {
        switch self {
        case .reminders: return "Reminders"
        case .calendar: return "Calendar"
        case .timers: return "Timers"
        case .music: return "Music"
        case .weather: return "Weather"
        case .places: return "Maps & Location"
        case .contacts: return "Contacts"
        case .messages: return "Messages"
        case .phone: return "Calls"
        case .memory: return "Memory"
        case .knowledge: return "Answers"
        case .system: return "Aside"
        }
    }
}

/// Permission state for an integration.
public enum AccessState: String, Sendable, Codable, Hashable {
    case granted, limited, denied, notDetermined, unavailable

    public var isUsable: Bool { self == .granted || self == .limited }
}

// MARK: - Calls

/// Where a tool call came from. Provenance is recorded in the journal and used by policy.
public enum CallOrigin: String, Sendable, Codable, Hashable {
    case fastPath, onDeviceModel, cloudModel, correction, undo, followUp, siri, system
}

public struct ToolCall: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: JSONValue
    public var origin: CallOrigin
    /// The utterance that led to this call (for idempotency and the journal).
    public var turnID: String?

    public init(id: String = Identifier.make("call"), name: String, arguments: JSONValue, origin: CallOrigin, turnID: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.origin = origin
        self.turnID = turnID
    }

    public func with(_ key: String, _ value: JSONValue?) -> ToolCall {
        var copy = self
        copy.arguments = arguments.setting(key, to: value)
        return copy
    }
}

/// Description of a tool for the registry and for model tool definitions.
public struct ToolSpec: Sendable {
    public var name: String
    /// Model-facing description: what it does, when to use it, what it returns.
    public var description: String
    /// JSON Schema for arguments.
    public var inputSchema: JSONValue
    public var capability: Capability
    /// Baseline risk; `prepare` may raise it for specific arguments.
    public var risk: RiskTier
    /// Offered to cloud models. Some tools are internal (e.g. undo plans).
    public var exposedToModels: Bool

    public init(name: String, description: String, inputSchema: JSONValue, capability: Capability, risk: RiskTier, exposedToModels: Bool = true) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.capability = capability
        self.risk = risk
        self.exposedToModels = exposedToModels
    }
}

// MARK: - Outcomes

/// What a tool needs from the user, or what happened.
public enum ToolOutcome: Sendable {
    case completed(ActionResult)
    case needsConfirmation(ConfirmationRequest)
    case needsChoice(ChoiceRequest)
    case needsInfo(SlotRequest)
    case needsPermission(PermissionRequest)
    case failed(ToolFailure)

    public var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

/// Variants of a spoken reply by verbosity.
public struct SpeechPlan: Sendable, Hashable {
    public var minimal: String?
    public var balanced: String?
    public var detailed: String?

    public init(minimal: String? = nil, balanced: String? = nil, detailed: String? = nil) {
        self.minimal = minimal
        self.balanced = balanced
        self.detailed = detailed
    }

    public init(_ text: String?) {
        self.init(minimal: text, balanced: text, detailed: text)
    }

    public static let silent = SpeechPlan(minimal: nil, balanced: nil, detailed: nil)

    public func text(for verbosity: Verbosity) -> String? {
        switch verbosity {
        case .minimal: return minimal
        case .balanced: return balanced ?? minimal
        case .detailed: return detailed ?? balanced ?? minimal
        }
    }
}

/// Something "it" or "that" can refer to in a follow-up ("change it to tomorrow").
public struct Referent: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case reminder, event, timer, note, memory, message, music, place
    }

    public var kind: Kind
    public var id: String
    public var title: String
    public var date: Date?
    public var hasTime: Bool

    public init(kind: Kind, id: String, title: String, date: Date? = nil, hasTime: Bool = false) {
        self.kind = kind
        self.id = id
        self.title = title
        self.date = date
        self.hasTime = hasTime
    }
}

/// How to reverse an action.
public struct UndoPlan: Sendable, Hashable, Codable {
    public var toolName: String
    public var arguments: JSONValue
    /// "removed the reminder", used in "Okay, I removed the reminder."
    public var pastTense: String

    public init(toolName: String, arguments: JSONValue, pastTense: String) {
        self.toolName = toolName
        self.arguments = arguments
        self.pastTense = pastTense
    }
}

/// Sounds Aside uses instead of words when words aren't needed.
public enum Earcon: String, Sendable, Hashable, Codable, CaseIterable {
    case none
    /// Microphone opened.
    case listening
    /// End of the user's turn was detected.
    case heard
    /// An action completed.
    case success
    /// Something was cancelled or dismissed.
    case cancelled
    /// Something failed.
    case failure
    /// Aside needs a decision.
    case attention
    /// Still working (long operations).
    case working
}

public struct ActionResult: Sendable {
    /// Factual summary for the journal and for the model ("Created reminder …").
    public var summary: String
    public var speech: SpeechPlan
    public var card: Card?
    public var undo: UndoPlan?
    public var referent: Referent?
    /// Structured result returned to models.
    public var data: JSONValue
    public var earcon: Earcon
    /// Whether this result contains personal details that shouldn't be spoken on a speaker in discreet mode.
    public var isPersonal: Bool
    /// A single, optional suggestion to offer after the result ("Want a reminder for that?").
    public var followUp: FollowUpOffer?

    public init(summary: String, speech: SpeechPlan, card: Card? = nil, undo: UndoPlan? = nil, referent: Referent? = nil,
                data: JSONValue = .null, earcon: Earcon = .success, isPersonal: Bool = false, followUp: FollowUpOffer? = nil) {
        self.summary = summary
        self.speech = speech
        self.card = card
        self.undo = undo
        self.referent = referent
        self.data = data
        self.earcon = earcon
        self.isPersonal = isPersonal
        self.followUp = followUp
    }
}

/// A yes/no offer Aside makes once, right after an action. Saying anything else drops it.
public struct FollowUpOffer: Sendable, Hashable {
    public var prompt: String
    public var toolName: String
    public var arguments: JSONValue

    public init(prompt: String, toolName: String, arguments: JSONValue) {
        self.prompt = prompt
        self.toolName = toolName
        self.arguments = arguments
    }
}

public struct ConfirmationRequest: Sendable, Identifiable, Hashable {
    public var id: String
    public var call: ToolCall
    /// "Send message"
    public var title: String
    /// Who or what it affects ("Sam Lee · +1 555 0100").
    public var subject: String?
    /// The content ("I'm running ten minutes late").
    public var detail: String?
    /// What will happen ("Sends an iMessage. This can't be unsent.").
    public var consequence: String
    /// Spoken question ("Send it to Sam Lee?")
    public var prompt: String
    public var confirmLabel: String
    public var strength: ConfirmationStrength
    public var isDestructive: Bool
    public var expiresAt: Date

    public init(id: String = Identifier.make("confirm"), call: ToolCall, title: String, subject: String? = nil, detail: String? = nil,
                consequence: String, prompt: String, confirmLabel: String, strength: ConfirmationStrength,
                isDestructive: Bool = false, expiresAt: Date) {
        self.id = id
        self.call = call
        self.title = title
        self.subject = subject
        self.detail = detail
        self.consequence = consequence
        self.prompt = prompt
        self.confirmLabel = confirmLabel
        self.strength = strength
        self.isDestructive = isDestructive
        self.expiresAt = expiresAt
    }
}

public struct ChoiceOption: Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var detail: String?
    public var value: JSONValue

    public init(id: String = Identifier.make("opt"), label: String, detail: String? = nil, value: JSONValue) {
        self.id = id
        self.label = label
        self.detail = detail
        self.value = value
    }
}

public struct ChoiceRequest: Sendable, Identifiable, Hashable {
    public var id: String
    public var prompt: String
    public var options: [ChoiceOption]
    /// Argument to fill with the chosen option's value.
    public var parameter: String
    public var call: ToolCall

    public init(id: String = Identifier.make("choice"), prompt: String, options: [ChoiceOption], parameter: String, call: ToolCall) {
        self.id = id
        self.prompt = prompt
        self.options = options
        self.parameter = parameter
        self.call = call
    }
}

public struct SlotRequest: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case text, duration, dateTime, contact, place }

    public var prompt: String
    public var parameter: String
    public var kind: Kind
    public var call: ToolCall

    public init(prompt: String, parameter: String, kind: Kind, call: ToolCall) {
        self.prompt = prompt
        self.parameter = parameter
        self.kind = kind
        self.call = call
    }
}

public struct PermissionRequest: Sendable, Hashable {
    public var capability: Capability
    public var state: AccessState
    /// Spoken/visible explanation ("I need access to your reminders for that.").
    public var explanation: String
    public var call: ToolCall

    public init(capability: Capability, state: AccessState, explanation: String, call: ToolCall) {
        self.capability = capability
        self.state = state
        self.explanation = explanation
        self.call = call
    }
}

public struct ToolFailure: Error, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case invalidArguments, notFound, unavailable, unsupported, denied, service, network, timeout, cancelled
    }

    public var kind: Kind
    /// Spoken, plain-language explanation.
    public var message: String
    /// Technical detail for the journal and the model.
    public var detail: String
    public var isRetryable: Bool
    /// The user has already been told (so it isn't spoken twice).
    public var toldUser: Bool

    public init(_ kind: Kind, message: String, detail: String? = nil, isRetryable: Bool = false, toldUser: Bool = false) {
        self.kind = kind
        self.message = message
        self.detail = detail ?? message
        self.isRetryable = isRetryable
        self.toldUser = toldUser
    }
}

// MARK: - Cards

/// Small, temporary visual elements. Never a feed, never a dashboard.
public enum Card: Sendable, Hashable, Identifiable {
    case confirmation(ConfirmationRequest)
    case choice(ChoiceRequest)
    case agenda(AgendaCard)
    case list(ListCard)
    case place(PlaceCard)
    case weather(WeatherCard)
    case nowPlaying(NowPlayingCard)
    case status(StatusCard)
    case permission(PermissionCard)
    case sources(SourcesCard)

    public var id: String {
        switch self {
        case .confirmation(let value): return value.id
        case .choice(let value): return value.id
        case .agenda(let value): return value.id
        case .list(let value): return value.id
        case .place(let value): return value.id
        case .weather(let value): return value.id
        case .nowPlaying(let value): return value.id
        case .status(let value): return value.id
        case .permission(let value): return value.id
        case .sources(let value): return value.id
        }
    }

    /// Cards that wait for the user stay until resolved; others fade on their own.
    public var requiresInteraction: Bool {
        switch self {
        case .confirmation, .choice, .permission: return true
        default: return false
        }
    }

    /// How long an informational card stays visible.
    public var lifetime: TimeInterval {
        switch self {
        case .agenda, .list: return 12
        case .place, .weather: return 10
        case .status: return 4
        case .nowPlaying: return 5
        case .sources: return 8
        default: return .infinity
        }
    }
}

public struct AgendaCard: Sendable, Hashable {
    public struct Item: Sendable, Hashable {
        public var time: String
        public var title: String
        public var detail: String?

        public init(time: String, title: String, detail: String? = nil) {
            self.time = time
            self.title = title
            self.detail = detail
        }
    }

    public var id: String
    public var heading: String
    public var items: [Item]

    public init(id: String = Identifier.make("card"), heading: String, items: [Item]) {
        self.id = id
        self.heading = heading
        self.items = items
    }
}

public struct ListCard: Sendable, Hashable {
    public var id: String
    public var heading: String
    public var symbol: String
    public var items: [String]

    public init(id: String = Identifier.make("card"), heading: String, symbol: String, items: [String]) {
        self.id = id
        self.heading = heading
        self.symbol = symbol
        self.items = items
    }
}

public struct PlaceCard: Sendable, Hashable {
    public var id: String
    public var name: String
    public var address: String?
    public var latitude: Double
    public var longitude: Double
    public var travelSummary: String?

    public init(id: String = Identifier.make("card"), name: String, address: String?, latitude: Double, longitude: Double, travelSummary: String?) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.travelSummary = travelSummary
    }
}

public struct WeatherCard: Sendable, Hashable {
    public var id: String
    public var place: String
    public var temperature: String
    public var condition: String
    public var symbol: String
    public var range: String?
    public var attribution: String?

    public init(id: String = Identifier.make("card"), place: String, temperature: String, condition: String, symbol: String,
                range: String?, attribution: String?) {
        self.id = id
        self.place = place
        self.temperature = temperature
        self.condition = condition
        self.symbol = symbol
        self.range = range
        self.attribution = attribution
    }
}

public struct NowPlayingCard: Sendable, Hashable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var provider: String

    public init(id: String = Identifier.make("card"), title: String, subtitle: String?, provider: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.provider = provider
    }
}

public struct StatusCard: Sendable, Hashable {
    public enum Tone: String, Sendable, Hashable { case success, info, warning, failure }

    public var id: String
    public var symbol: String
    public var title: String
    public var detail: String?
    public var tone: Tone
    /// Optional action, e.g. "Open Settings".
    public var actionLabel: String?
    public var actionURL: String?

    public init(id: String = Identifier.make("card"), symbol: String, title: String, detail: String? = nil, tone: Tone = .info,
                actionLabel: String? = nil, actionURL: String? = nil) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.tone = tone
        self.actionLabel = actionLabel
        self.actionURL = actionURL
    }
}

public struct PermissionCard: Sendable, Hashable {
    public var id: String
    public var capability: Capability
    public var explanation: String
    /// The system won't ask again; the user has to change it in Settings.
    public var needsSettings: Bool

    public init(id: String = Identifier.make("card"), capability: Capability, explanation: String, needsSettings: Bool) {
        self.id = id
        self.capability = capability
        self.explanation = explanation
        self.needsSettings = needsSettings
    }
}

public struct SourcesCard: Sendable, Hashable {
    public struct Source: Sendable, Hashable {
        public var title: String
        public var url: String

        public init(title: String, url: String) {
            self.title = title
            self.url = url
        }
    }

    public var id: String
    public var sources: [Source]

    public init(id: String = Identifier.make("card"), sources: [Source]) {
        self.id = id
        self.sources = sources
    }
}

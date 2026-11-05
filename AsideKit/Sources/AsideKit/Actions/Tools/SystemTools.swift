import Foundation

/// Owns the user's preferences and persists them.
public actor PreferencesStore {
    private let store: PersistentStore?
    private let key = "preferences.v1"
    private var value: Preferences = Preferences()
    private var loaded = false
    private var observers: [@Sendable (Preferences) -> Void] = []

    public init(store: PersistentStore?, initial: Preferences? = nil) {
        self.store = store
        if let initial { value = initial; loaded = store == nil }
    }

    public func current() async -> Preferences {
        await ensureLoaded()
        return value
    }

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        if let store, let data = try? await store.load(key) { value = Preferences.decodeLenient(data) }
    }

    @discardableResult
    public func update(_ mutate: @Sendable (inout Preferences) -> Void) async -> Preferences {
        await ensureLoaded()
        mutate(&value)
        if let store, let data = try? StoreCoding.encoder().encode(value) { try? await store.save(data, for: key) }
        for observer in observers { observer(value) }
        return value
    }

    public func replace(with preferences: Preferences) async {
        await update { $0 = preferences }
    }

    public func observe(_ observer: @escaping @Sendable (Preferences) -> Void) {
        observers.append(observer)
    }
}

// MARK: - Preferences tool

public struct SetPreferenceTool: ToolHandler {
    let preferences: PreferencesStore

    public init(preferences: PreferencesStore) { self.preferences = preferences }

    public var spec: ToolSpec {
        ToolSpec(
            name: "set_preference",
            description: "Change how Aside behaves when the user asks: how much it talks, whether it speaks aloud, its personality, the default music service, or what to call the user.",
            inputSchema: Schema.object([
                "setting": Schema.string("Which setting.", enum: ["verbosity", "speech_privacy", "personality", "music_provider", "preferred_name", "speech_rate"]),
                "value": Schema.string("verbosity: minimal|balanced|detailed; speech_privacy: always|headphonesForPersonal|discreet; personality: warm|crisp|playful; music_provider: apple_music|spotify; preferred_name: a name; speech_rate: slower|faster|normal."),
            ], required: ["setting", "value"]),
            capability: .system, risk: .reversible)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let setting = prepared.call.arguments["setting"]?.stringValue ?? ""
        let value = prepared.call.arguments["value"]?.stringValue ?? ""
        let before = await preferences.current()
        var speech: SpeechPlan
        var previous: String
        switch setting {
        case "verbosity":
            guard let verbosity = Verbosity(rawValue: value) else { return invalid() }
            previous = before.verbosity.rawValue
            await preferences.update { $0.verbosity = verbosity }
            speech = SpeechPlan(verbosity == .minimal ? "Okay, I'll keep it short." : verbosity == .detailed ? "Okay, I'll go into more detail." : "Okay, back to normal.")
        case "speech_privacy":
            guard let privacy = SpeechPrivacy(rawValue: value) else { return invalid() }
            previous = before.speechPrivacy.rawValue
            await preferences.update { $0.speechPrivacy = privacy }
            speech = SpeechPlan(privacy == .discreet ? nil : privacy == .always ? "Okay, I'll talk out loud again." : "Okay, I'll keep personal details off the speaker.")
        case "personality":
            guard let personality = Personality(rawValue: value) else { return invalid() }
            previous = before.personality.rawValue
            await preferences.update { $0.personality = personality }
            speech = SpeechPlan(personality == .crisp ? "Done." : personality == .playful ? "Oh, this'll be fun." : "Sure thing.")
        case "music_provider":
            guard let provider = MusicProvider(argument: value) else { return invalid() }
            previous = before.preferredMusicProvider?.rawValue ?? ""
            await preferences.update { $0.preferredMusicProvider = provider }
            speech = SpeechPlan("Okay, I'll use \(provider.displayName) for music.")
        case "preferred_name":
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count < 40 else { return invalid() }
            previous = before.preferredName ?? ""
            await preferences.update { $0.preferredName = name }
            speech = SpeechPlan("Okay, \(name).")
        case "speech_rate":
            previous = String(before.speechRate)
            let rate: Double
            switch value {
            case "slower": rate = max(0.35, before.speechRate - 0.06)
            case "faster": rate = min(0.65, before.speechRate + 0.06)
            default: rate = Double(value) ?? Preferences().speechRate
            }
            await preferences.update { $0.speechRate = rate }
            speech = SpeechPlan(value == "slower" ? "Okay, I'll slow down." : value == "faster" ? "Okay, a bit faster." : "Okay.")
        default:
            return invalid()
        }
        return .completed(ActionResult(
            summary: "Set \(setting) to \(value)", speech: speech,
            undo: UndoPlan(toolName: "set_preference", arguments: ["setting": .string(setting), "value": .string(previous.isEmpty ? "balanced" : previous)],
                           pastTense: "put that setting back"),
            data: ["setting": .string(setting), "value": .string(value)], earcon: .success))
    }

    private func invalid() -> ToolOutcome {
        .failed(ToolFailure(.invalidArguments, message: "I can't change that setting."))
    }
}

// MARK: - Undo

/// Weak handle so the undo tool can call back into the engine that runs it.
public final class EngineHandle: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storedEngine: ActionEngine?

    public init() {}

    public var engine: ActionEngine? {
        get { lock.lock(); defer { lock.unlock() }; return storedEngine }
        set { lock.lock(); storedEngine = newValue; lock.unlock() }
    }
}

public struct UndoTool: ToolHandler {
    let handle: EngineHandle

    public init(handle: EngineHandle) { self.handle = handle }

    public var spec: ToolSpec {
        ToolSpec(name: "undo_last_action", description: "Undo the most recent thing Aside did (within the last 15 minutes).",
                 inputSchema: Schema.object([:]), capability: .system, risk: .reversible)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        guard let engine = handle.engine else {
            return .failed(ToolFailure(.unavailable, message: "I can't undo that right now."))
        }
        return await engine.undoLast(context: context)
    }
}

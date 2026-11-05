import Foundation
import Observation

/// Everything the runtime needs from the platform.
@MainActor
public struct AgentDependencies {
    public var speechInput: any SpeechInput
    public var speechOutput: any SpeechOutput
    public var earcons: (any EarconPlayer)?
    public var engine: ActionEngine
    public var memory: MemoryStore
    public var preferences: PreferencesStore
    public var reasoner: (any Reasoner)?
    public var localModel: (any LocalIntentModel)?
    public var music: MusicRouter?
    public var clock: any AgentClock
    public var temporal: @MainActor () -> TemporalContext
    public var device: @MainActor () -> DeviceContext
    public var locality: (any LocationContextProvider)?

    public init(speechInput: any SpeechInput, speechOutput: any SpeechOutput, earcons: (any EarconPlayer)?, engine: ActionEngine,
                memory: MemoryStore, preferences: PreferencesStore, reasoner: (any Reasoner)?, localModel: (any LocalIntentModel)?,
                music: MusicRouter?, clock: any AgentClock = SystemClock(),
                temporal: @escaping @MainActor () -> TemporalContext = { TemporalContext() },
                device: @escaping @MainActor () -> DeviceContext, locality: (any LocationContextProvider)? = nil) {
        self.speechInput = speechInput
        self.speechOutput = speechOutput
        self.earcons = earcons
        self.engine = engine
        self.memory = memory
        self.preferences = preferences
        self.reasoner = reasoner
        self.localModel = localModel
        self.music = music
        self.clock = clock
        self.temporal = temporal
        self.device = device
        self.locality = locality
    }
}

/// The conversation engine: turn-taking, interruption, routing, confirmation and reply.
///
/// It is deliberately UI-agnostic. The apps observe `phase`, `transcript`, levels and
/// `cards` to draw the presence; everything else happens here.
@MainActor
@Observable
public final class AgentRuntime {
    public enum Phase: String, Sendable, Hashable {
        /// Nothing happening; microphone off.
        case idle
        /// Microphone on, waiting for or hearing the user.
        case listening
        /// Understanding or working on a request.
        case thinking
        /// Aside is talking.
        case speaking
        /// Waiting for the user to decide (confirmation, choice).
        case waiting
    }

    // MARK: Observable state

    public private(set) var phase: Phase = .idle
    /// What the user is saying right now (live caption).
    public private(set) var transcript: String = ""
    /// What Aside is saying right now (caption; the only output in discreet mode).
    public private(set) var replyCaption: String = ""
    /// Transient cards currently shown.
    public private(set) var cards: [Card] = []
    public private(set) var inputLevel: Float = 0
    public private(set) var isMicrophoneActive = false
    /// "Checking your calendar" — answers "what are you doing?" and labels the presence.
    public private(set) var activity: String?
    public private(set) var preferences: Preferences = Preferences()

    public var outputLevel: Float { deps.speechOutput.level }

    // MARK: Internals

    @ObservationIgnored private var deps: AgentDependencies
    @ObservationIgnored private let fastPath = FastPathParser()
    @ObservationIgnored private var endpointer: Endpointer?
    @ObservationIgnored private var endpointTask: Task<Void, Never>?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var pending: PendingInteraction?
    @ObservationIgnored private var echoGuard = EchoGuard()
    @ObservationIgnored private var lastReferent: (referent: Referent, at: Date)?
    @ObservationIgnored private var lastReply: String?
    @ObservationIgnored private var lastInteractionAt: Date?
    @ObservationIgnored private var activation: ActivationSource = .tap
    @ObservationIgnored private var cardTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var turnCounter = 0
    @ObservationIgnored private var heardSpeechThisTurn = false
    @ObservationIgnored private var headlessBuffer: [String]?
    @ObservationIgnored private var expectReplyAfterSpeech = false
    @ObservationIgnored private var currentTurnText: String = ""
    @ObservationIgnored private var turnInFlight = 0

    /// How long context (what "it" means, the cloud conversation) survives between interactions.
    public var sessionTimeout: TimeInterval = 5 * 60

    public init(dependencies: AgentDependencies) {
        self.deps = dependencies
        deps.speechOutput.onUtteranceStart = { [weak self] text in
            self?.replyCaption = text
            self?.echoGuard.speaking(text)
        }
        Task { [weak self] in
            guard let self else { return }
            self.preferences = await dependencies.preferences.current()
        }
    }

    private var now: Date { deps.clock.now }

    // MARK: - Activation

    /// Summon Aside: start listening (interrupting any speech in progress).
    public func activate(source: ActivationSource) {
        activation = source
        if let last = lastInteractionAt, now.timeIntervalSince(last) > sessionTimeout { endSession() }
        if deps.speechOutput.isSpeaking { deps.speechOutput.stop() }
        Task { await refreshPreferences() }
        // If Aside asked something, a fresh activation answers it.
        startListening(earcon: true, asAnswer: pending != nil)
    }

    /// Push-to-talk released: the user is done talking.
    public func pushToTalkEnded() {
        guard phase == .listening else { return }
        endpointTask?.cancel()
        if transcript.trimmingCharacters(in: .whitespaces).isEmpty {
            // Give the recognizer a moment to deliver the last words.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self?.finishTurn()
            }
        } else {
            finishTurn()
        }
    }

    /// Close everything without speaking (Escape, tap outside, "never mind").
    public func dismiss() {
        turnTask?.cancel()
        pending?.resolve(.cancelled)
        pending = nil
        deps.speechOutput.stop()
        stopListening()
        phase = .idle
        transcript = ""
        activity = nil
        removeInteractiveCards()
    }

    /// Text entry point for Siri, Shortcuts and App Intents. Nothing is spoken by Aside;
    /// the reply text is returned for the system to present.
    public func submit(text: String, origin: CallOrigin = .siri) async -> String {
        await refreshPreferences()
        headlessBuffer = []
        defer { headlessBuffer = nil }
        let utterance = Utterance(text)
        if let command = ControlCommandParser.parse(utterance), command == .undo {
            await handleControl(command)
        } else {
            await process(utterance, origin: origin)
        }
        let reply = (headlessBuffer ?? []).joined(separator: " ")
        return reply.isEmpty ? "Done." : reply
    }

    // MARK: - Card interaction

    public func confirm(_ requestID: String) {
        guard let pending, case .confirmation(let request) = pending.kind, request.id == requestID else { return }
        pending.resolve(.confirmed)
    }

    public func decline(_ requestID: String) {
        guard let pending, case .confirmation(let request) = pending.kind, request.id == requestID else { return }
        pending.resolve(.declined)
    }

    public func choose(_ optionID: String, in requestID: String) {
        guard let pending, case .choice(let request) = pending.kind, request.id == requestID,
              let option = request.options.first(where: { $0.id == optionID }) else { return }
        pending.resolve(.chose(option))
    }

    public func dismissCard(_ id: String) {
        if let pending, pending.cardID == id { pending.resolve(.cancelled) }
        cards.removeAll { $0.id == id }
    }

    /// Undo a specific action from the Activity view.
    public func undo(journalEntryID: String) async -> String {
        let outcome = await deps.engine.undo(entryID: journalEntryID, context: makeContext(origin: .undo))
        switch outcome {
        case .completed(let result): return result.speech.text(for: .balanced) ?? "Undone."
        case .failed(let failure): return failure.message
        default: return "That can't be undone."
        }
    }

    // MARK: - Listening

    private func startListening(earcon: Bool, asAnswer: Bool = false) {
        transcript = ""
        heardSpeechThisTurn = false
        phase = asAnswer ? .waiting : .listening
        activity = nil
        lastInteractionAt = now
        if earcon { play(.listening) }
        endpointer = Endpointer(startedAt: now)
        deps.speechInput.beginTurn()
        if !deps.speechInput.isCapturing {
            isMicrophoneActive = true
            let locale = deps.temporal().locale
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.deps.speechInput.start(locale: locale) { [weak self] event in
                        self?.handleInput(event)
                    }
                } catch let failure as SpeechInputFailure {
                    self.inputFailed(failure)
                } catch {
                    self.inputFailed(.audioFailure("\(error)"))
                }
            }
        }
        startEndpointing()
    }

    private func stopListening() {
        endpointTask?.cancel()
        endpointTask = nil
        endpointer = nil
        if deps.speechInput.isCapturing { deps.speechInput.stop() }
        isMicrophoneActive = false
        inputLevel = 0
    }

    private func startEndpointing() {
        endpointTask?.cancel()
        guard activation != .pushToTalk || phase == .waiting else { return }
        endpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                guard self.phase == .listening || self.phase == .waiting, var endpointer = self.endpointer else { continue }
                endpointer.transcriptLooksComplete = self.looksComplete(self.transcript)
                self.endpointer = endpointer
                switch endpointer.decide(at: self.now) {
                case .keepListening: continue
                case .endOfTurn: self.finishTurn(); return
                case .noSpeech: self.noSpeech(); return
                }
            }
        }
    }

    private func looksComplete(_ text: String) -> Bool {
        let utterance = Utterance(text)
        guard utterance.count >= 2 else { return ControlCommandParser.parse(utterance) != nil }
        if ControlCommandParser.parse(utterance) != nil { return true }
        if pending != nil, AnswerParser.yesNo(utterance) != nil { return true }
        if case .call(_, let arguments, let confidence)? = fastPath.parse(utterance), confidence >= 0.9, arguments["title"] != nil || arguments["seconds"] != nil || arguments["query"] != nil || arguments["when"] != nil {
            return true
        }
        return false
    }

    private func handleInput(_ event: SpeechInputEvent) {
        switch event {
        case .level(let level):
            inputLevel = level
        case .voiceActivity(let active):
            endpointer?.voiceActivity(active, at: now)
            if active && phase == .speaking && preferences.allowInterruptions {
                deps.speechOutput.duck(true)
            }
        case .transcript(let text, _):
            handleTranscript(text)
        case .routeChanged:
            break
        case .interrupted(let failure):
            inputFailed(failure)
        }
    }

    private func handleTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch phase {
        case .listening, .waiting:
            transcript = trimmed
            heardSpeechThisTurn = true
            endpointer?.transcriptChanged(trimmed, at: now)
        case .speaking, .thinking:
            guard preferences.allowInterruptions else { return }
            guard echoGuard.isGenuineInterruption(trimmed) else {
                deps.speechOutput.duck(false)
                return
            }
            let utterance = Utterance(trimmed)
            if let command = ControlCommandParser.parse(utterance) {
                deps.speechInput.beginTurn()
                Task { await self.handleControl(command) }
                return
            }
            if utterance.count == 1, utterance.norms == ["pause"] {
                deps.speechOutput.pause()
                return
            }
            // A real interruption: stop talking and listen to the new request.
            interrupt()
            transcript = trimmed
            heardSpeechThisTurn = true
            endpointer = Endpointer(startedAt: now)
            endpointer?.transcriptChanged(trimmed, at: now)
            phase = .listening
            startEndpointing()
        case .idle:
            break
        }
    }

    private func interrupt() {
        turnTask?.cancel()
        turnTask = nil
        deps.speechOutput.stop()
        echoGuard.reset()
        if let pending { pending.resolve(.cancelled); self.pending = nil }
    }

    private func noSpeech() {
        if phase == .waiting, let pending {
            // No answer to a question: leave it be.
            pending.resolve(.timeout)
            return
        }
        stopListening()
        phase = .idle
        transcript = ""
    }

    private func inputFailed(_ failure: SpeechInputFailure) {
        stopListening()
        if failure == .systemInterruption {
            phase = .idle
            return
        }
        phase = .idle
        let message = failure.spokenMessage
        if failure == .microphoneDenied {
            show(.permission(PermissionCard(capability: .system, explanation: message, needsSettings: true)))
        } else {
            show(.status(StatusCard(symbol: "mic.slash", title: "Can't listen right now", detail: message, tone: .failure)))
        }
        play(.failure)
    }

    private func finishTurn() {
        endpointTask?.cancel()
        endpointTask = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        deps.speechInput.beginTurn()
        endpointer = nil
        guard !text.isEmpty else {
            if pending != nil { pending?.resolve(.timeout); return }
            stopListening()
            phase = .idle
            return
        }
        lastInteractionAt = now
        currentTurnText = text
        let utterance = Utterance(text)

        if let pending {
            routeAnswer(utterance, to: pending)
            return
        }
        if let command = ControlCommandParser.parse(utterance) {
            Task { await self.handleControl(command) }
            return
        }
        if !preferences.conversationMode { stopListeningAfterTurnIfNeeded() }
        turnInFlight += 1
        let token = turnInFlight
        turnTask = Task { [weak self] in
            guard let self else { return }
            await self.process(utterance, origin: .fastPath)
            await self.concludeTurn()
            if self.turnInFlight == token { self.turnTask = nil }
        }
    }

    /// Keeps the microphone on during the reply only when interruptions are allowed.
    private func stopListeningAfterTurnIfNeeded() {
        if !preferences.allowInterruptions { stopListening() }
    }

    // MARK: - Pending interactions

    private func routeAnswer(_ utterance: Utterance, to pending: PendingInteraction) {
        if let command = ControlCommandParser.parse(utterance), [.stop, .cancel, .dismiss, .done].contains(command) {
            pending.resolve(.cancelled)
            return
        }
        switch pending.kind {
        case .confirmation(let request):
            switch AnswerParser.yesNo(utterance) {
            case .yes:
                if request.strength == .voice {
                    pending.resolve(.confirmed)
                } else {
                    // Voice alone never approves consequential actions.
                    let hint = request.strength == .deviceAuthentication ? "Tap \(request.confirmLabel) to confirm with Face ID or your passcode." : "Tap \(request.confirmLabel) to confirm."
                    Task {
                        await self.say(hint)
                        await self.deps.speechOutput.waitUntilFinished()
                        self.startListening(earcon: false, asAnswer: true)
                    }
                }
            case .no:
                pending.resolve(.declined)
            case nil:
                pending.resolve(.newRequest(utterance.raw))
            }
        case .choice(let request):
            if let index = AnswerParser.choice(utterance, options: request.options.map(\.label)) {
                pending.resolve(.chose(request.options[index]))
            } else if AnswerParser.yesNo(utterance) == .no {
                pending.resolve(.declined)
            } else {
                pending.resolve(.newRequest(utterance.raw))
            }
        case .slot:
            pending.resolve(.text(utterance.raw))
        case .offer:
            switch AnswerParser.yesNo(utterance) {
            case .yes: pending.resolve(.confirmed)
            case .no: pending.resolve(.declined)
            case nil: pending.resolve(.newRequest(utterance.raw))
            }
        }
    }

    /// Shows a question and suspends until the user answers (by voice or tap).
    private func ask(_ kind: PendingInteraction.Kind, prompt: String, card: Card?, timeout: TimeInterval) async -> PendingAnswer {
        if headlessBuffer != nil {
            headlessBuffer?.append(prompt)
            return .headless
        }
        let interaction = PendingInteraction(kind: kind, cardID: card?.id)
        pending = interaction
        if let card { show(card) }
        play(.attention)
        await say(prompt, expectReply: true)
        await deps.speechOutput.waitUntilFinished()
        guard !interaction.isResolved else {
            return await interaction.answer()
        }
        startListening(earcon: false, asAnswer: true)
        let timer = Task { [weak interaction] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            interaction?.resolve(.timeout)
        }
        let answer = await interaction.answer()
        timer.cancel()
        if pending === interaction { pending = nil }
        if let id = card?.id { cards.removeAll { $0.id == id } }
        return answer
    }

    // MARK: - Processing

    private func process(_ utterance: Utterance, origin: CallOrigin) async {
        turnCounter += 1
        let turnID = "turn_\(turnCounter)_\(Int(now.timeIntervalSince1970))"
        phase = .thinking
        activity = "Thinking"
        await refreshPreferences()

        // Corrections to the thing just discussed.
        if let recent = lastReferent, now.timeIntervalSince(recent.at) < sessionTimeout,
           let correction = CorrectionParser.parse(utterance, referent: recent.referent),
           let call = CorrectionParser.call(for: correction, referent: recent.referent, turnID: turnID) {
            await perform(call)
            return
        }

        // Local grammar.
        if let result = fastPath.parse(utterance) {
            switch result {
            case .reply(let plan):
                await say(plan.text(for: preferences.verbosity) ?? "")
                return
            case .offer(let prompt, let name, let arguments):
                let answer = await ask(.offer(prompt), prompt: prompt, card: nil, timeout: 20)
                if case .confirmed = answer {
                    await perform(ToolCall(name: name, arguments: arguments, origin: .fastPath, turnID: turnID))
                } else if case .newRequest(let text) = answer {
                    await process(Utterance(text), origin: origin)
                }
                return
            case .call(let name, let arguments, let confidence):
                if confidence >= 0.75 {
                    let call = ToolCall(name: name, arguments: arguments, origin: origin == .siri ? .siri : .fastPath, turnID: turnID)
                    let outcome = await resolveInteractively(call, externalContent: false)
                    let mayFallThrough = arguments["fallthrough"]?.boolValue == true
                    if case .failed(let failure) = outcome, failure.kind == .notFound, mayFallThrough, cloudAvailable || localModelEnabled {
                        break
                    }
                    await present(outcome)
                    return
                }
            }
        }

        // Cloud reasoning for everything else, when allowed and reachable.
        if cloudAvailable, let reasoner = deps.reasoner {
            await reason(with: reasoner, utterance: utterance, turnID: turnID)
            return
        }

        // On-device model: private, offline-capable understanding.
        if localModelEnabled, let model = deps.localModel, await model.isAvailable {
            activity = "Thinking"
            if let frame = await model.interpret(utterance.raw, context: makeContext(origin: .onDeviceModel)),
               let call = frame.toolCall(turnID: turnID) {
                let outcome = await resolveInteractively(call, externalContent: false)
                await present(outcome)
                return
            }
        }

        if !deps.device().isOnline && preferences.reasoningMode == .hybrid {
            await say("I'm offline right now, so I can only handle things like reminders, timers, your calendar and notes.")
        } else if deps.reasoner == nil || preferences.reasoningMode == .onDeviceOnly {
            await say("I can't do that on this device yet.")
        } else {
            await say("Sorry, I'm not sure how to help with that.")
        }
    }

    private var cloudAvailable: Bool {
        preferences.reasoningMode == .hybrid && deps.reasoner != nil && deps.device().isOnline
    }

    private var localModelEnabled: Bool { preferences.useOnDeviceModel && deps.localModel != nil }

    private func reason(with reasoner: any Reasoner, utterance: Utterance, turnID: String) async {
        let context = makeContext(origin: .cloudModel)
        let memories = preferences.memoryEnabled ? await deps.memory.context(for: utterance.raw, now: now) : []
        let locality = await deps.locality?.approximateLocality()
        let turn = ReasonerTurn(utterance: utterance.raw, context: context, memories: memories, locality: locality, turnID: turnID)
        let tools = deps.engine.registry.modelSpecs
        let executor = RuntimeToolExecutor { [weak self] call, external in
            guard let self else { return .failed(ToolFailure(.cancelled, message: "")) }
            return await self.resolveForModel(call, externalContent: external)
        }
        activity = "Thinking"
        do {
            let result = try await reasoner.respond(to: turn, tools: tools, executor: executor) { [weak self] event in
                await self?.handleReasonerEvent(event)
            }
            if result.refused {
                await say("I can't help with that one.")
            } else if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && result.toolsUsed.isEmpty {
                await say("Hmm, I don't have an answer for that.")
            }
            lastReply = result.text.isEmpty ? lastReply : SpeechText.sanitize(result.text)
        } catch let error as ReasonerError {
            if error != .cancelled {
                play(.failure)
                await say(error.spokenMessage)
            }
        } catch is CancellationError {
            // Interrupted by the user.
        } catch {
            play(.failure)
            await say(ReasonerError.badResponse("\(error)").spokenMessage)
        }
    }

    private func handleReasonerEvent(_ event: ReasonerEvent) async {
        guard !Task.isCancelled else { return }
        switch event {
        case .speech(let text):
            await say(text, waitForCompletion: false)
        case .toolStarted(let name):
            activity = Self.describeActivity(tool: name)
        case .sources(let sources):
            show(.sources(SourcesCard(sources: Array(sources.prefix(3)))))
        }
    }

    static func describeActivity(tool: String) -> String {
        switch tool {
        case "web_search": return "Looking that up"
        case "get_schedule": return "Checking your calendar"
        case "list_reminders": return "Checking your reminders"
        case "get_weather": return "Checking the weather"
        case "find_places", "get_travel_time", "open_directions": return "Checking maps"
        case "play_music": return "Finding music"
        case "recall": return "Checking your notes"
        case "send_message": return "Preparing a message"
        default: return "Working on it"
        }
    }

    // MARK: - Execution

    /// Runs a call from the local paths and presents the result.
    private func perform(_ call: ToolCall) async {
        let outcome = await resolveInteractively(call, externalContent: false)
        await present(outcome)
    }

    /// For cloud tool calls: acts, shows cards, and speaks write confirmations immediately.
    private func resolveForModel(_ call: ToolCall, externalContent: Bool) async -> ToolOutcome {
        let outcome = await resolveInteractively(call, externalContent: externalContent)
        if case .completed(let result) = outcome {
            let risk = deps.engine.registry.handler(named: call.name)?.spec.risk ?? .read
            if risk > .read {
                await present(outcome)
            } else if let card = result.card {
                show(card)
                remember(result.referent)
            } else {
                remember(result.referent)
            }
        }
        return outcome
    }

    /// Runs a call, handling confirmation, choices, missing details and permissions with the user.
    private func resolveInteractively(_ call: ToolCall, externalContent: Bool) async -> ToolOutcome {
        var current = call
        activity = Self.describeActivity(tool: call.name)
        for _ in 0..<5 {
            if Task.isCancelled { return .failed(ToolFailure(.cancelled, message: "")) }
            var context = makeContext(origin: current.origin)
            context.turnHasExternalContent = externalContent
            let outcome = await deps.engine.perform(current, context: context)
            switch outcome {
            case .completed, .failed:
                return outcome

            case .needsConfirmation(let request):
                let answer = await ask(.confirmation(request), prompt: request.prompt, card: .confirmation(request),
                                       timeout: request.strength == .voice ? 25 : 90)
                switch answer {
                case .confirmed:
                    phase = .thinking
                    let confirmed = await deps.engine.confirm(request.id, now: now)
                    switch confirmed {
                    case .completed, .failed: return confirmed
                    default: return .failed(ToolFailure(.service, message: "That didn't finish."))
                    }
                case .headless:
                    return .failed(ToolFailure(.denied, message: "Open Aside to confirm that.", detail: "needs confirmation"))
                case .newRequest(let text):
                    await deps.engine.decline(request.id, now: now)
                    redirect(to: text)
                    return .failed(ToolFailure(.cancelled, message: "", toldUser: true))
                default:
                    await deps.engine.decline(request.id, now: now)
                    return .failed(ToolFailure(.cancelled, message: answer == .timeout ? "I'll leave that for now." : "Okay, I won't.", toldUser: false))
                }

            case .needsChoice(let request):
                let answer = await ask(.choice(request), prompt: request.prompt, card: .choice(request), timeout: 30)
                switch answer {
                case .chose(let option):
                    current = request.call.with(request.parameter, option.value)
                    phase = .thinking
                case .headless:
                    return .failed(ToolFailure(.notFound, message: request.prompt, detail: "needs a choice", toldUser: true))
                case .newRequest(let text):
                    redirect(to: text)
                    return .failed(ToolFailure(.cancelled, message: "", toldUser: true))
                default:
                    return .failed(ToolFailure(.cancelled, message: "Okay.", toldUser: false))
                }

            case .needsInfo(let slot):
                let answer = await ask(.slot(slot), prompt: slot.prompt, card: nil, timeout: 20)
                switch answer {
                case .text(let text):
                    current = slot.call.with(slot.parameter, .string(text))
                    phase = .thinking
                case .headless:
                    return .failed(ToolFailure(.invalidArguments, message: slot.prompt, detail: "needs more information", toldUser: true))
                default:
                    return .failed(ToolFailure(.cancelled, message: "", toldUser: true))
                }

            case .needsPermission(let request):
                show(.permission(PermissionCard(capability: request.capability, explanation: request.explanation,
                                                needsSettings: request.state == .denied)))
                return .failed(ToolFailure(.denied, message: request.explanation, detail: "permission \(request.state.rawValue)", toldUser: false))
            }
        }
        return .failed(ToolFailure(.service, message: "I couldn't finish that."))
    }

    /// The user said something new instead of answering; handle it as a fresh request.
    private func redirect(to text: String) {
        let utterance = Utterance(text)
        Task { [weak self] in
            guard let self else { return }
            if let command = ControlCommandParser.parse(utterance) {
                await self.handleControl(command)
            } else {
                await self.process(utterance, origin: .fastPath)
                await self.concludeTurn()
            }
        }
    }

    // MARK: - Presentation

    private func present(_ outcome: ToolOutcome) async {
        switch outcome {
        case .completed(let result):
            await present(result)
        case .failed(let failure):
            guard !failure.message.isEmpty, !failure.toldUser else { return }
            if failure.kind != .cancelled { play(.failure) } else { play(.cancelled) }
            await say(failure.message)
        default:
            break
        }
    }

    private func present(_ result: ActionResult) async {
        remember(result.referent)
        if let card = result.card { show(card) }
        if result.earcon != .none { play(result.earcon) }
        var text = result.speech.text(for: preferences.verbosity)
        if result.isPersonal, preferences.speechPrivacy == .headphonesForPersonal, !deps.device().usesPrivateAudio, result.card != nil {
            text = "Here you go."
        }
        if let text, !text.isEmpty { await say(text) }
        if let offer = result.followUp, headlessBuffer == nil {
            let answer = await ask(.offer(offer.prompt), prompt: offer.prompt, card: nil, timeout: 12)
            if case .confirmed = answer {
                let call = ToolCall(name: offer.toolName, arguments: offer.arguments, origin: .followUp)
                await perform(call)
            } else if case .newRequest(let text) = answer {
                redirect(to: text)
            }
        }
    }

    private func remember(_ referent: Referent?) {
        if let referent { lastReferent = (referent, now) }
    }

    /// Speaks (or, in discreet/headless mode, shows) a reply.
    private func say(_ text: String, expectReply: Bool = false, waitForCompletion: Bool = false) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastReply = trimmed
        if headlessBuffer != nil {
            headlessBuffer?.append(trimmed)
            return
        }
        replyCaption = trimmed
        if preferences.speechPrivacy == .discreet {
            show(.status(StatusCard(symbol: "text.bubble", title: trimmed, tone: .info)))
            return
        }
        if phase != .waiting { phase = .speaking }
        echoGuard.speaking(trimmed)
        deps.speechOutput.enqueue(SpokenUtterance(text: trimmed, rate: preferences.speechRate, volume: preferences.speechVolume,
                                                  voiceIdentifier: preferences.voiceIdentifier))
        if waitForCompletion { await deps.speechOutput.waitUntilFinished() }
    }

    /// After a turn: listen again if conversation continues, otherwise go quiet.
    private func concludeTurn() async {
        guard !Task.isCancelled else { return }
        await deps.speechOutput.waitUntilFinished()
        guard !Task.isCancelled, pending == nil else { return }
        echoGuard.reset()
        activity = nil
        if preferences.conversationMode {
            startListening(earcon: false)
        } else {
            stopListening()
            phase = .idle
            transcript = ""
        }
    }

    private func endSession() {
        lastReferent = nil
        lastReply = nil
        Task { await deps.reasoner?.reset() }
    }

    // MARK: - Control

    private func handleControl(_ command: ControlCommand) async {
        lastInteractionAt = now
        switch command {
        case .stop:
            let wasBusy = phase == .speaking || phase == .thinking || phase == .waiting
            interrupt()
            if !wasBusy, let music = deps.music, await music.isPlaying() {
                await perform(ToolCall(name: "control_playback", arguments: ["action": "pause"], origin: .fastPath))
            }
            finishQuietly()
        case .dismiss:
            interrupt()
            play(.cancelled)
            finishQuietly()
        case .cancel:
            let hadWork = turnTask != nil || pending != nil
            interrupt()
            if hadWork {
                play(.cancelled)
                finishQuietly()
            } else {
                await undoLast(spokenFallback: "There's nothing to cancel.")
                await concludeTurn()
            }
        case .undo:
            interrupt()
            await undoLast(spokenFallback: nil)
            await concludeTurn()
        case .hold:
            deps.speechOutput.pause()
            phase = .listening
            startListening(earcon: false)
        case .resume:
            deps.speechOutput.resume()
            if deps.speechOutput.isSpeaking { phase = .speaking } else { finishQuietly() }
        case .repeatLast:
            interrupt()
            await say(lastReply ?? "I haven't said anything yet.")
            await concludeTurn()
        case .status:
            let description: String
            if let pendingKind = pending?.kind {
                switch pendingKind {
                case .confirmation(let request): description = "I'm waiting for you to confirm: \(request.title.lowercasedFirst)."
                case .choice(let request): description = request.prompt
                case .slot(let slot): description = slot.prompt
                case .offer(let prompt): description = prompt
                }
            } else if let activity, turnTask != nil {
                description = "\(activity)."
            } else {
                description = "Nothing right now — I'm listening."
            }
            await say(description)
            if pending == nil { await concludeTurn() }
        case .explainLast:
            interrupt()
            if let entry = await deps.engine.journal.lastCompleted() {
                let when = SpokenFormatter(context: deps.temporal(), now: now).when(entry.date, includeTime: true)
                await say("\(entry.summary), \(when.hasPrefix("at ") ? when : "\(when)").")
            } else {
                await say("I haven't done anything yet.")
            }
            await concludeTurn()
        case .done:
            interrupt()
            play(.cancelled)
            endSession()
            finishQuietly()
        case .adjustSpeech(let adjustment):
            await deps.preferences.update { preferences in
                switch adjustment {
                case .louder: preferences.speechVolume = min(1, preferences.speechVolume + 0.2)
                case .quieter: preferences.speechVolume = max(0.2, preferences.speechVolume - 0.2)
                case .faster: preferences.speechRate = min(0.65, preferences.speechRate + 0.06)
                case .slower: preferences.speechRate = max(0.35, preferences.speechRate - 0.06)
                }
            }
            await refreshPreferences()
            await say("Okay, like this?")
            await concludeTurn()
        case .setDiscreet(let on):
            await deps.preferences.update { $0.speechPrivacy = on ? .discreet : .always }
            await refreshPreferences()
            play(.success)
            if !on { await say("Okay, I'll talk out loud again.") }
            await concludeTurn()
        }
    }

    private func undoLast(spokenFallback: String?) async {
        let outcome = await deps.engine.undoLast(context: makeContext(origin: .undo))
        switch outcome {
        case .completed(let result):
            play(.cancelled)
            await say(result.speech.text(for: preferences.verbosity) ?? "Undone.")
            lastReferent = nil
        case .failed(let failure):
            await say(spokenFallback ?? failure.message)
        default:
            break
        }
    }

    private func finishQuietly() {
        stopListening()
        phase = .idle
        transcript = ""
        activity = nil
    }

    // MARK: - Cards

    private func show(_ card: Card) {
        cards.removeAll { $0.id == card.id || Self.sameKind($0, card) }
        cards.append(card)
        if cards.count > 2 { cards.removeFirst(cards.count - 2) }
        cardTimers[card.id]?.cancel()
        if !card.requiresInteraction, card.lifetime.isFinite {
            let id = card.id
            cardTimers[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(card.lifetime * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.cards.removeAll { $0.id == id }
                self?.cardTimers[id] = nil
            }
        }
    }

    private static func sameKind(_ lhs: Card, _ rhs: Card) -> Bool {
        switch (lhs, rhs) {
        case (.status, .status), (.agenda, .agenda), (.weather, .weather), (.place, .place), (.nowPlaying, .nowPlaying),
             (.list, .list), (.sources, .sources), (.permission, .permission):
            return true
        default:
            return false
        }
    }

    private func removeInteractiveCards() {
        cards.removeAll { $0.requiresInteraction }
    }

    // MARK: - Helpers

    private func play(_ earcon: Earcon) {
        guard preferences.playEarcons, headlessBuffer == nil, earcon != .none else { return }
        deps.earcons?.play(earcon)
    }

    private func refreshPreferences() async {
        let latest = await deps.preferences.current()
        if latest != preferences { preferences = latest }
    }

    private func makeContext(origin: CallOrigin) -> ExecutionContext {
        let referent = lastReferent.flatMap { now.timeIntervalSince($0.at) < sessionTimeout ? $0.referent : nil }
        return ExecutionContext(now: now, temporal: deps.temporal(), preferences: preferences, device: deps.device(), origin: origin,
                                lastReferent: referent, utterance: currentTurnText)
    }
}

// MARK: - Pending interaction plumbing

enum PendingAnswer: Sendable, Equatable {
    case confirmed, declined, cancelled, timeout, headless
    case chose(ChoiceOption)
    case text(String)
    case newRequest(String)
}

@MainActor
final class PendingInteraction {
    enum Kind {
        case confirmation(ConfirmationRequest)
        case choice(ChoiceRequest)
        case slot(SlotRequest)
        case offer(String)
    }

    let kind: Kind
    let cardID: String?
    private var continuation: CheckedContinuation<PendingAnswer, Never>?
    private var result: PendingAnswer?

    init(kind: Kind, cardID: String?) {
        self.kind = kind
        self.cardID = cardID
    }

    var isResolved: Bool { result != nil }

    func resolve(_ answer: PendingAnswer) {
        guard result == nil else { return }
        result = answer
        continuation?.resume(returning: answer)
        continuation = nil
    }

    func answer() async -> PendingAnswer {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }
}

struct RuntimeToolExecutor: ToolExecutor {
    let block: @Sendable (ToolCall, Bool) async -> ToolOutcome

    func resolve(_ call: ToolCall, externalContent: Bool) async -> ToolOutcome {
        await block(call, externalContent)
    }
}

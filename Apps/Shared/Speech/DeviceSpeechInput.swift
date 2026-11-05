import AVFoundation
import CoreMedia
import Foundation
import Speech
import AsideKit

/// Microphone capture plus on-device speech recognition.
///
/// Uses SpeechAnalyzer/SpeechTranscriber (fully on device) when its model for the user's
/// language is installed. On first run, while that model downloads in the background,
/// it falls back to SFSpeechRecognizer — on device where supported.
@MainActor
final class DeviceSpeechInput: SpeechInput {
    private let audio: VoiceAudioEngine
    private let sink = CaptureSink()
    private var events: (@MainActor (SpeechInputEvent) -> Void)?
    private(set) var isCapturing = false

    // SpeechAnalyzer
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""
    private var turnBoundary: Double = 0

    // Fallback
    private var recognizer: SFSpeechRecognizer?
    private var legacyTask: SFSpeechRecognitionTask?
    private var legacyGeneration = 0

    private var locale = Locale.current

    init(audio: VoiceAudioEngine) {
        self.audio = audio
        audio.onInputLevel = { [weak self] level in self?.events?(.level(level)) }
        audio.onVoiceActivity = { [weak self] active in self?.events?(.voiceActivity(active)) }
        audio.onRouteChange = { [weak self] privateAudio in self?.events?(.routeChanged(privateAudio: privateAudio)) }
        audio.onInterruption = { [weak self] in
            guard let self, self.isCapturing else { return }
            self.stop()
            self.events?(.interrupted(.systemInterruption))
        }
    }

    // MARK: SpeechInput

    func start(locale: Locale, events: @escaping @MainActor (SpeechInputEvent) -> Void) async throws {
        self.events = events
        self.locale = locale
        try await ensureMicrophonePermission()
        if let transcriber = await installedTranscriber(for: locale) {
            try await startAnalyzer(transcriber)
        } else {
            Task.detached(priority: .utility) { await DeviceSpeechInput.prepareAssets(for: locale) }
            try await startLegacy(locale: locale)
        }
        isCapturing = true
    }

    func beginTurn() {
        finalized = ""
        volatile = ""
        turnBoundary = sink.secondsFed
        if recognizer != nil, isCapturing { restartLegacyRequest() }
    }

    func stop() {
        guard isCapturing || analyzer != nil || legacyTask != nil else { return }
        isCapturing = false
        audio.stopCapture()
        sink.clear()
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            self.analyzer = nil
            Task { await analyzer.cancelAndFinishNow() }
        }
        legacyTask?.cancel()
        legacyTask = nil
        recognizer = nil
        finalized = ""
        volatile = ""
    }

    // MARK: Permission

    private func ensureMicrophonePermission() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw SpeechInputFailure.microphoneDenied
        default:
            guard await AVAudioApplication.requestRecordPermission() else { throw SpeechInputFailure.microphoneDenied }
        }
    }

    // MARK: SpeechAnalyzer

    private func installedTranscriber(for locale: Locale) async -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [.audioTimeRange])
        let status = await AssetInventory.status(forModules: [transcriber])
        return status == .installed ? transcriber : nil
    }

    /// Downloads the on-device speech model for a language ahead of first use.
    nonisolated static func prepareAssets(for locale: Locale) async {
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            _ = try? await AssetInventory.reserve(locale: supported)
        } catch {
            // Try again next launch.
        }
    }

    private func startAnalyzer(_ transcriber: SpeechTranscriber) async throws {
        let modules: [any SpeechModule] = [transcriber]
        let analyzer = SpeechAnalyzer(modules: modules, options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw SpeechInputFailure.recognizerUnavailable("No compatible audio format")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        finalized = ""
        volatile = ""
        sink.setAnalyzer(continuation: continuation, format: format)
        turnBoundary = 0

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let end = result.range.end.seconds
                    let isFinal = result.isFinal
                    self?.handleAnalyzerResult(text: text, isFinal: isFinal, endTime: end.isFinite ? end : .infinity)
                }
            } catch {
                guard let self, self.isCapturing else { return }
                self.stop()
                self.events?(.interrupted(.recognizerUnavailable("\(error)")))
            }
        }

        do {
            try audio.startCapture { [sink] buffer, _ in sink.consume(buffer) }
        } catch {
            stop()
            throw error
        }
    }

    private func handleAnalyzerResult(text: String, isFinal: Bool, endTime: Double) {
        // Ignore the tail of the previous turn.
        guard endTime > turnBoundary + 0.05 else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !trimmed.isEmpty { finalized = finalized.isEmpty ? trimmed : finalized + " " + trimmed }
            volatile = ""
        } else {
            volatile = trimmed
        }
        let combined = [finalized, volatile].filter { !$0.isEmpty }.joined(separator: " ")
        events?(.transcript(combined, isFinal: volatile.isEmpty))
    }

    // MARK: SFSpeechRecognizer fallback

    private func startLegacy(locale: Locale) async throws {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw SpeechInputFailure.recognizerUnavailable("Speech recognition is turned off for Aside in Settings.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw SpeechInputFailure.recognizerUnavailable("Speech recognition isn't available right now.")
        }
        self.recognizer = recognizer
        restartLegacyRequest()
        do {
            try audio.startCapture { [sink] buffer, _ in sink.consume(buffer) }
        } catch {
            stop()
            throw error
        }
    }

    private func restartLegacyRequest() {
        guard let recognizer else { return }
        legacyTask?.finish()
        legacyGeneration += 1
        let generation = legacyGeneration
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        sink.setLegacy(request)
        legacyTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil && result == nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.legacyGeneration else { return }
                    if let text { self.events?(.transcript(text, isFinal: isFinal)) }
                    if failed, self.isCapturing {
                        // Recognition requests time out after long silences; start a fresh one.
                        self.restartLegacyRequest()
                    }
                }
            }
        }
    }
}

/// Receives microphone buffers on the audio thread and forwards them to the active recognizer.
final class CaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    private var fed: Double = 0

    var secondsFed: Double {
        lock.lock(); defer { lock.unlock() }
        return fed
    }

    func setAnalyzer(continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        self.continuation?.finish()
        self.continuation = continuation
        targetFormat = format
        converter = nil
        legacyRequest = nil
        fed = 0
    }

    func setLegacy(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock(); defer { lock.unlock() }
        legacyRequest?.endAudio()
        legacyRequest = request
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
        legacyRequest?.endAudio()
        legacyRequest = nil
        converter = nil
        targetFormat = nil
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if let legacyRequest {
            legacyRequest.append(buffer)
            return
        }
        guard let continuation, let targetFormat else { return }
        var input = buffer
        if buffer.format != targetFormat {
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            }
            guard let converter, let converted = AudioConversion.convert(buffer, with: converter, to: targetFormat) else { return }
            input = converted
        }
        fed += Double(input.frameLength) / targetFormat.sampleRate
        continuation.yield(AnalyzerInput(buffer: input))
    }
}

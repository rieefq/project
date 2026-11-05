import AVFoundation
import Foundation
import AsideKit

/// One audio graph for the whole interaction: microphone with voice processing (echo
/// cancellation, so the user can interrupt while Aside talks), a player for speech and a
/// player for earcons. The engine runs only while Aside is active.
@MainActor
final class VoiceAudioEngine {
    private let engine = AVAudioEngine()
    private let speechPlayer = AVAudioPlayerNode()
    private let earconPlayer = AVAudioPlayerNode()
    let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    private var isConfigured = false
    private var isCapturing = false
    private var captureHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var monitor: InputMonitor?
    private var idleStop: Task<Void, Never>?
    private var converters: [String: AVAudioConverter] = [:]
    private lazy var earcons = EarconSynth(format: playbackFormat)

    /// Smoothed microphone level (0…1) and voice activity, reported on the main actor.
    var onInputLevel: ((Float) -> Void)?
    var onVoiceActivity: ((Bool) -> Void)?
    /// The route changed or the engine was reconfigured by the system.
    var onRouteChange: ((Bool) -> Void)?
    var onInterruption: (() -> Void)?

    private(set) var outputLevel: Float = 0
    private(set) var usesPrivateAudio = false

    init() {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
        #if os(iOS)
        AudioSessionController.shared.onInterruption = { [weak self] began in
            guard let self else { return }
            if began { self.stopCapture(); self.onInterruption?() }
        }
        AudioSessionController.shared.onRouteChange = { [weak self] privateAudio in
            self?.usesPrivateAudio = privateAudio
            self?.onRouteChange?(privateAudio)
        }
        usesPrivateAudio = AudioSessionController.shared.usesPrivateAudio
        #endif
    }

    // MARK: Setup

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }
        #if os(iOS)
        try AudioSessionController.shared.activate()
        #endif
        // Voice processing gives echo cancellation and noise suppression; it must be set before starting.
        try engine.inputNode.setVoiceProcessingEnabled(true)
        engine.attach(speechPlayer)
        engine.attach(earconPlayer)
        engine.connect(speechPlayer, to: engine.mainMixerNode, format: playbackFormat)
        engine.connect(earconPlayer, to: engine.mainMixerNode, format: playbackFormat)
        speechPlayer.installTap(onBus: 0, bufferSize: 1_024, format: playbackFormat) { [weak self] buffer, _ in
            let level = InputMonitor.rms(buffer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.outputLevel = self.outputLevel * 0.6 + min(1, level * 4) * 0.4
                }
            }
        }
        isConfigured = true
    }

    private func startEngineIfNeeded() throws {
        try configureIfNeeded()
        idleStop?.cancel()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// Stops the engine shortly after everything is quiet, to save power.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, !self.isCapturing, !self.speechPlayer.isPlaying else { return }
            self.engine.stop()
            #if os(iOS)
            AudioSessionController.shared.deactivate()
            #endif
            self.outputLevel = 0
        }
    }

    // MARK: Capture

    /// Starts delivering microphone buffers (on the audio thread) to `handler`.
    func startCapture(_ handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        try configureIfNeeded()
        captureHandler = handler
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechInputFailure.audioFailure("No microphone input is available.")
        }
        let monitor = InputMonitor()
        self.monitor = monitor
        monitor.onLevel = { [weak self] level in self?.onInputLevel?(level) }
        monitor.onVoiceActivity = { [weak self] active in self?.onVoiceActivity?(active) }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, time in
            handler(buffer, time)
            monitor.process(buffer)
        }
        isCapturing = true
        try startEngineIfNeeded()
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        isCapturing = false
        captureHandler = nil
        monitor = nil
        scheduleIdleStop()
    }

    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    private func handleConfigurationChange() {
        // The system stopped the engine (route change, device change). Rebuild capture if it was running.
        #if os(iOS)
        usesPrivateAudio = AudioSessionController.shared.usesPrivateAudio
        #endif
        onRouteChange?(usesPrivateAudio)
        guard let handler = captureHandler, isCapturing else { return }
        isCapturing = false
        do {
            try startCapture(handler)
        } catch {
            onInterruption?()
        }
    }

    // MARK: Playback

    /// Schedules a synthesized speech buffer; `completion` runs (on the main actor) once it has played.
    func scheduleSpeech(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        do { try startEngineIfNeeded() } catch { completion(); return }
        guard let converted = convert(buffer, to: playbackFormat) else { completion(); return }
        speechPlayer.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async { completion() }
        }
        if !speechPlayer.isPlaying { speechPlayer.play() }
    }

    func stopSpeech() {
        speechPlayer.stop()
        speechPlayer.volume = 1
        outputLevel = 0
        scheduleIdleStop()
    }

    func pauseSpeech() { speechPlayer.pause() }
    func resumeSpeech() { speechPlayer.play() }
    func duckSpeech(_ ducked: Bool) { speechPlayer.volume = ducked ? 0.35 : 1 }

    func speechDidFinish() { scheduleIdleStop() }

    func play(_ earcon: Earcon) {
        guard let buffer = earcons.buffer(for: earcon) else { return }
        do { try startEngineIfNeeded() } catch { return }
        earconPlayer.scheduleBuffer(buffer, at: nil, options: [.interrupts]) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleIdleStop() } }
        }
        if !earconPlayer.isPlaying { earconPlayer.play() }
    }

    // MARK: Conversion

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        let key = "\(buffer.format.sampleRate)-\(buffer.format.channelCount)-\(buffer.format.commonFormat.rawValue)->\(format.sampleRate)-\(format.channelCount)-\(format.commonFormat.rawValue)"
        let converter: AVAudioConverter
        if let cached = converters[key] {
            converter = cached
        } else {
            guard let made = AVAudioConverter(from: buffer.format, to: format) else { return nil }
            converters[key] = made
            converter = made
        }
        return AudioConversion.convert(buffer, with: converter, to: format)
    }
}

/// Stateless buffer conversion helper usable from any thread with a thread-confined converter.
enum AudioConversion {
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil { return nil }
        return output
    }
}

/// Microphone level metering and energy-based voice activity detection with an adaptive
/// noise floor. Runs on the audio thread; reports to the main actor at ~30 Hz.
final class InputMonitor: @unchecked Sendable {
    var onLevel: ((Float) -> Void)?
    var onVoiceActivity: ((Bool) -> Void)?

    private var noiseFloor: Float = -55
    private var speaking = false
    private var lastVoiceAt: TimeInterval = 0
    private var lastReport: TimeInterval = 0
    private var smoothed: Float = 0

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let count = Int(buffer.frameLength)
        for index in 0..<count { sum += channel[index] * channel[index] }
        return sqrt(sum / Float(count))
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let level = Self.rms(buffer)
        let decibels = 20 * log10(max(level, 0.000_01))
        let now = ProcessInfo.processInfo.systemUptime
        // Noise floor: falls quickly, rises slowly.
        if decibels < noiseFloor { noiseFloor = noiseFloor * 0.9 + decibels * 0.1 } else { noiseFloor = noiseFloor * 0.998 + decibels * 0.002 }
        noiseFloor = min(max(noiseFloor, -75), -25)
        let threshold = speaking ? noiseFloor + 7 : noiseFloor + 13
        if decibels > threshold { lastVoiceAt = now }
        let active = now - lastVoiceAt < 0.35
        let normalized = max(0, min(1, (decibels - noiseFloor) / 40))
        smoothed = smoothed * 0.5 + normalized * 0.5
        let changed = active != speaking
        speaking = active
        guard changed || now - lastReport > 0.033 else { return }
        lastReport = now
        let value = smoothed
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onLevel?(value)
            if changed { self.onVoiceActivity?(active) }
        }
    }
}

/// Short, quiet, synthesized interface sounds. No audio assets to ship or license.
final class EarconSynth {
    private let format: AVAudioFormat
    private var cache: [Earcon: AVAudioPCMBuffer] = [:]

    init(format: AVAudioFormat) { self.format = format }

    struct Note { var frequency: Double; var start: Double; var duration: Double; var gain: Double }

    func buffer(for earcon: Earcon) -> AVAudioPCMBuffer? {
        if let cached = cache[earcon] { return cached }
        let notes: [Note]
        switch earcon {
        case .none: return nil
        case .listening: notes = [Note(frequency: 880, start: 0, duration: 0.09, gain: 0.5), Note(frequency: 1_318.5, start: 0.07, duration: 0.14, gain: 0.42)]
        case .heard: notes = [Note(frequency: 1_046.5, start: 0, duration: 0.06, gain: 0.28)]
        case .success: notes = [Note(frequency: 1_567.98, start: 0, duration: 0.12, gain: 0.32), Note(frequency: 2_093, start: 0.045, duration: 0.16, gain: 0.2)]
        case .cancelled: notes = [Note(frequency: 1_318.5, start: 0, duration: 0.08, gain: 0.38), Note(frequency: 880, start: 0.065, duration: 0.13, gain: 0.36)]
        case .failure: notes = [Note(frequency: 440, start: 0, duration: 0.12, gain: 0.42), Note(frequency: 415.3, start: 0.13, duration: 0.17, gain: 0.38)]
        case .attention: notes = [Note(frequency: 987.77, start: 0, duration: 0.1, gain: 0.36), Note(frequency: 987.77, start: 0.14, duration: 0.1, gain: 0.3)]
        case .working: notes = [Note(frequency: 660, start: 0, duration: 0.05, gain: 0.18)]
        }
        let sampleRate = format.sampleRate
        let total = (notes.map { $0.start + $0.duration }.max() ?? 0.1) + 0.05
        let frames = AVAudioFrameCount(total * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for index in 0..<Int(frames) { data[index] = 0 }
        let masterGain = 0.16
        for note in notes {
            let startFrame = Int(note.start * sampleRate)
            let length = Int(note.duration * sampleRate)
            for offset in 0..<length where startFrame + offset < Int(frames) {
                let t = Double(offset) / sampleRate
                let attack = min(1, t / 0.006)
                let decay = exp(-t / (note.duration * 0.35))
                let tone = sin(2 * .pi * note.frequency * t) + 0.18 * sin(4 * .pi * note.frequency * t)
                data[startFrame + offset] += Float(tone * attack * decay * note.gain * masterGain)
            }
        }
        cache[earcon] = buffer
        return buffer
    }
}

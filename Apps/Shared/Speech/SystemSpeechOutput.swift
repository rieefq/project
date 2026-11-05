import AVFoundation
import Foundation
import AsideKit

/// On-device speech synthesis routed through the shared audio engine, so echo
/// cancellation hears exactly what Aside says and the user can talk over it.
@MainActor
final class SystemSpeechOutput: NSObject, SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()
    private let audio: VoiceAudioEngine
    private var queue: [SpokenUtterance] = []
    private var current: SpokenUtterance?
    private var pendingBuffers = 0
    private var synthesisFinished = false
    private var generation = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isPaused = false

    var onUtteranceStart: (@MainActor (String) -> Void)?

    init(audio: VoiceAudioEngine) {
        self.audio = audio
        super.init()
    }

    var isSpeaking: Bool { current != nil || !queue.isEmpty }
    var level: Float { isSpeaking ? audio.outputLevel : 0 }

    func enqueue(_ utterance: SpokenUtterance) {
        queue.append(utterance)
        if current == nil { startNext() }
    }

    func waitUntilFinished() async {
        guard isSpeaking else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func stop() {
        generation += 1
        queue.removeAll()
        current = nil
        pendingBuffers = 0
        isPaused = false
        synthesizer.stopSpeaking(at: .immediate)
        audio.stopSpeech()
        resumeWaiters()
    }

    func pause() {
        guard isSpeaking, !isPaused else { return }
        isPaused = true
        audio.pauseSpeech()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        audio.resumeSpeech()
    }

    func duck(_ ducked: Bool) { audio.duckSpeech(ducked) }

    // MARK: Queue

    private func startNext() {
        guard !queue.isEmpty else {
            current = nil
            audio.speechDidFinish()
            resumeWaiters()
            return
        }
        let next = queue.removeFirst()
        current = next
        pendingBuffers = 0
        synthesisFinished = false
        let token = generation
        let utterance = AVSpeechUtterance(string: next.text)
        utterance.rate = Float(min(max(next.rate, 0.3), 0.7))
        utterance.volume = Float(min(max(next.volume, 0.1), 1))
        utterance.voice = VoiceCatalog.voice(identifier: next.voiceIdentifier)
        utterance.postUtteranceDelay = 0.05
        onUtteranceStart?(next.text)
        synthesizer.write(utterance) { [weak self] buffer in
            let pcm = buffer as? AVAudioPCMBuffer
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(pcm, token: token) }
            }
        }
    }

    private func receive(_ buffer: AVAudioPCMBuffer?, token: Int) {
        guard token == generation else { return }
        guard let buffer, buffer.frameLength > 0 else {
            synthesisFinished = true
            if pendingBuffers == 0 { finishCurrent() }
            return
        }
        pendingBuffers += 1
        audio.scheduleSpeech(buffer) { [weak self] in
            MainActor.assumeIsolated { self?.bufferPlayed(token: token) }
        }
    }

    private func bufferPlayed(token: Int) {
        guard token == generation else { return }
        pendingBuffers -= 1
        if synthesisFinished && pendingBuffers <= 0 { finishCurrent() }
    }

    private func finishCurrent() {
        current = nil
        startNext()
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// The voices available for Aside, best quality first.
enum VoiceCatalog {
    struct Option: Identifiable, Hashable {
        var id: String
        var name: String
        var detail: String
    }

    static func voice(identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
        return bestVoice(for: Locale.current)
    }

    static func bestVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language == language && !voice.voiceTraits.contains(.isNoveltyVoice)
        }
        return candidates.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }

    static func options() -> [Option] {
        let language = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
            .map { voice in
                let quality: String
                switch voice.quality {
                case .premium: quality = "Premium"
                case .enhanced: quality = "Enhanced"
                default: quality = "Standard"
                }
                let personal = voice.voiceTraits.contains(.isPersonalVoice) ? " · Personal Voice" : ""
                return Option(id: voice.identifier, name: voice.name, detail: "\(quality) · \(voice.language)\(personal)")
            }
    }
}

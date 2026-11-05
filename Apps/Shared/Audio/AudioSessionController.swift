#if os(iOS)
import AVFoundation
import Foundation

/// Configures the shared audio session for a voice conversation and reports interruptions
/// (calls, Siri, other apps) and route changes (AirPods connected, Bluetooth, speaker).
@MainActor
final class AudioSessionController {
    static let shared = AudioSessionController()

    var onInterruption: ((Bool) -> Void)?
    var onRouteChange: ((Bool) -> Void)?
    private(set) var isActive = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated { self?.onInterruption?(began) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onRouteChange?(self.usesPrivateAudio)
            }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isActive = false
                self?.onInterruption?(true)
            }
        }
    }

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        // Play and record for barge-in; Bluetooth HFP so AirPods' microphone works; duck
        // other audio rather than stopping it.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers])
        try session.setActive(true)
        isActive = true
    }

    func deactivate() {
        guard isActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isActive = false
    }

    /// Headphones, AirPods or a car — places where speaking personal details is private.
    var usesPrivateAudio: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let privatePorts: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio]
        return outputs.contains { privatePorts.contains($0.portType) }
    }
}
#endif

import Foundation
import Network
import Observation
import AsideKit
#if os(iOS)
import UIKit
#endif

/// Composition root: builds every service once and wires them into the agent runtime.
@MainActor
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let store: EncryptedFileStore
    let preferences: PreferencesStore
    let memory: MemoryStore
    let journal: ActionJournal
    let proactivity: ProactivityLedger
    let engine: ActionEngine
    let runtime: AgentRuntime
    let audio: VoiceAudioEngine
    let credentials: CredentialStore
    let reasoner: ClaudeReasoner
    let location: LocationProvider
    let spotify: SpotifyService
    let appleMusic: AppleMusicService
    let reminders: EventKitReminders
    let calendar: EventKitCalendar
    let contacts: SystemContacts
    let notifications: UserNotificationScheduler
    let weather: AppleWeather

    /// Mirrors the stored preferences for SwiftUI.
    private(set) var currentPreferences = Preferences()
    let connectivity = Connectivity()
    var isOnline: Bool { connectivity.isOnline }

    private init() {
        let store = EncryptedFileStore()
        self.store = store
        let preferences = PreferencesStore(store: store)
        self.preferences = preferences
        memory = MemoryStore(store: store)
        journal = ActionJournal(store: store)
        proactivity = ProactivityLedger(store: store)

        location = LocationProvider()
        reminders = EventKitReminders()
        calendar = EventKitCalendar()
        contacts = SystemContacts()
        notifications = UserNotificationScheduler()
        weather = AppleWeather(location: location)
        appleMusic = AppleMusicService()
        spotify = SpotifyService(clientID: Bundle.main.object(forInfoDictionaryKey: "AsideSpotifyClientID") as? String ?? "")

        #if os(iOS)
        let communication: any CommunicationService = PhoneCommunication()
        #else
        let communication: any CommunicationService = MacCommunication()
        #endif

        let services = AsideServices(reminders: reminders, calendar: calendar, notifications: notifications,
                                     music: [appleMusic, spotify], weather: weather, places: MapKitPlaces(location: location),
                                     contacts: contacts, communication: communication)
        let assembly = Toolbox.assemble(services: services, memory: memory, preferences: preferences, store: store)
        engine = ActionEngine(registry: assembly.registry, journal: journal, authenticator: BiometricAuthenticator())
        assembly.engineHandle.engine = engine

        let credentials = CredentialStore()
        self.credentials = credentials
        reasoner = ClaudeReasoner(configuration: ClaudeConfiguration(baseURL: credentials.relayURL ?? URL(string: "https://api.anthropic.com")!)) {
            await MainActor.run { credentials.credential() }
        }

        audio = VoiceAudioEngine()
        let input = DeviceSpeechInput(audio: audio)
        let output = SystemSpeechOutput(audio: audio)
        let earcons = EngineEarcons(audio: audio)
        let audio = self.audio

        var platform = PlatformKind.macOS
        #if os(iOS)
        platform = .iOS
        #endif
        let devicePlatform = platform
        let connectivity = self.connectivity

        runtime = AgentRuntime(dependencies: AgentDependencies(
            speechInput: input, speechOutput: output, earcons: earcons, engine: engine, memory: memory, preferences: preferences,
            reasoner: reasoner, localModel: OnDeviceIntentModel(), music: assembly.music,
            temporal: { TemporalContext(calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent) },
            device: {
                var locked = false
                #if os(iOS)
                locked = !UIApplication.shared.isProtectedDataAvailable
                #endif
                return DeviceContext(platform: devicePlatform, isLocked: locked, usesPrivateAudio: audio.usesPrivateAudio,
                                     isOnline: connectivity.isOnline)
            },
            locality: location))

        UserNotificationScheduler.registerCategories()
        connectivity.start()
        Task { await self.loadPreferences() }
    }

    private func loadPreferences() async {
        currentPreferences = await preferences.current()
        applyToReasoner(currentPreferences)
        await journal.setRetention(days: currentPreferences.journalRetentionDays)
        await preferences.observe { [weak self] updated in
            Task { @MainActor in
                self?.currentPreferences = updated
                self?.applyToReasoner(updated)
            }
        }
        // Download the on-device speech model ahead of first use.
        let locale = Locale.current
        Task.detached(priority: .background) { await DeviceSpeechInput.prepareAssets(for: locale) }
    }

    private func applyToReasoner(_ preferences: Preferences) {
        let configuration = ClaudeConfiguration(baseURL: credentials.relayURL ?? URL(string: "https://api.anthropic.com")!,
                                                model: preferences.cloudModel, webSearch: preferences.allowWebSearch)
        Task { await reasoner.update(configuration: configuration) }
    }

    // MARK: Settings actions

    func update(_ mutate: @escaping @Sendable (inout Preferences) -> Void) {
        Task { await preferences.update(mutate) }
    }

    func cloudConfigurationChanged() {
        applyToReasoner(currentPreferences)
        Task { await reasoner.reset() }
    }

    /// Deletes everything Aside stores: memory, journal, preferences, timers, credentials, and the encryption key.
    func eraseAllData() async {
        await memory.removeAll()
        await journal.clear()
        await proactivity.reset()
        await preferences.replace(with: Preferences())
        credentials.removeAll()
        spotify.disconnect()
        await reasoner.reset()
        await store.eraseAll()
    }
}

/// Network reachability, so Aside can say "I'm offline" instead of failing slowly.
@MainActor
@Observable
final class Connectivity {
    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "app.aside.network"))
    }
}

@MainActor
final class EngineEarcons: EarconPlayer {
    private let audio: VoiceAudioEngine
    init(audio: VoiceAudioEngine) { self.audio = audio }
    func play(_ earcon: Earcon) { audio.play(earcon) }
}

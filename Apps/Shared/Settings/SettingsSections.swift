import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import AsideKit

/// Binding into stored preferences.
@MainActor
func preference<Value>(_ environment: AppEnvironment, _ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
    Binding(get: { environment.currentPreferences[keyPath: keyPath] },
            set: { value in environment.update { $0[keyPath: keyPath] = value } })
}

// MARK: - Voice

struct VoiceSettings: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var voices: [VoiceCatalog.Option] = []

    var body: some View {
        Form {
            Section {
                Picker("Voice", selection: preference(environment, \.voiceIdentifier)) {
                    Text("Automatic (best available)").tag(String?.none)
                    ForEach(voices) { voice in
                        Text("\(voice.name) — \(voice.detail)").tag(String?.some(voice.id))
                    }
                }
                LabeledContent("Speaking rate") {
                    Slider(value: preference(environment, \.speechRate), in: 0.35...0.65)
                }
                Picker("How much I say", selection: preference(environment, \.verbosity)) {
                    ForEach(Verbosity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Personality", selection: preference(environment, \.personality)) {
                    ForEach(Personality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("Download Enhanced and Premium voices, or create a Personal Voice, in the system's Accessibility settings under Spoken Content.")
            }

            Section("Speaking aloud") {
                Picker("Speak", selection: preference(environment, \.speechPrivacy)) {
                    ForEach(SpeechPrivacy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Interface sounds", isOn: preference(environment, \.playEarcons))
                Toggle("Show live captions", isOn: preference(environment, \.showLiveCaption))
            }

            Section {
                Toggle("Let me interrupt while Aside talks", isOn: preference(environment, \.allowInterruptions))
                Toggle("Keep listening after questions", isOn: preference(environment, \.autoListenAfterQuestions))
                Toggle("Stay in conversation", isOn: preference(environment, \.conversationMode))
            } header: {
                Text("Conversation")
            } footer: {
                Text("With “Stay in conversation” on, Aside keeps listening after each reply until you say “that's all” or stop talking.")
            }

            Section("Your name") {
                TextField("What should Aside call you?", text: Binding(
                    get: { environment.currentPreferences.preferredName ?? "" },
                    set: { value in environment.update { $0.preferredName = value.isEmpty ? nil : value } }))
            }
        }
        .formStyle(.grouped)
        .onAppear { voices = VoiceCatalog.options() }
    }
}

// MARK: - Intelligence

struct IntelligenceSettings: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var apiKey = ""
    @State private var relayURL = ""
    @State private var relayToken = ""
    @State private var instructions = ""

    private let models: [(String, String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5 — most capable"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5 — balanced"),
        ("claude-haiku-5-5", "Claude Haiku 5.5 — fastest"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Understanding", selection: preference(environment, \.reasoningMode)) {
                    ForEach(ReasoningMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Use the on-device model", isOn: preference(environment, \.useOnDeviceModel))
                LabeledContent("On-device model", value: OnDeviceIntentModel.statusDescription)
            } header: {
                Text("Where requests are understood")
            } footer: {
                Text("Everyday requests — reminders, timers, your calendar, music, notes — are understood on this device. Open questions and multi-step requests go to the cloud only when cloud understanding is on.")
            }

            Section {
                if environment.credentials.hasCredential {
                    LabeledContent("Claude API key", value: environment.credentials.maskedKey ?? "Connected through relay")
                    Button("Remove", role: .destructive) {
                        environment.credentials.setAPIKey("")
                        environment.credentials.setRelay(url: "", token: "")
                        environment.cloudConfigurationChanged()
                    }
                } else {
                    SecureField("Claude API key", text: $apiKey)
                    Button("Save key") {
                        environment.credentials.setAPIKey(apiKey)
                        apiKey = ""
                        environment.cloudConfigurationChanged()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Picker("Model", selection: preference(environment, \.cloudModel)) {
                    ForEach(models, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Search the web for current information", isOn: preference(environment, \.allowWebSearch))
            } header: {
                Text("Cloud")
            } footer: {
                Text("The key is stored in your Keychain on this device. Requests include what you said, the current time and city, and only the notes relevant to the request.")
            }

            Section("Organization relay (optional)") {
                TextField("Relay URL", text: $relayURL)
                SecureField("Relay token", text: $relayToken)
                Button("Use relay") {
                    environment.credentials.setRelay(url: relayURL, token: relayToken)
                    relayToken = ""
                    environment.cloudConfigurationChanged()
                }
                .disabled(relayURL.isEmpty || relayToken.isEmpty)
            }

            Section {
                TextField("For example: Be direct. I'm vegetarian. Use metric units.", text: $instructions, axis: .vertical)
                    .lineLimit(2...5)
                Button("Save instructions") {
                    let text = instructions
                    environment.update { $0.customInstructions = text }
                    environment.cloudConfigurationChanged()
                }
            } header: {
                Text("Your instructions")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            instructions = environment.currentPreferences.customInstructions
            relayURL = environment.credentials.relayURL?.absoluteString ?? ""
        }
    }
}

// MARK: - Connections

struct ConnectionsSettings: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var states: [Capability: AccessState] = [:]
    @State private var microphone: AccessState = .notDetermined
    @State private var spotifyError: String?

    var body: some View {
        Form {
            Section {
                row("Microphone", symbol: "mic", state: microphone) {
                    _ = await AVAudioApplication.requestRecordPermission()
                }
                row("Reminders", symbol: "checklist", state: states[.reminders]) { _ = await environment.reminders.requestAccess() }
                row("Calendar", symbol: "calendar", state: states[.calendar]) { _ = await environment.calendar.requestAccess() }
                row("Contacts", symbol: "person.crop.circle", state: states[.contacts]) { _ = await environment.contacts.requestAccess() }
                row("Location", symbol: "location", state: states[.places]) { _ = await environment.location.requestAccess() }
                row("Notifications", symbol: "bell", state: states[.timers]) { _ = await environment.notifications.requestAccess() }
            } header: {
                Text("On this device")
            } footer: {
                Text("Aside asks for each permission the first time a request needs it. You can change any of them here or in system Settings.")
            }

            Section("Music") {
                row("Apple Music", symbol: "music.note", state: states[.music]) { _ = await environment.appleMusic.requestAccess() }
                HStack {
                    Label("Spotify", systemImage: "music.quarternote.3")
                    Spacer()
                    if !environment.spotify.isConfigured {
                        Text("Not configured").foregroundStyle(.secondary)
                    } else if environment.spotify.isConnected {
                        Button("Disconnect") { environment.spotify.disconnect(); spotifyError = nil }
                    } else {
                        Button("Connect") {
                            Task {
                                do { try await environment.spotify.connect(); spotifyError = nil } catch { spotifyError = (error as? ToolFailure)?.message ?? error.localizedDescription }
                            }
                        }
                    }
                }
                if let spotifyError { Text(spotifyError).font(.footnote).foregroundStyle(.red) }
                Picker("Play music with", selection: preference(environment, \.preferredMusicProvider)) {
                    Text("Ask each time / automatic").tag(MusicProvider?.none)
                    ForEach(MusicProvider.allCases, id: \.self) { Text($0.displayName).tag(MusicProvider?.some($0)) }
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private func row(_ title: String, symbol: String, state: AccessState?, request: @escaping () async -> Void) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            switch state ?? .notDetermined {
            case .granted, .limited:
                Text(state == .limited ? "Limited" : "Allowed").foregroundStyle(.secondary)
            case .notDetermined:
                Button("Allow") { Task { await request(); await refresh() } }
            case .denied:
                Button("Open Settings") { SystemSettings.open(for: .system) }
            case .unavailable:
                Text("Unavailable").foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() async {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: microphone = .granted
        case .denied: microphone = .denied
        default: microphone = .notDetermined
        }
        states[.reminders] = await environment.reminders.access()
        states[.calendar] = await environment.calendar.access()
        states[.contacts] = await environment.contacts.access()
        states[.places] = environment.location.state
        states[.timers] = await environment.notifications.access()
        states[.music] = await environment.appleMusic.access()
    }
}

// MARK: - Memory

struct MemorySettings: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var items: [MemoryItem] = []
    @State private var confirmForgetAll = false
    @State private var exportDocument: JSONDocument?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("Remember things I ask you to", isOn: preference(environment, \.memoryEnabled))
                Picker("When Aside notices something", selection: preference(environment, \.learningMode)) {
                    ForEach(LearningMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text("Memory stays encrypted on this device. Say “forget that” or “what do you know about me?” anytime.")
            }

            ForEach(MemoryItem.Kind.allCases, id: \.self) { kind in
                let group = items.filter { $0.kind == kind }
                if !group.isEmpty {
                    Section(kind.displayName) {
                        ForEach(group) { item in
                            HStack(alignment: .firstTextBaseline) {
                                if item.isSensitive { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.text)
                                    Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    Task { await environment.memory.remove(item.id); await reload() }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Forget \(item.text)")
                            }
                        }
                    }
                }
            }

            Section {
                Button("Export memory…") {
                    Task { exportDocument = JSONDocument(data: await environment.memory.exportJSON()) }
                }
                Button("Forget everything…", role: .destructive) { confirmForgetAll = true }
                    .disabled(items.isEmpty)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .json, defaultFilename: "Aside Memory") { result in
            if case .success = result { message = "Exported." }
        }
        .confirmationDialog("Forget everything Aside remembers?", isPresented: $confirmForgetAll, titleVisibility: .visible) {
            Button("Forget Everything", role: .destructive) {
                Task {
                    if await BiometricAuthenticator().authenticate(reason: "Forget everything Aside remembers") {
                        await environment.memory.removeAll()
                        message = "Everything has been forgotten."
                        await reload()
                    }
                }
            }
        } message: {
            Text("This permanently deletes all notes, facts and preferences on this device.")
        }
    }

    private func reload() async { items = await environment.memory.all() }
}

struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: - Privacy

struct PrivacySettings: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var confirmErase = false
    @State private var erased = false

    var body: some View {
        Form {
            Section("How Aside handles your data") {
                PrivacyRow(symbol: "waveform", title: "Your voice", detail: "Speech is recognized on this device. Audio is never stored or uploaded by Aside.")
                PrivacyRow(symbol: "iphone", title: "Everyday requests", detail: "Reminders, timers, calendar, music, notes and settings are understood and handled on this device.")
                PrivacyRow(symbol: "cloud", title: "Cloud requests", detail: "When cloud understanding is on, open questions are sent with the time, your city and only relevant notes. Nothing is kept after the conversation ends.")
                PrivacyRow(symbol: "lock.shield", title: "Consequential actions", detail: "Messages, calls, deleting things and changes others see always need your tap. Voice alone never authorizes them.")
                PrivacyRow(symbol: "mic", title: "The microphone", detail: "Only on while Aside is visibly listening or talking — the system's microphone indicator shows when it is.")
            }

            Section("Suggestions") {
                Toggle("Occasional helpful suggestions", isOn: preference(environment, \.proactiveSuggestions))
                Stepper("At most \(environment.currentPreferences.maxProactiveNotificationsPerDay) a day",
                        value: preference(environment, \.maxProactiveNotificationsPerDay), in: 0...10)
                Picker("Quiet hours start", selection: preference(environment, \.quietHoursStart)) {
                    ForEach(18..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                }
                Picker("Quiet hours end", selection: preference(environment, \.quietHoursEnd)) {
                    ForEach(5..<11, id: \.self) { Text(hourLabel($0)).tag($0) }
                }
            }

            Section {
                Picker("Keep activity history", selection: preference(environment, \.journalRetentionDays)) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Button("Erase all Aside data…", role: .destructive) { confirmErase = true }
                if erased { Text("All Aside data was erased.").font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Data")
            } footer: {
                Text("Erasing removes memory, activity history, settings, saved connections and the encryption key from this device.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Erase all Aside data?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase Everything", role: .destructive) {
                Task {
                    if await BiometricAuthenticator().authenticate(reason: "Erase all Aside data") {
                        await environment.eraseAllData()
                        erased = true
                    }
                }
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct PrivacyRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Activity

struct ActivitySettings: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var entries: [JournalEntry] = []
    @State private var notice: String?

    var body: some View {
        Form {
            if entries.isEmpty {
                Text("Nothing yet. Things Aside does will show up here so you can check or undo them.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: symbol(entry.status)).foregroundStyle(color(entry.status))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.summary)
                            if let failure = entry.failure, entry.status != .completed {
                                Text(failure).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.capability.displayName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.isUndoable {
                            Button("Undo") {
                                Task {
                                    notice = await environment.runtime.undo(journalEntryID: entry.id)
                                    await reload()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } footer: {
                if let notice { Text(notice) }
            }
            if !entries.isEmpty {
                Section {
                    Button("Clear history", role: .destructive) {
                        Task { await environment.journal.clear(); await reload() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
    }

    private func reload() async { entries = await environment.journal.recent(limit: 150) }

    private func symbol(_ status: JournalEntry.Status) -> String {
        switch status {
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .declined: return "hand.raised"
        case .awaitingConfirmation: return "clock"
        case .undone: return "arrow.uturn.backward.circle"
        case .deduplicated: return "equal.circle"
        }
    }

    private func color(_ status: JournalEntry.Status) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .declined, .undone, .deduplicated, .awaitingConfirmation: return .secondary
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                Text("Aside is an AI assistant. It can make mistakes, and it tells you when it couldn't do something.")
                    .foregroundStyle(.secondary)
            }
            Section("Data providers") {
                Link(" Weather — legal attribution", destination: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!)
                Text("Answers to open questions are provided by Claude, made by Anthropic, when cloud understanding is on.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

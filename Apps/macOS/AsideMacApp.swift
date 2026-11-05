import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications
import AsideKit

@main
struct AsideMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            MacSettingsView().environment(AppEnvironment.shared)
        }
    }
}

/// Aside on the Mac is a menu bar presence: no Dock icon, no window to manage.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let environment = AppEnvironment.shared
    private var statusItem: NSStatusItem?
    private var panel: PresencePanel?
    private let hotKeys = HotKeyCenter()
    private var activationHotKey: UInt32?
    private var escapeHotKey: UInt32?
    private var pressStartedAt: Date?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    private var runtime: AgentRuntime { environment.runtime }

    /// The live delegate (with an adaptor, `NSApp.delegate` is SwiftUI's proxy, not this object).
    private(set) static weak var current: MacAppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MacAppDelegate.current = self
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        panel = PresencePanel(runtime: runtime)
        setUpStatusItem()
        registerActivationShortcut()
        observeRuntime()
        if !UserDefaults.standard.bool(forKey: "aside.welcomed") { showWelcome() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Aside")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Aside — \(Self.shortcut.display) to talk"
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if runtime.phase == .idle {
            runtime.activate(source: .tap)
        } else {
            runtime.dismiss()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let talk = NSMenuItem(title: "Talk to Aside", action: #selector(talkFromMenu), keyEquivalent: "")
        talk.target = self
        menu.addItem(talk)
        menu.addItem(.separator())
        let activity = NSMenuItem(title: "Activity…", action: #selector(showActivity), keyEquivalent: "")
        activity.target = self
        menu.addItem(activity)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Aside", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func talkFromMenu() { runtime.activate(source: .tap) }
    @objc private func showSettingsFromMenu() { showSettings() }
    @objc private func showActivity() { showSettings(tab: .activity) }

    private func updateStatusIcon() {
        let name: String
        switch runtime.phase {
        case .idle: name = "waveform"
        case .listening, .waiting: name = "mic.fill"
        case .thinking: name = "ellipsis.circle"
        case .speaking: name = "waveform.circle.fill"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Aside")
        statusItem?.button?.image?.isTemplate = true
    }

    // MARK: Shortcut

    static var shortcut: HotKeyCenter.Shortcut {
        if let data = UserDefaults.standard.data(forKey: "aside.shortcut"),
           let saved = try? JSONDecoder().decode(HotKeyCenter.Shortcut.self, from: data) { return saved }
        return .optionSpace
    }

    func registerActivationShortcut() {
        if let activationHotKey { hotKeys.unregister(activationHotKey) }
        activationHotKey = hotKeys.register(Self.shortcut, onPress: { [weak self] in self?.shortcutPressed() },
                                            onRelease: { [weak self] in self?.shortcutReleased() })
    }

    /// Hold to talk; tap to talk hands-free; tap again while listening to finish.
    private func shortcutPressed() {
        switch runtime.phase {
        case .listening:
            runtime.pushToTalkEnded()
            pressStartedAt = nil
        default:
            pressStartedAt = Date()
            runtime.activate(source: .pushToTalk)
        }
    }

    private func shortcutReleased() {
        guard let started = pressStartedAt else { return }
        pressStartedAt = nil
        if Date().timeIntervalSince(started) < 0.35 {
            runtime.continueHandsFree()
        } else {
            runtime.pushToTalkEnded()
        }
    }

    // MARK: Runtime observation

    private func observeRuntime() {
        withObservationTracking {
            _ = runtime.phase
            _ = runtime.cards
            _ = runtime.transcript
            _ = runtime.replyCaption
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.runtimeChanged()
                self?.observeRuntime()
            }
        }
    }

    private func runtimeChanged() {
        let active = runtime.phase != .idle
        panel?.setVisible(active || !runtime.cards.isEmpty)
        updateStatusIcon()
        // Escape dismisses only while Aside is active, so it never steals Escape otherwise.
        if active, escapeHotKey == nil {
            escapeHotKey = hotKeys.register(.escape, onPress: { [weak self] in self?.runtime.dismiss() })
        } else if !active, let escapeHotKey {
            hotKeys.unregister(escapeHotKey)
            self.escapeHotKey = nil
        }
    }

    // MARK: Windows

    func showSettings(tab: MacSettingsView.Tab = .general) {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: MacSettingsView(initialTab: tab).environment(environment))
            let window = NSWindow(contentViewController: controller)
            window.title = "Aside Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 640, height: 560))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showWelcome() {
        let view = MacWelcomeView(shortcut: Self.shortcut.display) { [weak self] tryNow in
            UserDefaults.standard.set(true, forKey: "aside.welcomed")
            self?.welcomeWindow?.close()
            self?.welcomeWindow = nil
            if tryNow { self?.runtime.activate(source: .tap) }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        welcomeWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor in
            if action == "aside.talk" { AppEnvironment.shared.runtime.activate(source: .notification) }
            completionHandler()
        }
    }
}

// MARK: - Settings window

struct MacSettingsView: View {
    enum Tab: Hashable { case general, voice, intelligence, connections, memory, privacy, activity, about }

    @State private var selection: Tab

    init(initialTab: Tab = .general) {
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selection) {
            MacGeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            VoiceSettings().tabItem { Label("Voice", systemImage: "waveform") }.tag(Tab.voice)
            IntelligenceSettings().tabItem { Label("Intelligence", systemImage: "sparkles") }.tag(Tab.intelligence)
            ConnectionsSettings().tabItem { Label("Connections", systemImage: "app.connected.to.app.below.fill") }.tag(Tab.connections)
            MemorySettings().tabItem { Label("Memory", systemImage: "brain") }.tag(Tab.memory)
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }.tag(Tab.privacy)
            ActivitySettings().tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }.tag(Tab.activity)
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag(Tab.about)
        }
        .frame(minWidth: 600, minHeight: 520)
    }
}

struct MacGeneralSettings: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var shortcut = MacAppDelegate.shortcut
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Talk to Aside", selection: $shortcut) {
                    ForEach(HotKeyCenter.Shortcut.presets) { Text($0.display).tag($0) }
                }
                .onChange(of: shortcut) { _, newValue in
                    if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: "aside.shortcut") }
                    MacAppDelegate.current?.registerActivationShortcut()
                }
                Text("Hold the shortcut while you talk, or tap it once and just speak — Aside notices when you're done. Press it again to finish, or Esc to cancel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Shortcut")
            }

            Section("Startup") {
                Toggle("Open Aside at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                if let loginError { Text(loginError).font(.footnote).foregroundStyle(.red) }
            }

            Section {
                Text("Aside can't listen for a wake word yet. A good wake word needs a dedicated, private, low-power detector; until it can meet that bar, the shortcut and the menu bar are the ways in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Hands-free")
            }
        }
        .formStyle(.grouped)
    }
}

struct MacWelcomeView: View {
    let shortcut: String
    let done: (Bool) -> Void

    var body: some View {
        VStack(spacing: 18) {
            WelcomeFilament()
                .frame(width: 220, height: 30)
                .padding(.top, 28)
            Text("Aside").font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("Press **\(shortcut)** and say what you need — “remind me to call Sam at 5”, “what's on tomorrow?”, “play something calm”. Hold it while you talk, or tap and just speak.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Text("Aside lives in the menu bar. It asks for each permission the first time it needs it.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack {
                Button("Later") { done(false) }
                Button("Try it now") { done(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 40)
        .frame(width: 480)
    }
}

/// A static rendition of the presence for the welcome window.
struct WelcomeFilament: View {
    var body: some View {
        PresenceView(phase: .listening, inputLevel: { 0.25 }, outputLevel: { 0 })
    }
}

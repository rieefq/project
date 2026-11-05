import SwiftUI
import UIKit
import UserNotifications
import AsideKit

@main
struct AsideiOSApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppEnvironment.shared)
                .onOpenURL { url in
                    if url.scheme == "aside", url.host == "listen" {
                        AppEnvironment.shared.runtime.activate(source: .systemIntent)
                    }
                }
        }
    }
}

final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        _ = AppEnvironment.shared
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor in
            if action == "aside.talk" { AppEnvironment.shared.runtime.activate(source: .notification) }
            completionHandler()
        }
    }
}

/// The whole iPhone app: a dark field, the presence, and nothing to operate.
/// Tap to talk, hold to keep talking. Settings are one small button away.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showSettings = false
    @State private var pressStartedAt: Date?
    @State private var holding = false
    @State private var holdTask: Task<Void, Never>?

    private var runtime: AgentRuntime { environment.runtime }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.035, green: 0.04, blue: 0.055), Color(red: 0.07, green: 0.075, blue: 0.10)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                PresenceSurface(runtime: runtime, filamentWidth: 300, filamentHeight: 46)
                    .padding(.horizontal, 20)
                Spacer()
                if runtime.phase == .idle && runtime.cards.isEmpty {
                    Text("Tap to talk · Hold to keep talking")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.bottom, 28)
                        .transition(.opacity)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(pressGesture)
        .overlay(alignment: .topTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(14)
            }
            .accessibilityLabel("Settings")
            .padding(.trailing, 6)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            PhoneSettingsView().environment(environment)
        }
        .accessibilityAction(named: "Talk to Aside") { runtime.activate(source: .tap) }
        .animation(.easeInOut(duration: 0.3), value: runtime.phase)
    }

    /// Tap: start (or finish) talking hands-free. Hold: push to talk.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard pressStartedAt == nil else { return }
                pressStartedAt = Date()
                holdTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled, pressStartedAt != nil, runtime.phase == .idle || runtime.phase == .speaking else { return }
                    holding = true
                    runtime.activate(source: .pushToTalk)
                }
            }
            .onEnded { _ in
                holdTask?.cancel()
                defer { pressStartedAt = nil; holding = false }
                if holding {
                    runtime.pushToTalkEnded()
                    return
                }
                switch runtime.phase {
                case .idle: runtime.activate(source: .tap)
                case .listening: runtime.pushToTalkEnded()
                case .speaking, .thinking: runtime.dismiss()
                case .waiting: break
                }
            }
    }
}

struct PhoneSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { VoiceSettings().navigationTitle("Voice") } label: { Label("Voice & personality", systemImage: "waveform") }
                    NavigationLink { IntelligenceSettings().navigationTitle("Intelligence") } label: { Label("Intelligence", systemImage: "sparkles") }
                    NavigationLink { ConnectionsSettings().navigationTitle("Connections") } label: { Label("Connections", systemImage: "app.connected.to.app.below.fill") }
                    NavigationLink { MemorySettings().navigationTitle("Memory") } label: { Label("Memory", systemImage: "brain") }
                    NavigationLink { PrivacySettings().navigationTitle("Privacy") } label: { Label("Privacy", systemImage: "hand.raised") }
                    NavigationLink { ActivitySettings().navigationTitle("Activity") } label: { Label("Activity", systemImage: "clock.arrow.circlepath") }
                }
                Section {
                    WaysToStart()
                } header: {
                    Text("Ways to start Aside")
                }
                Section {
                    NavigationLink { AboutSettings().navigationTitle("About") } label: { Label("About", systemImage: "info.circle") }
                }
            }
            .navigationTitle("Aside")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct WaysToStart: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Row(symbol: "button.horizontal.top.press", text: "Action button: Settings › Action Button › Shortcut › “Talk to Aside”.")
            Row(symbol: "switch.2", text: "Control Center or Lock Screen: add the “Talk to Aside” control.")
            Row(symbol: "mic.circle", text: "Siri: say “Ask Aside” — Siri will ask what you need and Aside handles it, even hands-free.")
            Row(symbol: "hand.tap", text: "Back Tap: Accessibility › Touch › Back Tap › “Talk to Aside”.")
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    private struct Row: View {
        let symbol: String
        let text: String
        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
                Text(text)
            }
        }
    }
}

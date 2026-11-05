import AppIntents
import Foundation
import AsideKit

/// "Hey Siri, ask Aside" — Siri asks what you need, Aside handles it without opening,
/// and Siri speaks the reply. This is the hands-free path iOS allows third-party apps:
/// Siri owns the wake word, Aside owns the work.
struct AskAsideIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Aside"
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Request", requestValueDialog: "What do you need?")
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await AppEnvironment.shared.runtime.submit(text: request, origin: .siri)
        return .result(dialog: IntentDialog(stringLiteral: reply))
    }
}

struct AsideShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ListenIntent(target: .conversation),
                    phrases: ["Talk to \(.applicationName)", "Start \(.applicationName)"],
                    shortTitle: "Talk to Aside", systemImageName: "waveform")
        AppShortcut(intent: AskAsideIntent(),
                    phrases: ["Ask \(.applicationName)", "Tell \(.applicationName)"],
                    shortTitle: "Ask Aside", systemImageName: "text.bubble")
    }
}

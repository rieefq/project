import AppKit
import Foundation
import AsideKit

/// Messages and calls on the Mac go through the system: Messages' own compose window and
/// FaceTime/iPhone call handoff. The user always presses Send or Call themselves, and Aside
/// says the message is ready — never that it was sent, because it can't see that here.
@MainActor
final class MacCommunication: CommunicationService {
    nonisolated func canSendMessages() async -> Bool {
        await MainActor.run { NSSharingService(named: .composeMessage) != nil }
    }

    nonisolated func composeMessage(_ draft: MessageDraft) async -> ComposeResult {
        await MainActor.run {
            guard let service = NSSharingService(named: .composeMessage) else { return .failed("Messages isn't available on this Mac.") }
            service.recipients = [draft.handle.value]
            guard service.canPerform(withItems: [draft.body]) else { return .failed("Messages can't send that.") }
            service.perform(withItems: [draft.body])
            NSApp.activate(ignoringOtherApps: true)
            return .handedOff
        }
    }

    nonisolated func placeCall(to handle: ContactHandle) async throws {
        let digits = handle.value.filter { "+0123456789".contains($0) }
        let scheme = handle.label == "facetime" ? "facetime" : "tel"
        let target = handle.kind == .email ? handle.value : digits
        guard let url = URL(string: "\(scheme):\(target)") else {
            throw ToolFailure(.invalidArguments, message: "That number doesn't look right.")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        if !opened { throw ToolFailure(.unavailable, message: "This Mac can't place calls. Turn on calls from iPhone in FaceTime settings.") }
    }
}

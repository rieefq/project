import Foundation
import MessageUI
import UIKit
import AsideKit

/// Messages and calls on iPhone use the system compose sheet and call prompt. The user
/// sees the recipient and the exact text, and taps Send themselves.
@MainActor
final class PhoneCommunication: NSObject, CommunicationService, MFMessageComposeViewControllerDelegate {
    private var continuation: CheckedContinuation<ComposeResult, Never>?

    nonisolated func canSendMessages() async -> Bool {
        await MainActor.run { MFMessageComposeViewController.canSendText() }
    }

    nonisolated func composeMessage(_ draft: MessageDraft) async -> ComposeResult {
        await present(draft)
    }

    private func present(_ draft: MessageDraft) async -> ComposeResult {
        guard MFMessageComposeViewController.canSendText() else { return .failed("This device can't send messages.") }
        guard let presenter = Self.topViewController() else { return .failed("Open Aside to send the message.") }
        let controller = MFMessageComposeViewController()
        controller.recipients = [draft.handle.value]
        controller.body = draft.body
        controller.messageComposeDelegate = self
        return await withCheckedContinuation { continuation in
            self.continuation?.resume(returning: .cancelled)
            self.continuation = continuation
            presenter.present(controller, animated: true)
        }
    }

    nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        MainActor.assumeIsolated {
            controller.dismiss(animated: true)
            let mapped: ComposeResult
            switch result {
            case .sent: mapped = .sent
            case .cancelled: mapped = .cancelled
            case .failed: mapped = .failed("The message didn't send.")
            @unknown default: mapped = .handedOff
            }
            continuation?.resume(returning: mapped)
            continuation = nil
        }
    }

    nonisolated func placeCall(to handle: ContactHandle) async throws {
        let digits = handle.value.filter { "+0123456789".contains($0) }
        let scheme = handle.label == "facetime" ? "facetime" : "tel"
        guard let url = URL(string: "\(scheme)://\(handle.kind == .email ? handle.value : digits)") else {
            throw ToolFailure(.invalidArguments, message: "That number doesn't look right.")
        }
        let opened = await UIApplication.shared.open(url)
        if !opened { throw ToolFailure(.unavailable, message: "This device can't place calls.") }
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

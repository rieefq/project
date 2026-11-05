import Foundation
import FoundationModels
import AsideKit

/// Structured reading of a request by Apple's on-device foundation model.
@Generable
struct GeneratedIntent {
    @Guide(description: "The single action that best fulfils the request, or none if it needs general knowledge or isn't one of these.",
           .anyOf(["create_reminder", "list_reminders", "get_schedule", "create_event", "start_timer", "play_music", "control_playback",
                   "get_weather", "send_message", "call_contact", "find_places", "get_travel_time", "save_note", "recall", "none"]))
    var action: String

    @Guide(description: "Main subject in the user's own words: reminder or event title, music to play, city, recipient name, place, or note text. Empty if not applicable.")
    var subject: String?

    @Guide(description: "When, copied exactly as the user said it (e.g. 'in 30 days', 'tomorrow at 9'). Never convert to a date. Empty if not said.")
    var when: String?

    @Guide(description: "Secondary detail: message text, timer duration ('10 minutes'), music service ('spotify'), or playback action (pause, resume, next, previous). Empty if not applicable.")
    var detail: String?
}

/// Private, offline understanding for requests the local grammar didn't cover.
/// Nothing leaves the device. Date arithmetic stays in Aside's own parser.
struct OnDeviceIntentModel: LocalIntentModel {
    private static let instructions = """
    You map a user's spoken request for a personal assistant to exactly one action and its fields. \
    Copy the user's words; don't invent details, don't compute dates, and use "none" for questions that need general knowledge, \
    opinions, or anything not in the action list.
    """

    var isAvailable: Bool {
        get async {
            if case .available = SystemLanguageModel.default.availability { return true }
            return false
        }
    }

    func interpret(_ utterance: String, context: ExecutionContext) async -> IntentFrame? {
        guard await isAvailable else { return nil }
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(to: utterance, generating: GeneratedIntent.self,
                                                     options: GenerationOptions(temperature: 0.0))
            let generated = response.content
            guard let action = IntentFrame.Action(rawValue: generated.action), action != .none else { return nil }
            return IntentFrame(action: action, subject: generated.subject, when: generated.when, detail: generated.detail)
        } catch {
            return nil
        }
    }

    /// Whether the device supports Apple Intelligence and the model is ready, for Settings.
    static var statusDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Ready on this device"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "Not supported on this device"
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence to use it"
            case .modelNotReady: return "Downloading…"
            @unknown default: return "Unavailable"
            }
        }
    }
}

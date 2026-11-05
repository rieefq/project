import AppIntents
import Foundation
#if !ASIDE_WIDGET_EXTENSION
import AsideKit
#endif

/// What a "Talk to Aside" control opens. A single value, required by `OpenIntent`.
enum ListenTarget: String, AppEnum {
    case conversation

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Aside"
    static let caseDisplayRepresentations: [ListenTarget: DisplayRepresentation] = [.conversation: "Conversation"]
}

/// Opens Aside listening. Used by the Control Center / Lock Screen control, the Action
/// button and Shortcuts. Compiled into both the app and the controls extension, as the
/// system requires for controls that open their app.
struct ListenIntent: OpenIntent {
    static let title: LocalizedStringResource = "Talk to Aside"

    @Parameter(title: "Target")
    var target: ListenTarget

    init() {}

    init(target: ListenTarget) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !ASIDE_WIDGET_EXTENSION
        AppEnvironment.shared.runtime.activate(source: .systemIntent)
        #endif
        return .result()
    }
}

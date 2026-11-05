import AppIntents
import SwiftUI
import WidgetKit

@main
struct AsideControlsBundle: WidgetBundle {
    var body: some Widget {
        TalkToAsideControl()
    }
}

/// A Control Center / Lock Screen / Action button control that opens Aside listening.
struct TalkToAsideControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.aside.controls.talk") {
            ControlWidgetButton(action: ListenIntent(target: .conversation)) {
                Label("Talk to Aside", systemImage: "waveform")
            }
        }
        .displayName("Talk to Aside")
        .description("Start talking to Aside.")
    }
}

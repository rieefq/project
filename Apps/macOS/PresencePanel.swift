import AppKit
import SwiftUI
import AsideKit

/// A floating, non-activating panel just below the menu bar. It never takes focus from
/// the app the user is working in, follows them across Spaces and full-screen apps, and
/// is only on screen while Aside is doing something.
final class PresencePanel: NSPanel {
    private let hosting: NSHostingView<PanelContent>
    private var isShown = false

    init(runtime: AgentRuntime) {
        hosting = NSHostingView(rootView: PanelContent(runtime: runtime))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        animationBehavior = .utilityWindow
        hosting.sizingOptions = [.intrinsicContentSize]
        contentView = hosting
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setVisible(_ visible: Bool) {
        if visible {
            reposition()
            if !isShown {
                isShown = true
                orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    animator().alphaValue = 1
                }
            }
        } else if isShown {
            isShown = false
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.isShown else { return }
                self.orderOut(nil)
            })
        }
    }

    /// Centers the panel under the menu bar of the screen the pointer is on.
    func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = hosting.fittingSize
        let width = max(size.width, 360)
        let height = max(size.height, 60)
        setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - height - 6, width: width, height: height), display: true)
    }
}

/// What the panel shows: the presence, a caption and any cards.
struct PanelContent: View {
    let runtime: AgentRuntime

    var body: some View {
        PresenceSurface(runtime: runtime, filamentWidth: 240, filamentHeight: 28, framed: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(width: 420)
            .fixedSize(horizontal: false, vertical: true)
    }
}

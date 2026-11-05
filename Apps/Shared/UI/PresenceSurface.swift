import SwiftUI
import AsideKit

/// The complete visible interface during an interaction: the presence, one line of
/// caption, and at most two transient cards.
struct PresenceSurface: View {
    let runtime: AgentRuntime
    var filamentWidth: CGFloat = 300
    var filamentHeight: CGFloat = 36
    var showsCaption: Bool = true
    /// Draw a glass capsule behind the filament (used where it floats over other apps).
    var framed: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            PresenceView(phase: runtime.phase,
                         inputLevel: { runtime.inputLevel },
                         outputLevel: { runtime.outputLevel },
                         isError: runtime.cards.contains(where: Self.isFailure))
                .frame(width: filamentWidth, height: filamentHeight)
                .padding(.horizontal, framed ? 22 : 0)
                .padding(.vertical, framed ? 10 : 0)
                .modifier(GlassCapsule(enabled: framed))
                .opacity(runtime.phase == .idle ? 0.0 : 1.0)
                .animation(.easeOut(duration: 0.35), value: runtime.phase == .idle)

            if showsCaption, let caption {
                Text(caption.text)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(caption.isUser ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.head)
                    .frame(maxWidth: filamentWidth + 60)
                    .transition(.opacity)
                    .id(caption.text.isEmpty ? "empty" : (caption.isUser ? "user" : "aside"))
                    .accessibilityLabel(caption.isUser ? "You said \(caption.text)" : caption.text)
            }

            if !runtime.cards.isEmpty {
                VStack(spacing: 10) {
                    ForEach(runtime.cards) { card in
                        CardView(card: card, runtime: runtime)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                }
                .frame(maxWidth: 380)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: runtime.cards.map(\.id))
        .animation(.easeInOut(duration: 0.2), value: caption?.text)
    }

    private struct Caption: Equatable {
        var text: String
        var isUser: Bool
    }

    private var caption: Caption? {
        guard runtime.preferences.showLiveCaption || runtime.preferences.speechPrivacy == .discreet else { return nil }
        switch runtime.phase {
        case .listening, .waiting:
            let text = runtime.transcript
            if text.isEmpty { return runtime.phase == .waiting ? Caption(text: runtime.replyCaption, isUser: false) : nil }
            return Caption(text: text, isUser: true)
        case .thinking:
            return runtime.activity.map { Caption(text: "\($0)…", isUser: false) }
        case .speaking:
            return runtime.replyCaption.isEmpty ? nil : Caption(text: runtime.replyCaption, isUser: false)
        case .idle:
            return nil
        }
    }

    private static func isFailure(_ card: Card) -> Bool {
        if case .status(let status) = card { return status.tone == .failure }
        return false
    }
}

private struct GlassCapsule: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
        }
    }
}

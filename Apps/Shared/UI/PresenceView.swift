import SwiftUI
import AsideKit

/// Aside's presence: a single filament of light.
///
/// It is the whole visual identity — no orb, no face, no chat. It widens and ripples
/// with the user's voice while listening, gathers into a travelling bead while thinking,
/// warms and pulses with Aside's voice while speaking, and holds a steady mint light when
/// it needs a decision. When nothing is happening it isn't there at all.
struct PresenceView: View {
    var phase: AgentRuntime.Phase
    var inputLevel: () -> Float
    var outputLevel: () -> Float
    var isError: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousTint = Tint.listening
    @State private var tintChangedAt = Date.distantPast

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: phase == .idle)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                draw(in: &context, size: size, time: time, now: timeline.date)
            }
        }
        .onChange(of: phase) { oldValue, _ in
            previousTint = Tint.for(phase: oldValue, error: false)
            tintChangedAt = Date()
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var accessibilityText: String {
        switch phase {
        case .idle: return "Aside is not listening"
        case .listening: return "Aside is listening"
        case .thinking: return "Aside is working"
        case .speaking: return "Aside is speaking"
        case .waiting: return "Aside is waiting for your answer"
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval, now: Date) {
        let target = Tint.for(phase: phase, error: isError)
        let blend = min(1, max(0, now.timeIntervalSince(tintChangedAt) / 0.35))
        let tint = previousTint.mixed(with: target, amount: blend)

        let width = size.width
        let midY = size.height / 2
        let level: Double
        switch phase {
        case .listening, .waiting: level = Double(inputLevel())
        case .speaking: level = Double(outputLevel())
        default: level = 0
        }
        let motion = reduceMotion ? 0.0 : 1.0

        // Thickness and amplitude by state.
        let baseThickness: Double
        let amplitude: Double
        switch phase {
        case .idle: baseThickness = 1.5; amplitude = 0
        case .listening: baseThickness = 2.5 + level * 5; amplitude = (2 + level * 14) * motion
        case .thinking: baseThickness = 2.2; amplitude = 1.5 * motion
        case .speaking: baseThickness = 2.5 + level * 4; amplitude = (1.5 + level * 10) * motion
        case .waiting: baseThickness = 2.6; amplitude = 1 * motion
        }

        // Build the filament as a lens-shaped ribbon following a gentle composite wave.
        let samples = 96
        var top: [CGPoint] = []
        var bottom: [CGPoint] = []
        for index in 0...samples {
            let u = Double(index) / Double(samples)            // 0…1 across
            let envelope = pow(sin(Double.pi * u), 1.6)        // tapers to points at both ends
            let wave = sin(u * 9.0 + time * 2.1) * 0.55 + sin(u * 15.0 - time * 3.3) * 0.3 + sin(u * 4.0 + time * 1.2) * 0.15
            let y = midY + wave * amplitude * envelope
            let half = max(0.35, baseThickness * envelope)
            let x = u * width
            top.append(CGPoint(x: x, y: y - half))
            bottom.append(CGPoint(x: x, y: y + half))
        }
        var ribbon = Path()
        ribbon.move(to: top[0])
        for point in top.dropFirst() { ribbon.addLine(to: point) }
        for point in bottom.reversed() { ribbon.addLine(to: point) }
        ribbon.closeSubpath()

        let gradient = Gradient(stops: [
            .init(color: tint.color.opacity(0.0), location: 0.0),
            .init(color: tint.color.opacity(0.85), location: 0.3),
            .init(color: Color.white.opacity(0.95), location: 0.5),
            .init(color: tint.color.opacity(0.85), location: 0.7),
            .init(color: tint.color.opacity(0.0), location: 1.0),
        ])
        let shading = GraphicsContext.Shading.linearGradient(gradient, startPoint: CGPoint(x: 0, y: midY), endPoint: CGPoint(x: width, y: midY))

        // Soft glow underneath.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 9 + level * 10))
            layer.opacity = 0.55 + level * 0.3
            layer.fill(ribbon, with: .color(tint.color))
        }
        context.fill(ribbon, with: shading)

        // Thinking: a bead of light travelling along the filament.
        if phase == .thinking {
            let period = 1.6
            let raw = (time.truncatingRemainder(dividingBy: period)) / period
            let eased = 0.5 - 0.5 * cos(Double.pi * 2 * raw)  // back and forth
            let x = (reduceMotion ? 0.5 : (0.15 + 0.7 * eased)) * width
            let bead = Path(ellipseIn: CGRect(x: x - 16, y: midY - 5, width: 32, height: 10))
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 8))
                layer.fill(bead, with: .color(Color.white.opacity(0.9)))
            }
        }

        // Waiting: a slow highlight drifting across, signalling "your turn".
        if phase == .waiting && !reduceMotion {
            let x = (0.5 + 0.35 * sin(time * 0.9)) * width
            let glint = Path(ellipseIn: CGRect(x: x - 22, y: midY - 4, width: 44, height: 8))
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 10))
                layer.fill(glint, with: .color(Color.white.opacity(0.55)))
            }
        }
    }
}

/// The presence palette: desaturated light, never neon.
struct Tint: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let listening = Tint(red: 0.56, green: 0.80, blue: 1.00)
    static let thinking = Tint(red: 0.72, green: 0.66, blue: 1.00)
    static let speaking = Tint(red: 1.00, green: 0.83, blue: 0.64)
    static let waiting = Tint(red: 0.62, green: 0.95, blue: 0.84)
    static let error = Tint(red: 1.00, green: 0.64, blue: 0.47)

    static func `for`(phase: AgentRuntime.Phase, error: Bool) -> Tint {
        if error { return .error }
        switch phase {
        case .idle, .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .waiting: return .waiting
        }
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    func mixed(with other: Tint, amount: Double) -> Tint {
        Tint(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount, blue: blue + (other.blue - blue) * amount)
    }
}

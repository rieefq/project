import MapKit
import SwiftUI
import AsideKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Transient cards: the only visual output besides the presence. Each is small,
/// purposeful and disappears on its own (or once a decision is made).
struct CardView: View {
    let card: Card
    let runtime: AgentRuntime

    var body: some View {
        Group {
            switch card {
            case .confirmation(let request): ConfirmationCardView(request: request, runtime: runtime)
            case .choice(let request): ChoiceCardView(request: request, runtime: runtime)
            case .agenda(let agenda): AgendaCardView(agenda: agenda)
            case .list(let list): ListCardView(list: list)
            case .place(let place): PlaceCardView(place: place)
            case .weather(let weather): WeatherCardView(weather: weather)
            case .nowPlaying(let playing): NowPlayingCardView(playing: playing)
            case .status(let status): StatusCardView(status: status)
            case .permission(let permission): PermissionCardView(permission: permission)
            case .sources(let sources): SourcesCardView(sources: sources)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .asideCardBackground()
        .contentShape(Rectangle())
        .onTapGesture {
            if !card.requiresInteraction { runtime.dismissCard(card.id) }
        }
    }
}

extension View {
    /// System-native glass, kept subtle.
    func asideCardBackground() -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

private struct CardHeader: View {
    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
    }
}

struct ConfirmationCardView: View {
    let request: ConfirmationRequest
    let runtime: AgentRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: request.isDestructive ? "exclamationmark.triangle" : "checkmark.shield", title: request.title, subtitle: request.subject)
            if let detail = request.detail {
                Text("“\(detail)”")
                    .font(.body)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            Text(request.consequence)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { runtime.decline(request.id) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(role: request.isDestructive ? .destructive : nil) {
                    runtime.confirm(request.id)
                } label: {
                    if request.strength == .deviceAuthentication {
                        Label(request.confirmLabel, systemImage: "lock.shield")
                    } else {
                        Text(request.confirmLabel)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.title). \(request.subject ?? "") \(request.detail ?? "")")
    }
}

struct ChoiceCardView: View {
    let request: ChoiceRequest
    let runtime: AgentRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(symbol: "questionmark.circle", title: request.prompt)
            ForEach(Array(request.options.enumerated()), id: \.element.id) { index, option in
                Button {
                    runtime.choose(option.id, in: request.id)
                } label: {
                    HStack {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label).font(.body)
                            if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AgendaCardView: View {
    let agenda: AgendaCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(symbol: "calendar", title: agenda.heading)
            ForEach(Array(agenda.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.time)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.body).lineLimit(1)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

struct ListCardView: View {
    let list: ListCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(symbol: list.symbol, title: list.heading)
            ForEach(Array(list.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(.secondary).frame(width: 4, height: 4)
                    Text(item).font(.body).lineLimit(2)
                }
            }
        }
    }
}

struct PlaceCardView: View {
    let place: PlaceCard

    var body: some View {
        let coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "mappin.and.ellipse", title: place.name, subtitle: place.address)
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1_400, longitudinalMeters: 1_400))) {
                Marker(place.name, coordinate: coordinate)
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .allowsHitTesting(false)
            if let travel = place.travelSummary {
                Label(travel, systemImage: "car").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

struct WeatherCardView: View {
    let weather: WeatherCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: weather.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 34))
                VStack(alignment: .leading, spacing: 2) {
                    Text(weather.temperature).font(.system(size: 34, weight: .light, design: .rounded))
                    Text(weather.condition).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(weather.place).font(.subheadline)
                    if let range = weather.range { Text(range).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
            if let attribution = weather.attribution {
                HStack(spacing: 4) {
                    Text(attribution)
                    Link("Legal", destination: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }
}

struct NowPlayingCardView: View {
    let playing: NowPlayingCard

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(playing.title).font(.headline).lineLimit(1)
                Text([playing.subtitle, playing.provider].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct StatusCardView: View {
    let status: StatusCard

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.symbol)
                .font(.headline)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.title).font(.body).lineLimit(4)
                if let detail = status.detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                if let label = status.actionLabel, let url = status.actionURL.flatMap(URL.init(string:)) {
                    Link(label, destination: url).font(.subheadline.weight(.medium))
                }
            }
        }
    }

    private var color: Color {
        switch status.tone {
        case .success: return .green
        case .info: return .secondary
        case .warning: return .orange
        case .failure: return .red
        }
    }
}

struct PermissionCardView: View {
    let permission: PermissionCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "hand.raised", title: "\(permission.capability.displayName) access")
            Text(permission.explanation).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Open Settings") { SystemSettings.open(for: permission.capability) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct SourcesCardView: View {
    let sources: SourcesCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(symbol: "globe", title: "Sources")
            ForEach(Array(sources.sources.enumerated()), id: \.offset) { _, source in
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        Text(url.host ?? source.title).font(.subheadline).lineLimit(1)
                    }
                }
            }
        }
    }
}

/// Opens the right system settings page for a permission.
enum SystemSettings {
    @MainActor
    static func open(for capability: Capability) {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #else
        let pane: String
        switch capability {
        case .reminders: pane = "Privacy_Reminders"
        case .calendar: pane = "Privacy_Calendars"
        case .contacts, .messages, .phone: pane = "Privacy_Contacts"
        case .places, .weather: pane = "Privacy_LocationServices"
        case .music: pane = "Privacy_Media"
        case .system: pane = "Privacy_Microphone"
        default: pane = "Privacy"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
        #endif
    }
}

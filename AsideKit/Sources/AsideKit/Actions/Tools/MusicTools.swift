import Foundation

/// Picks the right music service for a request and remembers which one is playing.
public actor MusicRouter {
    private let services: [MusicProvider: any MusicService]
    private var active: MusicProvider?

    public init(_ services: [any MusicService]) {
        var map: [MusicProvider: any MusicService] = [:]
        for service in services { map[service.provider] = service }
        self.services = map
    }

    public nonisolated var providers: [MusicProvider] { MusicProvider.allCases.filter { services[$0] != nil } }

    public func service(_ provider: MusicProvider) -> (any MusicService)? { services[provider] }

    /// Explicit request → stated preference → the only connected service → Apple Music.
    public func choose(explicit: MusicProvider?, preferred: MusicProvider?) async -> (any MusicService)? {
        if let explicit { return services[explicit] }
        if let preferred, let service = services[preferred] { return service }
        var usable: [any MusicService] = []
        for provider in MusicProvider.allCases {
            if let service = services[provider], await service.access().isUsable { usable.append(service) }
        }
        if usable.count == 1 { return usable[0] }
        return services[.appleMusic] ?? usable.first ?? services.values.first
    }

    public func setActive(_ provider: MusicProvider) { active = provider }

    public func activeService() -> (any MusicService)? {
        if let active, let service = services[active] { return service }
        return services[.appleMusic] ?? services.values.first
    }

    public func isPlaying() async -> Bool {
        guard let service = activeService() else { return false }
        return await service.nowPlaying()?.isPlaying ?? false
    }
}

extension MusicProvider {
    init?(argument: String?) {
        switch argument?.lowercased().replacingOccurrences(of: " ", with: "_") {
        case "spotify": self = .spotify
        case "apple_music", "applemusic", "apple", "music": self = .appleMusic
        default: return nil
        }
    }
}

// MARK: - Play

public struct PlayMusicTool: ToolHandler {
    let router: MusicRouter

    public init(router: MusicRouter) { self.router = router }

    public var spec: ToolSpec {
        ToolSpec(
            name: "play_music",
            description: "Play music: a song, artist, album, playlist or genre, on Apple Music or Spotify. An empty query plays the user's music.",
            inputSchema: Schema.object([
                "query": Schema.string("What to play, e.g. \"Blinding Lights by The Weeknd\", \"jazz\", \"my Discover Weekly\"."),
                "kind": Schema.string("What the query names.", enum: ["song", "artist", "album", "playlist", "genre", "any"]),
                "provider": Schema.string("Only if the user named a service.", enum: ["apple_music", "spotify"]),
                "shuffle": Schema.boolean("Shuffle playback."),
            ], required: ["query"]),
            capability: .music, risk: .reversible)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let arguments = prepared.call.arguments
        let explicit = MusicProvider(argument: arguments["provider"]?.stringValue)
        guard let service = await router.choose(explicit: explicit, preferred: context.preferences.preferredMusicProvider) else {
            return .failed(ToolFailure(.unavailable, message: "\(explicit?.displayName ?? "Music") isn't set up on this device yet."))
        }
        var state = await service.access()
        if state == .notDetermined { state = await service.requestAccess() }
        guard state.isUsable else {
            return .needsPermission(PermissionRequest(
                capability: .music, state: state,
                explanation: service.provider == .spotify
                    ? "Connect Spotify in Aside's settings and I can play it for you."
                    : "I need access to Apple Music for that.",
                call: prepared.call))
        }
        let query = arguments["query"]?.stringValue ?? ""
        let kind = MusicKind(rawValue: arguments["kind"]?.stringValue ?? "any") ?? .any
        do {
            let result = try await service.play(MusicRequest(query: query, kind: kind, shuffle: arguments["shuffle"]?.boolValue ?? false))
            await router.setActive(service.provider)
            let description = [result.title, result.subtitle].compactMap { $0 }.joined(separator: " by ")
            // The music itself confirms success. Only speak when the match might surprise.
            let surprising = !query.isEmpty && TitleMatch.score(query: query, title: description) < 0.5
            let speech = SpeechPlan(minimal: surprising ? "Playing \(description)." : nil,
                                    balanced: surprising ? "Here's \(description)." : nil,
                                    detailed: "Playing \(description) on \(result.provider.displayName).")
            return .completed(ActionResult(
                summary: "Playing \(description) on \(result.provider.displayName)",
                speech: speech,
                card: .nowPlaying(NowPlayingCard(title: result.title, subtitle: result.subtitle, provider: result.provider.displayName)),
                undo: UndoPlan(toolName: "control_playback", arguments: ["action": "pause"], pastTense: "stopped the music"),
                referent: Referent(kind: .music, id: result.provider.rawValue, title: result.title),
                data: ["title": .string(result.title), "subtitle": JSONValue(result.subtitle), "provider": .string(result.provider.rawValue)],
                earcon: .none))
        } catch let failure as ToolFailure {
            return .failed(failure)
        } catch {
            return .failed(ToolFailure(.service, message: "I couldn't start that on \(service.provider.displayName).", detail: "\(error)", isRetryable: true))
        }
    }
}

// MARK: - Control

public struct ControlPlaybackTool: ToolHandler {
    let router: MusicRouter

    public init(router: MusicRouter) { self.router = router }

    public var spec: ToolSpec {
        ToolSpec(name: "control_playback", description: "Pause, resume or skip the music Aside is playing.",
                 inputSchema: Schema.object(["action": Schema.string("Playback action.", enum: ["pause", "resume", "next", "previous"])], required: ["action"]),
                 capability: .music, risk: .reversible)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        guard let command = PlaybackCommand(rawValue: prepared.call.arguments["action"]?.stringValue ?? "") else {
            return .failed(ToolFailure(.invalidArguments, message: "Pause, resume or skip?"))
        }
        guard let service = await router.activeService() else {
            return .failed(ToolFailure(.unavailable, message: "Nothing's playing."))
        }
        do {
            try await service.control(command)
            let undo: UndoPlan? = switch command {
            case .pause: UndoPlan(toolName: "control_playback", arguments: ["action": "resume"], pastTense: "started the music again")
            case .resume: UndoPlan(toolName: "control_playback", arguments: ["action": "pause"], pastTense: "paused it again")
            case .next, .previous: nil
            }
            return .completed(ActionResult(summary: "Playback: \(command.rawValue)", speech: .silent, undo: undo,
                                           data: ["action": .string(command.rawValue)], earcon: .success))
        } catch let failure as ToolFailure {
            return .failed(failure)
        } catch {
            return .failed(ToolFailure(.service, message: "I couldn't control playback.", detail: "\(error)", isRetryable: true))
        }
    }
}

// MARK: - Now playing

public struct NowPlayingTool: ToolHandler {
    let router: MusicRouter

    public init(router: MusicRouter) { self.router = router }

    public var spec: ToolSpec {
        ToolSpec(name: "now_playing", description: "What's playing through Aside right now.",
                 inputSchema: Schema.object([:]), capability: .music, risk: .read)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        guard let service = await router.activeService(), let playing = await service.nowPlaying() else {
            return .completed(ActionResult(summary: "Nothing playing",
                                           speech: SpeechPlan("I'm not playing anything right now. I can't identify music playing around you yet."),
                                           earcon: .none))
        }
        let description = [playing.title, playing.subtitle].compactMap { $0 }.joined(separator: " by ")
        return .completed(ActionResult(summary: "Now playing \(description)", speech: SpeechPlan("This is \(description)."),
                                       card: .nowPlaying(NowPlayingCard(title: playing.title, subtitle: playing.subtitle, provider: playing.provider.displayName)),
                                       data: ["title": .string(playing.title), "subtitle": JSONValue(playing.subtitle)], earcon: .none))
    }
}

import AuthenticationServices
import CryptoKit
import Foundation
import MusicKit
import AsideKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Apple Music

final class AppleMusicService: MusicService, @unchecked Sendable {
    let provider: MusicProvider = .appleMusic

    func access() async -> AccessState {
        switch MusicAuthorization.currentStatus {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> AccessState {
        _ = await MusicAuthorization.request()
        return await access()
    }

    func play(_ request: AsideKit.MusicRequest) async throws -> PlaybackResult {
        if let subscription = try? await MusicSubscription.current, !subscription.canPlayCatalogContent {
            throw ToolFailure(.unavailable, message: "Playing from Apple Music needs a subscription.")
        }
        if request.query.trimmingCharacters(in: .whitespaces).isEmpty {
            try await Self.resume()
            return PlaybackResult(title: "Your music", kind: .any, provider: .appleMusic)
        }
        var search = MusicCatalogSearchRequest(term: request.query, types: Self.types(for: request.kind))
        search.limit = 5
        let response = try await search.response()

        switch request.kind {
        case .album:
            if let album = response.albums.first { return try await Self.play(album, title: album.title, subtitle: album.artistName, kind: .album, shuffle: request.shuffle) }
        case .playlist, .genre:
            if let playlist = response.playlists.first { return try await Self.play(playlist, title: playlist.name, subtitle: playlist.curatorName, kind: .playlist, shuffle: request.shuffle) }
        case .artist:
            if let artist = response.artists.first {
                let detailed = try await artist.with([.topSongs])
                if let songs = detailed.topSongs, !songs.isEmpty {
                    try await Self.playSongs(Array(songs), shuffle: request.shuffle)
                    return PlaybackResult(title: artist.name, subtitle: "Top songs", kind: .artist, provider: .appleMusic)
                }
            }
        case .song, .any:
            break
        }
        if let song = response.songs.first {
            return try await Self.play(song, title: song.title, subtitle: song.artistName, kind: .song, shuffle: false)
        }
        if let album = response.albums.first { return try await Self.play(album, title: album.title, subtitle: album.artistName, kind: .album, shuffle: request.shuffle) }
        if let playlist = response.playlists.first { return try await Self.play(playlist, title: playlist.name, subtitle: playlist.curatorName, kind: .playlist, shuffle: request.shuffle) }
        throw ToolFailure(.notFound, message: "I couldn't find \(request.query) on Apple Music.")
    }

    func control(_ command: PlaybackCommand) async throws {
        #if os(iOS)
        let player = SystemMusicPlayer.shared
        #else
        let player = ApplicationMusicPlayer.shared
        #endif
        switch command {
        case .pause: player.pause()
        case .resume: try await player.play()
        case .next: try await player.skipToNextEntry()
        case .previous: try await player.skipToPreviousEntry()
        }
    }

    func nowPlaying() async -> NowPlaying? {
        #if os(iOS)
        let player = SystemMusicPlayer.shared
        #else
        let player = ApplicationMusicPlayer.shared
        #endif
        guard let entry = player.queue.currentEntry else { return nil }
        return NowPlaying(title: entry.title, subtitle: entry.subtitle, provider: .appleMusic,
                          isPlaying: player.state.playbackStatus == .playing)
    }

    // MARK: Helpers

    private static func types(for kind: MusicKind) -> [any MusicCatalogSearchable.Type] {
        switch kind {
        case .song: return [Song.self]
        case .album: return [Album.self]
        case .playlist, .genre: return [Playlist.self]
        case .artist: return [Artist.self]
        case .any: return [Song.self, Album.self, Playlist.self]
        }
    }

    private static func resume() async throws {
        #if os(iOS)
        try await SystemMusicPlayer.shared.play()
        #else
        try await ApplicationMusicPlayer.shared.play()
        #endif
    }

    private static func play<Item: PlayableMusicItem>(_ item: Item, title: String, subtitle: String?, kind: MusicKind, shuffle: Bool) async throws -> PlaybackResult {
        #if os(iOS)
        let player = SystemMusicPlayer.shared
        player.queue = [item]
        player.state.shuffleMode = shuffle ? .songs : .off
        try await player.play()
        #else
        let player = ApplicationMusicPlayer.shared
        player.queue = [item]
        player.state.shuffleMode = shuffle ? .songs : .off
        try await player.play()
        #endif
        return PlaybackResult(title: title, subtitle: subtitle, kind: kind, provider: .appleMusic)
    }

    private static func playSongs(_ songs: [Song], shuffle: Bool) async throws {
        #if os(iOS)
        let player = SystemMusicPlayer.shared
        player.queue = SystemMusicPlayer.Queue(for: songs)
        player.state.shuffleMode = shuffle ? .songs : .off
        try await player.play()
        #else
        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: songs)
        player.state.shuffleMode = shuffle ? .songs : .off
        try await player.play()
        #endif
    }
}

// MARK: - Spotify

/// Spotify through its Web API (OAuth with PKCE; no client secret in the app).
/// Playback control needs Spotify Premium and an active Spotify device; without them,
/// Aside opens the item in the Spotify app and says so instead of claiming it's playing.
final class SpotifyService: NSObject, MusicService, @unchecked Sendable {
    let provider: MusicProvider = .spotify

    private let clientID: String
    private let redirectURI = "aside://spotify-callback"
    private let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing"
    private let tokenAccount = "spotify.tokens"
    private let lock = NSLock()
    private var authSession: ASWebAuthenticationSession?

    struct Tokens: Codable {
        var access: String
        var refresh: String
        var expires: Date
    }

    init(clientID: String) {
        self.clientID = clientID
    }

    var isConfigured: Bool { !clientID.isEmpty }

    private var tokens: Tokens? {
        get { Keychain.data(tokenAccount).flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { Keychain.set(data, for: tokenAccount) } else { Keychain.remove(tokenAccount) }
        }
    }

    var isConnected: Bool { tokens != nil }

    func access() async -> AccessState {
        guard isConfigured else { return .unavailable }
        return isConnected ? .granted : .denied
    }

    /// Spotify can't be connected by voice; Settings runs the sign-in.
    func requestAccess() async -> AccessState { await access() }

    func disconnect() { tokens = nil }

    // MARK: Sign in

    @MainActor
    func connect() async throws {
        guard isConfigured else { throw ToolFailure(.unavailable, message: "Spotify isn't configured in this build.") }
        let verifier = Self.randomString(64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: scopes),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "aside") { url, error in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? ToolFailure(.cancelled, message: "Cancelled")) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            session.start()
        }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw ToolFailure(.denied, message: "Spotify didn't connect.")
        }
        try await exchange(["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI, "client_id": clientID, "code_verifier": verifier])
    }

    private func exchange(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json = try? JSONValue.parse(data),
              let access = json["access_token"]?.stringValue else {
            throw ToolFailure(.denied, message: "Spotify sign-in didn't work. Try connecting again in settings.")
        }
        let refresh = json["refresh_token"]?.stringValue ?? form["refresh_token"] ?? tokens?.refresh ?? ""
        let expires = Date().addingTimeInterval(json["expires_in"]?.doubleValue ?? 3_600)
        tokens = Tokens(access: access, refresh: refresh, expires: expires)
    }

    private func accessToken() async throws -> String {
        guard let current = tokens else { throw ToolFailure(.denied, message: "Connect Spotify in Aside's settings first.") }
        if current.expires > Date().addingTimeInterval(60) { return current.access }
        try await exchange(["grant_type": "refresh_token", "refresh_token": current.refresh, "client_id": clientID])
        guard let refreshed = tokens else { throw ToolFailure(.denied, message: "Reconnect Spotify in settings.") }
        return refreshed.access
    }

    // MARK: Web API

    private func api(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> (Int, JSONValue?) {
        var components = URLComponents(string: "https://api.spotify.com/v1/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "authorization")
        if let body {
            request.httpBody = body.serialized()
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data.isEmpty ? nil : try? JSONValue.parse(data))
    }

    func play(_ request: AsideKit.MusicRequest) async throws -> PlaybackResult {
        if request.query.trimmingCharacters(in: .whitespaces).isEmpty {
            try await control(.resume)
            return PlaybackResult(title: "Spotify", kind: .any, provider: .spotify)
        }
        let type: String
        switch request.kind {
        case .song: type = "track"
        case .album: type = "album"
        case .artist: type = "artist"
        case .playlist, .genre: type = "playlist"
        case .any: type = "track,album,playlist"
        }
        let (status, json) = try await api("GET", "search", query: [URLQueryItem(name: "q", value: request.query), URLQueryItem(name: "type", value: type),
                                                                    URLQueryItem(name: "limit", value: "5")])
        guard status == 200, let json else { throw ToolFailure(.service, message: "I couldn't search Spotify right now.", isRetryable: true) }

        var uri: String?
        var isContext = false
        var title = request.query
        var subtitle: String?
        var kind = request.kind
        if let track = json["tracks"]?["items"]?[0], request.kind == .song || request.kind == .any {
            uri = track["uri"]?.stringValue
            title = track["name"]?.stringValue ?? title
            subtitle = track["artists"]?[0]?["name"]?.stringValue
            kind = .song
        } else if let album = json["albums"]?["items"]?[0] {
            uri = album["uri"]?.stringValue; isContext = true; title = album["name"]?.stringValue ?? title
            subtitle = album["artists"]?[0]?["name"]?.stringValue; kind = .album
        } else if let playlist = json["playlists"]?["items"]?.arrayValue?.first(where: { !$0.isNull }) {
            uri = playlist["uri"]?.stringValue; isContext = true; title = playlist["name"]?.stringValue ?? title; kind = .playlist
        } else if let artist = json["artists"]?["items"]?[0] {
            uri = artist["uri"]?.stringValue; isContext = true; title = artist["name"]?.stringValue ?? title; kind = .artist
        }
        guard let uri else { throw ToolFailure(.notFound, message: "I couldn't find \(request.query) on Spotify.") }

        let body: JSONValue = isContext ? ["context_uri": .string(uri)] : ["uris": [.string(uri)]]
        var (playStatus, playJSON) = try await api("PUT", "me/player/play", body: body)
        if playStatus == 404 {
            // No active device: wake the Spotify app, then target its device.
            await Self.open(URL(string: uri)!)
            if let device = await waitForDevice() {
                (playStatus, playJSON) = try await api("PUT", "me/player/play", query: [URLQueryItem(name: "device_id", value: device)], body: body)
            }
        }
        if playStatus == 403, playJSON?["error"]?["reason"]?.stringValue == "PREMIUM_REQUIRED" || playStatus == 404 {
            await Self.open(URL(string: uri)!)
            throw ToolFailure(.unsupported, message: "I opened \(title) in Spotify — starting playback from Aside needs Spotify Premium.")
        }
        guard (200..<300).contains(playStatus) else {
            throw ToolFailure(.service, message: "Spotify didn't start playing.", detail: "HTTP \(playStatus)", isRetryable: true)
        }
        return PlaybackResult(title: title, subtitle: subtitle, kind: kind, provider: .spotify)
    }

    private func waitForDevice() async -> String? {
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if let result = try? await api("GET", "me/player/devices"), result.0 == 200,
               let devices = result.1?["devices"]?.arrayValue, let first = devices.first?["id"]?.stringValue {
                return first
            }
        }
        return nil
    }

    func control(_ command: PlaybackCommand) async throws {
        let (method, path): (String, String)
        switch command {
        case .pause: (method, path) = ("PUT", "me/player/pause")
        case .resume: (method, path) = ("PUT", "me/player/play")
        case .next: (method, path) = ("POST", "me/player/next")
        case .previous: (method, path) = ("POST", "me/player/previous")
        }
        let (status, _) = try await api(method, path)
        guard (200..<300).contains(status) else {
            throw ToolFailure(.service, message: status == 403 ? "Controlling Spotify from Aside needs Spotify Premium." : "Spotify didn't respond.")
        }
    }

    func nowPlaying() async -> NowPlaying? {
        guard isConnected, let result = try? await api("GET", "me/player/currently-playing"), result.0 == 200,
              let json = result.1, let item = json["item"] else { return nil }
        return NowPlaying(title: item["name"]?.stringValue ?? "", subtitle: item["artists"]?[0]?["name"]?.stringValue, provider: .spotify,
                          isPlaying: json["is_playing"]?.boolValue ?? false)
    }

    // MARK: Utilities

    @MainActor
    private static func open(_ url: URL) async {
        #if os(iOS)
        await UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    private static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in characters[Int.random(in: 0..<characters.count)] })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension SpotifyService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
}

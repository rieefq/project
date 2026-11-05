import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Connection settings for the cloud reasoner.
public struct ClaudeConfiguration: Sendable, Hashable {
    public enum Credential: Sendable, Hashable {
        /// A Claude API key (sent as `x-api-key`).
        case apiKey(String)
        /// A token for a relay service that forwards to the Claude API (sent as a bearer token).
        case bearer(String)
    }

    public var baseURL: URL
    public var model: String
    /// Effort for conversational turns. Voice replies are short, so `low` keeps latency down.
    public var effort: String
    public var maxTokens: Int
    public var webSearch: Bool
    public var apiVersion: String
    public var requestTimeout: TimeInterval

    public init(baseURL: URL = URL(string: "https://api.anthropic.com")!, model: String = "claude-opus-5-5", effort: String = "low",
                maxTokens: Int = 16_000, webSearch: Bool = true, apiVersion: String = "2026-10-21", requestTimeout: TimeInterval = 60) {
        self.baseURL = baseURL
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.webSearch = webSearch
        self.apiVersion = apiVersion
        self.requestTimeout = requestTimeout
    }

    public var isOfficialEndpoint: Bool { baseURL.host == "api.anthropic.com" }

    /// Server-side refusal fallbacks (`fallbacks: "default"`) are offered on these models via the Claude API.
    var supportsDefaultFallbacks: Bool {
        isOfficialEndpoint && ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-fable-5", "claude-sonnet-5-5"].contains(model)
    }

    /// The web search tool version with dynamic filtering is available on newer Opus/Sonnet models.
    var webSearchToolType: String {
        let dynamic = ["claude-opus-5-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
                       "claude-sonnet-5-5", "claude-sonnet-5", "claude-sonnet-4-6", "claude-fable-5-1", "claude-fable-5"]
        return dynamic.contains(model) ? "web_search_20260209" : "web_search_20250305"
    }
}

/// Cloud reasoning with Claude through the Messages API: streaming, tool use, web search.
///
/// The conversation is append-only for the life of a session (thinking blocks and
/// tool results are echoed back exactly), and is discarded when the session ends.
public actor ClaudeReasoner: Reasoner {
    public typealias CredentialProvider = @Sendable () async -> ClaudeConfiguration.Credential?

    private var configuration: ClaudeConfiguration
    private let credentials: CredentialProvider
    private let session: URLSession
    private var messages: [JSONValue] = []
    private var sessionSystem: [JSONValue]?
    public private(set) var lastUsage: JSONValue?
    /// Per-turn streaming state (the actor serializes access).
    private var chunker = SentenceChunker()
    private var eventSink: (@Sendable (ReasonerEvent) async -> Void)?

    public init(configuration: ClaudeConfiguration, session: URLSession = .shared, credentials: @escaping CredentialProvider) {
        self.configuration = configuration
        self.session = session
        self.credentials = credentials
    }

    public func update(configuration: ClaudeConfiguration) {
        if configuration.model != self.configuration.model { reset() }
        self.configuration = configuration
    }

    public func reset() {
        messages.removeAll()
        sessionSystem = nil
    }

    public var conversationLength: Int { messages.count }

    // MARK: Turn

    public func respond(to turn: ReasonerTurn, tools: [ToolSpec], executor: ToolExecutor,
                        events: @escaping @Sendable (ReasonerEvent) async -> Void) async throws -> ReasonerResult {
        guard let credential = await credentials() else { throw ReasonerError.notConfigured }
        if !turn.context.device.isOnline { throw ReasonerError.offline }

        if sessionSystem == nil {
            sessionSystem = [
                ["type": "text", "text": .string(PersonaPrompt.core), "cache_control": ["type": "ephemeral"]],
                ["type": "text", "text": .string(PersonaPrompt.session(preferences: turn.context.preferences, device: turn.context.device,
                                                                         locale: turn.context.temporal.locale, locality: turn.locality))],
            ]
        }
        let turnStart = messages.count
        let contextText = PersonaPrompt.turnContext(now: turn.context.now, temporal: turn.context.temporal,
                                                    memories: turn.memories, device: turn.context.device)
        messages.append(["role": "user", "content": [
            ["type": "text", "text": .string(contextText)],
            ["type": "text", "text": .string(turn.utterance)],
        ]])

        var spoken = ""
        var toolsUsed: [String] = []
        var externalContent = false
        var continuations = 0

        eventSink = events
        defer { eventSink = nil }

        for _ in 0..<8 {
            try Task.checkCancellation()
            chunker = SentenceChunker()
            let accumulator: MessageAccumulator
            do {
                accumulator = try await stream(body(tools: tools, locality: turn.locality, timeZone: turn.context.temporal.timeZone),
                                               credential: credential)
            } catch {
                // Keep the transcript valid: drop this turn's unanswered user message.
                if messages.count == turnStart + 1 { messages.removeLast() }
                throw error
            }
            if let rest = chunker.flush() {
                let speakable = SpeechText.sanitize(rest)
                if !speakable.isEmpty { await events(.speech(speakable)) }
            }
            spoken += accumulator.text
            messages.append(["role": "assistant", "content": .array(accumulator.content)])
            if accumulator.usedServerTools {
                externalContent = true
                let sources = accumulator.citedSources
                if !sources.isEmpty { await events(.sources(sources)) }
            }

            switch accumulator.stopReason {
            case "tool_use":
                var results: [JSONValue] = []
                for use in accumulator.toolUses {
                    toolsUsed.append(use.name)
                    results.append(await runTool(use, tools: tools, executor: executor, turnID: turn.turnID, externalContent: externalContent))
                }
                messages.append(["role": "user", "content": .array(results)])
            case "pause_turn":
                continuations += 1
                if continuations > 3 { return ReasonerResult(text: spoken, toolsUsed: toolsUsed) }
            case "refusal":
                return ReasonerResult(text: spoken, toolsUsed: toolsUsed, refused: true)
            case "max_tokens":
                let pending = accumulator.toolUses
                if !pending.isEmpty {
                    // Never run a tool whose input may be truncated; keep the transcript valid.
                    messages.append(["role": "user", "content": .array(pending.map { use in
                        Self.toolResult(id: use.id, content: ["status": "not_run", "reason": "Output was cut off before the request finished. Nothing was done."], isError: true)
                    })])
                }
                return ReasonerResult(text: spoken, toolsUsed: toolsUsed)
            default:
                return ReasonerResult(text: spoken, toolsUsed: toolsUsed)
            }
        }
        return ReasonerResult(text: spoken, toolsUsed: toolsUsed)
    }

    // MARK: Tools

    private func runTool(_ use: MessageAccumulator.ToolUse, tools: [ToolSpec], executor: ToolExecutor, turnID: String, externalContent: Bool) async -> JSONValue {
        guard let input = use.input else {
            return Self.toolResult(id: use.id, content: ["INVALID_JSON": .string(use.rawInput)], isError: true)
        }
        guard let spec = tools.first(where: { $0.name == use.name }) else {
            return Self.toolResult(id: use.id, content: ["error": .string("Unknown tool \(use.name).")], isError: true)
        }
        if let problem = ToolInputValidator.validate(input, schema: spec.inputSchema) {
            return Self.toolResult(id: use.id, content: ["error": .string(problem)], isError: true)
        }
        let call = ToolCall(id: use.id, name: use.name, arguments: input, origin: .cloudModel, turnID: turnID)
        let outcome = await executor.resolve(call, externalContent: externalContent)
        switch outcome {
        case .completed(let result):
            var content: JSONValue = ["status": "completed", "summary": .string(result.summary)]
            if !result.data.isNull { content["data"] = result.data }
            if spec.risk > .read { content["acknowledged_to_user"] = true }
            return Self.toolResult(id: use.id, content: content, isError: false)
        case .failed(let failure):
            let status = failure.kind == .cancelled ? "declined_by_user" : "failed"
            return Self.toolResult(id: use.id, content: ["status": .string(status), "message": .string(failure.message), "detail": .string(failure.detail),
                                                         "told_user": true], isError: failure.kind != .cancelled)
        default:
            return Self.toolResult(id: use.id, content: ["status": "incomplete", "message": "The request wasn't completed."], isError: true)
        }
    }

    static func toolResult(id: String, content: JSONValue, isError: Bool) -> JSONValue {
        var block: JSONValue = ["type": "tool_result", "tool_use_id": .string(id), "content": .string(content.serializedString)]
        if isError { block["is_error"] = true }
        return block
    }

    // MARK: Request

    func body(tools: [ToolSpec], locality: String?, timeZone: TimeZone) -> JSONValue {
        var toolDefinitions: [JSONValue] = tools.map { spec in
            var definition: JSONValue = ["name": .string(spec.name), "description": .string(spec.description), "input_schema": spec.inputSchema]
            if configuration.isOfficialEndpoint { definition["eager_input_streaming"] = true }
            return definition
        }
        if configuration.webSearch {
            var webSearch: JSONValue = ["type": .string(configuration.webSearchToolType), "name": "web_search", "max_uses": 3]
            var location: JSONValue = ["type": "approximate", "timezone": .string(timeZone.identifier)]
            if let locality { location["city"] = .string(locality) }
            webSearch["user_location"] = location
            toolDefinitions.append(webSearch)
        }
        var body: JSONValue = [
            "model": .string(configuration.model),
            "max_tokens": .number(Double(configuration.maxTokens)),
            "stream": true,
            "system": .array(sessionSystem ?? []),
            "messages": .array(messages),
            "tools": .array(toolDefinitions),
            "output_config": ["effort": .string(configuration.effort)],
        ]
        if configuration.supportsDefaultFallbacks { body["fallbacks"] = "default" }
        return body
    }

    func urlRequest(_ body: JSONValue, credential: ClaudeConfiguration.Credential) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        if configuration.supportsDefaultFallbacks {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        switch credential {
        case .apiKey(let key): request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .bearer(let token): request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = body.serialized()
        return request
    }

    // MARK: Streaming

    private func stream(_ body: JSONValue, credential: ClaudeConfiguration.Credential) async throws -> MessageAccumulator {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await streamOnce(urlRequest(body, credential: credential))
            } catch let error as RetryableError where attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(error.delay * 1_000_000_000))
                continue
            } catch let error as RetryableError {
                throw error.underlying
            }
        }
    }

    private struct RetryableError: Error {
        var underlying: ReasonerError
        var delay: TimeInterval
    }

    /// Forwards a streamed delta: speakable sentences as soon as they're complete, tool starts for status.
    private func emit(_ delta: MessageAccumulator.Delta) async {
        switch delta {
        case .text(let text):
            for chunk in chunker.append(text) {
                let speakable = SpeechText.sanitize(chunk)
                if !speakable.isEmpty { await eventSink?(.speech(speakable)) }
            }
        case .toolUseStarted(let name, let isServer):
            await eventSink?(.toolStarted(name: isServer ? "web_search" : name))
        }
    }

    private func process(_ event: SSEParser.Event, into accumulator: inout MessageAccumulator, received: inout Bool) async throws {
        for delta in accumulator.handle(event) {
            received = true
            await emit(delta)
        }
        if let message = accumulator.errorMessage {
            if !received, accumulator.errorType == "overloaded_error" || accumulator.errorType == "api_error" {
                throw RetryableError(underlying: .unavailable(message), delay: 1.2)
            }
            throw ReasonerError.badResponse(message)
        }
    }

    private func streamOnce(_ request: URLRequest) async throws -> MessageAccumulator {
        var parser = SSEParser()
        var accumulator = MessageAccumulator()
        var received = false

        do {
            #if canImport(FoundationNetworking)
            let (data, response) = try await session.data(for: request)
            try check(response, body: data)
            for event in parser.feed(data) { try await process(event, into: &accumulator, received: &received) }
            #else
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 64_000 { break }
                }
                try check(response, body: data)
            }
            for try await byte in bytes {
                for event in parser.feed(CollectionOfOne(byte)) {
                    try await process(event, into: &accumulator, received: &received)
                }
            }
            #endif
            if let last = parser.finish() { try await process(last, into: &accumulator, received: &received) }
        } catch let error as RetryableError {
            throw error
        } catch let error as ReasonerError {
            throw error
        } catch is CancellationError {
            throw ReasonerError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw ReasonerError.cancelled
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff:
                throw ReasonerError.offline
            case .timedOut:
                if received { throw ReasonerError.unavailable("timed out") }
                throw RetryableError(underlying: .unavailable("timed out"), delay: 0.5)
            default:
                throw ReasonerError.unavailable(error.localizedDescription)
            }
        }
        if accumulator.stopReason == nil && accumulator.content.isEmpty {
            throw ReasonerError.badResponse("empty stream")
        }
        return accumulator
    }

    private func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode >= 400 else { return }
        let message = (try? JSONValue.parse(body))?["error"]?["message"]?.stringValue ?? "HTTP \(http.statusCode)"
        switch http.statusCode {
        case 401, 403: throw ReasonerError.unauthorized
        case 429:
            let retryAfter = Double(http.value(forHTTPHeaderField: "retry-after") ?? "") ?? 2
            if retryAfter <= 4 { throw RetryableError(underlying: .rateLimited, delay: retryAfter) }
            throw ReasonerError.rateLimited
        case 500, 502, 503, 504, 529:
            throw RetryableError(underlying: .unavailable(message), delay: 1.0)
        default:
            throw ReasonerError.badResponse(message)
        }
    }
}

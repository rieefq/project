import Foundation

/// Incremental Server-Sent Events parser that keeps blank lines (event boundaries).
public struct SSEParser: Sendable {
    public struct Event: Sendable, Hashable {
        public var name: String?
        public var data: String
    }

    private var lineBuffer: [UInt8] = []
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    /// Feeds raw bytes; returns any complete events.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [Event] {
        var events: [Event] = []
        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                if lineBuffer.last == UInt8(ascii: "\r") { lineBuffer.removeLast() }
                let line = String(decoding: lineBuffer, as: UTF8.self)
                lineBuffer.removeAll(keepingCapacity: true)
                if let event = process(line: line) { events.append(event) }
            } else {
                lineBuffer.append(byte)
            }
        }
        return events
    }

    public mutating func feed(_ text: String) -> [Event] { feed(Array(text.utf8)) }

    /// Flushes a final event if the stream ended without a trailing blank line.
    public mutating func finish() -> Event? {
        if !lineBuffer.isEmpty {
            let line = String(decoding: lineBuffer, as: UTF8.self)
            lineBuffer.removeAll()
            if let event = process(line: line) { return event }
        }
        return dispatch()
    }

    private mutating func process(line: String) -> Event? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> Event? {
        defer { eventName = nil; dataLines.removeAll() }
        guard !dataLines.isEmpty else { return nil }
        return Event(name: eventName, data: dataLines.joined(separator: "\n"))
    }
}

/// Accumulates a streamed Messages API response into exact content blocks.
///
/// Blocks are rebuilt as raw JSON so everything the API sent — thinking signatures,
/// citations, server tool results and block types this build doesn't know — is sent
/// back unchanged on the next request.
public struct MessageAccumulator: Sendable {
    public enum Delta: Sendable, Hashable {
        case text(String)
        case toolUseStarted(name: String, isServerTool: Bool)
    }

    public struct ToolUse: Sendable, Hashable {
        public var id: String
        public var name: String
        public var input: JSONValue?
        public var rawInput: String
    }

    private var blocks: [Int: JSONValue] = [:]
    private var texts: [Int: String] = [:]
    private var partialJSON: [Int: String] = [:]
    public private(set) var stopReason: String?
    public private(set) var stopDetails: JSONValue?
    public private(set) var model: String?
    public private(set) var errorMessage: String?
    public private(set) var errorType: String?

    public init() {}

    public mutating func handle(_ event: SSEParser.Event) -> [Delta] {
        guard let payload = try? JSONValue.parse(event.data) else { return [] }
        let type = payload["type"]?.stringValue ?? event.name ?? ""
        switch type {
        case "message_start":
            model = payload["message"]?["model"]?.stringValue
        case "content_block_start":
            guard let index = payload["index"]?.intValue, let block = payload["content_block"] else { return [] }
            blocks[index] = block
            let blockType = block["type"]?.stringValue ?? ""
            if blockType == "text" { texts[index] = block["text"]?.stringValue ?? "" }
            if blockType == "tool_use" || blockType == "server_tool_use" {
                partialJSON[index] = ""
                return [.toolUseStarted(name: block["name"]?.stringValue ?? "", isServerTool: blockType == "server_tool_use")]
            }
        case "content_block_delta":
            guard let index = payload["index"]?.intValue, let delta = payload["delta"] else { return [] }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let text = delta["text"]?.stringValue ?? ""
                texts[index, default: ""] += text
                return text.isEmpty ? [] : [.text(text)]
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
            case "thinking_delta":
                let existing = blocks[index]?["thinking"]?.stringValue ?? ""
                blocks[index]?["thinking"] = .string(existing + (delta["thinking"]?.stringValue ?? ""))
            case "signature_delta":
                let existing = blocks[index]?["signature"]?.stringValue ?? ""
                blocks[index]?["signature"] = .string(existing + (delta["signature"]?.stringValue ?? ""))
            case "citations_delta":
                if let citation = delta["citation"] {
                    var citations = blocks[index]?["citations"]?.arrayValue ?? []
                    citations.append(citation)
                    blocks[index]?["citations"] = .array(citations)
                }
            default:
                break
            }
        case "content_block_stop":
            guard let index = payload["index"]?.intValue else { return [] }
            if let text = texts[index] { blocks[index]?["text"] = .string(text) }
            if let raw = partialJSON[index] {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    blocks[index]?["input"] = .object([:])
                } else if let parsed = try? JSONValue.parse(trimmed) {
                    blocks[index]?["input"] = parsed
                } else {
                    // Keep the raw text so the tool loop can report INVALID_JSON.
                    blocks[index]?["input"] = .object([:])
                    blocks[index]?["_invalid_input"] = .string(trimmed)
                }
            }
        case "message_delta":
            if let reason = payload["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
            if let details = payload["delta"]?["stop_details"], !details.isNull { stopDetails = details }
        case "error":
            errorType = payload["error"]?["type"]?.stringValue
            errorMessage = payload["error"]?["message"]?.stringValue ?? "stream error"
        default:
            break
        }
        return []
    }

    /// Content blocks in order, ready to append as the assistant message.
    public var content: [JSONValue] {
        blocks.keys.sorted().compactMap { index in
            guard var block = blocks[index] else { return nil }
            block["_invalid_input"] = nil
            return block
        }
    }

    public var text: String {
        blocks.keys.sorted().compactMap { index -> String? in
            guard blocks[index]?["type"]?.stringValue == "text" else { return nil }
            return texts[index]
        }.joined()
    }

    /// Client tool calls (server tools run on Anthropic's side).
    public var toolUses: [ToolUse] {
        blocks.keys.sorted().compactMap { index in
            guard let block = blocks[index], block["type"]?.stringValue == "tool_use",
                  let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { return nil }
            let invalid = block["_invalid_input"]?.stringValue
            return ToolUse(id: id, name: name, input: invalid == nil ? block["input"] : nil, rawInput: invalid ?? "")
        }
    }

    /// Web sources cited in text blocks.
    public var citedSources: [SourcesCard.Source] {
        var seen = Set<String>()
        var sources: [SourcesCard.Source] = []
        for index in blocks.keys.sorted() {
            for citation in blocks[index]?["citations"]?.arrayValue ?? [] {
                guard let url = citation["url"]?.stringValue, !seen.contains(url) else { continue }
                seen.insert(url)
                sources.append(SourcesCard.Source(title: citation["title"]?.stringValue ?? URL(string: url)?.host ?? url, url: url))
            }
        }
        return sources
    }

    public var usedServerTools: Bool {
        blocks.values.contains { $0["type"]?.stringValue == "server_tool_use" }
    }
}

/// Validates model-provided tool input against the tool's JSON Schema (the subset Aside uses).
public enum ToolInputValidator {
    public static func validate(_ input: JSONValue, schema: JSONValue) -> String? {
        guard case .object(let object) = input else { return "Input must be a JSON object." }
        let properties = schema["properties"]?.objectValue ?? [:]
        for required in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[required] == nil || object[required]?.isNull == true {
            return "Missing required field `\(required)`."
        }
        for (key, value) in object {
            guard let property = properties[key] else {
                if schema["additionalProperties"]?.boolValue == false { return "Unknown field `\(key)`." }
                continue
            }
            if value.isNull { continue }
            switch property["type"]?.stringValue {
            case "string":
                guard case .string(let text) = value else { return "`\(key)` must be a string." }
                if let allowed = property["enum"]?.arrayValue?.compactMap(\.stringValue), !allowed.contains(text) {
                    return "`\(key)` must be one of: \(allowed.joined(separator: ", "))."
                }
            case "number":
                guard value.doubleValue != nil else { return "`\(key)` must be a number." }
            case "boolean":
                guard value.boolValue != nil else { return "`\(key)` must be true or false." }
            default:
                break
            }
        }
        return nil
    }
}

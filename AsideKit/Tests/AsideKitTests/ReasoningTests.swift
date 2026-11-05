import Foundation
import Testing
@testable import AsideKit

@Suite("Claude streaming")
struct ClaudeStreamTests {
    static let stream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[]}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-abc"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"check."}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: content_block_start
    data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_schedule","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"when\\": \\"tom"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"orrow\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":2}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":42}}

    event: message_stop
    data: {"type":"message_stop"}


    """

    @Test func parsesEventsAcrossArbitraryChunks() {
        var parser = SSEParser()
        let bytes = Array(Self.stream.utf8)
        var events: [SSEParser.Event] = []
        var index = 0
        while index < bytes.count {
            let end = min(bytes.count, index + 37)
            events += parser.feed(bytes[index..<end])
            index = end
        }
        if let last = parser.finish() { events.append(last) }
        #expect(events.count == 14)
        #expect(events.first?.name == "message_start")
    }

    @Test func rebuildsContentBlocksExactly() {
        var parser = SSEParser()
        var accumulator = MessageAccumulator()
        var deltas: [MessageAccumulator.Delta] = []
        for event in parser.feed(Self.stream) { deltas += accumulator.handle(event) }
        #expect(deltas.contains(.text("Let me ")))
        #expect(deltas.contains(.toolUseStarted(name: "get_schedule", isServerTool: false)))
        #expect(accumulator.stopReason == "tool_use")
        #expect(accumulator.text == "Let me check.")
        let content = accumulator.content
        #expect(content.count == 3)
        #expect(content[0]["signature"]?.stringValue == "sig-abc")
        #expect(content[2]["input"]?["when"]?.stringValue == "tomorrow")
        #expect(accumulator.toolUses.first?.input?["when"]?.stringValue == "tomorrow")
    }

    @Test func invalidToolJSONIsReportedNotRun() {
        var accumulator = MessageAccumulator()
        let events = [
            SSEParser.Event(name: nil, data: #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"x","input":{}}}"#),
            SSEParser.Event(name: nil, data: #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a\": "}}"#),
            SSEParser.Event(name: nil, data: #"{"type":"content_block_stop","index":0}"#),
        ]
        for event in events { _ = accumulator.handle(event) }
        #expect(accumulator.toolUses.first?.input == nil)
        #expect(accumulator.toolUses.first?.rawInput == "{\"a\":")
        #expect(accumulator.content.first?["_invalid_input"] == nil)
    }

    @Test func validatesToolInput() {
        let schema = CreateReminderTool(service: FakeReminders()).spec.inputSchema
        #expect(ToolInputValidator.validate(["title": "x"], schema: schema) == nil)
        #expect(ToolInputValidator.validate([:], schema: schema) != nil)
        #expect(ToolInputValidator.validate(["title": 4], schema: schema) != nil)
        #expect(ToolInputValidator.validate(["title": "x", "bogus": true], schema: schema) != nil)
    }

    @Test func requestBodyIsCacheFriendlyAndCurrent() async {
        let reasoner = ClaudeReasoner(configuration: ClaudeConfiguration()) { .apiKey("k") }
        let tools = [CreateReminderTool(service: FakeReminders()).spec, GetTimeTool().spec]
        let body = await reasoner.body(tools: tools, locality: "Oakland", timeZone: testCalendar.timeZone)
        #expect(body["model"]?.stringValue == "claude-opus-5-5")
        #expect(body["temperature"] == nil)
        #expect(body["fallbacks"]?.stringValue == "default")
        #expect(body["output_config"]?["effort"]?.stringValue == "low")
        let toolList = body["tools"]?.arrayValue ?? []
        #expect(toolList.first?["eager_input_streaming"]?.boolValue == true)
        #expect(toolList.last?["type"]?.stringValue == "web_search_20260209")
        let request = await reasoner.urlRequest(body, credential: .apiKey("k"))
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test func relaysDontGetOfficialOnlyFeatures() async {
        let config = ClaudeConfiguration(baseURL: URL(string: "https://relay.example.com")!, model: "claude-opus-5-5")
        let reasoner = ClaudeReasoner(configuration: config) { .bearer("t") }
        let body = await reasoner.body(tools: [GetTimeTool().spec], locality: nil, timeZone: testCalendar.timeZone)
        #expect(body["fallbacks"] == nil)
        #expect(body["tools"]?.arrayValue?.first?["eager_input_streaming"] == nil)
    }
}

@Suite("On-device intent frames")
struct IntentFrameTests {
    @Test func framesBecomeToolCalls() {
        let reminder = IntentFrame(action: .createReminder, subject: "water the plants", when: "every Sunday morning")
        #expect(reminder.toolCall(turnID: "t")?.arguments["when"]?.stringValue == "every Sunday morning")
        #expect(IntentFrame(action: .createReminder, subject: "none").toolCall(turnID: "t") == nil)
        let timer = IntentFrame(action: .startTimer, subject: "eggs", detail: "7 minutes")
        #expect(timer.toolCall(turnID: "t")?.arguments["label"]?.stringValue == "eggs")
        #expect(IntentFrame(action: .none).toolCall(turnID: "t") == nil)
    }
}

import XCTest
@testable import Core

/// Mock-based decoding tests for documented pi RPC responses. No real process
/// is spawned and no live model is ever hit — responses are crafted from the
/// documented protocol shapes (see `dist/modes/rpc/rpc-types.d.ts` in pi) and
/// fed through the same decoding path the app uses at runtime.
final class ResponseDecodingTests: XCTestCase {

    func testGetStateDecodesSessionState() throws {
        // Documented RpcSessionState (subset used by the client).
        let frame = response(command: "get_state", dataJSON: """
        {"model":{"id":"deepseek-v4-flash","provider":"deepseek","contextWindow":1000000},
         "thinkingLevel":"max","isStreaming":false,"sessionId":"abc",
         "sessionFile":"/tmp/s.json","sessionName":"demo","messageCount":4,"pendingMessageCount":0}
        """)
        let payload = frame.dataPayload(SessionStatePayload.self)
        XCTAssertNotNil(payload, "get_state response should decode to a session-state payload")
        XCTAssertEqual(payload?.model?.id, "deepseek-v4-flash")
        XCTAssertEqual(payload?.thinkingLevel, "max")
        XCTAssertEqual(payload?.sessionName, "demo")
    }

    func testGetAvailableModelsDecodes() throws {
        let frame = response(command: "get_available_models", dataJSON: """
        {"models":[
          {"id":"deepseek-v4-flash","name":"DeepSeek V4 Flash","provider":"deepseek","reasoning":true,"contextWindow":1000000},
          {"id":"deepseek-v4-pro","name":"DeepSeek V4 Pro","provider":"deepseek","reasoning":true,"contextWindow":1000000}
        ]}
        """)
        let payload = frame.dataPayload(ModelsPayload.self)
        XCTAssertEqual(payload?.models.count, 2)
        XCTAssertEqual(payload?.models.first?.id, "deepseek-v4-flash")
    }

    func testGetAvailableThinkingLevelsDecodes() throws {
        // Documented: the set depends on the current model's thinkingLevelMap.
        let frame = response(command: "get_available_thinking_levels", dataJSON: """
        {"levels":["off","high","max"]}
        """)
        let payload = frame.dataPayload(LevelsPayload.self)
        XCTAssertEqual(payload?.levels, ["off", "high", "max"])
    }

    func testGetSessionStatsDecodesContextUsage() throws {
        // Documented SessionStats.contextUsage — drives the status-bar %. A
        // `percent` is the fraction of the context window in use.
        let frame = response(command: "get_session_stats", dataJSON: """
        {"tokens":{"input":1200,"output":400,"cacheRead":0,"cacheWrite":0,"total":1600},
         "cost":0.01,"contextUsage":{"tokens":1600,"contextWindow":1000000,"percent":0.16}}
        """)
        let payload = frame.dataPayload(SessionStatsPayload.self)
        XCTAssertNotNil(payload?.contextUsage)
        XCTAssertEqual(payload?.contextUsage?.tokens, 1600)
        XCTAssertEqual(payload?.contextUsage?.contextWindow, 1000000)
        XCTAssertEqual(payload?.contextUsage?.percent, 0.16)
    }

    func testGetSessionStatsContextUsageMayBeAbsent() throws {
        // After a compaction the context token count can be unknown, so pi
        // omits `contextUsage` (or returns percent null). The client must not
        // crash and should surface a missing reading as nil.
        let frame = response(command: "get_session_stats", dataJSON: """
        {"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"cost":0}
        """)
        let payload = frame.dataPayload(SessionStatsPayload.self)
        XCTAssertNotNil(payload)
        XCTAssertNil(payload?.contextUsage)
    }

    func testGetMessagesDecodesAgentMessages() throws {
        // Documented AgentMessage shapes: text/thinking/toolCall content blocks.
        let frame = response(command: "get_messages", dataJSON: """
        {"messages":[
          {"role":"user","id":"u1","content":[{"type":"text","text":"hello"}]},
          {"role":"assistant","id":"a1","content":[
             {"type":"thinking","thinking":"reasoning..."},
             {"type":"toolCall","id":"t1","name":"bash","arguments":{"cmd":"ls"}},
             {"type":"text","text":"done"}
          ]}
        ]}
        """)
        let payload = frame.dataPayload(MessagesPayload.self)
        XCTAssertEqual(payload?.messages.count, 2)
        let assistant = payload?.messages[1]
        XCTAssertEqual(assistant?.content?.count, 3)
        XCTAssertEqual(assistant?.content?[1].isToolCall, true)
        XCTAssertEqual(assistant?.content?[1].name, "bash")
    }

    func testAgentMessageDecodesUsage() throws {
        // Documented usage shape on the finalized assistant message.
        let frame = response(command: "get_messages", dataJSON: """
        {"messages":[
          {"role":"assistant","id":"a1","content":[{"type":"text","text":"done"}],
           "usage":{"input":2119,"output":217,"cacheRead":640,"cacheWrite":0}}
        ]}
        """)
        let payload = frame.dataPayload(MessagesPayload.self)
        let usage = payload?.messages.first?.usage
        XCTAssertEqual(usage?.input, 2119)
        XCTAssertEqual(usage?.cacheRead, 640)
        XCTAssertEqual(usage?.cacheWrite, 0)
        XCTAssertEqual(usage?.output, 217)
        // 640 read / (640 read + 2119 uncached) = 23.2%.
        XCTAssertEqual(usage?.cacheHitRate ?? 0, 640.0 / 2759.0, accuracy: 0.0001)
    }

    func testUsageCacheHitRateHandlesMissingFields() {
        let usage = TokenUsage(input: nil, output: nil, cacheRead: nil, cacheWrite: nil)
        XCTAssertNil(usage.cacheHitRate)
        let allZero = TokenUsage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
        XCTAssertNil(allZero.cacheHitRate)
        let full = TokenUsage(input: 0, output: 0, cacheRead: 100, cacheWrite: 0)
        XCTAssertEqual(full.cacheHitRate ?? 0, 1.0, accuracy: 0.0001)
    }
}

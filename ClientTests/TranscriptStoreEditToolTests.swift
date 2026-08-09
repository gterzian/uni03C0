import XCTest
@testable import Core

/// Tests for the edit-tool path through `TranscriptStore`: the card must carry
/// the raw structured arguments (so the client renders a diff, not truncated
/// text), stay a single card across the streamed lifecycle, and attach results
/// on rebuild. Pure data — no pi process, no LLM.
final class TranscriptStoreEditToolTests: XCTestCase {

    private func editToolCallEndJSON() -> String {
        #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","contentIndex":1,"toolCall":{"type":"toolCall","id":"tc-edit","name":"edit","arguments":{"path":"/tmp/app.swift","edits":[{"oldText":"let a = 1","newText":"let a = 2"}]}}}}"#
    }

    func testEditCardCarriesRawArgumentsValue() {
        let store = TranscriptStore()
        XCTAssertTrue(store.apply(frame(type: "message_update", editToolCallEndJSON())))
        guard case .toolCall(let card)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected an edit tool card")
        }
        XCTAssertEqual(card.toolName, "edit")
        XCTAssertNotNil(card.argumentsValue, "raw args must be kept for the diff view")
        let ops = EditToolArgs.parse(card.argumentsValue)
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.path, "/tmp/app.swift")
        XCTAssertEqual(ops.first?.oldText, "let a = 1")
        XCTAssertEqual(ops.first?.newText, "let a = 2")
    }

    func testEditCardSurvivesExecutionLifecycleAsOneCard() {
        let store = TranscriptStore()
        XCTAssertTrue(store.apply(frame(type: "message_update", editToolCallEndJSON())))
        XCTAssertEqual(store.count, 1)

        XCTAssertTrue(store.apply(frame(type: "tool_execution_start",
            #"{"type":"tool_execution_start","toolCallId":"tc-edit","toolName":"edit","args":{"path":"/tmp/app.swift","edits":[{"oldText":"let a = 1","newText":"let a = 2"}]}}"#)))
        XCTAssertEqual(store.count, 1, "execution start must not duplicate the card")

        XCTAssertTrue(store.apply(frame(type: "tool_execution_update",
            #"{"type":"tool_execution_update","toolCallId":"tc-edit","partialResult":{"content":[{"type":"text","text":"Applied"}]}}"#)))
        guard case .toolCall(let running)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool card")
        }
        XCTAssertEqual(running.output, "Applied")
        XCTAssertEqual(running.state, .running)
        XCTAssertNotNil(running.argumentsValue)

        XCTAssertTrue(store.apply(frame(type: "tool_execution_end",
            #"{"type":"tool_execution_end","toolCallId":"tc-edit","toolName":"edit","result":{"content":[{"type":"text","text":"Applied"}]}}"#)))
        guard case .toolCall(let done)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool card")
        }
        XCTAssertEqual(done.state, .done)
        XCTAssertNotNil(done.argumentsValue, "the raw args survive the lifecycle")
    }

    func testEditArgsSurviveExecutionStartArgSwap() {
        let store = TranscriptStore()
        XCTAssertTrue(store.apply(frame(type: "message_update", editToolCallEndJSON())))
        // execution_start carries the same shape; the store swaps args in
        // place but must keep the raw value too.
        XCTAssertTrue(store.apply(frame(type: "tool_execution_start",
            #"{"type":"tool_execution_start","toolCallId":"tc-edit","toolName":"edit","args":{"path":"/tmp/app.swift","edits":[{"oldText":"let a = 1","newText":"let a = 2"}]}}"#)))
        guard case .toolCall(let card)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool card")
        }
        XCTAssertEqual(EditToolArgs.parse(card.argumentsValue).count, 1)
    }

    func testRebuildFromMessagesKeepsRawArgsAndAttachesOutput() {
        let store = TranscriptStore()
        let messages: [AgentMessage] = [
            AgentMessage(role: "assistant", content: [
                ContentBlock(type: "toolCall", id: "tc-edit", name: "edit", arguments: [
                    "path": "f.swift",
                    "edits": [["oldText": "x", "newText": "y"]],
                ]),
            ], id: "a1"),
            AgentMessage(role: "toolResult", content: [
                ContentBlock(type: "text", text: "Edited 1 block"),
            ], id: "r1", toolCallId: "tc-edit"),
        ]
        store.rebuild(from: messages)

        XCTAssertEqual(store.count, 1, "the result attaches to the card, no separate row")
        guard case .toolCall(let card)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool card")
        }
        XCTAssertEqual(card.toolName, "edit")
        XCTAssertEqual(card.state, .done)
        XCTAssertEqual(card.output, "Edited 1 block")
        XCTAssertEqual(EditToolArgs.parse(card.argumentsValue).first?.path, "f.swift")
    }

    func testAbortDropsTurnStartPlaceholder() {
        let store = TranscriptStore()
        XCTAssertTrue(store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u1\",\"content\":[{\"type\":\"text\",\"text\":\"go\"}]}}")))
        XCTAssertEqual(store.count, 2, "echoed user message + turn-start placeholder")

        // Aborted before any assistant message: turn_end drops the placeholder.
        XCTAssertTrue(store.apply(frame(type: "turn_end", "{\"type\":\"turn_end\"}")))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.entry(at: 0)?.kind, .userMessage(text: "go"))
    }

    func testAbortMidStreamFinalizesStreamingRow() {
        let store = TranscriptStore()
        _ = store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}"))
        _ = store.apply(frame(type: "message_update",
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"partial\"}}"))
        XCTAssertTrue(store.apply(frame(type: "agent_end", "{\"type\":\"agent_end\"}")))
        XCTAssertEqual(store.entry(at: 0)?.kind, .assistantMessage(text: "partial", thinking: "", isStreaming: false))
    }
}

import XCTest
@testable import Core

/// Tests for surfacing failed LLM streams (network errors, aborts, truncation)
/// as transcript error rows — matching pi's TUI (`assistant-message.js`).
/// Pure data folding; no pi process, no LLM.
final class TranscriptStoreErrorTests: XCTestCase {

    private func beginAssistant(_ store: TranscriptStore, id: String = "a1") {
        XCTAssertTrue(store.apply(frame(type: "message_start",
            #"{"type":"message_start","message":{"role":"assistant","id":"\#(id)","content":[{"type":"text","text":""}]}}"#)))
    }

    func testNetworkErrorAppendsErrorRow() {
        let store = TranscriptStore()
        beginAssistant(store)
        XCTAssertTrue(store.apply(frame(type: "message_end",
            #"{"type":"message_end","message":{"role":"assistant","id":"a1","stopReason":"error","errorMessage":"fetch failed: connection refused","content":[{"type":"text","text":"partial"}]}}"#)))
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.entry(at: 0)?.kind, .assistantMessage(text: "partial", thinking: "", isStreaming: false))
        XCTAssertEqual(store.entry(at: 1)?.kind, .errorMessage("Error: fetch failed: connection refused"))
    }

    func testErrorWithoutMessageFallsBackToUnknownError() {
        let store = TranscriptStore()
        beginAssistant(store)
        _ = store.apply(frame(type: "message_end",
            #"{"type":"message_end","message":{"role":"assistant","id":"a1","stopReason":"error","content":[]}}"#))
        XCTAssertEqual(store.entry(at: 1)?.kind, .errorMessage("Error: Unknown error"))
    }

    func testAbortAppendsOperationAborted() {
        let store = TranscriptStore()
        beginAssistant(store)
        _ = store.apply(frame(type: "message_end",
            #"{"type":"message_end","message":{"role":"assistant","id":"a1","stopReason":"aborted","errorMessage":"Request was aborted","content":[]}}"#))
        XCTAssertEqual(store.entry(at: 1)?.kind, .abortedMessage("Operation aborted"))
    }

    func testAbortWithDistinctMessageSurfacesIt() {
        let store = TranscriptStore()
        beginAssistant(store)
        _ = store.apply(frame(type: "message_end",
            #"{"type":"message_end","message":{"role":"assistant","id":"a1","stopReason":"aborted","errorMessage":"Aborted after 2 retry attempts","content":[]}}"#))
        XCTAssertEqual(store.entry(at: 1)?.kind, .abortedMessage("Aborted after 2 retry attempts"))
    }

    func testLengthStopSurfacesTruncation() {
        let store = TranscriptStore()
        beginAssistant(store)
        _ = store.apply(frame(type: "message_end",
            #"{"type":"message_end","message":{"role":"assistant","id":"a1","stopReason":"length","content":[{"type":"text","text":"cut off"}]}}"#))
        XCTAssertEqual(store.entry(at: 0)?.kind, .assistantMessage(text: "cut off", thinking: "", isStreaming: false))
        XCTAssertEqual(store.entry(at: 1)?.kind, .errorMessage("Response was truncated before completion."))
    }

    func testNormalEndAppendsNoErrorRow() {
        let store = TranscriptStore()
        beginAssistant(store)
        _ = store.apply(frame(type: "message_end",
            #"{"type":"message_end","message":{"role":"assistant","id":"a1","stopReason":"end","content":[{"type":"text","text":"done"}]}}"#))
        XCTAssertEqual(store.count, 1, "a clean end adds no error row")
    }

    func testErrorWithToolCallsDoesNotAppendErrorRow() {
        // Tool failures surface in their cards (the TUI skips the message-level
        // error text when the message carries tool calls).
        let store = TranscriptStore()
        beginAssistant(store)
        _ = store.apply(frame(type: "message_end",
            #"{"type":"message_end","message":{"role":"assistant","id":"a1","stopReason":"error","errorMessage":"boom","content":[{"type":"toolCall","id":"tc1","name":"bash"}]}}"#))
        XCTAssertEqual(store.count, 1)
    }

    func testTurnEndAfterMessageEndDoesNotDuplicateErrorRow() {
        let store = TranscriptStore()
        beginAssistant(store)
        _ = store.apply(frame(type: "message_end",
            #"{"type":"message_end","message":{"role":"assistant","id":"a1","stopReason":"error","errorMessage":"boom","content":[]}}"#))
        // turn_end arrives after message_end; it must not add another row.
        _ = store.apply(frame(type: "turn_end", "{\"type\":\"turn_end\"}"))
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.entry(at: 1)?.kind, .errorMessage("Error: boom"))
    }

    func testRebuildFromMessagesSurfacesStoredError() {
        let store = TranscriptStore()
        let messages: [AgentMessage] = [
            AgentMessage(role: "assistant", content: [
                ContentBlock(type: "text", text: "partial"),
            ], id: "a1", stopReason: "error", errorMessage: "stream failed"),
        ]
        store.rebuild(from: messages)
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.entry(at: 0)?.kind, .assistantMessage(text: "partial", thinking: "", isStreaming: false))
        XCTAssertEqual(store.entry(at: 1)?.kind, .errorMessage("Error: stream failed"))
    }

    func testFailureKindMapping() {
        XCTAssertEqual(TranscriptStore.failureKind(for: AgentMessage(role: "assistant", id: "x", stopReason: "error")), .errorMessage("Error: Unknown error"))
        XCTAssertEqual(TranscriptStore.failureKind(for: AgentMessage(role: "assistant", id: "x", stopReason: "error", errorMessage: "503")), .errorMessage("Error: 503"))
        XCTAssertEqual(TranscriptStore.failureKind(for: AgentMessage(role: "assistant", id: "x", stopReason: "aborted")), .abortedMessage("Operation aborted"))
        XCTAssertEqual(TranscriptStore.failureKind(for: AgentMessage(role: "assistant", id: "x", stopReason: "aborted", errorMessage: "Aborted after 2 retry attempts")), .abortedMessage("Aborted after 2 retry attempts"))
        XCTAssertEqual(TranscriptStore.failureKind(for: AgentMessage(role: "assistant", id: "x", stopReason: "length")), .errorMessage("Response was truncated before completion."))
        XCTAssertNil(TranscriptStore.failureKind(for: AgentMessage(role: "assistant", id: "x", stopReason: "end")))
        XCTAssertNil(TranscriptStore.failureKind(for: AgentMessage(role: "assistant", id: "x")))
    }

    // MARK: - Interrupted tool cards (settle on abort/error)

    /// An interrupted tool gets no `tool_execution_end`, so the turn-end
    /// signal must settle its card out of `.running` or the spinner animates
    /// forever. The abort arrives as `message_end` with stopReason "aborted".
    func testAbortMidToolSettlesRunningCard() {
        let store = TranscriptStore()
        XCTAssertTrue(store.apply(frame(type: "tool_execution_start",
            "{\"type\":\"tool_execution_start\",\"toolCallId\":\"t1\",\"toolName\":\"bash\",\"args\":{\"cmd\":\"sleep 5\"}}")))
        XCTAssertTrue(store.apply(frame(type: "tool_execution_update",
            "{\"type\":\"tool_execution_update\",\"toolCallId\":\"t1\",\"partialResult\":{\"content\":[{\"type\":\"text\",\"text\":\"halfway\"}]}}")))
        guard case .toolCall(let running)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(running.state, .running)

        _ = store.apply(frame(type: "message_end",
            #"{"type":"message_end","message":{"role":"assistant","id":"a1","stopReason":"aborted","errorMessage":"Request was aborted","content":[]}}"#))

        guard case .toolCall(let settled)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(settled.state, .failed, "an interrupted tool card must leave .running so its spinner stops")
        XCTAssertEqual(settled.output, "halfway", "partial output is kept")
    }

    /// The abort can also arrive with no final `message_end` at all — only
    /// `turn_end`/`agent_end`. The settle must fire there too.
    func testAbortMidToolViaTurnEndSettlesRunningCard() {
        let store = TranscriptStore()
        XCTAssertTrue(store.apply(frame(type: "tool_execution_start",
            "{\"type\":\"tool_execution_start\",\"toolCallId\":\"t1\",\"toolName\":\"bash\",\"args\":{\"cmd\":\"sleep 5\"}}")))

        XCTAssertTrue(store.apply(frame(type: "turn_end", "{\"type\":\"turn_end\"}")))

        guard case .toolCall(let settled)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(settled.state, .failed)
    }

    /// A tool-USE step's `message_end` (stopReason "tool_use") is the
    /// message that generated the call — its card is legitimately running
    /// (created at `toolcall_end`, before `tool_execution_start`). Settling
    /// there would fail every tool before it runs.
    func testToolUseMessageEndKeepsCardRunning() {
        let store = TranscriptStore()
        _ = store.apply(frame(type: "message_start",
            #"{"type":"message_start","message":{"role":"assistant","id":"a1","content":[{"type":"text","text":""}]}}"#))
        _ = store.apply(frame(type: "message_update",
            #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","contentIndex":1,"toolCall":{"type":"toolCall","id":"tc1","name":"bash","arguments":{"cmd":"ls"}}}}"#))
        XCTAssertEqual(store.count, 2)
        _ = store.apply(frame(type: "message_end",
            #"{"type":"message_end","message":{"role":"assistant","id":"a1","stopReason":"tool_use","content":[{"type":"toolCall","id":"tc1","name":"bash","arguments":{"cmd":"ls"}}]}}"#))
        guard case .toolCall(let card)? = store.entry(at: 1)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(card.state, .running, "a tool-use step's message_end must not settle its card")
    }

    /// A settle is provisional: if the tool actually finished (late
    /// `tool_execution_end`, e.g. the abort raced the real end), the real
    /// outcome wins.
    func testLateToolExecutionEndOverwritesSettle() {
        let store = TranscriptStore()
        XCTAssertTrue(store.apply(frame(type: "tool_execution_start",
            "{\"type\":\"tool_execution_start\",\"toolCallId\":\"t1\",\"toolName\":\"bash\",\"args\":{\"cmd\":\"build\"}}")))
        _ = store.apply(frame(type: "turn_end", "{\"type\":\"turn_end\"}"))
        guard case .toolCall(let settled)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(settled.state, .failed)

        XCTAssertTrue(store.apply(frame(type: "tool_execution_end",
            "{\"type\":\"tool_execution_end\",\"toolCallId\":\"t1\",\"toolName\":\"bash\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}")))
        guard case .toolCall(let done)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(done.state, .done)
    }
}

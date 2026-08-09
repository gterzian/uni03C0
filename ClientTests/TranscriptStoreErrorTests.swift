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
}

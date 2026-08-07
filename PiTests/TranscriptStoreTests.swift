import XCTest
@testable import PiCore

/// Tests for `TranscriptStore` event folding — pure data, no pi process needed.
final class TranscriptStoreTests: XCTestCase {

    func testFoldsAssistantStreamingToFinalized() {
        let store = TranscriptStore()

        // Start an assistant message (empty content) -> streaming row.
        XCTAssertTrue(store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}")))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.entry(at: 0)?.kind, .assistantMessage(text: "", thinking: "", isStreaming: true))

        // A text delta appends to the streaming row.
        XCTAssertTrue(store.apply(frame(type: "message_update",
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"Hello\"}}")))
        XCTAssertEqual(store.entry(at: 0)?.kind, .assistantMessage(text: "Hello", thinking: "", isStreaming: true))

        // A second delta.
        XCTAssertTrue(store.apply(frame(type: "message_update",
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\" world\"}}")))
        XCTAssertEqual(store.entry(at: 0)?.kind, .assistantMessage(text: "Hello world", thinking: "", isStreaming: true))

        // message_end finalizes it (isStreaming -> false).
        XCTAssertTrue(store.apply(frame(type: "message_end",
            "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"Hello world\"}]}}")))
        XCTAssertEqual(store.entry(at: 0)?.kind, .assistantMessage(text: "Hello world", thinking: "", isStreaming: false))
    }

    func testAppendsUserMessage() {
        let store = TranscriptStore()
        XCTAssertTrue(store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u1\",\"content\":[{\"type\":\"text\",\"text\":\"What is pi?\"}]}}")))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.entry(at: 0)?.kind, .userMessage(text: "What is pi?"))
    }

    func testFoldsToolCallLifecycle() {
        let store = TranscriptStore()

        // Start -> running card.
        XCTAssertTrue(store.apply(frame(type: "tool_execution_start",
            "{\"type\":\"tool_execution_start\",\"toolCallId\":\"t1\",\"toolName\":\"bash\",\"args\":{\"cmd\":\"ls\"}}")))
        XCTAssertEqual(store.count, 1)
        guard case .toolCall(let card)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(card.toolName, "bash")
        XCTAssertEqual(card.state, .running)

        // Update -> output is set.
        XCTAssertTrue(store.apply(frame(type: "tool_execution_update",
            "{\"type\":\"tool_execution_update\",\"toolCallId\":\"t1\",\"partialResult\":{\"content\":[{\"type\":\"text\",\"text\":\"file.txt\"}]}}")))
        guard case .toolCall(let updated)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(updated.output, "file.txt")

        // End -> done.
        XCTAssertTrue(store.apply(frame(type: "tool_execution_end",
            "{\"type\":\"tool_execution_end\",\"toolCallId\":\"t1\",\"toolName\":\"bash\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"file.txt\"}]}}")))
        guard case .toolCall(let done)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(done.state, .done)
    }

    func testUnrelatedFramesAreIgnored() {
        let store = TranscriptStore()
        XCTAssertFalse(store.apply(frame(type: "stderr", "{\"type\":\"stderr\",\"text\":\"warn\"}")))
        XCTAssertFalse(store.apply(frame(type: "some_extension", "{\"type\":\"some_extension\"}")))
        XCTAssertEqual(store.count, 0)
    }

    func testRebuildReplacesHistory() {
        let store = TranscriptStore()
        _ = store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u1\",\"content\":[{\"type\":\"text\",\"text\":\"old\"}]}}"))
        XCTAssertEqual(store.count, 1)

        let message = AgentMessage(role: "assistant", content: [ContentBlock(type: "text", text: "fresh")], id: "n1")
        XCTAssertTrue(store.rebuild(from: [message]))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.entry(at: 0)?.kind, .assistantMessage(text: "fresh", thinking: "", isStreaming: false))
    }

    func testVersionAndGenerationAdvance() {
        let store = TranscriptStore()
        let v0 = store.currentVersion
        _ = store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u1\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"))
        XCTAssertGreaterThan(store.currentVersion, v0)

        let g0 = store.currentGeneration
        _ = store.rebuild(from: [AgentMessage(role: "user", content: [ContentBlock(type: "text", text: "x")])])
        XCTAssertGreaterThan(store.currentGeneration, g0)
    }
}

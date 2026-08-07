import XCTest
@testable import Core

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
        // The echoed user message plus the turn-start placeholder below it
        // (the response slot with the pulsing caret during TTFT).
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.entry(at: 0)?.kind, .userMessage(text: "What is pi?"))
        XCTAssertEqual(store.entry(at: 1)?.kind, .assistantMessage(text: "", thinking: "", isStreaming: true))
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

    func testToolCallAppearsWhileModelStillStreamsArguments() {
        let store = TranscriptStore()

        // The assistant message starts streaming text.
        _ = store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}"))
        XCTAssertEqual(store.count, 1)

        // The model begins generating a tool call: the card appears
        // immediately, long before tool_execution_start.
        XCTAssertTrue(store.apply(frame(type: "message_update",
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"toolcall_start\",\"contentIndex\":1,\"id\":\"tc1\",\"toolName\":\"bash\"}}")))
        XCTAssertEqual(store.count, 2)
        guard case .toolCall(let card)? = store.entry(at: 1)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(card.id, "tc1")
        XCTAssertEqual(card.toolName, "bash")
        XCTAssertEqual(card.state, .running)

        // Argument deltas accumulate live (toolcall_delta carries no id).
        XCTAssertTrue(store.apply(frame(type: "message_update",
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"toolcall_delta\",\"contentIndex\":1,\"delta\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}")))
        guard case .toolCall(let deltaCard)? = store.entry(at: 1)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertTrue(deltaCard.arguments.contains("ls"))

        // toolcall_end: arguments become the pretty-printed block.
        XCTAssertTrue(store.apply(frame(type: "message_update",
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"toolcall_end\",\"contentIndex\":1,\"toolCall\":{\"type\":\"toolCall\",\"id\":\"tc1\",\"name\":\"bash\",\"arguments\":{\"cmd\":\"ls\"}}}}")))
        guard case .toolCall(let ended)? = store.entry(at: 1)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertTrue(ended.arguments.contains("\"cmd\""))

        // tool_execution_start must NOT create a duplicate card — the same id
        // is reused and the args get the final pretty-printed form.
        XCTAssertTrue(store.apply(frame(type: "tool_execution_start",
            "{\"type\":\"tool_execution_start\",\"toolCallId\":\"tc1\",\"toolName\":\"bash\",\"args\":{\"cmd\":\"ls -la\"}}")))
        XCTAssertEqual(store.count, 2, "execution start must reuse the streamed card")
        guard case .toolCall(let executed)? = store.entry(at: 1)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(executed.state, .running)
        XCTAssertTrue(executed.arguments.contains("ls -la"))
    }

    func testTurnStartPlaceholderPromotedByMessageStart() {
        let store = TranscriptStore()

        // The echoed user message reserves a placeholder slot below it — the
        // pulsing-caret feedback during time-to-first-token.
        XCTAssertTrue(store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u1\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}")))
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.entry(at: 1)?.kind, .assistantMessage(text: "", thinking: "", isStreaming: true))

        // message_start (assistant) promotes the placeholder in place — no
        // orphaned row, no duplicate.
        XCTAssertTrue(store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"\"}]}}")))
        XCTAssertEqual(store.count, 2, "message_start must promote the placeholder, not append")
        XCTAssertEqual(store.entry(at: 0)?.kind, .userMessage(text: "hi"))
        XCTAssertEqual(store.entry(at: 1)?.kind, .assistantMessage(text: "", thinking: "", isStreaming: true))

        // Thinking deltas stream into the promoted row (no text yet).
        XCTAssertTrue(store.apply(frame(type: "message_update",
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"thinking_delta\",\"delta\":\"let me\"}}")))
        XCTAssertEqual(store.entry(at: 1)?.kind, .assistantMessage(text: "", thinking: "let me", isStreaming: true))

        // message_end finalizes it.
        XCTAssertTrue(store.apply(frame(type: "message_end",
            "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"let me think\"}]}}")))
        XCTAssertEqual(store.entry(at: 1)?.kind, .assistantMessage(text: "", thinking: "let me think", isStreaming: false))
    }

    func testAbortDropsNeverPromotedPlaceholder() {
        let store = TranscriptStore()

        // The user echo reserves a placeholder that never gets an assistant
        // message (abort before time-to-first-token).
        _ = store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u1\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"))
        XCTAssertEqual(store.count, 2)

        // Abort → agent_end: the placeholder is removed, not left blinking.
        XCTAssertTrue(store.apply(frame(type: "agent_end", "{\"type\":\"agent_end\"}")))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.entry(at: 0)?.kind, .userMessage(text: "hi"))
    }

    func testToolCallCardGetsIdFromMessageBlock() {
        let store = TranscriptStore()
        _ = store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}"))

        // toolcall_start WITHOUT id/toolName — the frame's `message` carries
        // the authoritative content block.
        XCTAssertTrue(store.apply(frame(type: "message_update",
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"toolcall_start\",\"contentIndex\":1},\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"\"},{\"type\":\"toolCall\",\"id\":\"tc9\",\"name\":\"bash\",\"arguments\":{}}]}}")))
        guard case .toolCall(let card)? = store.entry(at: 1)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(card.id, "tc9")
        XCTAssertEqual(card.toolName, "bash")

        // tool_execution_start with the same id reuses the card — no
        // duplicate "tool" block above the real one.
        XCTAssertTrue(store.apply(frame(type: "tool_execution_start",
            "{\"type\":\"tool_execution_start\",\"toolCallId\":\"tc9\",\"toolName\":\"bash\",\"args\":{\"cmd\":\"ls\"}}")))
        XCTAssertEqual(store.count, 2, "execution start must reuse the streamed card")
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
        XCTAssertEqual(store.count, 2) // user message + turn-start placeholder

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

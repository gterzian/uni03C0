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
        XCTAssertNil(store.entry(at: 0)?.cacheHitRate)

        // A text delta appends to the streaming row.
        XCTAssertTrue(store.apply(frame(type: "message_update",
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"Hello\"}}")))
        XCTAssertEqual(store.entry(at: 0)?.kind, .assistantMessage(text: "Hello", thinking: "", isStreaming: true))

        // A second delta.
        XCTAssertTrue(store.apply(frame(type: "message_update",
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\" world\"}}")))
        XCTAssertEqual(store.entry(at: 0)?.kind, .assistantMessage(text: "Hello world", thinking: "", isStreaming: true))

        // message_end finalizes it (isStreaming -> false); usage sets the rate.
        XCTAssertTrue(store.apply(frame(type: "message_end",
            "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"Hello world\"}],\"usage\":{\"input\":100,\"output\":10,\"cacheRead\":900,\"cacheWrite\":0}}}")))
        XCTAssertEqual(store.entry(at: 0)?.kind, .assistantMessage(text: "Hello world", thinking: "", isStreaming: false))
        XCTAssertEqual(store.entry(at: 0)?.cacheHitRate ?? 0, 0.9, accuracy: 0.0001)
    }

    func testToolCallTurnDoesNotAttachCacheRate() {
        let store = TranscriptStore()
        // A tool-use assistant message ends a step, not a turn: no rate row.
        XCTAssertTrue(store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}")))
        XCTAssertTrue(store.apply(frame(type: "message_end",
            "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"toolCall\",\"id\":\"t1\",\"name\":\"bash\",\"arguments\":{\"cmd\":\"ls\"}}],\"usage\":{\"input\":100,\"cacheRead\":900},\"stopReason\":\"toolUse\"}}")))
        XCTAssertNil(store.entry(at: 0)?.cacheHitRate)
    }

    func testLiveTurnAggregatesStepsIntoTurnAverage() {
        let store = TranscriptStore()
        // User message opens the turn (fresh average).
        XCTAssertTrue(store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u1\",\"content\":[{\"type\":\"text\",\"text\":\"do it\"}]}}")))
        // Step 1: tool-use (cached).
        XCTAssertTrue(store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}")))
        XCTAssertTrue(store.apply(frame(type: "message_end",
            "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"toolCall\",\"id\":\"t1\",\"name\":\"bash\",\"arguments\":{}}],\"usage\":{\"input\":1000,\"cacheRead\":9000},\"stopReason\":\"toolUse\"}}")))
        // Step 2: final answer (cached).
        XCTAssertTrue(store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a2\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}")))
        XCTAssertTrue(store.apply(frame(type: "message_end",
            "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"id\":\"a2\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}],\"usage\":{\"input\":300,\"cacheRead\":27000},\"stopReason\":\"stop\"}}")))

        // Final row is the answer; rate spans BOTH steps: (9000+27000)/(1000+9000+300+27000).
        guard case .assistantMessage(let text, _, _)? = store.entry(at: 2)?.kind else {
            return XCTFail("expected final assistant row")
        }
        XCTAssertEqual(text, "done")
        XCTAssertEqual(store.entry(at: 2)?.cacheHitRate ?? 0, 36000.0 / 37300.0, accuracy: 0.0001)
        XCTAssertFalse(store.entry(at: 2)?.cacheMiss ?? true)
    }

    func testLiveTurnFlagsLargeMissAfterIdle() {
        let store = TranscriptStore()
        // Turn 1: fully cached.
        XCTAssertTrue(store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u1\",\"content\":[{\"type\":\"text\",\"text\":\"q1\"}]}}")))
        XCTAssertTrue(store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}")))
        XCTAssertTrue(store.apply(frame(type: "message_end",
            "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"ans1\"}],\"usage\":{\"input\":1000,\"cacheRead\":99000},\"stopReason\":\"stop\"}}")))
        // Turn 2, first step: cache fully evicted (0 read, 100k input).
        XCTAssertTrue(store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u2\",\"content\":[{\"type\":\"text\",\"text\":\"q2\"}]}}")))
        XCTAssertTrue(store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a2\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}")))
        XCTAssertTrue(store.apply(frame(type: "message_end",
            "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"id\":\"a2\",\"content\":[{\"type\":\"text\",\"text\":\"ans2\"}],\"usage\":{\"input\":100000,\"cacheRead\":0},\"stopReason\":\"stop\"}}")))

        XCTAssertTrue(store.entry(at: 3)?.cacheMiss ?? false)
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

    func testToolCallStreamsSingleCardWithRealName() {
        // Real RPC frames: `message_update` strips the cumulative message and
        // the event's `partial`, so toolcall_start/delta carry only a
        // contentIndex — the id/name/args are unknowable until toolcall_end,
        // which carries the completed call block.
        let store = TranscriptStore()

        // The assistant message starts streaming text.
        _ = store.apply(frame(type: "message_start",
            #"{"type":"message_start","message":{"role":"assistant","id":"a1","content":[{"type":"text","text":""}]}}"#))
        XCTAssertEqual(store.count, 1)

        // toolcall_start (bare): no placeholder "tool" card yet.
        XCTAssertTrue(store.apply(frame(type: "message_update",
            #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","contentIndex":1}}"#)))
        XCTAssertEqual(store.count, 1, "no card until the id/name are known")

        // toolcall_delta: still nothing — args arrive whole at toolcall_end.
        XCTAssertTrue(store.apply(frame(type: "message_update",
            #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_delta","contentIndex":1,"delta":"{\"cmd\":\"ls\"}"}}"#)))
        XCTAssertEqual(store.count, 1)

        // toolcall_end: the card appears with the real name and pretty args.
        XCTAssertTrue(store.apply(frame(type: "message_update",
            #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","contentIndex":1,"toolCall":{"type":"toolCall","id":"tc1","name":"bash","arguments":{"cmd":"ls"}}}}"#)))
        XCTAssertEqual(store.count, 2)
        guard case .toolCall(let card)? = store.entry(at: 1)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(card.id, "tc1")
        XCTAssertEqual(card.toolName, "bash")
        XCTAssertTrue(card.arguments.contains(#""cmd""#))
        XCTAssertEqual(card.state, .running)

        // tool_execution_start must NOT create a duplicate card — the real id
        // matches, args get the final form, state stays running.
        XCTAssertTrue(store.apply(frame(type: "tool_execution_start",
            #"{"type":"tool_execution_start","toolCallId":"tc1","toolName":"bash","args":{"cmd":"ls -la"}}"#)))
        XCTAssertEqual(store.count, 2, "execution start must reuse the streamed card")
        guard case .toolCall(let executed)? = store.entry(at: 1)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertTrue(executed.arguments.contains("ls -la"))

        // The result lands in the SAME card.
        XCTAssertTrue(store.apply(frame(type: "tool_execution_update",
            #"{"type":"tool_execution_update","toolCallId":"tc1","partialResult":{"content":[{"type":"text","text":"file.txt"}]}}"#)))
        XCTAssertEqual(store.count, 2, "output updates the same card, never a second one")
        guard case .toolCall(let updated)? = store.entry(at: 1)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(updated.output, "file.txt")

        XCTAssertTrue(store.apply(frame(type: "tool_execution_end",
            #"{"type":"tool_execution_end","toolCallId":"tc1","toolName":"bash","result":{"content":[{"type":"text","text":"file.txt"}]}}"#)))
        guard case .toolCall(let done)? = store.entry(at: 1)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(done.state, .done)
        XCTAssertEqual(done.output, "file.txt")
    }

    func testToolCallCardHandlesAnthropicInputAndOpenAIStringArgs() {
        let store = TranscriptStore()

        // Anthropic-style block: id/name/input.
        XCTAssertTrue(store.apply(frame(type: "message_update",
            #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","contentIndex":0,"toolCall":{"type":"tool_use","id":"tc-a","name":"read","input":{"path":"/tmp/x"}}}}"#)))
        guard case .toolCall(let anthropic)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(anthropic.id, "tc-a")
        XCTAssertEqual(anthropic.toolName, "read")
        XCTAssertTrue(anthropic.arguments.contains("path"))

        // OpenAI-completions-style block: arguments arrive as a JSON-encoded
        // string.
        XCTAssertTrue(store.apply(frame(type: "message_update",
            #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","contentIndex":1,"toolCall":{"type":"toolCall","id":"tc-b","name":"edit","arguments":"{\"path\":\"/tmp/y\"}"}}}"#)))
        guard case .toolCall(let openai)? = store.entry(at: 1)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(openai.toolName, "edit")
        XCTAssertTrue(openai.arguments.contains("path"))

        // A toolcall_end without a usable block id must not fabricate a card:
        // tool_execution_start creates it with the real id/name instead.
        XCTAssertTrue(store.apply(frame(type: "message_update",
            #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","contentIndex":2,"toolCall":{"type":"toolCall","name":"bash","arguments":{}}}}"#)))
        XCTAssertEqual(store.count, 2, "no fabricated card when the id is unknown")
        XCTAssertTrue(store.apply(frame(type: "tool_execution_start",
            #"{"type":"tool_execution_start","toolCallId":"tc-c","toolName":"bash","args":{"cmd":"ls"}}"#)))
        XCTAssertEqual(store.count, 3)
        guard case .toolCall(let created)? = store.entry(at: 2)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(created.id, "tc-c")
        XCTAssertEqual(created.toolName, "bash")
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

    func testToolCallExecutionStartCreatesCardWithoutStreamEvents() {
        // Providers can skip the toolcall_* stream entirely (e.g. a resumed
        // session): tool_execution_start alone must create the card with the
        // real id/name.
        let store = TranscriptStore()
        XCTAssertTrue(store.apply(frame(type: "tool_execution_start",
            #"{"type":"tool_execution_start","toolCallId":"t9","toolName":"bash","args":{"cmd":"ls"}}"#)))
        XCTAssertEqual(store.count, 1)
        guard case .toolCall(let card)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(card.id, "t9")
        XCTAssertEqual(card.toolName, "bash")
        XCTAssertEqual(card.state, .running)

        // And its result lands in that same single card.
        XCTAssertTrue(store.apply(frame(type: "tool_execution_end",
            #"{"type":"tool_execution_end","toolCallId":"t9","toolName":"bash","result":{"content":[{"type":"text","text":"ok"}]}}"#)))
        XCTAssertEqual(store.count, 1, "execution start + end must be one card")
        guard case .toolCall(let done)? = store.entry(at: 0)?.kind else {
            return XCTFail("expected tool call card")
        }
        XCTAssertEqual(done.state, .done)
        XCTAssertEqual(done.output, "ok")
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

    func testRebuildAttachesCacheRateToFinalResponse() {
        let store = TranscriptStore()
        // Final response with usage: the text entry carries the rate.
        let final = AgentMessage(role: "assistant", content: [ContentBlock(type: "text", text: "done")], id: "a1",
                                 usage: TokenUsage(input: 100, output: 10, cacheRead: 900, cacheWrite: 0))
        // Tool-use step: no rate on its own (intermediate request inside a turn),
        // but its usage feeds the turn average.
        let toolStep = AgentMessage(role: "assistant", content: [
            ContentBlock(type: "toolCall", id: "t1", name: "bash", arguments: nil),
        ], id: "a2", usage: TokenUsage(input: 50, output: 0, cacheRead: 950, cacheWrite: 0))

        XCTAssertTrue(store.rebuild(from: [toolStep, final]))
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.entry(at: 1)?.kind, .assistantMessage(text: "done", thinking: "", isStreaming: false))
        // Turn average across both calls: (950 + 900) / (50+950 + 100+900) = 1850/2000.
        XCTAssertEqual(store.entry(at: 1)?.cacheHitRate ?? 0, 1850.0 / 2000.0, accuracy: 0.0001)
        XCTAssertFalse(store.entry(at: 1)?.cacheMiss ?? true)
        XCTAssertNil(store.entry(at: 0)?.cacheHitRate)
    }

    func testRebuildAggregatesStepsIntoTurnAverage() {
        let store = TranscriptStore()
        // Three steps in one turn: two tool-use + final. Average must span all.
        let step1 = AgentMessage(role: "assistant", content: [ContentBlock(type: "toolCall", id: "t1", name: "bash", arguments: nil)],
                                 id: "s1", usage: TokenUsage(input: 1000, output: 0, cacheRead: 9000, cacheWrite: 0))
        let step2 = AgentMessage(role: "assistant", content: [ContentBlock(type: "toolCall", id: "t2", name: "read", arguments: nil)],
                                 id: "s2", usage: TokenUsage(input: 2000, output: 0, cacheRead: 18000, cacheWrite: 0))
        let final = AgentMessage(role: "assistant", content: [ContentBlock(type: "text", text: "done")],
                                 id: "s3", usage: TokenUsage(input: 300, output: 10, cacheRead: 27000, cacheWrite: 0))

        XCTAssertTrue(store.rebuild(from: [step1, step2, final]))
        // (9000 + 18000 + 27000) / (1000+9000 + 2000+18000 + 300+27000) = 54000/57300.
        XCTAssertEqual(store.entry(at: 2)?.cacheHitRate ?? 0, 54000.0 / 57300.0, accuracy: 0.0001)
        XCTAssertFalse(store.entry(at: 2)?.cacheMiss ?? true)
    }

    func testRebuildFlagsLargeMissOnEviction() {
        let store = TranscriptStore()
        // A turn whose first step fully re-billed the previous turn's prompt:
        // the previous request was 100k prompt tokens, this one reads 0 cached.
        let previous = AgentMessage(role: "assistant", content: [ContentBlock(type: "text", text: "prev")],
                                    id: "p1", usage: TokenUsage(input: 1000, output: 0, cacheRead: 99000, cacheWrite: 0))
        let evicted = AgentMessage(role: "assistant", content: [ContentBlock(type: "text", text: "after idle")],
                                   id: "e1", usage: TokenUsage(input: 100000, output: 0, cacheRead: 0, cacheWrite: 0))
        // 100k prompt re-billed (was 100k before, 0 cached now) — well past 20k.
        XCTAssertTrue(store.rebuild(from: [previous, evicted]))
        XCTAssertTrue(store.entry(at: 1)?.cacheMiss ?? false)
        XCTAssertFalse(store.entry(at: 0)?.cacheMiss ?? true)
    }

    func testRebuildWithoutUsageHasNoRate() {
        let store = TranscriptStore()
        let message = AgentMessage(role: "assistant", content: [ContentBlock(type: "text", text: "no usage")], id: "a1")
        XCTAssertTrue(store.rebuild(from: [message]))
        XCTAssertNil(store.entry(at: 0)?.cacheHitRate)
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

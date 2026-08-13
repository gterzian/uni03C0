import XCTest
@testable import Core

/// Tests for `TranscriptStore.search` — the per-session find over the FULL
/// conversation (store data, not the materialized view window).
final class TranscriptStoreSearchTests: XCTestCase {

    private func makeStore() -> TranscriptStore {
        let store = TranscriptStore()
        // User message.
        _ = store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u1\",\"content\":[{\"type\":\"text\",\"text\":\"fix the WindowProxy bug\"}]}}"))
        // Assistant: thinking + text (one row).
        _ = store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}"))
        _ = store.apply(frame(type: "message_update",
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"thinking_delta\",\"delta\":\"Let me check the proxy list\"}}"))
        _ = store.apply(frame(type: "message_update",
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"The windowproxy.rs is where it lives.\"}}"))
        _ = store.apply(frame(type: "message_end",
            "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"Let me check the proxy list\"},{\"type\":\"text\",\"text\":\"The windowproxy.rs is where it lives.\"}]}}"))
        // Tool call card: created at toolcall_end with the real id/name/args.
        _ = store.apply(frame(type: "message_update",
            #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","contentIndex":1,"toolCall":{"type":"toolCall","id":"t1","name":"bash","arguments":{"command":"git status --short"}}}}"#))
        // Tool result attaches the output into the same card.
        _ = store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"toolResult\",\"toolCallId\":\"t1\",\"toolName\":\"bash\",\"content\":[{\"type\":\"text\",\"text\":\" M content/src/main.rs\"}]}}"))
        return store
    }

    func testSearchFindsTextInAssistantRow() {
        let store = makeStore()
        let hits = store.search("windowproxy.rs")
        XCTAssertEqual(hits.count, 1, "case-insensitive hit in the assistant text")
        XCTAssertEqual(hits[0].storeIndex, 1)
        XCTAssertTrue(hits[0].snippet.lowercased().contains("windowproxy.rs"))
    }

    func testSearchFindsUserMessages() {
        let store = makeStore()
        let hits = store.search("fix the")
        XCTAssertEqual(hits.count, 1, "hit in the user message")
        XCTAssertEqual(hits[0].storeIndex, 0)
    }

    func testSearchIsCaseInsensitiveAndSpansThinking() {
        let store = makeStore()
        XCTAssertEqual(store.search("PROXY LIST").count, 1, "hit in the thinking")
        XCTAssertEqual(store.search("proxy list").count, 1)
    }

    func testSearchFindsToolNameArgsAndOutput() {
        let store = makeStore()
        XCTAssertEqual(store.search("git status").count, 1, "hit in the tool arguments")
        XCTAssertEqual(store.search("main.rs").count, 1, "hit in the tool output")
        XCTAssertEqual(store.search("bash").count, 1, "hit in the tool name")
    }

    func testSearchReturnsMatchesInStoreOrder() {
        let store = makeStore()
        let hits = store.search("the")
        let indexes = hits.map(\.storeIndex)
        XCTAssertEqual(indexes, indexes.sorted(), "matches must be in store order")
    }

    func testSearchEmptyOrWhitespaceQueryReturnsNoMatches() {
        let store = makeStore()
        XCTAssertTrue(store.search("").isEmpty)
        XCTAssertTrue(store.search("   \n  ").isEmpty)
    }

    func testSearchMissReturnsNoMatches() {
        let store = makeStore()
        XCTAssertTrue(store.search("nothing-matches-this").isEmpty)
    }

    func testSearchSnippetIsBoundedAndSingleLine() {
        let store = makeStore()
        let hits = store.search("lives")
        XCTAssertEqual(hits.count, 1, "expected a hit")
        guard let hit = hits.first else { return }
        XCTAssertFalse(hit.snippet.contains("\n"), "snippet must be a single line")
        XCTAssertLessThanOrEqual(hit.snippet.count, 120, "snippet must stay small")
    }
}

import XCTest
@testable import Core

/// Tests for `TranscriptStore.search` — the per-session find over the
/// conversation (store data, not the materialized view window). The store
/// search is RANGE-based: the view model drives it in batches over the whole
/// conversation, so these tests also pin the range semantics (a slice covers
/// only its rows; out-of-bounds slices are clamped, never crash).
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

    /// The whole-store range, for tests that don't care about slicing.
    private func wholeStoreRange(_ store: TranscriptStore) -> Range<Int> {
        0..<store.count
    }

    func testSearchFindsTextInAssistantRow() {
        let store = makeStore()
        let hits = store.search("windowproxy.rs", in: wholeStoreRange(store))
        XCTAssertEqual(hits.count, 1, "case-insensitive hit in the assistant text")
        XCTAssertEqual(hits[0].storeIndex, 1)
        XCTAssertTrue(hits[0].snippet.lowercased().contains("windowproxy.rs"))
    }

    func testSearchFindsUserMessages() {
        let store = makeStore()
        let hits = store.search("fix the", in: wholeStoreRange(store))
        XCTAssertEqual(hits.count, 1, "hit in the user message")
        XCTAssertEqual(hits[0].storeIndex, 0)
    }

    func testSearchIsCaseInsensitiveAndSpansThinking() {
        let store = makeStore()
        XCTAssertEqual(store.search("PROXY LIST", in: wholeStoreRange(store)).count, 1, "hit in the thinking")
        XCTAssertEqual(store.search("proxy list", in: wholeStoreRange(store)).count, 1)
    }

    func testSearchCaseSensitiveMatchesExactly() {
        let store = makeStore()
        // Default is case-insensitive: the user's capitalized "WindowProxy"
        // and the assistant's lowercase "windowproxy.rs" both hit.
        XCTAssertEqual(store.search("windowproxy", in: wholeStoreRange(store)).count, 2)
        // Case-sensitive: only the exact casing matches.
        let lower = store.search("windowproxy", caseSensitive: true, in: wholeStoreRange(store))
        XCTAssertEqual(lower.count, 1, "lowercase query matches only the assistant's lowercase text")
        XCTAssertEqual(lower[0].storeIndex, 1)
        let upper = store.search("WindowProxy", caseSensitive: true, in: wholeStoreRange(store))
        XCTAssertEqual(upper.count, 1, "capitalized query matches only the user's 'WindowProxy'")
        XCTAssertEqual(upper[0].storeIndex, 0)
        // A differently-cased word is a miss when sensitive.
        XCTAssertTrue(store.search("THE", caseSensitive: true, in: wholeStoreRange(store)).isEmpty, "'The' in the thinking is not 'THE'")
        // Whitespace is still trimmed either way.
        XCTAssertEqual(store.search("  windowproxy  ", caseSensitive: true, in: wholeStoreRange(store)).count, 1)
    }

    func testSearchFindsToolNameArgsAndOutput() {
        let store = makeStore()
        XCTAssertEqual(store.search("git status", in: wholeStoreRange(store)).count, 1, "hit in the tool arguments")
        XCTAssertEqual(store.search("main.rs", in: wholeStoreRange(store)).count, 1, "hit in the tool output")
        XCTAssertEqual(store.search("bash", in: wholeStoreRange(store)).count, 1, "hit in the tool name")
    }

    func testSearchReturnsMatchesInStoreOrder() {
        let store = makeStore()
        let hits = store.search("the", in: wholeStoreRange(store))
        let indexes = hits.map(\.storeIndex)
        XCTAssertEqual(indexes, indexes.sorted(), "matches must be in store order")
    }

    func testSearchEmptyOrWhitespaceQueryReturnsNoMatches() {
        let store = makeStore()
        XCTAssertTrue(store.search("", in: wholeStoreRange(store)).isEmpty)
        XCTAssertTrue(store.search("   \n  ", in: wholeStoreRange(store)).isEmpty)
    }

    func testSearchMissReturnsNoMatches() {
        let store = makeStore()
        XCTAssertTrue(store.search("nothing-matches-this", in: wholeStoreRange(store)).isEmpty)
    }

    func testSearchSnippetIsBoundedAndSingleLine() {
        let store = makeStore()
        let hits = store.search("lives", in: wholeStoreRange(store))
        XCTAssertEqual(hits.count, 1, "expected a hit")
        guard let hit = hits.first else { return }
        XCTAssertFalse(hit.snippet.contains("\n"), "snippet must be a single line")
        XCTAssertLessThanOrEqual(hit.snippet.count, 120, "snippet must stay small")
    }

    // MARK: - Range semantics

    func testSearchOnlyCoversTheGivenRange() {
        let store = makeStore()
        // The user row (0) holds "WindowProxy"; the assistant row (1) holds
        // "windowproxy.rs". A range that covers only the assistant row must
        // not return the user row's match.
        let hits = store.search("windowproxy", in: 1..<2)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].storeIndex, 1, "only the in-range row matches")
    }

    func testSearchRangeSkipsEarlierRows() {
        let store = makeStore()
        // "the" appears in the user row (0), the assistant thinking (1) and
        // the assistant text (1). Searching only the tool-card row (2) finds
        // nothing.
        XCTAssertTrue(store.search("the", in: 2..<3).isEmpty, "no 'the' in the tool card")
        // Searching rows 0..<2 finds both user and assistant rows.
        XCTAssertEqual(store.search("the", in: 0..<2).count, 2)
    }

    func testSearchRangeIsClampedToTheStore() {
        let store = makeStore()
        // A range that extends past the tail is clamped and returns the hits
        // within the live entries (no crash).
        let overhang = store.search("the", in: 1..<1_000)
        let full = store.search("the", in: wholeStoreRange(store))
        XCTAssertEqual(overhang.count, full.count - 1, "clamped range drops the user row (0) but keeps the rest")
        XCTAssertTrue(overhang.allSatisfy { $0.storeIndex >= 1 })
        // A range entirely outside the store returns no matches.
        XCTAssertTrue(store.search("the", in: 100..<200).isEmpty)
        // An empty range returns no matches.
        XCTAssertTrue(store.search("the", in: 2..<2).isEmpty)
    }
}

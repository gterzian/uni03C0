import XCTest
@testable import Core

/// The Cmd+Up / Cmd+Down user-message cycle DECISION, in isolation: given a
/// conversation and a viewport anchor (the first visible store index), which
/// user message is previous/next, or nil (the caller then falls back to the
/// top of the conversation / the live tail). The coordinator turns the result
/// into a scroll; the decision itself is pure and exercised here with
/// synthetic kind sequences. Strictness is the load-bearing property: the
/// cycle always moves strictly above/below the anchor, so standing on a user
/// message and pressing Down moves to the one after it, never re-showing the
/// same one.
final class TranscriptCyclerTests: XCTestCase {

    /// Returns a cycler-friendly `entryAt` over the given kinds; out-of-range
    /// indices yield nil, exactly like `TranscriptStore.entry(at:)`.
    private func entryAt(_ kinds: [TranscriptEntryKind]) -> (Int) -> TranscriptEntry? {
        { i in kinds.indices.contains(i) ? TranscriptEntry(id: "\(i)", kind: kinds[i]) : nil }
    }

    /// A realistic conversation: three exchanges, the third still streaming.
    ///  0 user "first"       1 assistant "reply"
    ///  2 user "second"      3 assistant "reply"
    ///  4 user "third"       5 assistant "streaming…" (tail)
    private let conversation: [TranscriptEntryKind] = [
        .userMessage(text: "first"),
        .assistantMessage(text: "reply", thinking: "", isStreaming: false),
        .userMessage(text: "second"),
        .assistantMessage(text: "reply", thinking: "", isStreaming: false),
        .userMessage(text: "third"),
        .assistantMessage(text: "streaming…", thinking: "", isStreaming: true),
    ]

    private func isUserMessage(_ i: Int, in kinds: [TranscriptEntryKind]) -> Bool {
        guard kinds.indices.contains(i) else { return false }
        return TranscriptCycler.isUserMessage(kinds[i])
    }

    // MARK: - Up

    func testUpFromAResponseFindsTheUserMessageAbove() {
        // Anchor mid-exchange (3 = assistant reply of the second exchange):
        // previous user message is 2.
        XCTAssertEqual(TranscriptCycler.previousUserMessage(anchor: 3, entryAt: entryAt(conversation)), 2)
    }

    func testUpFromAUserMessageGoesToTheOneAbove() {
        // Standing ON a user message, Up moves to the one strictly above (0),
        // never re-showing 2.
        XCTAssertEqual(TranscriptCycler.previousUserMessage(anchor: 2, entryAt: entryAt(conversation)), 0)
    }

    func testUpFromTheFirstUserMessageReturnsNil() {
        // The terminal step: past the first user message there is nothing
        // above — the caller jumps to the top of the conversation.
        XCTAssertNil(TranscriptCycler.previousUserMessage(anchor: 0, entryAt: entryAt(conversation)))
    }

    func testUpFromTheTopOfTheConversationReturnsNil() {
        let kinds: [TranscriptEntryKind] = [.assistantMessage(text: "hi", thinking: "", isStreaming: false)]
        XCTAssertNil(TranscriptCycler.previousUserMessage(anchor: 0, entryAt: entryAt(kinds)))
    }

    func testUpWithNoUserMessagesReturnsNil() {
        let kinds: [TranscriptEntryKind] = (0..<4).map {
            .assistantMessage(text: "reply \($0)", thinking: "", isStreaming: false)
        }
        XCTAssertNil(TranscriptCycler.previousUserMessage(anchor: 3, entryAt: entryAt(kinds)))
    }

    // MARK: - Down

    func testDownFromAResponseFindsTheNextUserMessage() {
        XCTAssertEqual(TranscriptCycler.nextUserMessage(anchor: 1, count: conversation.count, entryAt: entryAt(conversation)), 2)
    }

    func testDownFromAUserMessageGoesToTheOneBelow() {
        XCTAssertEqual(TranscriptCycler.nextUserMessage(anchor: 2, count: conversation.count, entryAt: entryAt(conversation)), 4)
    }

    func testDownFromTheLastUserMessageReturnsNil() {
        // 4 is the last user message; 5 is the streaming assistant reply. With
        // no user message below, Down means "all the way to the live tail".
        XCTAssertNil(TranscriptCycler.nextUserMessage(anchor: 4, count: conversation.count, entryAt: entryAt(conversation)))
    }

    func testDownFromTheStreamingTailReturnsNil() {
        XCTAssertNil(TranscriptCycler.nextUserMessage(anchor: 5, count: conversation.count, entryAt: entryAt(conversation)))
    }

    func testDownFromTheVeryLastRowReturnsNil() {
        XCTAssertNil(TranscriptCycler.nextUserMessage(anchor: conversation.count - 1, count: conversation.count, entryAt: entryAt(conversation)))
    }

    func testDownFromAboveTheConversationFindsTheFirstUserMessage() {
        // A degenerate anchor above everything ("before the conversation")
        // cycles to the first user message.
        XCTAssertEqual(TranscriptCycler.nextUserMessage(anchor: -1, count: conversation.count, entryAt: entryAt(conversation)), 0)
    }

    // MARK: - Skipping non-user rows

    func testCycleSkipsToolCallsErrorsAndAborts() {
        // 0 user, 1 tool card, 2 error, 3 aborted, 4 user, 5 streaming reply.
        let kinds: [TranscriptEntryKind] = [
            .userMessage(text: "q"),
            .toolCall(card: ToolCallCard(id: "t1", toolName: "bash", arguments: "ls")),
            .errorMessage("boom"),
            .abortedMessage("aborted"),
            .userMessage(text: "q2"),
            .assistantMessage(text: "streaming…", thinking: "", isStreaming: true),
        ]
        // Up from the streaming tail skips the aborted/error rows and the
        // tool card, landing on 4.
        XCTAssertEqual(TranscriptCycler.previousUserMessage(anchor: 5, entryAt: entryAt(kinds)), 4)
        // Up from 4 skips the card/error/aborted rows, landing on 0.
        XCTAssertEqual(TranscriptCycler.previousUserMessage(anchor: 4, entryAt: entryAt(kinds)), 0)
        // Down from 0 skips the non-user rows, landing on 4.
        XCTAssertEqual(TranscriptCycler.nextUserMessage(anchor: 0, count: kinds.count, entryAt: entryAt(kinds)), 4)
        // Down from 4 (the last user message) returns nil despite the rows
        // below being non-user.
        XCTAssertNil(TranscriptCycler.nextUserMessage(anchor: 4, count: kinds.count, entryAt: entryAt(kinds)))
    }

    func testEmptyConversationReturnsNilBothWays() {
        XCTAssertNil(TranscriptCycler.previousUserMessage(anchor: 0, entryAt: entryAt([])))
        XCTAssertNil(TranscriptCycler.nextUserMessage(anchor: 0, count: 0, entryAt: entryAt([])))
    }

    // MARK: - isUserMessage

    func testIsUserMessageClassification() {
        XCTAssertTrue(TranscriptCycler.isUserMessage(.userMessage(text: "x")))
        XCTAssertFalse(TranscriptCycler.isUserMessage(.assistantMessage(text: "x", thinking: "", isStreaming: false)))
        XCTAssertFalse(TranscriptCycler.isUserMessage(.assistantMessage(text: "x", thinking: "", isStreaming: true)))
        XCTAssertFalse(TranscriptCycler.isUserMessage(.errorMessage("x")))
        XCTAssertFalse(TranscriptCycler.isUserMessage(.abortedMessage("x")))
        XCTAssertFalse(TranscriptCycler.isUserMessage(.toolCall(card: ToolCallCard(id: "t", toolName: "bash", arguments: "ls"))))
    }

    // MARK: - Integration with the real store

    /// Builds a real `TranscriptStore` whose rows match `conversation` (three
    /// turns), so the cycler is exercised against the store's own
    /// `entry(at:)` — the exact accessor the coordinator passes in.
    private func storeWithThreeTurns() -> TranscriptStore {
        let store = TranscriptStore()
        func turn(_ user: String, _ reply: String) {
            _ = store.apply(frame(type: "message_start",
                "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u\(store.count)\",\"content\":[{\"type\":\"text\",\"text\":\"\(user)\"}]}}"))
            _ = store.apply(frame(type: "message_start",
                "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a\(store.count)\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}"))
            _ = store.apply(frame(type: "message_update",
                "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"\(reply)\"}}"))
            _ = store.apply(frame(type: "message_end",
                "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"id\":\"a\(store.count - 1)\",\"content\":[{\"type\":\"text\",\"text\":\"\(reply)\"}]}}"))
        }
        turn("first", "reply")
        turn("second", "reply")
        turn("third", "reply")
        return store
    }

    func testCycleAgainstTheRealStore() {
        let store = storeWithThreeTurns()
        XCTAssertEqual(store.count, 6, "one user + one assistant row per turn")
        // Previous user message above the second assistant reply is the second
        // user message (index 2); next below the first reply is the second
        // user message (index 2) as well.
        XCTAssertEqual(TranscriptCycler.previousUserMessage(anchor: 3, entryAt: store.entry(at:)), 2)
        XCTAssertEqual(TranscriptCycler.nextUserMessage(anchor: 1, count: store.count, entryAt: store.entry(at:)), 2)
        // Terminal cases against the store's accessor: past the last user
        // message, and past the first.
        XCTAssertNil(TranscriptCycler.nextUserMessage(anchor: 4, count: store.count, entryAt: store.entry(at:)))
        XCTAssertNil(TranscriptCycler.previousUserMessage(anchor: 0, entryAt: store.entry(at:)))
        // Out-of-range reads beyond the tail: next yields nil; previous
        // sensibly returns the last user message above the (impossible) anchor.
        XCTAssertNil(TranscriptCycler.nextUserMessage(anchor: 5, count: store.count, entryAt: store.entry(at:)))
        XCTAssertEqual(TranscriptCycler.previousUserMessage(anchor: 100, entryAt: store.entry(at:)), 4)
    }
}

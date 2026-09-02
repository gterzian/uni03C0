import AppKit
import XCTest

/// Unit tests for `TextRowView`'s incremental (append-only) text-storage
/// update while streaming — the fix for the streaming-thinking hot spot, where
/// `setAttributedString` on every 0.25s batch invalidated the whole storage and
/// forced the layout manager to re-typeset the entire paragraph (fresh
/// CTTypesetter + full GPOS kerning) per batch.
///
/// The behaviors under test:
/// - a growing stream appends only the tail (prefix text and attributes intact);
/// - the streaming caret moves with the tail;
/// - when the markdown re-interprets the prefix (a fence/bold closing
///   mid-stream), the prefix IS re-styled (full-replace fallback);
/// - an app-wide font-size change re-styles the prefix (full-replace fallback);
/// - an identical re-render (scroll re-entry) touches nothing.
final class StreamingStorageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontSettings.shared.bodySize = 13
    }

    private func textView(of row: TextRowView) -> NSTextView {
        row.subviews.compactMap { $0 as? NSTextView }.first!
    }

    // MARK: - Pure tail append

    func testStreamingAppendKeepsPrefixAndMovesCaret() {
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        row.configure(text: "Hello wor", thinking: nil, role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        let tv = textView(of: row)
        XCTAssertEqual(tv.string, "Hello wor▌", "streaming text carries the caret")

        row.configure(text: "Hello world", thinking: nil, role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(tv.string, "Hello world▌", "second batch appends to the tail")
        // The already-rendered prefix keeps its exact attributes (the storage
        // was appended to, not rebuilt): body font at index 0.
        XCTAssertEqual(RenderTestHelper.font(tv.textStorage!, at: 0)?.pointSize, FontSettings.shared.bodySize)
    }

    func testThinkingStreamAppendsIncrementally() {
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        row.configure(text: "", thinking: "Let me think", role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        let tv = textView(of: row)
        XCTAssertEqual(tv.string, "💭 Let me think▌")

        row.configure(text: "", thinking: "Let me think harder", role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(tv.string, "💭 Let me think harder▌")
        // The thinking run keeps its smaller font through the append (the
        // prefix was preserved, not re-typeset). "💭 " is 3 UTF-16 units.
        XCTAssertEqual(RenderTestHelper.font(tv.textStorage!, at: 4)?.pointSize, FontSettings.shared.bodySize - 1)
    }

    /// The regression behind the thinking-stream hotspot in samples: the text
    /// STORAGE resolves the "💭 " emoji run to `AppleColorEmojiUI` (recording
    /// the source font in `NSOriginalFont`), while the freshly-built string
    /// keeps the plain system font. `prefixAttributesMatch` compared fonts
    /// with `NSFont.isEqual` and the full attribute dictionaries, so it failed
    /// at the emoji run and the row fell back to a FULL `setAttributedString`
    /// on every streaming batch — the layout manager then re-typeset the whole
    /// growing thinking block per batch (the linear per-batch layout cost in
    /// samples, hidden behind the "incremental" comment). The emoji-prefixed
    /// append must take the incremental path.
    func testEmojiPrefixedThinkingAppendIsIncremental() {
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        row.configure(text: "", thinking: "Let me think", role: .assistant, isStreaming: true)
        // First batch: the storage was empty, so a full replace is correct.
        XCTAssertFalse(row.lastStorageApplyWasIncremental)
        // The coordinator lays out after every configure — and the layout pass
        // is what makes the storage RESOLVE the emoji run to AppleColorEmojiUI
        // (recording NSOriginalFont). Without it the storage still holds the
        // plain system font and the bug stays hidden: the test must reproduce
        // the real streaming path.
        row.layoutSubtreeIfNeeded()

        row.configure(text: "", thinking: "Let me think harder", role: .assistant, isStreaming: true)
        XCTAssertTrue(
            row.lastStorageApplyWasIncremental,
            "an emoji-prefixed thinking stream must append incrementally — " +
            "the full-replace fallback re-typesets the whole block every batch"
        )
    }

    // MARK: - Full-replace fallbacks (prefix genuinely changed)

    func testClosingBoldReStylesThePrefix() {
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        row.configure(text: "**bo", thinking: nil, role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        let tv = textView(of: row)
        // An unclosed bold renders verbatim (plain); the caret is the tail.
        XCTAssertEqual(tv.string, "**bo▌")

        row.configure(text: "**bold**", thinking: nil, role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        // The closing ** re-styles the prefix bold: the storage must reflect
        // the new styling (the incremental path's attribute check falls back
        // to a full replace).
        XCTAssertEqual(tv.string, "bold▌", "markers are stripped once the bold closes")
        XCTAssertTrue(RenderTestHelper.font(tv.textStorage!, at: 2, hasTrait: .bold), "prefix re-styled bold")
    }

    func testFontSizeChangeReStylesThePrefix() {
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        row.configure(text: "hello", thinking: nil, role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        FontSettings.shared.bodySize = 16
        defer { FontSettings.shared.bodySize = 13 }
        row.configure(text: "hello world", thinking: nil, role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        let tv = textView(of: row)
        XCTAssertEqual(tv.string, "hello world▌")
        XCTAssertEqual(RenderTestHelper.font(tv.textStorage!, at: 0)?.pointSize, 16, "font change re-styles the prefix")
    }

    // MARK: - Settle (caret removed, cache line appended)

    func testSettleRemovesCaretAndAppendsCacheLine() {
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        row.configure(text: "answer", thinking: nil, role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(textView(of: row).string, "answer▌")

        row.configure(text: "answer", thinking: nil, role: .assistant, isStreaming: false, cacheHitRate: 0.95, cacheMiss: false)
        row.layoutSubtreeIfNeeded()
        let settled = textView(of: row).string
        XCTAssertFalse(settled.hasSuffix("▌"), "the caret leaves when the message settles")
        XCTAssertTrue(settled.contains("⚡ cache 95%"), "the cache line lands under the final message")
        XCTAssertTrue(settled.hasPrefix("answer"), "the answer text survives the settle")
    }

    // MARK: - Identical re-render touches nothing

    func testIdenticalReconfigureIsANoOp() {
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        row.configure(text: "same text", thinking: nil, role: .assistant, isStreaming: false)
        row.layoutSubtreeIfNeeded()
        let tv = textView(of: row)
        let storage = tv.textStorage!
        let before = storage.string
        row.configure(text: "same text", thinking: nil, role: .assistant, isStreaming: false)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(storage.string, before, "identical re-render leaves the storage untouched")
        XCTAssertEqual(storage.string, "same text")
    }

    // MARK: - Search highlights survive the incremental path

    func testQueryChangeDropsStaleHighlights() {
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        row.configure(text: "foo bar foo", thinking: nil, role: .assistant, isStreaming: false,
                      searchQuery: "foo", searchCaseSensitive: false)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.searchHighlightRangesForTesting.count, 2, "both 'foo' occurrences highlighted")

        row.configure(text: "foo bar foo", thinking: nil, role: .assistant, isStreaming: false,
                      searchQuery: "bar", searchCaseSensitive: false)
        row.layoutSubtreeIfNeeded()
        let ranges = row.searchHighlightRangesForTesting
        XCTAssertEqual(ranges.count, 1, "stale 'foo' highlights are dropped when the query changes")
        XCTAssertEqual(ranges.first?.location, 4, "the surviving highlight sits on 'bar'")
        XCTAssertEqual(ranges.first?.length, 3)
    }

    func testClearingTheSearchDropsAllHighlights() {
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        row.configure(text: "foo bar", thinking: nil, role: .assistant, isStreaming: false,
                      searchQuery: "foo", searchCaseSensitive: false)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.searchHighlightRangesForTesting.count, 1)
        row.configure(text: "foo bar", thinking: nil, role: .assistant, isStreaming: false)
        row.layoutSubtreeIfNeeded()
        XCTAssertTrue(row.searchHighlightRangesForTesting.isEmpty, "clearing the search removes every backdrop")
    }
}

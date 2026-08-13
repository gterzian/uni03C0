import AppKit
import XCTest

/// Unit tests for `TextRowView` — the row's chrome (code cards + corner copy
/// buttons) and its height behavior. View-level, but deterministic: rows are
/// configured and laid out in memory, never through a live session.
final class TextRowViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontSettings.shared.bodySize = 13
    }

    private func makeRow(
        text: String,
        role: TextRowView.Role,
        isStreaming: Bool = false,
        width: CGFloat = 800
    ) -> TextRowView {
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        row.configure(text: text, thinking: nil, role: role, isStreaming: isStreaming)
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func textView(of row: TextRowView) -> NSTextView {
        row.subviews.compactMap { $0 as? NSTextView }.first!
    }

    private let codeMarkdown = "intro\n\n```swift\nlet a = 1\nlet b = 2\n```\n\noutro\n\n```swift\nlet c = 3\n```"

    // MARK: - Code chrome

    func testFinalAssistantGetsACardAndButtonPerBlock() {
        let row = makeRow(text: codeMarkdown, role: .assistant)
        XCTAssertEqual(row.renderedCodeBlockCount, 2)
        XCTAssertEqual(row.renderedCopyButtonCount, 2)
    }

    func testUserGetsCardsButNoButtons() {
        let row = makeRow(text: codeMarkdown, role: .user)
        XCTAssertEqual(row.renderedCodeBlockCount, 2, "cards render on any markdown row")
        XCTAssertEqual(row.renderedCopyButtonCount, 0, "buttons are assistant-final only")
    }

    func testStreamingAssistantGetsNoButtons() {
        let row = makeRow(text: codeMarkdown, role: .assistant, isStreaming: true)
        XCTAssertEqual(row.renderedCodeBlockCount, 2)
        XCTAssertEqual(row.renderedCopyButtonCount, 0, "a partially-streamed block is not copy-worthy")
    }

    func testErrorRowHasNoChrome() {
        let row = makeRow(text: "**not markdown**", role: .error)
        XCTAssertEqual(row.renderedCodeBlockCount, 0)
        XCTAssertEqual(row.renderedCopyButtonCount, 0)
    }

    // MARK: - Search-term highlight

    func testSearchTermIsHighlightedNotTheRow() {
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        row.configure(text: "proxy windowproxy Proxy", thinking: nil, role: .assistant, isStreaming: false,
                      searchQuery: "proxy", searchCaseSensitive: false)
        row.layoutSubtreeIfNeeded()
        let ranges = row.searchHighlightRangesForTesting
        XCTAssertEqual(ranges.count, 3, "every occurrence is highlighted, not the row")
        XCTAssertEqual(ranges.map(\.location), [0, 6, 18], "ranges sit exactly on each occurrence")
        XCTAssertEqual(ranges.map(\.length), [5, 5, 5])
    }

    func testNoHighlightWithoutAQuery() {
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        row.configure(text: "proxy windowproxy", thinking: nil, role: .assistant, isStreaming: false)
        row.layoutSubtreeIfNeeded()
        XCTAssertTrue(row.searchHighlightRangesForTesting.isEmpty, "no query → no highlight")
    }

    func testSearchHighlightRespectsCaseSensitivity() {
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        row.configure(text: "Proxy proxy", thinking: nil, role: .assistant, isStreaming: false,
                      searchQuery: "Proxy", searchCaseSensitive: true)
        row.layoutSubtreeIfNeeded()
        let ranges = row.searchHighlightRangesForTesting
        XCTAssertEqual(ranges.count, 1, "case-sensitive: only the exact-cased occurrence")
        XCTAssertEqual(ranges.first?.location, 0)
    }

    func testCurrentMatchUsesTheStrongerShade() {
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        row.configure(text: "proxy", thinking: nil, role: .assistant, isStreaming: false,
                      searchQuery: "proxy", searchCaseSensitive: false, isCurrentSearchMatch: true)
        row.layoutSubtreeIfNeeded()
        let color = textView(of: row).textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertTrue(color === SearchMatchHighlight.current, "current match uses the stronger shade")
        XCTAssertFalse(color === SearchMatchHighlight.match)
    }

    // MARK: - Card geometry

    func testCardCoversExactlyTheCodeLines() {
        let row = makeRow(text: codeMarkdown, role: .assistant)
        let tv = textView(of: row)
        for (index, block) in row.codeBlocksForTesting.enumerated() {
            let glyphs = tv.layoutManager!.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            var minY = CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude
            tv.layoutManager!.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
                minY = min(minY, used.minY)
                maxY = max(maxY, used.maxY)
            }
            // The code lines' union lives in the text view's (flipped) container
            // coordinates; the card lives in the row's (non-flipped) coordinates.
            // Convert, exactly as TextRowView.layout does.
            let containerY = tv.textContainerInset.height
            let codeRect = tv.convert(
                NSRect(x: 0, y: minY + containerY, width: tv.bounds.width, height: maxY - minY),
                to: row
            )
            let card = row.renderedCodeCardFrame(at: index)
            XCTAssertEqual(card.minY, codeRect.minY, accuracy: 1.5, "card top at first code line")
            XCTAssertEqual(card.maxY, codeRect.maxY, accuracy: 1.5, "card bottom at last code line")
            XCTAssertEqual(card.width, row.bounds.width, "card spans the full row width")
        }
    }

    func testCopyButtonsSitInsideTheCardTopRight() {
        let row = makeRow(text: codeMarkdown, role: .assistant)
        for index in 0..<row.renderedCopyButtonCount {
            let card = row.renderedCodeCardFrame(at: index)
            let button = row.copyButtonsForTesting[index]
            // top-right corner: flush inside the card's right and top edges
            // (8pt right margin, 6pt top margin — in the non-flipped row,
            // maxX/maxY are the right/top edges).
            XCTAssertEqual(button.frame.maxX, card.maxX - 8, accuracy: 1, "right margin")
            XCTAssertEqual(button.frame.maxY, card.maxY - 6, accuracy: 1, "top margin")
            XCTAssertGreaterThan(button.frame.minX, card.minX, "button inside the card horizontally")
            XCTAssertLessThan(button.frame.minY, card.maxY, "button inside the card vertically")
        }
    }

    // MARK: - Height

    func testRowHeightMatchesMeasurement() {
        let row = makeRow(text: codeMarkdown, role: .assistant)
        let measured = TranscriptText.measuredHeight(text: codeMarkdown, thinking: nil, role: .assistant, isStreaming: false, width: 800)
        XCTAssertEqual(row.contentHeight, measured, accuracy: 3)
    }

    func testContentHeightAtWidthIgnoresStaleWideFrame() {
        // Regression: a reused cell can hold a stale (wider) frame after a
        // window resize. Measuring at that stale width under-reports the
        // height; the row then renders short and the taller text overflows
        // upward, clipping the message's top.
        let msg = "> quote line\n\nsecond paragraph text here that wraps"
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100)) // stale-wide frame
        row.configure(text: msg, thinking: nil, role: .user, isStreaming: false)
        row.layoutSubtreeIfNeeded()

        let at400 = row.contentHeight(atWidth: 400)
        let measured400 = TranscriptText.measuredHeight(text: msg, thinking: nil, role: .user, isStreaming: false, width: 400)
        XCTAssertEqual(at400, measured400, accuracy: 3, "measure at the real width, not the stale frame")

        let at800 = row.contentHeight(atWidth: 800)
        let measured800 = TranscriptText.measuredHeight(text: msg, thinking: nil, role: .user, isStreaming: false, width: 800)
        XCTAssertEqual(at800, measured800, accuracy: 3)
    }
}

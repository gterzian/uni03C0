import AppKit
import Core
import XCTest

/// Pins the find-in-buffer behavior of the code pane: the pure range scan,
/// the highlight paint (with the edit overlay restored underneath on clear),
/// and the scroll-to-match. The engine that cycles matches lives in the
/// app-only `CodeSearchModel`; everything it drives through the pane is
/// exercised here.
final class FilePaneSearchTests: XCTestCase {
    // MARK: - Range scan

    func testSearchRangesFindsEveryOccurrence() {
        let text = "alpha beta ALPHA gamma alpha\n"
        XCTAssertEqual(ReadOnlyCodeTextView.searchRanges(of: "alpha", in: text, caseSensitive: false).count, 3)
        XCTAssertEqual(ReadOnlyCodeTextView.searchRanges(of: "alpha", in: text, caseSensitive: true).count, 2)
    }

    func testSearchRangesTrimsTheQueryAndHandlesEmptyInput() {
        XCTAssertTrue(ReadOnlyCodeTextView.searchRanges(of: "   ", in: "anything", caseSensitive: false).isEmpty)
        XCTAssertTrue(ReadOnlyCodeTextView.searchRanges(of: "", in: "anything", caseSensitive: false).isEmpty)
        XCTAssertTrue(ReadOnlyCodeTextView.searchRanges(of: "x", in: "", caseSensitive: false).isEmpty)
    }

    func testSearchRangesReturnsNonOverlappingHits() {
        // "aa" in "aaaa": two non-overlapping hits, not three.
        XCTAssertEqual(ReadOnlyCodeTextView.searchRanges(of: "aa", in: "aaaa", caseSensitive: true).count, 2)
    }

    // MARK: - Highlight paint

    @MainActor
    private func makeContainer() -> FilePaneContainer {
        let container = FilePaneContainer(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return container
    }

    @MainActor
    func testSearchHighlightPaintsMatchesAndCurrentInTheStrongerShade() {
        let container = makeContainer()
        let text = NSAttributedString(string: "one two one three one\n")
        container.displayContent(path: "/tmp/search-highlight.txt", text: text)

        let ranges = ReadOnlyCodeTextView.searchRanges(of: "one", in: text.string, caseSensitive: true)
        XCTAssertEqual(ranges.count, 3)
        container.applySearchHighlight(ranges: ranges, currentIndex: 1)

        let storage = container.codeView.textStorage!
        XCTAssertEqual(container.codeView.searchHighlightRanges.count, 3)
        XCTAssertEqual(container.codeView.currentSearchHighlightIndex, 1)
        XCTAssertTrue((storage.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor) === SearchMatchHighlight.match)
        XCTAssertTrue((storage.attribute(.backgroundColor, at: ranges[1].location, effectiveRange: nil) as? NSColor) === SearchMatchHighlight.current)
        XCTAssertTrue((storage.attribute(.backgroundColor, at: ranges[2].location, effectiveRange: nil) as? NSColor) === SearchMatchHighlight.match)
    }

    @MainActor
    func testClearingSearchRestoresTheEditOverlayUnderneath() {
        let container = makeContainer()
        let text = NSMutableAttributedString(string: "one two one three one\n")
        // Stand in for the edit overlay's added-line green over the first line.
        let green = NSColor.systemGreen
        text.addAttribute(.backgroundColor, value: green, range: NSRange(location: 0, length: 7))
        container.displayContent(path: "/tmp/search-overlay.txt", text: text)

        let ranges = ReadOnlyCodeTextView.searchRanges(of: "one", in: text.string, caseSensitive: true)
        container.applySearchHighlight(ranges: ranges, currentIndex: 0)
        let storage = container.codeView.textStorage!
        // The search shade replaced the green while active...
        XCTAssertTrue((storage.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor) === SearchMatchHighlight.current)

        container.clearSearchHighlight()
        // ...and the green is back underneath, while the match on plain text
        // has no background at all.
        XCTAssertTrue((storage.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor) === green)
        XCTAssertNil(storage.attribute(.backgroundColor, at: ranges[2].location, effectiveRange: nil))
        XCTAssertTrue(container.codeView.searchHighlightRanges.isEmpty)
        XCTAssertEqual(container.codeView.currentSearchHighlightIndex, -1)
    }

    @MainActor
    func testReapplyingSearchDoesNotAccumulateOverlays() {
        let container = makeContainer()
        let text = NSAttributedString(string: "one two one three one\n")
        container.displayContent(path: "/tmp/search-reapply.txt", text: text)
        let ranges = ReadOnlyCodeTextView.searchRanges(of: "one", in: text.string, caseSensitive: true)

        container.applySearchHighlight(ranges: ranges, currentIndex: 0)
        container.applySearchHighlight(ranges: ranges, currentIndex: 2)

        let storage = container.codeView.textStorage!
        XCTAssertTrue((storage.attribute(.backgroundColor, at: ranges[2].location, effectiveRange: nil) as? NSColor) === SearchMatchHighlight.current)
        // The first match went back to the pale shade (no stale "current").
        XCTAssertTrue((storage.attribute(.backgroundColor, at: ranges[0].location, effectiveRange: nil) as? NSColor) === SearchMatchHighlight.match)
    }

    // MARK: - Scroll to match

    @MainActor
    func testRevealSearchMatchScrollsTheHitIntoView() {
        let container = makeContainer()
        let lines = (1...400).map { $0 == 300 ? "needle here" : "line \($0) of the scroll test — padding padding" }
        let text = NSAttributedString(string: lines.joined(separator: "\n") + "\n")
        container.displayContent(path: "/tmp/search-reveal.txt", text: text)

        let ranges = ReadOnlyCodeTextView.searchRanges(of: "needle", in: text.string, caseSensitive: true)
        XCTAssertEqual(ranges.count, 1)
        container.revealSearchMatch(ranges[0])
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        // The match's box, converted into the clip view, must intersect the
        // visible rect (the jump centered it).
        let layoutManager = container.codeView.layoutManager!
        let textContainer = container.codeView.textContainer!
        let glyphRange = layoutManager.glyphRange(forCharacterRange: ranges[0], actualCharacterRange: nil)
        let box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let clip = container.scrollView.contentView
        let boxInClip = clip.convert(
            NSRect(x: 0, y: box.minY + container.codeView.textContainerInset.height, width: 10, height: box.height),
            from: container.codeView
        )
        XCTAssertTrue(boxInClip.intersects(clip.bounds), "the match is scrolled into the viewport")
    }
}

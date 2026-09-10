import AppKit
import Core
import XCTest

/// Pins the line-number gutter's two load-bearing behaviors (see
/// `CodeLineRulerView`):
///
/// 1. **The ruler redraws when the text scrolls or the buffer changes.** The
///    ruler is a sibling view sitting next to the clip view; scrolling the
///    clip does NOT invalidate it (nothing asks the ruler to redraw), so
///    without observers the numbers freeze on the old viewport while the text
///    scrolls underneath — missing/duplicated/misattached numbers that only
///    snap back when some unrelated event repaints the ruler. `needsDisplay`
///    cannot be READ back in this offscreen harness (the window consumes the
///    dirty flags on run-loop turns), so these tests pin the behavior
///    end-to-end: the ruler carries a draw counter, and a scroll or a buffer
///    swap must advance it (a dirty ruler is redrawn by the window's display
///    pass; a clean one is not).
///
/// 2. **Every painted number lands on the same screen row as its line's
///    text.** Positions come from the layout manager's fragment rects (via
///    view conversion), never from "line index × pitch" document arithmetic —
///    which drifts whenever the document's origin is offset (a scroll-view
///    tiling offset, a text-container inset). Asserted by rasterizing the real
///    pane at several scroll positions and checking that each painted label
///    band in the gutter aligns 1:1 with its text row band next to it, and
///    that nothing paints below the last line of a short file.
final class CodeLineRulerTests: XCTestCase {

    @MainActor
    private func makeLoadedPane(lineCount: Int = 900) -> FilePaneContainer {
        let container = FilePaneContainer(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        // Let the window/scroll-view settle before content lands (the document
        // view's frame grows on the layout pass after text loads).
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let lines = (1...lineCount).map { "this is line number \($0) of the ruler test — padding padding" }
        let text = lines.joined(separator: "\n") + "\n"
        container.displayContent(
            path: "/tmp/CodeLineRulerTests.swift",
            text: NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        return container
    }

    @MainActor
    private func ruler(in container: FilePaneContainer) -> CodeLineRulerView {
        container.scrollView.verticalRulerView as! CodeLineRulerView
    }

    // MARK: - Redraw triggers

    @MainActor
    func testScrollingTheClipViewRedrawsTheRuler() {
        let container = makeLoadedPane()
        let scrollView = container.scrollView
        let clip = scrollView.contentView
        let ruler = ruler(in: container)

        // Settle: no redraw may be pending from the load itself.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let before = ruler.renderedFrameCount

        // A programmatic scroll (exactly what the pane's reveal / place-
        // preserving reload do) must redraw the gutter: without the scroll
        // observer the ruler is a clean sibling view and nothing repaints it,
        // so the count would not advance.
        clip.scroll(to: NSPoint(x: 0, y: 3000))
        scrollView.reflectScrolledClipView(clip)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        container.window?.displayIfNeeded()

        XCTAssertGreaterThan(ruler.renderedFrameCount, before,
                             "scrolling the document must redraw the ruler (a sibling view AppKit never invalidates on scroll)")
    }

    @MainActor
    func testReplacingTheBufferRedrawsTheRuler() {
        let container = makeLoadedPane()
        let ruler = ruler(in: container)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let before = ruler.renderedFrameCount

        // A new file (different line count) loads into the same pane.
        let text = (1...40).map { "short file line \($0)" }.joined(separator: "\n") + "\n"
        container.displayContent(
            path: "/tmp/short.swift",
            text: NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        container.window?.displayIfNeeded()

        XCTAssertGreaterThan(ruler.renderedFrameCount, before,
                             "a buffer swap (file load) must redraw the ruler so numbers track the new text")
    }

    // MARK: - Painted geometry (rasterized ground truth)

    /// Painted (non-background) row bands in a horizontal strip of the pane's
    /// rasterization. `xPts` are in points from the pane's left edge; the
    /// bitmap is 2× (the container is 700×500pt in an offscreen window).
    private func paintedBands(_ rep: NSBitmapImageRep, xPts: Range<CGFloat>) -> [(start: CGFloat, end: CGFloat)] {
        let scale = CGFloat(rep.pixelsWide) / 700.0
        let xRange = Int(xPts.lowerBound * scale)..<Int(xPts.upperBound * scale)
        // The strip's dominant background luminance (appearance-agnostic: the
        // offscreen window may resolve to light or dark).
        var histogram = [Int](repeating: 0, count: 256)
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: xRange.lowerBound, to: xRange.upperBound, by: 4) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let l = 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
                histogram[min(255, Int(l * 255))] += 1
            }
        }
        var mode = 0
        for (i, count) in histogram.enumerated() where count > histogram[mode] { mode = i }
        let background = CGFloat(mode) / 255.0

        var bands: [(start: CGFloat, end: CGFloat)] = []
        var inBand = false
        var bandStart = 0
        for y in 0..<rep.pixelsHigh {
            var painted = 0
            var sampled = 0
            for x in stride(from: xRange.lowerBound, to: xRange.upperBound, by: 2) {
                sampled += 1
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let l = 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
                if abs(l - background) > 0.18 { painted += 1 }
            }
            let isPainted = CGFloat(painted) / CGFloat(max(sampled, 1)) > 0.02
            if isPainted && !inBand { inBand = true; bandStart = y }
            if !isPainted && inBand {
                inBand = false
                if CGFloat(y - bandStart) >= 1.5 * scale {
                    bands.append((CGFloat(bandStart) / scale, CGFloat(y) / scale))
                }
            }
        }
        if inBand { bands.append((CGFloat(bandStart) / scale, CGFloat(rep.pixelsHigh) / scale)) }
        return bands
    }

    /// Bands that sit fully inside the viewport (more than 5pt from either
    /// edge): a row that grazes the top or bottom edge may legitimately have
    /// its number clipped away, so only interior rows are compared 1:1.
    private func interiorBands(_ bands: [(start: CGFloat, end: CGFloat)]) -> [(start: CGFloat, end: CGFloat)] {
        bands.filter { $0.start > 5 && $0.end < 495 }
    }

    /// Rasterizes the pane and asserts the gutter's painted label bands align
    /// one-to-one with the code area's painted interior text rows at the
    /// current scroll position. A stale or doc-arithmetic-derived gutter fails
    /// here (wrong count — the missing-band regression — or labels whose
    /// midpoints don't match their text rows — the stale/misattached
    /// regression).
    @MainActor
    private func assertLabelsAlignWithTextRows(_ container: FilePaneContainer, file: StaticString = #filePath, line: UInt = #line) {
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
            XCTFail("could not rasterize the pane", file: file, line: line)
            return
        }
        container.cacheDisplay(in: container.bounds, to: rep)

        // Gutter strip: the ruler is the leftmost 52pt. Code strip: a mid swath
        // clear of the gutter and the scrollers.
        let labelBands = interiorBands(paintedBands(rep, xPts: 6..<50))
        let textBands = interiorBands(paintedBands(rep, xPts: 110..<640))
        XCTAssertEqual(labelBands.count, textBands.count,
                       "every visible interior text row must have a line number next to it (gutter \(labelBands.count) labels vs \(textBands.count) text rows)",
                       file: file, line: line)
        guard labelBands.count == textBands.count else { return }
        for (label, text) in zip(labelBands, textBands) {
            let labelMid = (label.start + label.end) / 2
            let textMid = (text.start + text.end) / 2
            XCTAssertLessThan(abs(labelMid - textMid), 2.5,
                              "the label for a line must sit on its text row (label mid \(labelMid), text mid \(textMid))",
                              file: file, line: line)
        }
    }

    @MainActor
    func testLabelsAlignWithTextRowsAtTheTop() {
        let container = makeLoadedPane()
        assertLabelsAlignWithTextRows(container)
    }

    @MainActor
    func testLabelsAlignWithTextRowsAfterScrollingIntoTheMiddle() {
        let container = makeLoadedPane()
        // Scroll to a band like the reported one (rows ~37-71 at a 550pt
        // offset) and deep into the file; the labels must follow the text at
        // every position.
        for y in [550.0, 8000.0] {
            let clip = container.scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: y))
            container.scrollView.reflectScrolledClipView(clip)
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            assertLabelsAlignWithTextRows(container)
        }
    }

    @MainActor
    func testNoLabelsBleedBelowTheLastLineOfAShortFile() {
        // A short file in a tall viewport: the gutter must not paint numbers
        // into the empty space below the last text line (doc-arithmetic
        // gutters over-run past EOF), and the ones it does paint must sit on
        // their text rows.
        let container = makeLoadedPane(lineCount: 8)
        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 0))
        container.scrollView.reflectScrolledClipView(clip)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
            XCTFail("could not rasterize the pane")
            return
        }
        container.cacheDisplay(in: container.bounds, to: rep)
        let labelBands = paintedBands(rep, xPts: 6..<50)
        let textBands = paintedBands(rep, xPts: 110..<640)
        XCTAssertEqual(labelBands.count, textBands.count,
                       "a short file must show exactly as many labels as text rows, not extra numbers below the file")
        if labelBands.count == textBands.count {
            for (label, text) in zip(labelBands, textBands) {
                XCTAssertLessThan(abs(((label.start + label.end) / 2) - ((text.start + text.end) / 2)), 2.5,
                                  "each label must sit on its text row")
            }
        }
        // Below the last text row, the gutter must be empty.
        if let lastText = textBands.last {
            let scanStartY = Int(lastText.end * 2) + 4
            var found = false
            if scanStartY < rep.pixelsHigh {
                for y in stride(from: scanStartY, to: rep.pixelsHigh, by: 2) {
                    for x in stride(from: 12, to: 100, by: 2) {
                        if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                            let l = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                            if l < 0.85 { found = true; break }
                        }
                    }
                    if found { break }
                }
            }
            XCTAssertFalse(found, "no line numbers may paint into the empty space below the last text line")
        }
    }
}

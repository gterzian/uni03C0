import AppKit
import Core
import XCTest

/// Pins the diff viewer's SCROLLBAR edit map (`CodePaneEditMarkerScroller`,
/// installed by `CodePaneContainer`): changed display lines become colored ticks
/// at their exact document fraction, and every document swap replaces the
/// previous map. The whole document is in the text view (no incremental
/// loading), so markers are always exact positions — these tests freeze the
/// mapping arithmetic that would change if that ever became windowed.
final class FilePaneScrollbarMarkerTests: XCTestCase {
    /// A container hosting a 900-line document, laid out in an offscreen window.
    @MainActor
    private func makeContainer() -> CodePaneContainer {
        let container = CodePaneContainer(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
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

    private func paneText(lineCount: Int = 900, trailingNewline: Bool = true) -> NSAttributedString {
        let lines = (1...lineCount).map { "this is line number \($0) of the pane test — padding padding" }
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        return NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
    }

    private func scroller(of container: CodePaneContainer) -> CodePaneEditMarkerScroller? {
        container.scrollView.verticalScroller as? CodePaneEditMarkerScroller
    }

    @MainActor
    func testEditMapInstallsAMarkerScroller() {
        let container = makeContainer()
        XCTAssertNotNil(scroller(of: container), "the viewer's vertical scroller is the marker subclass")
    }

    @MainActor
    func testEditedLinesBecomeTicksAtTheirDocumentFraction() {
        let container = makeContainer()
        container.displayDocument(path: "/tmp/x.swift", text: paneText(), markers: .lines(added: [10, 858], removed: []))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        let markers = scroller(of: container)?.markers ?? []
        XCTAssertEqual(markers.count, 2, "one tick per edited line")
        XCTAssertEqual(markers[0].fraction, (10.0 - 0.5) / 900.0, accuracy: 0.001, "line 10 maps to its document fraction")
        XCTAssertEqual(markers[1].fraction, (858.0 - 0.5) / 900.0, accuracy: 0.001, "line 858 maps to its document fraction")
        XCTAssertEqual(markers[0].color, .systemGreen, "added lines are green (matches the text overlay)")
    }

    @MainActor
    func testRemovedLinesBecomeRedTicks() {
        let container = makeContainer()
        container.displayDocument(path: "/tmp/x.swift", text: paneText(), markers: .lines(added: [10], removed: [858]))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        let markers = scroller(of: container)?.markers ?? []
        XCTAssertEqual(markers.count, 2, "one tick per edited line (both sides)")
        XCTAssertEqual(markers[0].color, .systemGreen, "added lines are green")
        XCTAssertEqual(markers[0].fraction, (10.0 - 0.5) / 900.0, accuracy: 0.001)
        XCTAssertEqual(markers[1].color, .systemRed, "removed lines are red (matches the text overlay)")
        XCTAssertEqual(markers[1].fraction, (858.0 - 0.5) / 900.0, accuracy: 0.001)
    }

    @MainActor
    func testEachLoadReplacesThePreviousMap() {
        let container = makeContainer()
        container.displayDocument(path: "/tmp/x.swift", text: paneText(), markers: .lines(added: [100], removed: []))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(scroller(of: container)?.markers.count, 1)

        container.displayDocument(path: "/tmp/clean.swift", text: paneText(), markers: .none)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertTrue(scroller(of: container)?.markers.isEmpty ?? false, "ticks clear on a load with no edits")
    }

    @MainActor
    func testBatchedDrawingPaintsEveryTickAtItsFraction() {
        let container = makeContainer()
        container.displayDocument(path: "/tmp/x.swift", text: paneText(), markers: .lines(added: [10, 858], removed: []))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 6000))
        container.scrollView.reflectScrolledClipView(clip)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        guard let scroller = scroller(of: container) else { return XCTFail("no marker scroller") }
        guard let rep = scroller.bitmapImageRepForCachingDisplay(in: scroller.bounds) else { return XCTFail("could not rasterize the scroller") }
        scroller.cacheDisplay(in: scroller.bounds, to: rep)

        let scale = CGFloat(rep.pixelsWide) / scroller.bounds.width
        var bands: [(start: CGFloat, end: CGFloat)] = []
        var inBand = false
        var bandStart = 0
        func isGreen(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return c.greenComponent - c.redComponent > 0.15 && c.greenComponent - c.blueComponent > 0.15
        }
        for y in 0..<rep.pixelsHigh {
            var green = false
            for x in stride(from: rep.pixelsWide / 4, to: rep.pixelsWide * 3 / 4, by: 2) where isGreen(x, y) {
                green = true
                break
            }
            if green && !inBand { inBand = true; bandStart = y }
            if !green && inBand {
                inBand = false
                if CGFloat(y - bandStart) >= 1.5 * scale {
                    bands.append((CGFloat(bandStart) / scale, CGFloat(y) / scale))
                }
            }
        }
        if inBand { bands.append((CGFloat(bandStart) / scale, CGFloat(rep.pixelsHigh) / scale)) }

        XCTAssertEqual(bands.count, 2, "both ticks paint: line 10 near the top of the track, 858 near the bottom")
        guard bands.count == 2 else { return }
        let centers = bands.map { ($0.start + $0.end) / 2 }
        let height = scroller.bounds.height
        XCTAssertLessThan(centers[0] / height, 0.12, "the top tick paints near the top of the track")
        XCTAssertGreaterThan(centers[1] / height, 0.85, "the bottom tick paints near the bottom of the track")
        XCTAssertLessThan(centers[0], centers[1], "ticks keep document order")
    }

    // MARK: - Pinned document height (the scroller/map geometry)

    /// `allowsNonContiguousLayout` makes `sizeToFit`/`usedRect` report an
    /// ESTIMATE that grows as more of a large document is laid out, so an
    /// auto-sizing text view shrank the document mid-scroll — which slid the
    /// scroller and the edit map out from under the reader. A supplied exact
    /// height must be pinned for the life of the document.
    @MainActor
    func testPinnedDocumentHeightStaysExactWhileScrolling() {
        let container = makeContainer()
        let view = container.codeView
        let lineHeight = ReadOnlyCodeTextView.lineHeight(for: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        let lineCount = 900
        let textHeight = CGFloat(lineCount) * lineHeight
        let expected = textHeight + view.textContainerInset.height * 2

        container.displayDocument(
            path: "/tmp/x.swift",
            text: paneText(lineCount: lineCount, trailingNewline: false),
            markers: .lines(added: [10, 858], removed: []),
            contentHeight: textHeight
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(view.frame.height, expected, accuracy: 0.5, "the pinned height IS the document height")
        XCTAssertEqual(scroller(of: container)?.knobProportion ?? 0,
                       container.scrollView.contentView.bounds.height / expected,
                       accuracy: 0.005,
                       "the knob reflects the exact document height, not TextKit's estimate")

        let clip = container.scrollView.contentView
        for y in [expected / 3, expected / 2, max(0, expected - clip.bounds.height)] {
            clip.scroll(to: NSPoint(x: 0, y: y))
            container.scrollView.reflectScrolledClipView(clip)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(view.frame.height, expected, accuracy: 0.5,
                           "laying out more of the document must not resize it")
        }
        // The document is fully scrollable: the bottom sits at the exact content
        // height (an underestimated height left the last lines unreachable).
        XCTAssertEqual(clip.bounds.minY, expected - clip.bounds.height, accuracy: 1.0,
                       "the last line is reachable at the exact document height")
    }

    /// The diff document mixes the 12pt code font with the 11pt expand row
    /// font, so the builder sums each line's own height. The total must equal
    /// TextKit's laid-out height exactly, or the pinning is off by the
    /// difference.
    @MainActor
    func testPinnedHeightEqualsTheLaidOutHeightForMixedFonts() {
        let code = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let small = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let text = NSMutableAttributedString()
        var height: CGFloat = 0
        for index in 1...600 {
            if index > 1 { text.append(NSAttributedString(string: "\n")) }
            if index % 10 == 0 {
                text.append(NSAttributedString(string: "  ⌃  \(index) more lines below — click to expand", attributes: [.font: small]))
                height += ReadOnlyCodeTextView.lineHeight(for: small)
            } else {
                text.append(NSAttributedString(string: "code line \(index) — padding padding", attributes: [.font: code]))
                height += ReadOnlyCodeTextView.lineHeight(for: code)
            }
        }

        let container = makeContainer()
        container.displayDocument(path: "/tmp/mix.swift", text: text, contentHeight: height)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let view = container.codeView
        XCTAssertEqual(view.frame.height, height + view.textContainerInset.height * 2, accuracy: 0.5)

        view.layoutManager?.ensureLayout(for: view.textContainer!)
        XCTAssertEqual(view.layoutManager!.usedRect(for: view.textContainer!).height, height, accuracy: 0.5,
                       "the builder's per-line font sum is exactly TextKit's laid-out height")
    }

    /// `ReadOnlyCodeTextView.lineHeight` is what the off-main builder totals,
    /// so it must stay equal to TextKit's own line height for the fonts the
    /// differ uses.
    @MainActor
    func testLineHeightMatchesTextKit() {
        let layoutManager = NSLayoutManager()
        for size in [10.0, 11.0, 12.0] as [CGFloat] {
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            XCTAssertEqual(ReadOnlyCodeTextView.lineHeight(for: font),
                           layoutManager.defaultLineHeight(for: font),
                           accuracy: 0.001,
                           "line height at \(size)pt")
        }
    }
}

import AppKit
import Core
import XCTest

/// Pins the file pane's SCROLLBAR edit map (`CodePaneEditMarkerScroller`,
/// installed by `FilePaneContainer`): edit lines become colored ticks at their
/// exact document fraction, whole-file edits tint the whole track, and every
/// load replaces the previous map. The files are loaded WHOLE into the text
/// view (no incremental loading), so markers are always exact positions —
/// these tests freeze the mapping arithmetic that would change if that ever
/// became windowed.
final class FilePaneScrollbarMarkerTests: XCTestCase {
    /// A container hosting a 900-line file, laid out in an offscreen window.
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

    private func paneText() -> NSAttributedString {
        let lines = (1...900).map { "this is line number \($0) of the pane test — padding padding" }
        let text = lines.joined(separator: "\n") + "\n"
        return NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
    }

    private func scroller(of container: FilePaneContainer) -> CodePaneEditMarkerScroller? {
        container.scrollView.verticalScroller as? CodePaneEditMarkerScroller
    }

    @MainActor
    func testEditMapInstallsAMarkerScroller() {
        // The scroll view must be using the marker subclass, and assigning a
        // subclass forces the legacy (always-visible) style — the edit map is
        // only useful while the bar is shown.
        let container = makeContainer()
        XCTAssertNotNil(scroller(of: container), "the pane's vertical scroller is the marker subclass")
    }

    @MainActor
    func testEditedLinesBecomeTicksAtTheirDocumentFraction() {
        let container = makeContainer()
        container.displayContent(path: "/tmp/x.swift", text: paneText(), preserveScroll: false, targetLines: nil, markers: .lines([10, 858]))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        let markers = scroller(of: container)?.markers ?? []
        XCTAssertEqual(markers.count, 2, "one tick per edited line")
        // (line − 0.5) / lineCount — line 10 near the top, 858 near the bottom.
        XCTAssertEqual(markers[0].fraction, (10.0 - 0.5) / 900.0, accuracy: 0.001, "line 10 maps to its document fraction")
        XCTAssertEqual(markers[1].fraction, (858.0 - 0.5) / 900.0, accuracy: 0.001, "line 858 maps to its document fraction")
        XCTAssertEqual(markers[0].color, .systemGreen, "added lines are green (matches the text overlay)")
        XCTAssertNil(scroller(of: container)?.wholeTrackColor)
    }

    @MainActor
    func testWholeFileEditsTintTheTrack() {
        let container = makeContainer()
        container.displayContent(path: "/tmp/new.swift", text: paneText(), preserveScroll: false, targetLines: nil, markers: .wholeAdded)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertNotNil(scroller(of: container)?.wholeTrackColor, "a brand-new file tints the whole track")
        XCTAssertTrue(scroller(of: container)?.markers.isEmpty ?? false)

        container.displayContent(path: "/tmp/gone.swift", text: paneText(), preserveScroll: false, targetLines: nil, markers: .wholeDeleted)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertNotNil(scroller(of: container)?.wholeTrackColor, "a deleted file tints the whole track (the removed side)")
    }

    @MainActor
    func testEachLoadReplacesThePreviousMap() {
        let container = makeContainer()
        container.displayContent(path: "/tmp/x.swift", text: paneText(), preserveScroll: false, targetLines: nil, markers: .lines([100]))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(scroller(of: container)?.markers.count, 1)

        // A plain reload of an unedited file clears the map.
        container.displayContent(path: "/tmp/clean.swift", text: paneText(), preserveScroll: false, targetLines: nil, markers: .none)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertTrue(scroller(of: container)?.markers.isEmpty ?? false, "ticks clear on a load with no edits")
        XCTAssertNil(scroller(of: container)?.wholeTrackColor)
    }

    @MainActor
    func testBatchedDrawingPaintsEveryTickAtItsFraction() {
        // The scroller batches same-color ticks into ONE path + ONE fill (see
        // `EditMarkerScroller.drawEditMarkers`); this pins that the batched
        // drawing still paints a tick for EVERY marker at its mapped track
        // position — a grouping bug would drop ticks or pile them at one spot.
        let container = makeContainer()
        container.displayContent(path: "/tmp/x.swift", text: paneText(), preserveScroll: false, targetLines: nil, markers: .lines([10, 858]))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        // Scroll to the middle so the knob (which covers whatever it overlaps)
        // sits mid-track and neither edge tick hides under it.
        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 6000))
        container.scrollView.reflectScrolledClipView(clip)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        guard let scroller = scroller(of: container) else { return XCTFail("no marker scroller") }
        guard let rep = scroller.bitmapImageRepForCachingDisplay(in: scroller.bounds) else { return XCTFail("could not rasterize the scroller") }
        scroller.cacheDisplay(in: scroller.bounds, to: rep)

        // Scan for green-dominant pixels (the added-line tick color) and
        // collect their row bands.
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
        // Line 10 sits at fraction ~0.01, line 858 at ~0.95 of the document —
        // their ticks must land at the corresponding ends of the track.
        XCTAssertLessThan(centers[0] / height, 0.12, "the top tick paints near the top of the track")
        XCTAssertGreaterThan(centers[1] / height, 0.85, "the bottom tick paints near the bottom of the track")
        XCTAssertLessThan(centers[0], centers[1], "ticks keep document order")
    }
}

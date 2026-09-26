import XCTest
@testable import Core

/// Pins `DiffHighlightPlan` — the pure windowing behind the diff viewer's
/// PREFETCH highlighting. The load-bearing property: after every step the
/// viewport sits INSIDE the colored window with a buffer to spare, so the
/// reader never arrives on a line that is still being colored (the "stuff
/// changes as I scroll" regression). The technique mirrors the transcript's
/// materialized row window + compounding history fetch.
final class DiffHighlightPlanTests: XCTestCase {

    // MARK: - Buffer

    func testBufferIsAFloorOfViewports() {
        XCTAssertEqual(DiffHighlightPlan.buffer(viewportLines: 10), DiffHighlightPlan.minBuffer,
                       "a small viewport still prefetches a screenful")
        XCTAssertEqual(DiffHighlightPlan.buffer(viewportLines: 100), 300,
                       "a large viewport scales the buffer with it")
    }

    // MARK: - Prefetch trigger

    func testNoWindowAlwaysNeedsAFirstFetch() {
        XCTAssertTrue(DiffHighlightPlan.needsPrefetch(state: .init(), visible: 1...40, total: 1000))
    }

    func testInsideTheWindowNeedsNoFetch() {
        let state = DiffHighlightPlan.State(start: 500, end: 2500)
        // 40-line viewport: buffer 240. Comfortably inside.
        XCTAssertFalse(DiffHighlightPlan.needsPrefetch(state: state, visible: 1000...1039, total: 10_000))
    }

    func testNearEitherEdgeNeedsAFetch() {
        let state = DiffHighlightPlan.State(start: 500, end: 2500)
        XCTAssertTrue(DiffHighlightPlan.needsPrefetch(state: state, visible: 700...739, total: 10_000),
                      "within the buffer of the top edge")
        XCTAssertTrue(DiffHighlightPlan.needsPrefetch(state: state, visible: 2280...2319, total: 10_000),
                      "within the buffer of the bottom edge")
    }

    func testAnEdgeAtTheDocumentBoundaryNeedsNoFetch() {
        let state = DiffHighlightPlan.State(start: 1, end: 500)
        // The top edge cannot grow (already at line 1); the viewport is near it.
        XCTAssertFalse(DiffHighlightPlan.needsPrefetch(state: state, visible: 100...139, total: 10_000))
        let bottom = DiffHighlightPlan.State(start: 9500, end: 10_000)
        XCTAssertFalse(DiffHighlightPlan.needsPrefetch(state: bottom, visible: 9960...9999, total: 10_000))
    }

    // MARK: - Extending

    func testFirstPassOpensAWindowAroundTheViewport() {
        let visible = 1000...1039
        let (ranges, state) = DiffHighlightPlan.step(state: .init(), visible: visible, total: 10_000)
        let reach = max(DiffHighlightPlan.buffer(viewportLines: 40), DiffHighlightPlan.blockStart)
        XCTAssertEqual(ranges, [(1000 - reach)...(1039 + reach)])
        XCTAssertEqual(state.start, 1000 - reach)
        XCTAssertEqual(state.end, 1039 + reach)
        XCTAssertEqual(state.block, DiffHighlightPlan.blockStart)
    }

    func testViewportComfortablyInsideDoesNothing() {
        let state = DiffHighlightPlan.State(start: 500, end: 2500)
        let (ranges, next) = DiffHighlightPlan.step(state: state, visible: 1000...1039, total: 10_000)
        XCTAssertTrue(ranges.isEmpty, "nothing to color when the buffer is intact")
        XCTAssertEqual(next, state)
    }

    func testNearEdgeExtendsByOneBlockAndDoublesIt() {
        let state = DiffHighlightPlan.State(start: 500, end: 1500)
        // 40-line viewport, buffer 240; 1500 - 1319 = 181 ≤ 240.
        let (ranges, next) = DiffHighlightPlan.step(state: state, visible: 1280...1319, total: 10_000)
        XCTAssertEqual(ranges, [1501...1900], "the extension reaches a full block past the viewport")
        XCTAssertEqual(next.start, 500, "the far edge is untouched")
        XCTAssertEqual(next.end, 1900)
        XCTAssertEqual(next.block, DiffHighlightPlan.blockStart * 2, "the next fetch compounds")
    }

    func testBlocksCompoundUpToTheCap() {
        var state = DiffHighlightPlan.State(start: 1, end: 1000)
        for expected in [800, 1600, 3200, 4000, 4000] {
            let visible = (state.end - 30)...(state.end - 1)
            let (_, next) = DiffHighlightPlan.step(state: state, visible: visible, total: 1_000_000)
            state = next
            XCTAssertEqual(state.block, expected)
        }
    }

    func testJumpOutsideTheWindowOpensAFreshOne() {
        let state = DiffHighlightPlan.State(start: 1, end: 1000)
        let visible = 5000...5039
        let (ranges, next) = DiffHighlightPlan.step(state: state, visible: visible, total: 100_000)
        let reach = max(DiffHighlightPlan.buffer(viewportLines: 40), DiffHighlightPlan.blockStart)
        XCTAssertEqual(ranges, [(5000 - reach)...(5039 + reach)])
        XCTAssertEqual(next.start, 5000 - reach)
        XCTAssertEqual(next.end, 5039 + reach)
        XCTAssertEqual(next.block, DiffHighlightPlan.blockStart, "a jump restarts the compounding")
    }

    func testWindowClampsToTheDocument() {
        let visible = 990...1000
        let (ranges, next) = DiffHighlightPlan.step(state: .init(), visible: visible, total: 1000)
        XCTAssertEqual(next.end, 1000)
        XCTAssertEqual(ranges, [next.start...1000])
    }

    // MARK: - The load-bearing invariant

    /// Scrolling down in steps smaller than the buffer must always leave the
    /// viewport inside the colored window — the visible lines are already
    /// painted when they arrive.
    func testViewportStaysInsideTheWindowAcrossAScroll() {
        let total = 50_000
        var state = DiffHighlightPlan.State()
        var visible = 1...40
        while visible.upperBound < total {
            let (_, next) = DiffHighlightPlan.step(state: state, visible: visible, total: total)
            state = next
            XCTAssertLessThanOrEqual(state.start, visible.lowerBound, "window must cover the viewport top")
            XCTAssertGreaterThanOrEqual(state.end, visible.upperBound, "window must cover the viewport bottom")
            let advance = min(200, total - visible.upperBound)
            visible = (visible.lowerBound + advance)...(visible.upperBound + advance)
        }
    }
}

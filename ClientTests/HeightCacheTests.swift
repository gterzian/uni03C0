import XCTest
@testable import Core

/// Tests for `HeightCache` — the transcript's (id, width) → height cache.
/// Pure data: the measure closure is supplied by the caller.
final class HeightCacheTests: XCTestCase {

    func testMeasuresAndCaches() {
        let cache = HeightCache()
        var calls = 0
        let height = cache.height(for: "row-1", width: 640) {
            calls += 1
            return 100
        }
        XCTAssertEqual(height, 100)
        XCTAssertEqual(cache.height(for: "row-1", width: 640) { 0 }, 100, "second lookup hits the cache")
        XCTAssertEqual(calls, 1)
    }

    func testWidthChangeRemeasures() {
        let cache = HeightCache()
        var measured: [CGFloat] = []
        _ = cache.height(for: "row-1", width: 640) { measured.append(640); return 100 }
        _ = cache.height(for: "row-1", width: 800) { measured.append(800); return 200 }
        XCTAssertEqual(measured, [640, 800], "a materially different width must re-measure")
    }

    func testSmallWidthJitterIsIgnored() {
        let cache = HeightCache()
        var calls = 0
        _ = cache.height(for: "row-1", width: 640) { calls += 1; return 100 }
        _ = cache.height(for: "row-1", width: 640.4) { calls += 1; return 100 }
        XCTAssertEqual(calls, 1, "sub-0.5px jitter must not re-measure")
    }

    func testInvalidateForcesRemeasure() {
        let cache = HeightCache()
        var calls = 0
        _ = cache.height(for: "row-1", width: 640) { calls += 1; return 100 }
        cache.invalidate("row-1")
        _ = cache.height(for: "row-1", width: 640) { calls += 1; return 120 }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(cache.height(for: "row-1", width: 640) { 0 }, 120)
    }

    func testInvalidateOnlyRemovesOneId() {
        let cache = HeightCache()
        _ = cache.height(for: "a", width: 640) { 10 }
        _ = cache.height(for: "b", width: 640) { 20 }
        cache.invalidate("a")
        XCTAssertTrue(cache.hasHeight(for: "b"))
        XCTAssertFalse(cache.hasHeight(for: "a"))
    }

    func testStorePreseeds() {
        let cache = HeightCache()
        cache.store("row-1", width: 640, height: 55)
        var called = false
        let height = cache.height(for: "row-1", width: 640) {
            called = true
            return 0
        }
        XCTAssertEqual(height, 55, "the preseeded height wins, no measure closure runs")
        XCTAssertFalse(called)
    }

    func testClearDropsEverything() {
        let cache = HeightCache()
        _ = cache.height(for: "a", width: 640) { 10 }
        _ = cache.height(for: "b", width: 640) { 20 }
        cache.clear()
        XCTAssertEqual(cache.count, 0)
        XCTAssertFalse(cache.hasHeight(for: "a"))
    }

    // MARK: - Content tags (streaming rows)

    func testTaggedHeightHitsWhileContentUnchanged() {
        let cache = HeightCache()
        var calls = 0
        // First render of a streaming row: measure and cache under the content.
        let h1 = cache.height(for: "row-1", width: 640, tag: "c1") {
            calls += 1
            return 100
        }
        XCTAssertEqual(h1, 100)
        // Same content re-asked (table layout/scroll between batches): hit.
        XCTAssertEqual(cache.height(for: "row-1", width: 640, tag: "c1") { 0 }, 100)
        XCTAssertEqual(calls, 1)
    }

    func testTaggedHeightRemeasuresOnlyOnContentChange() {
        let cache = HeightCache()
        var calls = 0
        _ = cache.height(for: "row-1", width: 640, tag: "c1") { calls += 1; return 100 }
        // A delta arrived: the content changed, so the cached height is stale.
        let h2 = cache.height(for: "row-1", width: 640, tag: "c2") { calls += 1; return 120 }
        XCTAssertEqual(h2, 120)
        XCTAssertEqual(cache.height(for: "row-1", width: 640, tag: "c2") { 0 }, 120)
        XCTAssertEqual(calls, 2, "exactly one re-measure per content change, then hits again")
    }

    func testHeightIfPresentIgnoresContentTag() {
        let cache = HeightCache()
        _ = cache.height(for: "row-1", width: 640, tag: "c1") { 100 }
        // The table's heightOfRow asks without a content tag: it must serve
        // whatever the renderer seeded (the last rendered content), even when
        // the store has since grown.
        XCTAssertEqual(cache.heightIfPresent(for: "row-1", width: 640), 100)
    }

    func testHeightIfPresentNilWhenAbsentOrWidthMismatch() {
        let cache = HeightCache()
        XCTAssertNil(cache.heightIfPresent(for: "row-1", width: 640))
        _ = cache.height(for: "row-1", width: 640, tag: "c1") { 100 }
        XCTAssertNil(cache.heightIfPresent(for: "row-1", width: 800), "a different width must miss")
        XCTAssertEqual(cache.heightIfPresent(for: "row-1", width: 640), 100)
    }

    func testNilTagQueryDoesNotHitContentTrackedEntry() {
        let cache = HeightCache()
        // A row streamed (content-tracked store), then settled: the caller now
        // tracks nothing, but the cached height was measured for streaming
        // content (caret included) and must not be reused for the final text.
        _ = cache.height(for: "row-1", width: 640, tag: "streaming") { 100 }
        var calls = 0
        let h = cache.height(for: "row-1", width: 640) {
            calls += 1
            return 110
        }
        XCTAssertEqual(h, 110)
        XCTAssertEqual(calls, 1, "a nil-tag query never reuses a content-tracked entry")
    }

    func testStoreWithTagPreseedsTaggedQuery() {
        let cache = HeightCache()
        cache.store("row-1", width: 640, height: 55, tag: "c1")
        var called = false
        let height = cache.height(for: "row-1", width: 640, tag: "c1") {
            called = true
            return 0
        }
        XCTAssertEqual(height, 55)
        XCTAssertFalse(called)
    }
}

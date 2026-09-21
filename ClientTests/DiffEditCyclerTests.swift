import XCTest
@testable import Core

/// Pins the Changes viewer's Cmd+Up / Cmd+Down edit cycle: consecutive changed
/// lines collapse into one stop, and navigation always moves strictly past the
/// viewport anchor (so a landing is never re-targeted by the next press).
final class DiffEditCyclerTests: XCTestCase {
    func testNoEditsHasNoStops() {
        XCTAssertEqual(DiffEditCycler.editStops(added: [], removed: []), [])
    }

    func testSingleChangedLineIsOneStop() {
        XCTAssertEqual(DiffEditCycler.editStops(added: [7], removed: []), [7])
        XCTAssertEqual(DiffEditCycler.editStops(added: [], removed: [9]), [9])
    }

    func testConsecutiveAddedBlockCollapsesToItsFirstLine() {
        XCTAssertEqual(DiffEditCycler.editStops(added: [10, 11, 12, 13], removed: []), [10])
    }

    func testSeparatedRunsBecomeSeparateStops() {
        XCTAssertEqual(DiffEditCycler.editStops(added: [3, 4, 20], removed: []), [3, 20])
    }

    func testAdjacentAddedAndRemovedLinesAreOneRun() {
        // A replacement: removals and additions interleaved and contiguous.
        XCTAssertEqual(DiffEditCycler.editStops(added: [6, 7], removed: [5, 8]), [5])
    }

    func testInterleavedRunsAcrossBothSides() {
        // removed 5, added 10, removed 11, added 30 → runs at 5, 10-11, 30.
        XCTAssertEqual(DiffEditCycler.editStops(added: [10, 30], removed: [5, 11]), [5, 10, 30])
    }

    func testNextMovesStrictlyBelow() {
        let stops = [5, 10, 30]
        XCTAssertEqual(DiffEditCycler.next(after: 5, stops: stops), 10)
        XCTAssertEqual(DiffEditCycler.next(after: 9, stops: stops), 10)
        XCTAssertEqual(DiffEditCycler.next(after: 30, stops: stops), nil)
        XCTAssertEqual(DiffEditCycler.next(after: 1, stops: stops), 5)
    }

    func testPreviousMovesStrictlyAbove() {
        let stops = [5, 10, 30]
        XCTAssertEqual(DiffEditCycler.previous(before: 10, stops: stops), 5)
        XCTAssertEqual(DiffEditCycler.previous(before: 11, stops: stops), 10)
        XCTAssertEqual(DiffEditCycler.previous(before: 5, stops: stops), nil)
        XCTAssertEqual(DiffEditCycler.previous(before: 100, stops: stops), 30)
    }
}

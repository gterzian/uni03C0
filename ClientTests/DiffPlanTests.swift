import XCTest
@testable import Core

/// The Changes viewer's pure layout math (`DiffPlan`): a file's changed lines
/// become a handful of hunks plus context with one expand control per hidden
/// gap, instead of one run spanning first change to last. These pin the
/// arithmetic that keeps the viewer from rendering a whole file whose changes
/// sit far apart.
final class DiffPlanTests: XCTestCase {
    private func lines(_ items: [DiffRenderItem]) -> [ClosedRange<Int>] {
        items.compactMap { if case .lines(let range) = $0 { return range } else { return nil } }
    }

    private func expands(_ items: [DiffRenderItem]) -> [(gap: Int, hidden: Int)] {
        items.compactMap { if case .expand(let gap, let hidden) = $0 { return (gap, hidden) } else { return nil } }
    }

    func testFarApartChangesCollapseToHunksAndControls() {
        // 100 lines, changes at display lines 10 and 90 (1-based).
        let items = DiffPlan.renderItems(added: [10, 90], removed: [], count: 100, expansion: [:])
        XCTAssertEqual(lines(items), [6...12, 86...92])
        XCTAssertEqual(expands(items).map(\.gap), [0, 13, 93])
        XCTAssertEqual(expands(items).map(\.hidden), [6, 73, 7])
        // The controls bracket the hunks in document order.
        XCTAssertEqual(items.count, 5)
        if case .expand(let gap, _) = items[0] { XCTAssertEqual(gap, 0) } else { XCTFail() }
        if case .lines = items[1] {} else { XCTFail() }
        if case .expand(let gap, _) = items[2] { XCTAssertEqual(gap, 13) } else { XCTFail() }
        if case .lines = items[3] {} else { XCTFail() }
        if case .expand(let gap, _) = items[4] { XCTAssertEqual(gap, 93) } else { XCTFail() }
    }

    func testAdjacentChangedLinesFormOneRun() {
        let items = DiffPlan.renderItems(added: [10, 11], removed: [12], count: 100, expansion: [:])
        XCTAssertEqual(lines(items).first, 6...14)
    }

    func testHugeRunIsInitiallyCapped() {
        // A new 1000-line file: the whole file is added, but only the cap opens.
        let added = Array(1...1000)
        let items = DiffPlan.renderItems(added: added, removed: [], count: 1000, expansion: [:])
        XCTAssertEqual(lines(items), [0...79])
        XCTAssertEqual(expands(items).map(\.gap), [80])
        XCTAssertEqual(expands(items).map(\.hidden), [920])
    }

    func testExpansionRevealsHalfFromEachEdge() {
        let base = DiffPlan.renderItems(added: [10, 90], removed: [], count: 100, expansion: [:])
        let middleGap = expands(base).first { $0.gap == 13 }!.gap
        let revealed = DiffPlan.renderItems(added: [10, 90], removed: [], count: 100, expansion: [middleGap: 40])
        XCTAssertEqual(lines(revealed), [6...32, 66...92],
                       "40 revealed lines split 20 from the gap's top and 20 from its bottom")
        XCTAssertEqual(expands(revealed).map(\.gap), [0, middleGap, 93],
                       "the control keeps the ORIGINAL gap id while its lines move")
        XCTAssertEqual(expands(revealed).map(\.hidden), [6, 33, 7])
    }

    func testExpansionEventuallyShowsTheWholeGap() {
        let added = Array(1...1000)
        // 80 base + 40*something; 920 hidden, doubling blocks reach it quickly.
        var expansion: DiffPlan.Expansion = [:]
        var current = DiffPlan.renderItems(added: added, removed: [], count: 1000, expansion: expansion)
        var revealed = 0
        for _ in 0..<12 {
            guard let gap = expands(current).first?.gap else { break }
            revealed = DiffPlan.nextBlock(revealed)
            expansion[gap] = revealed
            current = DiffPlan.renderItems(added: added, removed: [], count: 1000, expansion: expansion)
        }
        XCTAssertTrue(expands(current).isEmpty, "the gap is fully revealed and its control is gone")
        XCTAssertEqual(lines(current), [0...999])
    }

    func testFarApartChangesDoNotRenderTheUnchangedMiddle() {
        let items = DiffPlan.renderItems(added: [2, 5000], removed: [], count: 6000, expansion: [:])
        let rendered = lines(items).reduce(0) { $0 + DiffPlan.gapLength($1) }
        XCTAssertLessThan(rendered, 40, "only the hunks plus context render, not 6000 lines")
    }

    func testNextBlockCompoundsAndCaps() {
        XCTAssertEqual(DiffPlan.nextBlock(0), 40)
        XCTAssertEqual(DiffPlan.nextBlock(40), 80)
        XCTAssertEqual(DiffPlan.nextBlock(80), 160)
        XCTAssertEqual(DiffPlan.nextBlock(4000), 4000)
    }
}

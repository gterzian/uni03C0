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
        // 100 lines, changes at display lines 10 and 90 (1-based). The head and
        // tail gaps are under `minCollapsedGap`, so they render inline; only the
        // large middle gap collapses.
        let items = DiffPlan.renderItems(added: [10, 90], removed: [], count: 100, expansion: [:])
        XCTAssertEqual(lines(items), [0...12, 86...99])
        XCTAssertEqual(expands(items).map(\.gap), [13])
        XCTAssertEqual(expands(items).map(\.hidden), [73])
        XCTAssertEqual(items.count, 3)
        if case .lines = items[0] {} else { XCTFail() }
        if case .expand(let gap, _) = items[1] { XCTAssertEqual(gap, 13) } else { XCTFail() }
        if case .lines = items[2] {} else { XCTFail() }
    }

    func testGapsUnderMinCollapsedGapShowInline() {
        // A 16-line head gap still collapses, but a 7-line tail gap does not.
        let accepted = DiffPlan.renderItems(added: [20], removed: [], count: 30, expansion: [:])
        XCTAssertEqual(lines(accepted), [16...29])
        XCTAssertEqual(expands(accepted).map(\.gap), [0])
        XCTAssertEqual(expands(accepted).map(\.hidden), [16])

        // Change near the top: the 1-line head gap shows inline, the tail collapses.
        let head = DiffPlan.renderItems(added: [5], removed: [], count: 30, expansion: [:])
        XCTAssertEqual(lines(head), [0...7])
        XCTAssertEqual(expands(head).map(\.gap), [8])
        XCTAssertEqual(expands(head).map(\.hidden), [22])
    }

    func testAdjacentChangedLinesFormOneRun() {
        let items = DiffPlan.renderItems(added: [10, 11], removed: [12], count: 100, expansion: [:])
        // 6...14 is the run plus context; the 6-line head gap is under the
        // collapse threshold, so the whole head renders too.
        XCTAssertEqual(lines(items).first, 0...14)
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
        XCTAssertEqual(lines(revealed), [0...32, 66...99],
                       "40 revealed lines split 20 from the gap's top and 20 from its bottom")
        XCTAssertEqual(expands(revealed).map(\.gap), [middleGap],
                       "the control keeps the ORIGINAL gap id while its lines move")
        XCTAssertEqual(expands(revealed).map(\.hidden), [33])
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

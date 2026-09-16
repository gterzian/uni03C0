import XCTest
@testable import Core

/// Unit tests for `TextDiff.hunks` — the pure hunk splitter behind the Changes
/// page's GitHub-style diff. No LLM, no pi process: pure strings → hunks.
final class DiffHunkTests: XCTestCase {

    private func lines(_ hunks: [TextDiff.Hunk]) -> [[String]] {
        hunks.map { $0.lines.map(\.text) }
    }

    private func kinds(_ hunks: [TextDiff.Hunk]) -> [[DiffLineKind]] {
        hunks.map { $0.lines.map(\.kind) }
    }

    // MARK: - One change

    func testSingleChangeProducesOneHunkWithContext() {
        let old = "a\nb\nc\nd\ne\nf\ng\nh\ni"
        let new = "a\nb\nc\nd\nE\nf\ng\nh\ni"
        let hunks = TextDiff.hunks(old: old, new: new, context: 1)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(lines(hunks), [["d", "e", "E", "f"]])
        XCTAssertEqual(kinds(hunks), [[.same, .removed, .added, .same]])
        // Header: one line of context before (d) and after (f); on both sides
        // the run starts at line 4 and covers three lines.
        XCTAssertEqual(hunks[0].oldStart, 4)
        XCTAssertEqual(hunks[0].oldCount, 3)
        XCTAssertEqual(hunks[0].newStart, 4)
        XCTAssertEqual(hunks[0].newCount, 3)
    }

    func testContextIsClampedAtFileEdges() {
        let old = "a\nb\nc"
        let new = "A\nb\nc"
        let hunks = TextDiff.hunks(old: old, new: new, context: 3)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(lines(hunks), [["a", "A", "b", "c"]])
        XCTAssertEqual(hunks[0].oldStart, 1)
        XCTAssertEqual(hunks[0].oldCount, 3)
        XCTAssertEqual(hunks[0].newStart, 1)
        XCTAssertEqual(hunks[0].newCount, 3)
    }

    // MARK: - Hunk splitting

    func testDistantChangesSplitIntoTwoHunks() {
        let old = (1...15).map { "L\($0)" }.joined(separator: "\n")
        var new = (1...15).map { "L\($0)" }
        new[2] = "X"   // line 3
        new[12] = "Y"  // line 13
        let hunks = TextDiff.hunks(old: old, new: new.joined(separator: "\n"), context: 3)
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(lines(hunks)[0], ["L1", "L2", "L3", "X", "L4", "L5", "L6"])
        XCTAssertEqual(lines(hunks)[1], ["L10", "L11", "L12", "L13", "Y", "L14", "L15"])
        XCTAssertEqual(hunks[0].oldStart, 1)
        XCTAssertEqual(hunks[0].oldCount, 6)
        XCTAssertEqual(hunks[1].oldStart, 10)
        XCTAssertEqual(hunks[1].oldCount, 6)
    }

    func testNearbyChangesMergeIntoOneHunk() {
        // Two changes two lines apart: with context 3 their expanded runs
        // overlap, so they are a single hunk.
        let old = "a\nb\nc\nd\ne\nf\ng"
        let new = "a\nB\nc\nd\nE\nf\ng"
        let hunks = TextDiff.hunks(old: old, new: new, context: 3)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(TextDiff.hunks(old: old, new: new, context: 1).count, 1)
    }

    // MARK: - Insertions and deletions

    func testPureInsertionHunkHasZeroOldCount() {
        let old = "a\nb"
        let new = "a\nx\ny\nb"
        let hunks = TextDiff.hunks(old: old, new: new, context: 1)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(lines(hunks), [["a", "x", "y", "b"]])
        XCTAssertEqual(hunks[0].oldStart, 1)
        XCTAssertEqual(hunks[0].oldCount, 2)
        XCTAssertEqual(hunks[0].newCount, 4)
    }

    func testPureDeletionHunkHasZeroNewCount() {
        let old = "a\nx\ny\nb"
        let new = "a\nb"
        let hunks = TextDiff.hunks(old: old, new: new, context: 1)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(lines(hunks), [["a", "x", "y", "b"]])
        XCTAssertEqual(hunks[0].oldCount, 4)
        XCTAssertEqual(hunks[0].newCount, 2)
    }

    // MARK: - Line numbering

    func testHunkLinesCarryOldAndNewLineNumbers() {
        let old = "one\ntwo\nthree\nfour\nfive"
        let new = "one\nTWO\nthree\nfour\nfive"
        let hunks = TextDiff.hunks(old: old, new: new, context: 1)
        let hunk = try! XCTUnwrap(hunks.first)
        // one (1/1), two (2/–), TWO (–/2), three (3/3).
        XCTAssertEqual(hunk.lines.map(\.oldLine), [1, 2, nil, 3])
        XCTAssertEqual(hunk.lines.map(\.newLine), [1, nil, 2, 3])
    }

    // MARK: - Trivial

    func testNoChangesProducesNoHunks() {
        XCTAssertTrue(TextDiff.hunks(old: "a\nb", new: "a\nb").isEmpty)
    }

    func testEmptyOldIsOneAllAddedHunk() {
        let hunks = TextDiff.hunks(old: "", new: "a\nb")
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(kinds(hunks), [[.added, .added]])
        XCTAssertEqual(hunks[0].oldCount, 0)
        XCTAssertEqual(hunks[0].newCount, 2)
    }
}

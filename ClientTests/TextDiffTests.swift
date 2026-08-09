import XCTest
@testable import Core

/// Unit tests for `TextDiff` — the pure line diff behind the edit-tool card's
/// red/green view. No LLM, no pi process: pure string → [DiffLine].
final class TextDiffTests: XCTestCase {

    private func kinds(_ lines: [DiffLine]) -> [DiffLineKind] {
        lines.map(\.kind)
    }

    private func texts(_ lines: [DiffLine]) -> [String] {
        lines.map(\.text)
    }

    // MARK: - Trivial cases

    func testIdenticalTextsAreAllSame() {
        let old = "one\ntwo\nthree"
        let diff = TextDiff.diff(old: old, new: old)
        XCTAssertEqual(kinds(diff), [.same, .same, .same])
        XCTAssertEqual(texts(diff), ["one", "two", "three"])
    }

    func testEmptyOldIsAllAdded() {
        let diff = TextDiff.diff(old: "", new: "a\nb")
        XCTAssertEqual(kinds(diff), [.added, .added])
        XCTAssertEqual(texts(diff), ["a", "b"])
    }

    func testEmptyNewIsAllRemoved() {
        let diff = TextDiff.diff(old: "a\nb", new: "")
        XCTAssertEqual(kinds(diff), [.removed, .removed])
        XCTAssertEqual(texts(diff), ["a", "b"])
    }

    func testBothEmptyIsEmpty() {
        XCTAssertEqual(TextDiff.diff(old: "", new: ""), [])
    }

    // MARK: - Add / remove / replace

    func testPureAdditionAppendsAfterContext() {
        let diff = TextDiff.diff(old: "a\nb", new: "a\nb\nc")
        XCTAssertEqual(kinds(diff), [.same, .same, .added])
        XCTAssertEqual(texts(diff), ["a", "b", "c"])
    }

    func testPureRemovalDropsLines() {
        let diff = TextDiff.diff(old: "a\nb\nc", new: "a\nc")
        // Common prefix "a", common suffix "c", middle removes "b".
        XCTAssertEqual(kinds(diff), [.same, .removed, .same])
        XCTAssertEqual(texts(diff), ["a", "b", "c"])
    }

    func testReplacementIsRemovedThenAdded() {
        // GitHub order: removed lines first, then added lines.
        let diff = TextDiff.diff(old: "a\nold\nc", new: "a\nnew\nc")
        XCTAssertEqual(kinds(diff), [.same, .removed, .added, .same])
        XCTAssertEqual(texts(diff), ["a", "old", "new", "c"])
    }

    func testMultipleHunksKeepContextSeparate() {
        let old = "1\n2\n3\n4\n5\n6\n7\n8\n9"
        let new = "1\nX\n3\n4\n5\n6\n7\nY\n9"
        let diff = TextDiff.diff(old: old, new: new)
        XCTAssertEqual(kinds(diff), [.same, .removed, .added, .same, .same, .same, .same, .same, .removed, .added, .same])
    }

    // MARK: - Line splitting

    func testTrailingNewlineIsNotALine() {
        // "a\n" and "a" diff to a single same line, not an added empty line.
        let diff = TextDiff.diff(old: "a\n", new: "a")
        XCTAssertEqual(diff, [DiffLine(kind: .same, text: "a")])
    }

    func testCRLFStrippedSoWindowsFilesDiffAgainstLF() {
        let diff = TextDiff.diff(old: "a\r\nb\r\n", new: "a\nb")
        XCTAssertEqual(diff, [DiffLine(kind: .same, text: "a"), DiffLine(kind: .same, text: "b")])
    }

    func testBlankLinesAreDiffable() {
        let diff = TextDiff.diff(old: "a\n\nb", new: "a\nx\nb")
        XCTAssertEqual(kinds(diff), [.same, .removed, .added, .same])
        XCTAssertEqual(texts(diff), ["a", "", "x", "b"])
    }

    func testLinesOfEmptyAndWhitespace() {
        XCTAssertEqual(TextDiff.lines(of: ""), [])
        XCTAssertEqual(TextDiff.lines(of: "a\n"), ["a"])
        XCTAssertEqual(TextDiff.lines(of: "\n"), [""])
        XCTAssertEqual(TextDiff.lines(of: "a\r\nb\r\n"), ["a", "b"])
    }

    // MARK: - LCS behavior

    func testMiddleInsertionBetweenIdenticalEdges() {
        // Everything except the insertion is common prefix/suffix.
        let diff = TextDiff.diff(old: "a\nb\nc", new: "a\nb\nX\nc")
        XCTAssertEqual(kinds(diff), [.same, .same, .added, .same])
    }

    func testShiftedBlockRecognizesUnchangedLines() {
        // A block inserted in the middle: the trailing lines are the common
        // suffix even though their positions shifted.
        let diff = TextDiff.diff(old: "one\ntwo\nthree\nfour", new: "one\ntwo\n2.5\nthree\nfour")
        XCTAssertEqual(kinds(diff), [.same, .same, .added, .same, .same])
    }

    func testDuplicateLinesAlignToFirstOccurrence() {
        // LCS keeps the earliest alignment; "dup" exists in both so it is
        // context, and the extra "dup" in new is an addition.
        let diff = TextDiff.diff(old: "dup\nx", new: "dup\ndup\nx")
        XCTAssertEqual(kinds(diff), [.same, .added, .same])
        XCTAssertEqual(texts(diff), ["dup", "dup", "x"])
    }

    // MARK: - Size guard

    func testHugeMismatchedInputFallsBackToWholeBlockReplace() {
        // All lines differ → no common prefix/suffix → the middle exceeds the
        // LCS cap → whole-block replace (all removed, then all added). This
        // must stay correct (same line multiset) and bounded.
        let old = (0..<3_000).map { "old-\($0)" }
        let new = (0..<3_000).map { "new-\($0)" }
        let diff = TextDiff.diff(oldLines: old, newLines: new)
        XCTAssertEqual(diff.count, 6_000)
        XCTAssertEqual(Array(kinds(diff).prefix(3_000)), Array(repeating: DiffLineKind.removed, count: 3_000))
        XCTAssertEqual(Array(kinds(diff).suffix(3_000)), Array(repeating: DiffLineKind.added, count: 3_000))
    }

    func testHugeInputWithCommonSuffixStillTrimmed() {
        // A huge middle but a shared tail: the suffix trim shrinks the middle
        // below the cap, so the LCS runs and the shared tail stays context.
        let shared = (0..<50).map { "tail-\($0)" }
        let old = (0..<2_500).map { "old-\($0)" } + shared
        let new = (0..<2_500).map { "new-\($0)" } + shared
        let diff = TextDiff.diff(oldLines: old, newLines: new)
        XCTAssertEqual(Array(diff.suffix(50)), shared.map { DiffLine(kind: .same, text: $0) })
    }
}

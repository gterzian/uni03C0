import XCTest
@testable import Core

/// Pure parsing/classification in `GitStatus` — porcelain line decoding,
/// C-style unquoting of unusual paths, and the XY-code → status mapping.
/// No git subprocess, no filesystem: everything here is a pure function of
/// documented `git status --porcelain=v1` output shapes.
final class GitStatusParsingTests: XCTestCase {
    // MARK: - parsePorcelainLine

    func testPlainModifiedLine() {
        let parsed = GitStatus.parsePorcelainLine(" M foo.swift")
        XCTAssertEqual(parsed?.code, " M")
        XCTAssertEqual(parsed?.path, "foo.swift")
    }

    func testUntrackedLine() {
        let parsed = GitStatus.parsePorcelainLine("?? notes.txt")
        XCTAssertEqual(parsed?.code, "??")
        XCTAssertEqual(parsed?.path, "notes.txt")
    }

    func testPathWithSpacesIsKeptVerbatim() {
        // Spaces are not quoted in porcelain v1 — the whole remainder is the
        // path, including interior and trailing spaces.
        let parsed = GitStatus.parsePorcelainLine(" M Sources/My File.swift")
        XCTAssertEqual(parsed?.path, "Sources/My File.swift")
    }

    func testQuotedPathWithControlCharacterIsUnquoted() {
        // A path containing a tab is C-style quoted: `"a\tb"`.
        let parsed = GitStatus.parsePorcelainLine(" M \"a\\tb\"")
        XCTAssertEqual(parsed?.code, " M")
        XCTAssertEqual(parsed?.path, "a\tb")
    }

    func testQuotedPathWithBackslashAndQuoteIsUnquoted() {
        // A path containing a quote and a backslash: `"a\"b\\c"`.
        let parsed = GitStatus.parsePorcelainLine("?? \"a\\\"b\\\\c\"")
        XCTAssertEqual(parsed?.code, "??")
        XCTAssertEqual(parsed?.path, "a\"b\\c")
    }

    func testBranchHeaderLineParsesToNil() {
        XCTAssertNil(GitStatus.parsePorcelainLine("## main...origin/main"))
    }

    func testTooShortLineParsesToNil() {
        XCTAssertNil(GitStatus.parsePorcelainLine(" M"))
        XCTAssertNil(GitStatus.parsePorcelainLine(""))
    }

    // MARK: - statusClass

    func testStatusClassMapping() {
        XCTAssertEqual(GitStatus.statusClass(forPorcelainCode: "??"), .untracked)
        XCTAssertEqual(GitStatus.statusClass(forPorcelainCode: " M"), .modified)
        XCTAssertEqual(GitStatus.statusClass(forPorcelainCode: "M "), .modified)
        XCTAssertEqual(GitStatus.statusClass(forPorcelainCode: "MM"), .modified)
        XCTAssertEqual(GitStatus.statusClass(forPorcelainCode: "A "), .added)
        XCTAssertEqual(GitStatus.statusClass(forPorcelainCode: "AM"), .added)
        XCTAssertEqual(GitStatus.statusClass(forPorcelainCode: " D"), .deleted)
        XCTAssertEqual(GitStatus.statusClass(forPorcelainCode: "D "), .deleted)
        // A rename code has no A/D/?? — it is treated as a modification.
        XCTAssertEqual(GitStatus.statusClass(forPorcelainCode: "R "), .modified)
    }

    // MARK: - parseNumstatRecord (the `git diff -z --numstat` wire format)

    func testNumstatRecordParsesCountsAndRawPath() {
        let parsed = GitStatus.parseNumstatRecord("12\t7\tSources/Foo.swift")
        XCTAssertEqual(parsed?.path, "Sources/Foo.swift")
        XCTAssertEqual(parsed?.stats, GitStatus.DiffStats(added: 12, deleted: 7))
    }

    func testNumstatRecordKeepsPathContainingTabsVerbatim() {
        // The -z form never C-style-quotes paths; a tab inside a path is the
        // raw remainder of the record after the two counter fields.
        let parsed = GitStatus.parseNumstatRecord("1\t2\ta\tb.swift")
        XCTAssertEqual(parsed?.path, "a\tb.swift")
        XCTAssertEqual(parsed?.stats, GitStatus.DiffStats(added: 1, deleted: 2))
    }

    func testNumstatZeroCountersParse() {
        // A pure mode/whitespace-change record can carry 0/0; it still parses
        // (the view treats a zero total as uncolored).
        let parsed = GitStatus.parseNumstatRecord("0\t0\tmode.sh")
        XCTAssertEqual(parsed?.path, "mode.sh")
        XCTAssertEqual(parsed?.stats, GitStatus.DiffStats(added: 0, deleted: 0))
    }

    func testNumstatBinaryCountersAreNil() {
        // Binary diffs report "-" counters, which don't read as integers.
        XCTAssertNil(GitStatus.parseNumstatRecord("-\t-\tblob.bin"))
        XCTAssertNil(GitStatus.parseNumstatRecord("-\t12\tblob.bin"))
    }

    func testNumstatGarbageIsNil() {
        XCTAssertNil(GitStatus.parseNumstatRecord(""))
        XCTAssertNil(GitStatus.parseNumstatRecord("not a numstat record"))
        XCTAssertNil(GitStatus.parseNumstatRecord("1\t2"))
    }

    // MARK: - totalStats (the changeset's aggregate +/−)

    func testTotalStatsSumsCountableEntries() {
        let entries = [
            GitStatus.FileEntry(path: "a.swift", kind: .modified, stats: GitStatus.DiffStats(added: 10, deleted: 2)),
            GitStatus.FileEntry(path: "b.swift", kind: .added, stats: GitStatus.DiffStats(added: 5, deleted: 0)),
            GitStatus.FileEntry(path: "c.swift", kind: .modified, stats: GitStatus.DiffStats(added: 0, deleted: 7))
        ]
        XCTAssertEqual(GitStatus.totalStats(of: entries), GitStatus.DiffStats(added: 15, deleted: 9))
    }

    func testTotalStatsSkipsUncountableEntries() {
        // Untracked, binary, and normal entries carry no stats and add nothing.
        let entries = [
            GitStatus.FileEntry(path: "new.txt", kind: .untracked),
            GitStatus.FileEntry(path: "blob.bin", kind: .modified),
            GitStatus.FileEntry(path: "unchanged.swift", kind: .normal),
            GitStatus.FileEntry(path: "real.swift", kind: .modified, stats: GitStatus.DiffStats(added: 3, deleted: 4))
        ]
        XCTAssertEqual(GitStatus.totalStats(of: entries), GitStatus.DiffStats(added: 3, deleted: 4))
    }

    func testTotalStatsNilWhenNothingCountable() {
        XCTAssertNil(GitStatus.totalStats(of: []))
        XCTAssertNil(GitStatus.totalStats(of: [
            GitStatus.FileEntry(path: "new.txt", kind: .untracked)
        ]))
    }

    func testTotalStatsKeepsZeroTotalDistinctFromNil() {
        // A countable but unchanged record still yields a value (0/0), which
        // the view hides (it shows the summary only when the total is > 0).
        let entries = [GitStatus.FileEntry(path: "mode.sh", kind: .modified, stats: GitStatus.DiffStats(added: 0, deleted: 0))]
        XCTAssertEqual(GitStatus.totalStats(of: entries), GitStatus.DiffStats(added: 0, deleted: 0))
        XCTAssertEqual(GitStatus.totalStats(of: entries)?.total, 0)
    }

    // MARK: - parseNameStatusZ (the `git diff -z --name-status` wire format)

    func testNameStatusRecordsParseStatusAndRawPath() {
        let records = GitStatus.parseNameStatusZ("M\0a.swift\0A\0b\tc.swift\0D\0gone.swift\0")
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].code, "M")
        XCTAssertEqual(records[0].path, "a.swift")
        XCTAssertEqual(records[1].code, "A")
        // -z never quotes, so a tab in the path is raw.
        XCTAssertEqual(records[1].path, "b\tc.swift")
        XCTAssertEqual(records[2].code, "D")
        XCTAssertEqual(records[2].path, "gone.swift")
    }

    func testNameStatusEmptyIsEmpty() {
        XCTAssertTrue(GitStatus.parseNameStatusZ("").isEmpty)
    }

    func testNameStatusMissingTrailingNulStillParses() {
        let records = GitStatus.parseNameStatusZ("M\0a.swift")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].code, "M")
        XCTAssertEqual(records[0].path, "a.swift")
    }
}

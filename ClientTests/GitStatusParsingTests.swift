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
}

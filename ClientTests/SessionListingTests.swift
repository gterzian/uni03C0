import XCTest
@testable import Core

/// Tests for `SessionListing`'s path encoding (the mapping between a project
/// folder and pi's session directory). Pure string logic; no session files are
/// touched.
final class SessionListingTests: XCTestCase {

    func testSessionDirectoryEncoding() {
        let cwd = URL(fileURLWithPath: "/Users/Gregory/Projects/pi_native")
        let dir = SessionListing.sessionsDirectory(for: cwd)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            dir.path,
            home + "/.pi/agent/sessions/--Users-Gregory-Projects-pi_native--"
        )
    }

    func testNestedPathEncodesWithSingleLeadingDash() {
        // The leading "/" is stripped first, so a two-segment path encodes
        // to --a-b-- (exactly two leading dashes), never ---a-b--.
        let cwd = URL(fileURLWithPath: "/a/b")
        let dir = SessionListing.sessionsDirectory(for: cwd)
        XCTAssertTrue(dir.lastPathComponent == "--a-b--", "got \(dir.lastPathComponent)")
    }

    func testSessionsInDifferentFoldersDiffer() {
        let a = SessionListing.sessionsDirectory(for: URL(fileURLWithPath: "/tmp/a"))
        let b = SessionListing.sessionsDirectory(for: URL(fileURLWithPath: "/tmp/b"))
        XCTAssertNotEqual(a.path, b.path)
    }

    func testSameFolderIsStable() {
        let cwd = URL(fileURLWithPath: "/tmp/a")
        XCTAssertEqual(
            SessionListing.sessionsDirectory(for: cwd).path,
            SessionListing.sessionsDirectory(for: cwd).path
        )
    }
}

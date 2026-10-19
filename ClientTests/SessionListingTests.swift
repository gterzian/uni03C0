import XCTest
@testable import Core

/// Tests for `SessionListing`'s path encoding (the mapping between a project
/// folder and pi's session directory). Pure string logic; no session files are
/// touched.
final class SessionListingTests: XCTestCase {

    func testSessionDirectoryEncoding() {
        let cwd = URL(fileURLWithPath: "/Users/tester/Projects/pi_native")
        let dir = SessionListing.sessionsDirectory(for: cwd)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            dir.path,
            home + "/.pi/agent/sessions/--Users-tester-Projects-pi_native--"
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

/// Tests for the session-file title peek, using real pi session JSONL shapes
/// (pi 1.3): a `session` header, an optional `session_info` name entry, then
/// message entries.
final class SessionListingSummaryTests: XCTestCase {

    private func writeSession(_ lines: [String], id: String = "01a15275-e40b-75ac-acfb-f82e6b965f5b") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-listing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("2026-10-19T04-40-20-235Z_\(id).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private let header = #"{"type":"session","version":3,"id":"01a15275-e40b-75ac-acfb-f82e6b965f5b","timestamp":"2026-10-19T04:40:20.235Z","cwd":"/tmp/project"}"#
    private let userMessage = #"{"type":"message","id":"m1","parentId":null,"timestamp":"2026-10-19T04:40:21.000Z","message":{"role":"user","content":[{"type":"text","text":"First prompt"}],"timestamp":1792384821000}}"#

    func testSessionInfoNameIsTheTitle() throws {
        let nameEntry = #"{"type":"session_info","id":"f080b4e1","parentId":null,"timestamp":"2026-10-19T04:40:20.268Z","name":"my named smoke"}"#
        let file = try writeSession([header, nameEntry, userMessage])
        XCTAssertEqual(SessionListing.summarize(file).title, "my named smoke")
    }

    func testFirstUserMessageIsTheFallbackTitle() throws {
        let file = try writeSession([header, userMessage])
        XCTAssertEqual(SessionListing.summarize(file).title, "First prompt")
    }

    func testHeaderSuppliesIdAndTimestamp() throws {
        let file = try writeSession([header, userMessage])
        let summary = SessionListing.summarize(file)
        XCTAssertEqual(summary.id, "01a15275-e40b-75ac-acfb-f82e6b965f5b")
        XCTAssertNotEqual(summary.timestamp, .distantPast)
    }
}

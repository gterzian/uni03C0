import XCTest
@testable import Core

/// Tests for `PathCompletion` against a real (isolated) temp directory. No
/// LLM, no pi process — pure filesystem + string logic.
final class PathCompletionTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-pathcompletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // A few files and subdirectories to complete against.
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try "print(\"hi\")\n".write(to: tempDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "".write(to: tempDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCompletesRelativeFragmentAgainstCwd() {
        let results = PathCompletion.candidates(for: "m", cwd: tempDir)
        XCTAssertEqual(results, ["main.swift"])
    }

    func testCompletesDirectoryWithTrailingSlash() {
        let results = PathCompletion.candidates(for: "S", cwd: tempDir)
        XCTAssertEqual(results, ["Sources/"])
    }

    func testPartialNameCompletion() {
        let results = PathCompletion.candidates(for: "REA", cwd: tempDir)
        XCTAssertEqual(results, ["README.md"])
    }

    func testSkipsDotfilesUnlessFragmentStartsWithDot() {
        XCTAssertTrue(PathCompletion.candidates(for: "h", cwd: tempDir).isEmpty)
        let dotResults = PathCompletion.candidates(for: ".h", cwd: tempDir)
        XCTAssertEqual(dotResults, [".hidden/"])
    }

    func testCompletesPathWithDirectoryComponent() {
        let results = PathCompletion.candidates(for: "Sources/", cwd: tempDir)
        // Listing the Sources directory's (empty) contents yields nothing.
        XCTAssertEqual(results, [])
    }

    func testTrailingSlashKeepsDirectoryPrefix() throws {
        try "".write(to: tempDir.appendingPathComponent("Sources/PathCompletion.swift"), atomically: true, encoding: .utf8)
        // Regression: a trailing-slash fragment used to lose its directory
        // prefix (deletingLastPathComponent returns "" for "Sources/"),
        // emitting "/PathCompletion.swift" — committing that replaced the
        // whole token with only the last path component.
        let results = PathCompletion.candidates(for: "Sources/", cwd: tempDir)
        XCTAssertEqual(results, ["Sources/PathCompletion.swift"])
    }

    func testTrailingSlashWithPartialKeepsDirectoryPrefix() throws {
        try "".write(to: tempDir.appendingPathComponent("Sources/PathCompletion.swift"), atomically: true, encoding: .utf8)
        let results = PathCompletion.candidates(for: "Sources/PathCom", cwd: tempDir)
        XCTAssertEqual(results, ["Sources/PathCompletion.swift"])
    }

    func testNoMatchYieldsEmpty() {
        XCTAssertEqual(PathCompletion.candidates(for: "zzz", cwd: tempDir), [])
    }

    func testAbsoluteFragmentCompletesAgainstAbsoluteBase() {
        let results = PathCompletion.candidates(for: tempDir.path + "/m", cwd: tempDir)
        XCTAssertEqual(results, [tempDir.path + "/main.swift"])
    }

    func testIsPathLike() {
        XCTAssertTrue(PathCompletion.isPathLike("scratchpad"))
        XCTAssertTrue(PathCompletion.isPathLike("src/main"))
        XCTAssertTrue(PathCompletion.isPathLike("~/.pi"))
        XCTAssertTrue(PathCompletion.isPathLike(".git"))
        XCTAssertFalse(PathCompletion.isPathLike(""))
        XCTAssertFalse(PathCompletion.isPathLike("a b"))          // a space means prose, not a token
        XCTAssertFalse(PathCompletion.isPathLike("has space here"))
    }
}

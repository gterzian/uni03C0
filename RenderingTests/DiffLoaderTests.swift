import AppKit
import Core
import XCTest

/// Pins `DiffLoader` — the per-file diff behind the Changes viewer. The loader
/// is deliberately AppKit-free (pure Core + file IO), so it is exercised here
/// against a real throwaway git repository rather than through the viewer.
final class DiffLoaderTests: XCTestCase {
    // MARK: - Fixture

    private final class Repo {
        let root: URL
        let file: URL

        init() {
            let fm = FileManager.default
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("diff-loader-\(UUID().uuidString)", isDirectory: true)
            file = root.appendingPathComponent("a.txt")
            try! fm.createDirectory(at: root, withIntermediateDirectories: true)
            git(["init"])
            git(["config", "commit.gpgsign", "false"])
            git(["config", "user.email", "test@example.com"])
            git(["config", "user.name", "Test"])
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ text: String) {
            try! text.write(to: file, atomically: true, encoding: .utf8)
        }

        func git(_ args: [String]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = root
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try! process.run()
            process.waitUntilExit()
        }
    }

    /// Runs an async load to completion by pumping the run loop (the stub test
    /// runner invokes test methods synchronously).
    @MainActor
    private func load(_ repo: Repo, _ entry: GitStatus.FileEntry) -> LoadedFileDiff? {
        var result: LoadedFileDiff?
        Task { result = await DiffLoader.load(cwd: repo.root, entry: entry) }
        let deadline = Date().addingTimeInterval(3)
        while result == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return result
    }

    private func entry(_ path: String, _ kind: GitStatus.Kind) -> GitStatus.FileEntry {
        GitStatus.FileEntry(path: path, kind: kind)
    }

    // MARK: - Pure interleave

    func testInterleaveInsertsRemovedLinesInPlace() {
        let result = DiffLoader.interleaved(old: "one\ntwo\nthree\n", new: "one\nTWO\nthree\n")
        XCTAssertEqual(result.lines.map(\.text), ["one", "two", "TWO", "three"])
        XCTAssertEqual(result.lines.map(\.kind), [.same, .removed, .added, .same])
        // Removed line has no real line number; the others number 1,2,3. The
        // removed line keeps its OLD-file number for the gutter instead.
        XCTAssertEqual(result.lineNumbers, [1, nil, 2, 3])
        XCTAssertEqual(result.oldLineNumbers, [nil, 2, nil, nil])
        XCTAssertEqual(result.added, [3])
        XCTAssertEqual(result.removed, [2])
    }

    func testInterleaveOfPureAddition() {
        let result = DiffLoader.interleaved(old: "one\n", new: "one\ntwo\n")
        XCTAssertEqual(result.lines.map(\.kind), [.same, .added])
        XCTAssertEqual(result.added, [2])
        XCTAssertTrue(result.removed.isEmpty)
    }

    // MARK: - Loader against a repo

    @MainActor
    func testModifiedFileLoadsInterleavedDiff() {
        let repo = Repo()
        repo.write("a\nb\nc\nd\ne\n")
        repo.git(["add", "a.txt"])
        repo.git(["commit", "-m", "init"])
        repo.write("a\nB\nc\nd\ne\n")

        guard let diff = load(repo, entry("a.txt", .modified)) else { return XCTFail("no diff") }
        XCTAssertNil(diff.message)
        XCTAssertEqual(diff.lines.map(\.text), ["a", "b", "B", "c", "d", "e"])
        XCTAssertEqual(diff.added, [3])
        XCTAssertEqual(diff.removed, [2])
        XCTAssertEqual(diff.changeRange, 2...3)
    }

    @MainActor
    func testAddedFileIsAllAdditions() {
        let repo = Repo()
        repo.git(["init"])
        repo.git(["commit", "--allow-empty", "-m", "init"])
        repo.write("new\nfile\n")
        repo.git(["add", "a.txt"])

        guard let diff = load(repo, entry("a.txt", .added)) else { return XCTFail("no diff") }
        XCTAssertEqual(diff.lines.map(\.kind), [.added, .added])
        XCTAssertEqual(diff.added, [1, 2])
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertEqual(diff.lineNumbers, [1, 2])
    }

    @MainActor
    func testDeletedFileIsAllRemovalsFromHead() {
        let repo = Repo()
        repo.write("gone\nlines\n")
        repo.git(["add", "a.txt"])
        repo.git(["commit", "-m", "init"])
        try? FileManager.default.removeItem(at: repo.file)

        guard let diff = load(repo, entry("a.txt", .deleted)) else { return XCTFail("no diff") }
        XCTAssertEqual(diff.lines.map(\.text), ["gone", "lines"])
        XCTAssertEqual(diff.lines.map(\.kind), [.removed, .removed])
        XCTAssertEqual(diff.removed, [1, 2])
    }
}

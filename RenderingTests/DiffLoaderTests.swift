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

        @discardableResult
        func git(_ args: [String]) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = root
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            try! process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }

        /// The current `HEAD` commit, for pinning a turn baseline.
        func head() -> String {
            (git(["rev-parse", "HEAD"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Runs an async load to completion by pumping the run loop (the stub test
    /// runner invokes test methods synchronously).
    @MainActor
    private func load(_ repo: Repo, _ entry: GitStatus.FileEntry, base: String = "HEAD") -> LoadedFileDiff? {
        var result: LoadedFileDiff?
        Task { result = await DiffLoader.load(cwd: repo.root, entry: entry, base: base) }
        let deadline = Date().addingTimeInterval(3)
        while result == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return result
    }

    /// Runs `GitStatus.classify` to completion by pumping the run loop.
    @MainActor
    private func classify(_ repo: Repo, base: String) -> [GitStatus.FileEntry]? {
        var result: [GitStatus.FileEntry]?
        Task { result = await GitStatus.classify(at: repo.root, base: base) }
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

    // MARK: - Turn baseline across a mid-turn commit

    @MainActor
    func testPinnedBaseKeepsDiffAndListingAfterMidTurnCommit() {
        let repo = Repo()
        repo.write("a\nb\nc\n")
        repo.git(["add", "a.txt"])
        repo.git(["commit", "-m", "init"])
        let base = repo.head()
        XCTAssertFalse(base.isEmpty)

        // The agent edits and commits mid-turn: HEAD moves, the pinned base
        // does not — the turn's change stays reviewable.
        repo.write("a\nB\nc\n")
        repo.git(["add", "a.txt"])
        repo.git(["commit", "-m", "mid-turn"])

        guard let entries = classify(repo, base: base) else { return XCTFail("no classify") }
        let fileEntry = entries.first { $0.path == "a.txt" }
        XCTAssertEqual(fileEntry?.kind, .modified)
        XCTAssertEqual(fileEntry?.stats, GitStatus.DiffStats(added: 1, deleted: 1))

        guard let diff = load(repo, entry("a.txt", .modified), base: base) else { return XCTFail("no diff") }
        XCTAssertNil(diff.message)
        // The net turn change relative to the pinned base, not the now-clean
        // working tree.
        XCTAssertEqual(diff.lines.map(\.text), ["a", "b", "B", "c"])
        XCTAssertEqual(diff.added, [3])
        XCTAssertEqual(diff.removed, [2])

        // Sanity: the live HEAD now matches the working tree, so a live base
        // would have shown nothing — which is exactly what the pinned base
        // avoids.
        guard let headEntries = classify(repo, base: "HEAD") else { return XCTFail("no classify") }
        XCTAssertNil(headEntries.first { $0.path == "a.txt" && $0.kind != .normal })
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

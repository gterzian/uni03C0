import AppKit
import Core
import XCTest

/// Drives the Changes page's diff pane: `ReadOnlyFilePane` in `.hunks` mode
/// (only the changed regions plus context, one `@@ … @@` header per hunk,
/// still numbered by REAL file line and copying a reference to the real file).
final class ChangesPaneTests: XCTestCase {
    // MARK: - Fixture

    /// A throwaway git repo (removed on teardown) with one committed file.
    private final class Repo {
        let root: URL
        let file: URL

        init() {
            let fm = FileManager.default
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("changes-pane-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Pane driving

    @MainActor
    private func makePane() -> (container: FilePaneContainer, coordinator: ReadOnlyFilePane.Coordinator) {
        let container = FilePaneContainer(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let coordinator = ReadOnlyFilePane.Coordinator()
        coordinator.container = container
        return (container, coordinator)
    }

    @MainActor
    private func reload(
        _ coordinator: ReadOnlyFilePane.Coordinator,
        cwd: URL,
        kind: GitStatus.Kind,
        mode: ReadOnlyFilePane.LoadMode,
        token: Int = 1
    ) {
        coordinator.reload(cwd: cwd, path: "a.txt", kind: kind, token: token, mode: mode, reference: nil, onReferenceConsumed: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    // MARK: - Hunks-only buffer

    @MainActor
    func testHunkModeShowsOnlyChangedRegionsWithHeaders() {
        let repo = Repo()
        let committed = (1...20).map { "line\($0)" }.joined(separator: "\n") + "\n"
        repo.write(committed)
        repo.git(["add", "a.txt"])
        repo.git(["commit", "-m", "init"])
        var modified = (1...20).map { "line\($0)" }
        modified[2] = "CHANGED3"
        modified[14] = "CHANGED15"
        repo.write(modified.joined(separator: "\n") + "\n")

        let (container, coordinator) = makePane()
        reload(coordinator, cwd: repo.root, kind: .modified, mode: .hunks)

        let text = container.codeView.string
        XCTAssertTrue(text.contains("CHANGED3"), "the first change is shown")
        XCTAssertTrue(text.contains("CHANGED15"), "the second change is shown")
        XCTAssertTrue(text.contains("@@ -1,6 +1,6 @@"), "header for the first hunk")
        XCTAssertTrue(text.contains("@@ -12,7 +12,7 @@"), "header for the second hunk")
        XCTAssertFalse(text.contains("line7"), "the unchanged gap between hunks is not part of the buffer")
        XCTAssertFalse(text.contains("line8"), "the unchanged gap between hunks is not part of the buffer")
        XCTAssertFalse(text.contains("line11"), "the unchanged gap between hunks is not part of the buffer")
    }

    /// The hunk buffer keeps REAL current-file line numbers, so the gutter and
    /// copy-tagging still mean "line N of the real file".
    @MainActor
    func testHunkModeKeepsRealLineNumbers() {
        let repo = Repo()
        let committed = (1...20).map { "line\($0)" }.joined(separator: "\n") + "\n"
        repo.write(committed)
        repo.git(["add", "a.txt"])
        repo.git(["commit", "-m", "init"])
        var modified = (1...20).map { "line\($0)" }
        modified[2] = "CHANGED3"
        modified[14] = "CHANGED15"
        repo.write(modified.joined(separator: "\n") + "\n")

        let (container, coordinator) = makePane()
        reload(coordinator, cwd: repo.root, kind: .modified, mode: .hunks)

        let codeView = container.codeView
        let ns = codeView.string as NSString
        let changed3 = ns.range(of: "CHANGED3")
        let changed15 = ns.range(of: "CHANGED15")
        XCTAssertEqual(codeView.realLineNumber(forIndex: changed3.location), 3)
        XCTAssertEqual(codeView.realLineNumber(forIndex: changed15.location), 15)
        // The `@@` header lines carry no real line (the first hunk's header is
        // display line 1).
        XCTAssertNil(codeView.realLineNumber(forDisplayLine: 1))
    }

    /// A whole-buffer copy out of the hunk view drops the `@@` chrome and the
    /// removed (old-side) lines, and the reference points at the actual file —
    /// never at the diff buffer.
    @MainActor
    func testHunkBufferCopyReferencesTheRealFileWithoutChrome() {
        let view = ReadOnlyCodeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), textContainer: nil)
        let text = "@@ -1,2 +1,2 @@\nctx\nold\nnew\n@@ -9,2 +9,2 @@\nctx2\n"
        // Header lines and the removed `old` carry no real line.
        let map: [Int?] = [nil, 1, nil, 2, nil, 3]
        view.load(
            path: "/tmp/h.swift",
            text: NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            ]),
            lineNumbers: map
        )
        NSPasteboard.general.clearContents()
        view.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        view.copy(nil)

        guard let data = NSPasteboard.general.data(forType: .codeReference),
              let reference = try? JSONDecoder().decode(CodeReference.self, from: data) else {
            return XCTFail("expected the code-reference payload")
        }
        XCTAssertEqual(reference.absolutePath, "/tmp/h.swift")
        XCTAssertEqual(reference.startLine, 1)
        XCTAssertEqual(reference.endLine, 3)
        XCTAssertEqual(reference.snippet, "ctx\nnew\nctx2\n",
                       "the `@@` headers and the removed line are not quoted")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "ctx\nnew\nctx2\n")
    }
}

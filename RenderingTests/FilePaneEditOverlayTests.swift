import AppKit
import Core
import XCTest

/// Drives the real file-browser content pane (`ReadOnlyFilePane.Coordinator` +
/// `FilePaneContainer`) against a REAL throwaway git repository to pin the
/// edit overlay (the translucent green added-line background) — and, in
/// particular, the stale-kind reload:
///
/// a file-change notification bumps the pane reload token BEFORE the store's
/// debounced git refresh, so the reload that token triggers carries the OLD
/// git kind (clean → the pane loaded uncolored). When the refresh then lands
/// with the file now `modified`, the token is unchanged. The pane must treat
/// the kind as part of the loaded identity, or it dedupes that second reload
/// away and the file never gains its added-line coloring.
final class FilePaneEditOverlayTests: XCTestCase {
    // MARK: - Fixture

    /// A throwaway git repo (removed on teardown) with one committed file.
    private final class Repo {
        let root: URL
        let file: URL

        init() {
            let fm = FileManager.default
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pane-overlay-\(UUID().uuidString)", isDirectory: true)
            file = root.appendingPathComponent("a.txt")
            try! fm.createDirectory(at: root, withIntermediateDirectories: true)
            git(["init"])
            // The developer's global git config may sign commits; the fixture
            // must not depend on a signing key (this test runs in the app's
            // sandbox, which can't reach ~/.gnupg).
            git(["config", "commit.gpgsign", "false"])
            git(["config", "user.email", "test@example.com"])
            git(["config", "user.name", "Test"])
            write("one\ntwo\nthree\n")
            git(["add", "a.txt"])
            git(["commit", "-m", "init"])
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
        token: Int
    ) {
        coordinator.reload(cwd: cwd, path: "a.txt", kind: kind, token: token, reference: nil, onReferenceConsumed: nil)
        // The load is a main-actor Task (file IO + git off-main): spin the run
        // loop until it lands.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    /// The background attributes currently in the pane's text storage.
    @MainActor
    private func backgrounds(_ container: FilePaneContainer) -> [NSRange] {
        guard let storage = container.codeView.textStorage, storage.length > 0 else { return [] }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        return ranges
    }

    /// The added line's range in the displayed text.
    @MainActor
    private func addedLineRange(_ container: FilePaneContainer, _ line: String) -> NSRange {
        (container.codeView.string as NSString).range(of: line)
    }

    /// Whether the edit overlay (any background attribute) is painted at
    /// `location`.
    @MainActor
    private func hasOverlay(_ container: FilePaneContainer, at location: Int) -> Bool {
        guard let storage = container.codeView.textStorage,
              location >= 0, location < storage.length else { return false }
        return storage.attribute(.backgroundColor, at: location, effectiveRange: nil) != nil
    }

    /// The overlay color painted at `location` (nil when none).
    @MainActor
    private func overlayColor(_ container: FilePaneContainer, at location: Int) -> NSColor? {
        guard let storage = container.codeView.textStorage,
              location >= 0, location < storage.length else { return nil }
        return storage.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    @MainActor
    private func isRed(_ color: NSColor?) -> Bool {
        guard let rgb = color?.usingColorSpace(.deviceRGB) else { return false }
        return rgb.redComponent - rgb.greenComponent > 0.1
    }

    @MainActor
    private func isGreen(_ color: NSColor?) -> Bool {
        guard let rgb = color?.usingColorSpace(.deviceRGB) else { return false }
        return rgb.greenComponent - rgb.redComponent > 0.1
    }

    // MARK: - Tests

    @MainActor
    func testModifiedFileColorsTheAddedLine() {
        let repo = Repo()
        repo.write("one\ntwo and a half\nthree\n")
        let (container, coordinator) = makePane()
        reload(coordinator, cwd: repo.root, kind: .modified, token: 1)

        let added = addedLineRange(container, "two and a half")
        XCTAssertNotEqual(added.location, NSNotFound, "the modified file is displayed")
        XCTAssertTrue(hasOverlay(container, at: added.location),
                      "the added line carries the edit overlay")
    }

    @MainActor
    func testCleanFileHasNoOverlay() {
        let repo = Repo()
        let (container, coordinator) = makePane()
        reload(coordinator, cwd: repo.root, kind: .normal, token: 1)

        XCTAssertEqual(container.codeView.string, "one\ntwo\nthree\n")
        XCTAssertTrue(backgrounds(container).isEmpty,
                      "a committed-identical file is shown uncolored")
    }

    /// The regression: the file-change notification bumps the token while the
    /// store snapshot is still stale (the file's kind has not been recomputed
    /// yet), so the reload arrives as `.normal`; the store's debounced refresh
    /// then reclassifies the file `modified` with the SAME token. That second
    /// reload must still run, or the pane keeps the stale uncolored buffer.
    @MainActor
    func testStaleKindThenFreshKindWithSameTokenStillColors() {
        let repo = Repo()
        let (container, coordinator) = makePane()

        // Opened while clean (the user clicked the file before the agent
        // edited it): the pane shows it uncolored.
        reload(coordinator, cwd: repo.root, kind: .normal, token: 1)
        XCTAssertTrue(backgrounds(container).isEmpty)

        // The agent edits the file; the notification bumps the token but the
        // store snapshot is still stale, so the reload carries `.normal`.
        repo.write("one\ntwo and a half\nthree\n")
        reload(coordinator, cwd: repo.root, kind: .normal, token: 2)

        // The store refresh lands: now `modified`, same token.
        reload(coordinator, cwd: repo.root, kind: .modified, token: 2)

        let added = addedLineRange(container, "two and a half")
        XCTAssertNotEqual(added.location, NSNotFound, "the edited content is displayed")
        XCTAssertTrue(hasOverlay(container, at: added.location),
                      "the kind change alone (same token) re-colors the added line")
    }

    /// The reverse: a file reverted back to its committed content must lose
    /// the overlay on the kind change even though the token is unchanged.
    @MainActor
    func testKindChangeBackToNormalClearsOverlay() {
        let repo = Repo()
        repo.write("one\ntwo and a half\nthree\n")
        let (container, coordinator) = makePane()
        reload(coordinator, cwd: repo.root, kind: .modified, token: 1)
        XCTAssertFalse(backgrounds(container).isEmpty)

        repo.write("one\ntwo\nthree\n")
        reload(coordinator, cwd: repo.root, kind: .normal, token: 1)
        XCTAssertTrue(backgrounds(container).isEmpty,
                      "reverting removes the overlay at the same token")
    }

    // MARK: - Interleaved diff (added + removed lines)

    /// A substitution shows BOTH sides: the old line in red, the new line in
    /// green — the GitHub unified view.
    @MainActor
    func testSubstitutionShowsRemovedAndAddedLines() {
        let repo = Repo()
        repo.write("one\ntwo\nthree\n")
        repo.git(["add", "a.txt"])
        repo.git(["commit", "-m", "init"])
        repo.write("one\nTWO\nthree\n")
        let (container, coordinator) = makePane()
        reload(coordinator, cwd: repo.root, kind: .modified, token: 1)

        let removed = addedLineRange(container, "two")
        let added = addedLineRange(container, "TWO")
        XCTAssertNotEqual(removed.location, NSNotFound, "the old line is shown")
        XCTAssertNotEqual(added.location, NSNotFound, "the new line is shown")
        XCTAssertTrue(isRed(overlayColor(container, at: removed.location)), "the removed line renders red")
        XCTAssertTrue(isGreen(overlayColor(container, at: added.location)), "the added line renders green")
    }

    /// The gap this closed: a change that ONLY deletes lines used to render a
    /// changed tree row with a completely uncolored pane. The removed lines
    /// must be shown, in red.
    @MainActor
    func testDeletionOnlyChangeShowsTheRemovedLinesInRed() {
        let repo = Repo()
        repo.write("one\ntwo\nthree\nfour\n")
        repo.git(["add", "a.txt"])
        repo.git(["commit", "-m", "init"])
        repo.write("one\nfour\n")
        let (container, coordinator) = makePane()
        reload(coordinator, cwd: repo.root, kind: .modified, token: 1)

        for removedLine in ["two", "three"] {
            let location = addedLineRange(container, removedLine).location
            XCTAssertNotEqual(location, NSNotFound, "removed line \(removedLine) is displayed")
            XCTAssertTrue(isRed(overlayColor(container, at: location)), "removed line \(removedLine) renders red")
        }
    }

    /// The gutter/overlay keep REAL current-file line numbers through the
    /// interleaved diff: a removed line maps to nil, the lines after it keep
    /// their real numbers.
    @MainActor
    func testLineMapKeepsRealLineNumbersPastRemovals() {
        let repo = Repo()
        repo.write("one\ntwo\nthree\nfour\n")
        repo.git(["add", "a.txt"])
        repo.git(["commit", "-m", "init"])
        repo.write("one\nfour\n")
        let (container, coordinator) = makePane()
        reload(coordinator, cwd: repo.root, kind: .modified, token: 1)

        let codeView = container.codeView
        XCTAssertEqual(codeView.lineStartOffsets.count, 5, "display shows one, two, three, four + the trailing phantom line")
        // Display line 1 = real 1 (one), 2/3 = removed, 4 = real 2 (four).
        XCTAssertEqual(codeView.realLineNumber(forDisplayLine: 1), 1)
        XCTAssertNil(codeView.realLineNumber(forDisplayLine: 2), "a removed line has no real number")
        XCTAssertNil(codeView.realLineNumber(forDisplayLine: 3))
        XCTAssertEqual(codeView.realLineNumber(forDisplayLine: 4), 2)
        // A real line past the removal resolves to its display line.
        XCTAssertEqual(codeView.displayLine(forRealLine: 2), 4)
    }

    /// A reference jump into an interleaved diff still lands on the REAL line
    /// the link named: real line 2 (`four`) is display line 4 after two
    /// removed lines, and the ruler anchor marks that display line.
    @MainActor
    func testReferenceJumpMapsRealLinePastARemoval() {
        let (container, _) = makePane()
        let text = "one\ntwo\nthree\nfour\nfive\n"
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
        )
        // Display lines: 1=one(real 1), 2/3=removed, 4=four(real 2), 5=five(real 3).
        let map: [Int?] = [1, nil, nil, 2, 3]
        container.displayContent(
            path: "/tmp/a.txt",
            text: attributed,
            preserveScroll: false,
            targetLines: (2, 2),
            markers: .none,
            lineNumbers: map
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        let ruler = container.scrollView.verticalRulerView as? CodeLineRulerView
        XCTAssertEqual(ruler?.anchorLine, 4, "real line 2 resolves to display line 4")
        XCTAssertNotNil(container.codeView.revealFlashRect, "the reference range flashes")
    }
}

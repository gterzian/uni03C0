import AppKit
import Core
import Foundation
import Observation

/// The uncommitted-changes store behind the Changes page, and the model for its
/// one scrollable diff viewer. It owns the changed-file list (for the sidebar),
/// the loaded per-file diffs, and the per-file top/bottom expansion state, and
/// it does all the git + file work off the main thread.
///
/// The Changes page is gone: this is the only file/diff surface. Bodies stay thin
/// — the sidebar reads `entries`, and the viewer (an AppKit text view) rebinds
/// when `documentVersion` changes.
@MainActor
@Observable
final class ChangesStore {
    let cwd: URL

    // MARK: Changed-file list (sidebar)

    private(set) var entries: [GitStatus.FileEntry] = []
    private(set) var isLoading = true
    /// Bumped when `entries` changes.
    private(set) var listVersion = 0
    /// Bumped whenever the rendered diff document's inputs change: diffs
    /// loaded/reloaded, expansion changed, or appearance forced a re-render.
    private(set) var documentVersion = 0

    // MARK: Selection + viewer commands

    /// The file the viewer is showing (the section at the top of the viewport,
    /// kept in sync by the viewer's scroll spy). Clicking a sidebar row writes
    /// this and requests a scroll.
    var selectedPath: String?
    /// One-shot "scroll the viewer to this path's section" request. Consumed by
    /// the viewer via `consumeReveal()`.
    var revealPath: String?
    /// One-shot target line within `revealPath` (1-based real file line, the
    /// `#L…` of an agent's `pi-file` link), nil for a whole-file reveal.
    var revealLine: Int?

    /// The assembled document for `documentVersion`, from the viewer's off-main
    /// builder. The Changes page is `.id`-keyed per tab, so a tab switch
    /// remounts the viewer; re-applying this instead of rebuilding avoids the
    /// off-main rebuild, the busy spinner, and re-scanning the buffer on the
    /// main thread. Invalidated whenever a refresh advances `documentVersion`.
    @ObservationIgnored private var cachedDocument: DiffDocument?
    @ObservationIgnored private var cachedDocumentVersion = -1

    // MARK: The loaded diffs (off-main data, read by the document builder)

    @ObservationIgnored private(set) var diffs: [String: LoadedFileDiff] = [:]
    /// Per-gap reveal counters, path → (gap 0-based lower bound → lines
    /// revealed). A gap collapses to one expand control; each activation grows
    /// the counter in compounding blocks (see `DiffPlan`).
    @ObservationIgnored private var gapExpansion: [String: DiffPlan.Expansion] = [:]

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshInFlight = false
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private static let refreshSettleDelay: Duration = .milliseconds(350)
    @ObservationIgnored private var changeObserver: NSObjectProtocol?

    init(cwd: URL) {
        self.cwd = cwd
        changeObserver = NotificationCenter.default.addObserver(
            forName: GitStatus.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard (note.userInfo?["cwd"] as? URL) == cwd else { return }
            let path = note.userInfo?["path"] as? String
            MainActor.assumeIsolated {
                self.scheduleRefresh(changedPath: path)
            }
        }
    }

    func stop() {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
        refreshTask?.cancel()
        refreshTask = nil
        refreshQueued = false
    }

    // MARK: Refresh

    func scheduleRefresh(immediate: Bool = false, changedPath: String? = nil) {
        if refreshInFlight {
            refreshQueued = true
            return
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if !immediate {
                try? await Task.sleep(for: Self.refreshSettleDelay)
            }
            guard !Task.isCancelled else { return }
            await self.refresh(changedPath: changedPath)
        }
    }

    /// Re-lists the changed files, then (re)loads their diffs off the main
    /// thread. When `changedPath` names a file, only that file's diff is
    /// re-read; a nil path (a turn settled, a `git commit`) reloads them all.
    func refresh(changedPath: String? = nil) async {
        if refreshInFlight {
            refreshQueued = true
            return
        }
        refreshInFlight = true
        defer { refreshInFlight = false }
        repeat {
            refreshQueued = false
            guard !Task.isCancelled else { return }
            let cwd = self.cwd
            let all = await Task.detached(priority: .userInitiated) {
                await GitStatus.classify(at: cwd)
            }.value
            guard !Task.isCancelled else { return }
            let changed = all.filter { $0.kind != .normal }.sorted { $0.path < $1.path }
            let paths = Set(changed.map(\.path))
            let previousPaths = Set(diffs.keys)
            if entries != changed {
                entries = changed
                listVersion &+= 1
            }
            isLoading = false
            // Drop diffs for files that are no longer changed.
            diffs = diffs.filter { paths.contains($0.key) }
            gapExpansion = gapExpansion.filter { paths.contains($0.key) }

            let toLoad: [GitStatus.FileEntry]
            if let changedPath {
                // A change event naming one file: reload just that file (empty
                // when it is no longer changed). A nil path (a turn settled, a
                // `git commit`) reloads every changed file's diff.
                toLoad = changed.filter { $0.path == changedPath }
            } else {
                toLoad = changed
            }
            // Re-checking the working tree is cheap for the UI only if an
            // UNCHANGED reload is a no-op: bump `documentVersion` (and so
            // rebuild the document) only when the file set moved or a diff's
            // content actually changed. Re-opening Changes then costs no
            // highlighting, no rebuild, and no scroll jump.
            var needsRebuild = previousPaths != paths
            if !toLoad.isEmpty {
                let loaded = await self.load(changed: toLoad, cwd: cwd)
                for diff in loaded where diffs[diff.path] != diff {
                    diffs[diff.path] = diff
                    needsRebuild = true
                }
            }
            if needsRebuild {
                documentVersion &+= 1
                // The old document no longer matches its version: drop it so a
                // remount cannot re-apply stale bytes and the memory is freed.
                cachedDocument = nil
                cachedDocumentVersion = -1
            }
        } while refreshQueued
    }

    /// Loads a batch of files' diffs concurrently, bounded so a large changeset
    /// does not spawn one git process per file at once.
    private nonisolated func load(changed: [GitStatus.FileEntry], cwd: URL) async -> [LoadedFileDiff] {
        var result: [LoadedFileDiff] = []
        result.reserveCapacity(changed.count)
        let batchSize = 6
        var index = 0
        while index < changed.count {
            let batch = Array(changed[index..<min(index + batchSize, changed.count)])
            let loaded = await withTaskGroup(of: LoadedFileDiff.self) { group in
                for entry in batch {
                    group.addTask { await DiffLoader.load(cwd: cwd, entry: entry) }
                }
                var out: [LoadedFileDiff] = []
                for await diff in group { out.append(diff) }
                return out
            }
            result.append(contentsOf: loaded)
            index += batchSize
        }
        return result
    }

    // MARK: Expansion

    /// A file's rendered layout: the changed runs plus context, with the
    /// unchanged gaps between them collapsed to expand controls. Pure math in
    /// `DiffPlan`, so the builder stays color-free and the layout is testable.
    func renderItems(for diff: LoadedFileDiff) -> [DiffRenderItem] {
        DiffPlan.renderItems(
            added: diff.added,
            removed: diff.removed,
            count: diff.lines.count,
            expansion: gapExpansion[diff.path] ?? [:]
        )
    }

    /// Reveals the next compounding block of the gap starting at 0-based
    /// display index `gap`. No-ops when the gap is already fully shown, so a
    /// double click on a stale control never bumps the document version.
    func expand(path: String, gap: Int) {
        guard let diff = diffs[path] else { return }
        let current = renderItems(for: diff)
        guard current.contains(where: {
            if case .expand(let g, _) = $0 { return g == gap } else { return false }
        }) else { return }
        var map = gapExpansion[path] ?? [:]
        map[gap] = DiffPlan.nextBlock(map[gap] ?? 0)
        gapExpansion[path] = map
        documentVersion &+= 1
    }

    // MARK: Viewer commands

    /// Records the viewer's freshly built document, so a later remount of the
    /// Changes page (a tab switch) re-applies it without rebuilding.
    func cacheBuiltDocument(_ document: DiffDocument, version: Int) {
        cachedDocument = document
        cachedDocumentVersion = version
    }

    /// The cached document when it matches `version`, else nil (the viewer
    /// then builds a fresh one).
    func builtDocument(for version: Int) -> DiffDocument? {
        cachedDocumentVersion == version ? cachedDocument : nil
    }

    /// Scrolls the viewer to `path`'s section (optionally to a real file line
    /// inside it) and marks it selected.
    func reveal(_ path: String, line: Int? = nil) {
        selectedPath = path
        revealPath = path
        revealLine = line
    }

    func consumeReveal() {
        revealPath = nil
        revealLine = nil
    }

    /// The viewer's scroll spy: which file's section owns the top of the
    /// viewport. Ignores no-op updates so it never fights a click.
    func setTopSection(_ path: String?) {
        guard let path, path != selectedPath else { return }
        selectedPath = path
    }

    // MARK: - Open in another app

    /// Whether the full file exists on disk to hand to another app (a deleted
    /// file has no content to open).
    func canOpenInDefaultApp(_ path: String) -> Bool {
        entries.contains { $0.path == path && $0.kind != .deleted }
    }

    /// Opens the file's full, on-disk content in the user's default application
    /// — the diff viewer shows a window into the file, this hands the whole file
    /// to an editor. The app process is not sandboxed (the seatbelt policy wraps
    /// only agent subprocesses), so `NSWorkspace` can launch another app.
    func openInDefaultApp(_ path: String) {
        guard canOpenInDefaultApp(path) else { return }
        let url = URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL
        NSWorkspace.shared.open(url)
    }
}

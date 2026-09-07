import AppKit
import Core
import SwiftUI

/// The file browser page, nested inside a session tab (`SessionPage.files`):
/// a full, read-only file tree of the session's folder on the left (every
/// file git would consider part of the project — not just changed ones), and
/// the content pane (§2.6) for the selected file on the right. It stays in
/// sync live: one signal — `GitStatus.didChangeNotification` posted by the
/// owning `SessionTab` when the agent's `edit`/`write` tools touch a file
/// (per call) or a turn settles (path unknown) — drives the tree refresh and,
/// when the open file is the one touched, the content reload.
///
/// The view is a thin consumer of the SESSION's `FileBrowserStore` (the
/// file-side mirror of the transcript store): all file processing — git
/// listing, indexing, the whole tree build — happens off the main thread
/// inside the store, which belongs to the tab, warms up as soon as the
/// session opens, and refreshes itself whenever the agent touches files. This
/// view renders the store with a virtualized AppKit `NSTableView` over a
/// cheap, memoized flattened row list (class tree nodes, so flattening copies
/// references, never subtrees), plus the per-selection content pane. The pane
/// itself loads off-main (read + `git show` + `TextDiff`) and applies only the
/// final attributed buffer on main.
struct FileBrowserView: View {
    let store: FileBrowserStore

    /// Which directories are expanded (view state, like the transcript's
    /// materialized window). Survives refreshes because it is keyed by stable
    /// directory paths.
    @State private var expandedDirectories: Set<String> = []
    @State private var didExpandAllOnce = false
    /// Memoized flattened rows (see `rows`) — a class so body evaluations can
    /// refresh it without writing `@State` (which would re-invalidate).
    @State private var rowMemo = RowMemo()

    /// First listing auto-expands everything only up to this many files.
    /// Beyond that, a large project starts collapsed at its top level (expand
    /// folders as needed) — a giant auto-expanded tree is never a useful
    /// review surface, and keeping the default row list small bounds the
    /// flatten and the table's change detection for the life of the session.
    /// Folders containing CHANGED files are opened regardless (see
    /// `reconcileExpansion`), so the review surface — every file with an edit
    /// — is always visible even in a large project.
    private static let autoExpandFileLimit = 3000

    var body: some View {
        NavigationSplitView {
            treeColumn
                .navigationSplitViewColumnWidth(min: 250, ideal: 310)
        } detail: {
            detailPane
        }
        .onAppear {
            // The store warms at session start (off the main thread); a view
            // that appears over a store which never loaded refreshes here.
            if store.version == 0, !store.isLoading {
                store.scheduleRefresh(immediate: true)
            }
            reconcileExpansion()
        }
        .onReceive(NotificationCenter.default.publisher(for: GitStatus.didChangeNotification)) { note in
            // The STORE refreshes its data on this same signal (it subscribes
            // itself); this view only reloads the OPEN FILE's pane when the
            // signal names it (or doesn't know which file changed). A file the
            // user has open that WASN'T touched shouldn't visibly refresh out
            // from under them.
            guard (note.userInfo?["cwd"] as? URL) == store.cwd else { return }
            let path = note.userInfo?["path"] as? String
            if path == nil || path == store.selectedPath {
                store.bumpPaneReload()
            }
        }
        .onChange(of: store.version) { _, _ in
            reconcileExpansion()
        }
        // A selection change — a tree click, or an EXTERNAL open (a click on
        // an agent-emitted file reference in the transcript): open the new
        // path's ancestor folders (the tree can only select a row that exists
        // in the current flatten — a file under a collapsed folder needs its
        // ancestors opened, exactly like the changed-file expansion in
        // `reconcileExpansion`), and drop any pending reference intents that
        // belonged to a DIFFERENT path (the user navigated away before the
        // pane/tree could consume them — they must not leak into the file they
        // opened instead). NO reload-token bump here: a path change alone
        // reloads the pane (`ReadOnlyFilePane` dedupes on (path, token)), and
        // a redundant bump would trigger a SECOND reload that supersedes a
        // reference-driven load before it lands, dropping its target line.
        .onChange(of: store.selectedPath) { _, newValue in
            if let newValue {
                expandedDirectories.formUnion(ancestorDirectories(of: [newValue]))
                if let pending = store.pendingReference, pending.path != newValue {
                    store.clearReferenceIntents()
                }
            }
        }
    }

    // MARK: - Tree column

    /// The file tree. Rendered by a virtualized AppKit `NSTableView`, not a
    /// SwiftUI `List`: a `List` over the flattened, fully-expanded row array
    /// (thousands of rows on a large project) diffs and constructs every row
    /// on the main thread the moment the page appears — the multi-second
    /// beachball in samples. An `NSTableView` only ever materializes the
    /// visible rows (the transcript's exact technique).
    private var treeColumn: some View {
        FileTreeTable(
            rows: rows,
            selectedPath: store.selectedPath,
            // The one-shot reveal of an externally-opened file (nil for plain
            // clicks): the coordinator scrolls the row into view once, then
            // clears it via `onRevealConsumed`.
            revealPath: store.pendingRevealPath,
            onSelect: { store.selectedPath = $0 },
            onToggleDirectory: { toggleExpansion($0) },
            onRevealConsumed: { store.consumePendingReveal() }
        )
        .overlay {
            if store.isLoading && rows.isEmpty {
                // AppKit spinner (see `SpinnerView`) — never SwiftUI's
                // animated `ProgressView`: this page sits inside the window
                // content hosting view, so a SwiftUI spinner would keep the
                // whole shell graph invalidating per frame while it spins.
                HStack(spacing: 8) {
                    SpinnerView()
                    Text("Listing files…")
                        .font(.system(size: 12))
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else if !store.isLoading && rows.isEmpty {
                ContentUnavailableView(
                    "No files",
                    systemImage: "folder",
                    description: Text("Nothing to list — is this folder a git repository?")
                )
            }
        }
    }

    private func toggleExpansion(_ path: String) {
        if expandedDirectories.contains(path) {
            expandedDirectories.remove(path)
        } else {
            expandedDirectories.insert(path)
        }
    }

    /// Applies the first-load expansion policy and prunes expansions that a
    /// refresh dropped (their directories no longer exist). Called when the
    /// store's snapshot changes and when the view first appears over an
    /// already-loaded store (a session that loaded while its Files page was
    /// never shown).
    ///
    /// Whatever the policy, the ancestor folders of every CHANGED file are
    /// always opened — first load and every refresh — so a file with an edit
    /// is never buried under a collapsed directory: "all files with edits are
    /// open" holds in a large project that opened collapsed at the top level
    /// (a few dozen edited files only open their own folders, not the whole
    /// tree) and stays true as the agent edits files anywhere while the
    /// session runs. Expansion only ever grows — once a folder is open it
    /// stays open (only the user collapses), and a refresh stops force-opening
    /// a folder once none of its files are changed anymore.
    private func reconcileExpansion() {
        guard store.version > 0 else { return }
        // Re-derived from the current snapshot every time: folders of files
        // that were just edited appear on the next refresh; folders whose
        // changed files all reverted stop being force-opened (they stay open
        // until the user collapses them).
        let changedAncestors = ancestors(ofChangedFiles: store.fileEntries)
        if !didExpandAllOnce {
            didExpandAllOnce = true
            var expanded: Set<String> = store.fileCount <= Self.autoExpandFileLimit ? store.directoryPaths : []
            expanded.formUnion(changedAncestors)
            expandedDirectories = expanded
        } else {
            expandedDirectories.formIntersection(store.directoryPaths)
            expandedDirectories.formUnion(changedAncestors)
        }
    }

    /// The ancestor directories of every file git sees as changed — added,
    /// modified, deleted, and agent-created untracked (the "not added yet"
    /// rows) alike. Top-level files have none and are always visible. This is
    /// what keeps the review surface open without auto-expanding the whole
    /// project.
    private func ancestors(ofChangedFiles entries: [String: GitStatus.FileEntry]) -> Set<String> {
        ancestorDirectories(of: entries.filter { $0.value.kind != .normal }.map(\.key))
    }

    /// The ancestor directories of `paths` (top-level files have none). Used
    /// by the changed-file expansion AND by selection: opening a file under a
    /// collapsed folder must expand every directory on its path first, or the
    /// row never appears in the flatten for the tree to select/reveal.
    private func ancestorDirectories(of paths: [String]) -> Set<String> {
        var ancestors: Set<String> = []
        for path in paths {
            let components = path.split(separator: "/")
            guard components.count > 1 else { continue }
            var directory = ""
            for component in components.dropLast() {
                if directory.isEmpty {
                    directory = String(component)
                } else {
                    directory += "/" + component
                }
                ancestors.insert(directory)
            }
        }
        return ancestors
    }

    // MARK: - Tree model (view side)

    fileprivate struct Row: Identifiable {
        let node: FileTreeNode
        let depth: Int
        var id: String { node.path }
    }

    /// Cache for the memoized flatten. A class so body evaluations can update
    /// it without writing to `@State` (which would re-invalidate the view).
    private final class RowMemo {
        var version = -1
        var expanded: Set<String> = []
        var rows: [Row] = []
    }

    /// The flattened visible rows (directories whose expansion is set expand
    /// into their children). Nodes are CLASSES, so this is a cheap O(rows)
    /// list of references — never subtree copies — memoized on (version,
    /// expansion), so a re-render that changes neither is O(1). The view never
    /// re-flattens on selection clicks or spurious re-renders.
    private var rows: [Row] {
        if rowMemo.version != store.version || rowMemo.expanded != expandedDirectories {
            rowMemo.version = store.version
            rowMemo.expanded = expandedDirectories
            rowMemo.rows = Self.flatten(store.rootNodes, expanded: expandedDirectories)
        }
        return rowMemo.rows
    }

    private static func flatten(_ nodes: [FileTreeNode], expanded: Set<String>) -> [Row] {
        var result: [Row] = []
        func walk(_ nodes: [FileTreeNode], depth: Int) {
            for node in nodes {
                result.append(Row(node: node, depth: depth))
                if node.isDirectory, expanded.contains(node.path) {
                    walk(node.children, depth: depth + 1)
                }
            }
        }
        walk(nodes, depth: 0)
        return result
    }

    // MARK: - Detail column

    /// The editor's own meta panel, at the top of the detail column (not the
    /// whole window): just the open file — the project is already the tab's
    /// title, so repeating it here would be noise. Left inset so the first
    /// glyphs clear the window chrome, and vertically padded so the row
    /// doesn't hug the title bar.
    private var editorMeta: some View {
        HStack(spacing: 8) {
            if let path = store.selectedPath, store.fileEntries[path] != nil {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Select a file")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            editorMeta
            Divider()
            if let path = store.selectedPath, let entry = store.fileEntries[path] {
                ReadOnlyFilePane(
                    cwd: store.cwd,
                    path: path,
                    kind: entry.kind,
                    reloadToken: store.paneReloadToken,
                    pendingReference: store.pendingReference,
                    onReferenceConsumed: { store.consumePendingReference() }
                )
            } else {
                ContentUnavailableView(
                    "Select a file",
                    systemImage: "doc.text",
                    description: Text("Copy a selection to tag it as a path:line reference for the agent.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Tree table (virtualized AppKit)

/// The fill painted behind a changed file's name. When the file carries
/// batched diff counts (`FileEntry.stats`), the fill is a deletion↔addition
/// blend: hue runs from pure red (the change is all deletions) through amber
/// (balanced) to pure green (all additions), so how much of the change was
/// deletion vs. addition reads directly off the color behind the name — and a
/// staged-new file the agent later edited shows its worktree delta (real
/// deletions) instead of a flat "whole file is new" green. Opacity ramps with
/// the change's total size (saturating around 60 lines), so a one-line churn
/// stays a faint whisper while a rewrite saturates — a regenerated lockfile's
/// thousands of balanced +/− read amber, not alarm-red. Paths the batched
/// pass couldn't count (untracked — which carry their own "not added yet"
/// badge — and binaries) fall back to the flat kind color; committed-identical
/// rows get none.
fileprivate func rowTintColor(for entry: GitStatus.FileEntry?) -> NSColor? {
    guard let entry else { return nil }
    if let stats = entry.stats {
        let total = stats.added + stats.deleted
        if total > 0 {
            let addShare = CGFloat(stats.added) / CGFloat(total)
            // 1.0 (all additions) → green (120°); 0.0 (all deletions) → red
            // (0°); balanced → amber (60°).
            let hue = addShare / 3
            let opacity = 0.16 + 0.22 * min(1, CGFloat(total) / 60)
            return NSColor(hue: hue, saturation: 0.85, brightness: 0.9, alpha: opacity)
        }
    }
    switch entry.kind {
    case .added: return NSColor.systemGreen.withAlphaComponent(0.15)
    case .deleted: return NSColor.systemRed.withAlphaComponent(0.13)
    case .modified: return NSColor.systemOrange.withAlphaComponent(0.09)
    default: return nil
    }
}

/// The SCROLLBAR tick color for a changed file row (see `EditMarkerScroller`):
/// one tick per row git sees as changed — added, modified, deleted, or
/// agent-created untracked — the same "review surface" set the changed-file
/// ancestor expansion and the tab's edited-file badge count from, so the bar,
/// the force-opened folders, and the badge all tell one story. Colors mirror
/// the fill behind the name (`rowTintColor`): a row with countable diff stats
/// blends red→amber→green by its deletion↔addition share, and a stat-less row
/// falls back to its kind color. Unlike the fill, ticks draw at full opacity —
/// a ~4×5px tick on the track needs marker strength, not the wash tuned for a
/// light row background — and untracked rows, which the fill leaves blank (no
/// baseline to score), still get a tick: informational blue, "new content, not
/// added yet". nil = no tick.
fileprivate func rowMarkerColor(for entry: GitStatus.FileEntry?) -> NSColor? {
    guard let entry, entry.kind != .normal else { return nil }
    if let stats = entry.stats, stats.added + stats.deleted > 0 {
        let addShare = CGFloat(stats.added) / CGFloat(stats.added + stats.deleted)
        return NSColor(hue: addShare / 3, saturation: 0.85, brightness: 0.9, alpha: 1)
    }
    switch entry.kind {
    case .added: return .systemGreen
    case .deleted: return .systemRed
    case .modified: return .systemOrange
    case .untracked: return .systemBlue
    case .normal: return nil
    }
}

/// The file tree as an `NSTableView` (the transcript's technique, applied to
/// the sidebar): the SwiftUI side holds only DATA — the flattened visible
/// rows + the selection — and the table materializes just the rows on screen.
/// A SwiftUI `List` over the fully-expanded row array of a large project
/// diffs and constructs every row on the main thread when the Files page
/// appears (the multi-second beachball in samples); the table never does.
/// Directory rows toggle expansion on a plain click (never select); file rows
/// select normally.
private struct FileTreeTable: NSViewRepresentable {
    let rows: [FileBrowserView.Row]
    let selectedPath: String?
    /// When non-nil, the table must reveal that path's row (scroll it into
    /// view) once it exists in `rows` — an externally-opened file (agent file
    /// reference), where the user isn't already looking at the row. Cleared
    /// through `onRevealConsumed` after the scroll.
    let revealPath: String?
    let onSelect: (String?) -> Void
    let onToggleDirectory: (String) -> Void
    let onRevealConsumed: () -> Void

    func makeCoordinator() -> FileTreeCoordinator { FileTreeCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            rows: rows,
            selectedPath: selectedPath,
            revealPath: revealPath,
            onSelect: onSelect,
            onToggleDirectory: onToggleDirectory,
            onRevealConsumed: onRevealConsumed
        )
    }
}

private final class FileTreeCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 22

    private var tableView: FileTreeTableView!
    private var scrollView: NSScrollView!
    private var rows: [FileBrowserView.Row] = []
    /// The rows' paths (in table order), for O(n) change detection — the tree
    /// only reloads when this actually differs (or a row's kind — hence the
    /// tint suffix — changed), never on a selection flip.
    private var rowKeys: [String] = []
    private var rowIDs: [String] = []
    private var selectedPath: String?
    private var appliedSelection: String?
    private var onSelect: ((String?) -> Void)?
    private var onToggleDirectory: ((String) -> Void)?
    /// The path an external open asked the table to reveal (see
    /// `FileTreeTable.revealPath`). Held until the row exists in the flatten
    /// AND has been scrolled into view — a reference under a collapsed folder
    /// waits for the view's ancestor expansion to add its row on a later pass.
    private var revealPath: String?
    private var onRevealConsumed: (() -> Void)?
    /// True while a selection is being APPLIED from SwiftUI (a reload or an
    /// external selection change) — the resulting selectionDidChange must not
    /// round-trip back into `onSelect`.
    private var applyingSelection = false

    // MARK: Setup

    func makeScrollView() -> NSScrollView {
        let tv = FileTreeTableView()
        tv.headerView = nil
        tv.rowHeight = Self.rowHeight
        tv.intercellSpacing = .zero
        tv.backgroundColor = .clear
        tv.allowsMultipleSelection = false
        tv.allowsEmptySelection = true
        tv.selectionHighlightStyle = .regular
        tv.wantsLayer = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        column.resizingMask = .autoresizingMask
        column.width = 320
        tv.addTableColumn(column)
        tv.dataSource = self
        tv.delegate = self

        let sv = NSScrollView()
        sv.documentView = tv
        // The edited-file map lives on the vertical scroller (an
        // `EditMarkerScroller`, the type the content pane's scroller is a
        // subclass of). It must be installed BEFORE the scroll view creates
        // its own (`hasVerticalScroller = true` below would lazily make a
        // plain NSScroller otherwise — the content pane's install order), and
        // assigning a subclass forces the legacy (always-visible) scroller
        // style — intended, exactly like the content pane: the map is only
        // useful while the bar is shown.
        sv.verticalScroller = EditMarkerScroller()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false

        // A click on a directory row toggles its expansion (the old row-tap
        // behavior) and never disturbs the file selection; every other click
        // goes through to normal table selection.
        tv.clickConsumedByRow = { [weak self] row in
            guard let self, row >= 0, row < self.rows.count else { return false }
            let node = self.rows[row].node
            guard node.isDirectory else { return false }
            self.onToggleDirectory?(node.path)
            return true
        }
        tableView = tv
        scrollView = sv
        return sv
    }

    /// The SwiftUI side re-evaluated (rows/selection/callbacks may have
    /// changed). Reloads the table ONLY when the visible row list actually
    /// changed — reloadData on a large tree would otherwise run on every
    /// selection flip — and preserves the scroll position across a refresh
    /// (the agent edited files while you were reading lower in the tree).
    func update(
        rows: [FileBrowserView.Row],
        selectedPath: String?,
        revealPath: String?,
        onSelect: @escaping (String?) -> Void,
        onToggleDirectory: @escaping (String) -> Void,
        onRevealConsumed: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onToggleDirectory = onToggleDirectory
        self.onRevealConsumed = onRevealConsumed
        self.revealPath = revealPath
        guard tableView != nil else { return }

        let keys = rows.map { $0.id + Self.entrySuffix($0.node.entry) }
        if keys != rowKeys {
            let top = visibleTopKey()
            rowKeys = keys
            rowIDs = rows.map(\.id)
            self.rows = rows
            tableView.reloadData()
            restoreVisibleTop(top)
            // reloadData reset the table's selection; force `syncSelection` to
            // re-apply the SwiftUI selection (it no-ops when the path matches
            // `appliedSelection`, which still holds the pre-reload row).
            appliedSelection = nil
            // The row list changed, so the scrollbar's edited-file map is
            // stale — refresh it from the new flatten.
            updateEditMarkers()
        }
        syncSelection(selectedPath)
    }

    private func syncSelection(_ path: String?) {
        guard path != appliedSelection else {
            // Selection already applied — but a reveal request for this same
            // path may still be pending (a reference click on the file that is
            // already open: nothing re-runs the select, yet the row still has
            // to scroll into view).
            if let path, path == revealPath, let index = rowIDs.firstIndex(of: path) {
                revealRow(path, at: index)
            }
            return
        }
        appliedSelection = path
        applyingSelection = true
        defer { applyingSelection = false }
        if let path, let index = rowIDs.firstIndex(of: path) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            if path == revealPath {
                revealRow(path, at: index)
            }
        } else {
            tableView.deselectAll(nil)
        }
    }

    /// Scrolls the row into view and consumes the one-shot reveal request. A
    /// path that never appears in the flatten (a reference to a file outside
    /// the git-derived listing) is never revealed — the request stays pending
    /// until the user selects something else (see
    /// `FileBrowserView`'s stale-intent clearing on selection change).
    private func revealRow(_ path: String, at index: Int) {
        tableView.scrollRowToVisible(index)
        revealPath = nil
        onRevealConsumed?()
    }

    // MARK: Scrollbar edit map

    /// Refreshes the vertical scroller's edited-file ticks for the current
    /// flatten: one tick per changed-file row (see `rowMarkerColor`) at the
    /// row's fraction of the document, `(index + 0.5) / count` — rows are
    /// uniform-height, so a row's bar position is exact (the content pane's
    /// `(line − 0.5) / lineCount` mapping, applied to rows). Markers are
    /// doc-anchored and change only when the row list changes — reloads,
    /// expansion flips, refreshes — never on scroll or selection.
    private func updateEditMarkers() {
        guard let scroller = scrollView.verticalScroller as? EditMarkerScroller else { return }
        let count = rows.count
        guard count > 0 else {
            scroller.markers = []
            return
        }
        var markers: [EditMarkerScroller.Marker] = []
        markers.reserveCapacity(64)
        for (index, row) in rows.enumerated() {
            guard let color = rowMarkerColor(for: row.node.entry) else { continue }
            markers.append(EditMarkerScroller.Marker(
                fraction: (CGFloat(index) + 0.5) / CGFloat(count),
                color: color
            ))
        }
        scroller.markers = markers
    }

    // MARK: Scroll preservation across reloads

    private func visibleTopKey() -> String? {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0, visible.location >= 0, visible.location < rowIDs.count else { return nil }
        return rowIDs[visible.location]
    }

    private func restoreVisibleTop(_ key: String?) {
        guard let key, let index = rowIDs.firstIndex(of: key) else { return }
        tableView.scrollRowToVisible(index)
    }

    /// Reload discriminator per row: kind plus the diff counts when present.
    /// The tree reloads only when the visible row LIST changes — a refresh
    /// that only shifts a file's +/− counts must reload too (that is what
    /// repaints the fill), but a plain selection flip must not.
    private static func entrySuffix(_ entry: GitStatus.FileEntry?) -> String {
        guard let entry else { return "/d" }
        let kind: Character
        switch entry.kind {
        case .added: kind = "A"
        case .deleted: kind = "D"
        case .modified: kind = "M"
        case .untracked: kind = "U"
        case .normal: kind = "."
        }
        if let stats = entry.stats {
            return "/\(kind)+\(stats.added)-\(stats.deleted)"
        }
        return String(kind)
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rows.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileTreeRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? FileTreeRowView) ?? FileTreeRowView()
        cell.identifier = id
        let rowData = rows[row]
        // A directory is expanded iff its children immediately follow it.
        let isExpanded = row + 1 < rows.count && rows[row + 1].depth > rowData.depth
        cell.configure(row: rowData, isExpanded: isExpanded) { [weak self] path in
            self?.onToggleDirectory?(path)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("FileTreeRowBackground")
        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? FileTreeRowBackground {
            existing.tint = row < rows.count ? rowTintColor(for: rows[row].node.entry) : nil
            return existing
        }
        let background = FileTreeRowBackground()
        background.identifier = id
        background.tint = row < rows.count ? rowTintColor(for: rows[row].node.entry) : nil
        return background
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row >= 0 && row < rows.count && !rows[row].node.isDirectory
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        let row = tableView.selectedRow
        if row >= 0, row < rows.count {
            let path = rows[row].node.path
            appliedSelection = path
            onSelect?(path)
        } else {
            appliedSelection = nil
            onSelect?(nil)
        }
    }
}

/// The tree table itself: intercepts clicks on directory rows (toggle, never
/// select) and lets every other click fall through to normal selection.
private final class FileTreeTableView: NSTableView {
    /// Called with the clicked row's index before normal selection handling;
    /// return true to consume the click.
    var clickConsumedByRow: ((Int) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0, clickConsumedByRow?(row) == true else {
            super.mouseDown(with: event)
            return
        }
    }
}

/// One tree row: (optional disclosure chevron) + kind icon + name + optional
/// "not added yet" badge, laid out by hand in `layout()` — no autolayout
/// machinery per cell, no SwiftUI per-row view construction. Rows are reused
/// by the table and reconfigured per row, like the transcript's cells.
private final class FileTreeRowView: NSView {
    private let chevronButton = NSButton()
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let badgeField = NSTextField(labelWithString: "not added yet")
    private var config: (path: String, isDirectory: Bool, depth: Int)?
    private var toggleAction: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        chevronButton.setButtonType(.momentaryChange)
        chevronButton.isBordered = false
        chevronButton.imagePosition = .imageOnly
        chevronButton.contentTintColor = .secondaryLabelColor
        chevronButton.target = self
        chevronButton.action = #selector(chevronClicked(_:))
        addSubview(chevronButton)

        iconView.contentTintColor = .secondaryLabelColor
        addSubview(iconView)

        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.maximumNumberOfLines = 1
        addSubview(nameField)

        badgeField.textColor = .tertiaryLabelColor
        badgeField.lineBreakMode = .byClipping
        addSubview(badgeField)
    }

    /// (Re)configures a recycled cell for `row`. `isExpanded` decides the
    /// chevron direction; `toggle` fires when the disclosure is clicked.
    func configure(row: FileBrowserView.Row, isExpanded: Bool, toggle: @escaping (String) -> Void) {
        config = (row.node.path, row.node.isDirectory, row.depth)
        toggleAction = toggle
        let isDirectory = row.node.isDirectory
        nameField.stringValue = row.node.name
        nameField.font = isDirectory
            ? .systemFont(ofSize: 12)
            : .monospacedSystemFont(ofSize: 12, weight: .regular)
        iconView.image = isDirectory ? Self.folderIcon : Self.fileIcon
        chevronButton.isHidden = !isDirectory
        if isDirectory {
            chevronButton.image = isExpanded ? Self.chevronDown : Self.chevronRight
        }
        let untracked = row.node.entry?.kind == .untracked
        badgeField.isHidden = !untracked
        badgeField.sizeToFit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let config else { return }
        let height = bounds.height
        let indentX = CGFloat(config.depth) * 14 + 4
        if config.isDirectory {
            chevronButton.frame = NSRect(x: indentX + 1, y: (height - 12) / 2, width: 14, height: 12)
        }
        let iconX = indentX + 14 + 1
        iconView.frame = NSRect(x: iconX, y: (height - 13) / 2, width: 13, height: 13)
        let textX = iconX + 14
        var textWidth = bounds.width - textX - 8
        if !badgeField.isHidden {
            let badgeWidth = min(badgeField.frame.width, 90)
            textWidth -= badgeWidth + 8
            badgeField.frame = NSRect(x: bounds.width - badgeWidth - 8, y: (height - badgeField.frame.height) / 2, width: badgeWidth, height: badgeField.frame.height)
        }
        nameField.frame = NSRect(x: textX, y: (height - 16) / 2, width: max(textWidth, 8), height: 16)
    }

    @objc private func chevronClicked(_ sender: Any?) {
        if let path = config?.path {
            toggleAction?(path)
        }
    }

    // MARK: Symbol art (built once)

    private static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return base.withSymbolConfiguration(config) ?? base
    }

    private static let folderIcon = symbol("folder", pointSize: 11)
    private static let fileIcon = symbol("doc.text", pointSize: 11)
    private static let chevronRight = symbol("chevron.right", pointSize: 9, weight: .semibold)
    private static let chevronDown = symbol("chevron.down", pointSize: 9, weight: .semibold)
}

/// Draws the row's git-kind tint behind the (still default) selection
/// highlight.
private final class FileTreeRowBackground: NSTableRowView {
    var tint: NSColor? {
        didSet {
            guard tint != oldValue else { return }
            needsDisplay = true
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if let tint {
            tint.setFill()
            bounds.fill()
        } else {
            super.drawBackground(in: dirtyRect)
        }
    }
}

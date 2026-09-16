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
    /// Whether the Files page (not the conversation) is the visible page. The
    /// view stays mounted while hidden behind the conversation (so a page
    /// flip is an instant visibility flip and the tree's view state survives),
    /// but it does ZERO of its heavy work while off-screen — no first-load
    /// auto-expand + flatten, no content-pane load — the mirror of the
    /// transcript coordinator's page-active gating. Activation runs one
    /// catch-up pass (`reconcileExpansion`; the pane re-loads its latest
    /// deferred request itself). This is what keeps a SESSION switch (which
    /// remounts this view for the incoming tab — it is `.id`-keyed per tab)
    /// from flattening a project or highlighting an open file on the main
    /// thread while the user is looking at the conversation.
    var pageActive = true

    /// Who owns the tree column's collapse state. Bound HERE — never left to
    /// the framework's implicit handling — and the layout is a plain `HStack`
    /// (see `body`), so the Files page's toggle is a normal button in its own
    /// column header (see `treeHeader`/`editorMeta`) and nothing is ever
    /// injected into the window toolbar. The button's screen position is fixed
    /// by the column's own layout, not negotiated against the window title, so
    /// it never jumps when the column collapses.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The tree column's width; the detail column takes the rest. Owned here
    /// because the container is a plain `HStack` (see `body`): what used to be
    /// `.navigationSplitViewColumnWidth(min: 250, ideal: 310)` — an AppKit
    /// split-view constraint — is now plain view state starting at the old
    /// ideal (310) and draggable within `treeColumnWidthRange` via
    /// `columnDivider`. Per-tab view state like the rest of this view's (it is
    /// `.id`-keyed per tab), so a session switch resets it — the split view's
    /// width reset the same way.
    @State private var treeColumnWidth: CGFloat = 310

    /// The tree column's width range. The old split view let the user drag the
    /// sidebar between its 250pt minimum and a generous maximum (no explicit
    /// max was set on `.navigationSplitViewColumnWidth`); `columnDivider`
    /// clamps the drag to this.
    private static let treeColumnWidthRange: ClosedRange<CGFloat> = 250...520

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
        // A plain two-pane HStack (tree column, `columnDivider`, detail) —
        // NOT a `NavigationSplitView`. Why: NavigationSplitView is backed by
        // an `NSSplitViewController` whose first column is a `.sidebar` split
        // item, and a sidebar split item opts the WINDOW into sidebar-aware
        // title-bar layout — the native window title (which belongs to the
        // session chrome one level up, `SessionTabsView`) gets renegotiated
        // against the sidebar's tracked leading edge as the column
        // collapses/expands, so toggling the file tree moved and recentered
        // the title. AppKit applies that tracking for ANY mounted split view,
        // however deeply nested, and it cannot be opted out of from inside the
        // page: `.toolbar(removing: .sidebarToggle)` removes only the toolbar
        // BUTTON, not the window's sidebar-tracking registration. This page
        // already reimplements everything else NavigationSplitView would
        // provide — the collapse state (`columnVisibility`), the toggle
        // (`treeHeader`/`editorMeta`), the column width (`treeColumnWidth`),
        // the drag-resize divider (`columnDivider`) — so the container is
        // just two columns and no split view exists for AppKit to track.
        // Trade-offs: the tree column loses the split divider's native
        // accessibility role, and column drag-resize is reimplemented in
        // `columnDivider`. The divider restores the role itself — it exposes
        // an `.adjustable` accessibility element (keyboard/VoiceOver
        // increment/decrement) so resize stays reachable without the split
        // view's title-bar side effects.
        HStack(spacing: 0) {
            if columnVisibility != .detailOnly {
                treeColumn
                    .frame(width: treeColumnWidth)
                    .transition(.move(edge: .leading))
                columnDivider
                    .transition(.move(edge: .leading))
            }
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // The store warms at session start (off the main thread); a view
            // that appears over a store which never loaded refreshes here.
            if store.version == 0, !store.isLoading {
                store.scheduleRefresh(immediate: true)
            }
            // The first-load expansion policy runs only once the page is
            // actually shown: a view mounted behind the conversation (a
            // session switch into a conversation-page tab) defers its
            // auto-expand + flatten to first activation (see the
            // `pageActive` change handler).
            if pageActive {
                reconcileExpansion()
            }
        }
        // The Files page became visible: one catch-up pass — apply the
        // expansion policy against the current snapshot (a hidden mount
        // skipped it, and refreshes that landed while hidden were deferred
        // too). Runs only on the hidden→visible transition, never per body
        // evaluation.
        .onChange(of: pageActive) { _, active in
            if active {
                reconcileExpansion()
            }
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
            // A refresh landed while the page is hidden: defer the expansion
            // reconcile (it re-derives the changed-file folders and can grow
            // the flatten) — activation's catch-up applies it against the
            // latest snapshot.
            if pageActive {
                reconcileExpansion()
            }
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

    /// The file tree column: the column's own header row (the collapse toggle
    /// + a title) above the virtualized AppKit `NSTableView`. A `List` over
    /// the flattened, fully-expanded row array (thousands of rows on a large
    /// project) diffs and constructs every row on the main thread the moment
    /// the page appears — the multi-second beachball in samples. An
    /// `NSTableView` only ever materializes the visible rows (the transcript's
    /// exact technique).
    private var treeColumn: some View {
        VStack(spacing: 0) {
            treeHeader
            Divider()
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                // The loading/empty overlays cover the TABLE only, below the
                // header row (which stays interactive — its toggle works even
                // while the listing is still in flight).
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
    }

    /// The tree column's own header: the sidebar collapse toggle plus a
    /// column title. This is where the tree's collapse affordance LIVES — a
    /// plain SwiftUI button laid out by the column's own stack, not an item in
    /// the window toolbar (the layout is a plain `HStack`; see `body`). Its
    /// screen position is fixed by ordinary layout rules inside the column, so
    /// it never repositions when the column collapses; the whole column
    /// (header included) slides away with the tree.
    private var treeHeader: some View {
        HStack(spacing: 8) {
            sidebarToggleButton
            Text("Files")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        // Vertical padding tuned so this header row's TOTAL height matches
        // `editorMeta`'s (both land at 32pt: this row's content — the
        // toggle's fixed 18×18 image frame — plus 7pt top/bottom; the meta
        // strip's ~15pt icon+text content plus its 9pt/8pt top/bottom). Both
        // panes' rows start at the same y, so equal totals put the two
        // `Divider()` hairlines at the same height and the outlines meet at
        // the column divider instead of stepping. If either row's content
        // height changes, re-match the two here.
        .padding(.vertical, 7)
    }

    /// The collapse toggle, shown in the tree column's header while the tree
    /// is visible and MIRRORED at the leading edge of the detail column's
    /// header (`editorMeta`) while it is hidden — the only visible way back
    /// in once `.detailOnly` removed the tree header with the column. Either
    /// position flips `columnVisibility` between `.all` and `.detailOnly`
    /// (the button exists only where the current state allows the flip to be
    /// meaningful), animated so the column slide is smooth.
    private var sidebarToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                columnVisibility = columnVisibility == .all ? .detailOnly : .all
            }
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 12))
                // A modest fixed frame so the plain icon button has a
                // comfortable click target in both headers.
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(columnVisibility == .all ? "Hide file tree" : "Show file tree")
        .accessibilityLabel(columnVisibility == .all ? "Hide file tree" : "Show file tree")
    }

    /// The divider between the tree and detail columns — the narrow draggable
    /// strip whose position (the tree column's trailing edge) follows
    /// `treeColumnWidth`. The visible line is a hairline; dragging it resizes
    /// the tree column within `treeColumnWidthRange`, like the old split
    /// view's divider. Removed with the tree when it collapses.
    private var columnDivider: some View {
        ColumnDivider(width: $treeColumnWidth, range: Self.treeColumnWidthRange)
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

    /// The viewer's own meta strip at the top of the detail column: the open
    /// file's path (the project is already the tab's title, so repeating it
    /// would be noise). Left inset so the first glyphs clear the window
    /// chrome; vertically padded so the row doesn't hug the title bar.
    ///
    /// Painted with the CODE PANE's own background token
    /// (`NSColor.textBackgroundColor` — opaque, white in light mode) so the
    /// strip and the file beneath it are one continuous surface; the previous
    /// `NSColor.underPageBackgroundColor` resolved to a mid-grey
    /// (#969696 in light mode) and read as a grey slab sitting on the viewer.
    /// The strip's own top edge is NOT given a hairline here: the boundary
    /// between this strip (and the tree header) and the chrome above is the
    /// session chrome's divider under the translucent tab panel
    /// (`SessionTabsView`), and the fill is opaque, so the only way this
    /// surface ever read as see-through was the `NavigationSplitView`
    /// sidebar-tracking renegotiating the title-bar layout over it as the
    /// column collapsed/expanded — removed at the source by the plain-HStack
    /// container in `body`.
    ///
    /// When the tree column is collapsed (`.detailOnly`) this strip's leading
    /// edge mirrors the tree header's collapse toggle — the only visible way
    /// back in, since collapsing removed the tree header with its column.
    private var editorMeta: some View {
        HStack(spacing: 8) {
            if columnVisibility != .all {
                // The tree is hidden — lead with the affordance that brings
                // it back (see `sidebarToggleButton`).
                sidebarToggleButton
            }
            if let path = store.selectedPath, store.fileEntries[path] != nil {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // No file: the strip is empty (the `ContentUnavailableView` below
            // already says "Select a file") — the strip still anchors the
            // pane's top edge and hosts the reopen toggle when the tree is
            // collapsed.
            Spacer(minLength: 0)
        }
        .padding(.leading, columnVisibility != .all ? 10 : 16)
        .padding(.trailing, 12)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(Color(nsColor: .textBackgroundColor))
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
                    onReferenceConsumed: { store.consumePendingReference() },
                    // The pane defers its loads while the Files page is hidden
                    // (the conversation is up): no file IO / git show / syntax
                    // highlight for a page nothing renders (see
                    // `ReadOnlyFilePane.pageActive`).
                    pageActive: pageActive
                )
                // A flexible slot in this VStack (the placeholder branch below
                // declares the same). The pane now fills it exactly: its
                // `sizeThatFits` override adopts the proposed size instead of
                // reporting `FilePaneContainer`'s fitting size — the whole
                // file's text height (the code text view is unbounded so it can
                // scroll). Without both, the oversized fitting height inflates
                // the pane past this slot and the code pane's ruler rows paint
                // through the (translucent) chrome above the detail column.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Column divider (drag-to-resize)

/// The hairline divider between the tree and detail columns, with a wider
/// drag target to its right (see `FileBrowserView.columnDivider`). Replaces
/// the divider `NavigationSplitView`'s split view used to own — its
/// drag-to-resize is the one split-view behavior this page actually wanted
/// (see `FileBrowserView.body`): dragging moves the tree column's trailing
/// edge, clamped to `range`, and the detail column takes up the slack. The
/// resize cursor shows on hover.
private struct ColumnDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>

    /// The tree width when the current drag began. The drag's translation is
    /// added to this snapshot — not to the live (possibly already-clamped)
    /// width — so clamping at the ends during a drag doesn't compound into the
    /// width when the pointer comes back inside the range (the standard
    /// split-divider feel: the divider stops at the limit and resumes
    /// following the pointer once it re-enters).
    @State private var dragStartWidth: CGFloat = 310
    @State private var isDragging = false
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .leading) {
            // The surface right of the hairline is painted with the DETAIL
            // column's background token (the code pane's own), so the white
            // gutter reads as the detail column starting AT the hairline —
            // exactly like the old split view — rather than as stray page
            // background between the two panes. (The tree column's backdrop is
            // the window's; painting it here would show a gray notch in the
            // header band between the hairline and the white strip.)
            Color(nsColor: .textBackgroundColor)
            // The visible hairline, at the tree column's trailing edge (the
            // drag target is the whole strip to its right).
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(drag)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("File tree width")
        .accessibilityValue("\(Int(width)) points")
        .accessibilityHint("Adjusts the width of the file tree column")
        // Keyboard- and VoiceOver-accessible resize: the drag strip is an
        // adjustable element whose increment/decrement move the divider by a
        // fixed step (clamped to `range`), restoring the split divider's
        // accessibility role the plain-HStack container gave up (see
        // `FileBrowserView.body`). Full Keyboard Access focuses it like any
        // adjustable control and adjusts it with the arrow keys.
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = 20
            switch direction {
            case .increment:
                width = min(width + step, range.upperBound)
            case .decrement:
                width = max(width - step, range.lowerBound)
            @unknown default:
                break
            }
        }
        .onDisappear {
            // The column collapsed (or this view went away) mid-hover: leave
            // the cursor stack balanced.
            if isHovering {
                NSCursor.pop()
                isHovering = false
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragStartWidth = width
                }
                width = min(max(dragStartWidth + value.translation.width, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                isDragging = false
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

    /// Same contract as `ReadOnlyFilePane.sizeThatFits`: the tree table fills
    /// the slot given to it, never its content. An `NSTableView`'s fitting
    /// height is `rows × rowHeight` — for a large expanded project that would
    /// inflate the tree column (and the divider it shares with the detail
    /// pane) past the page slot, the same leak the code pane used to have.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        func finite(_ value: CGFloat?) -> CGFloat {
            guard let value, value.isFinite else { return 0 }
            return value
        }
        return CGSize(width: finite(proposal.width), height: finite(proposal.height))
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
    /// The badge's fitted size, measured ONCE when the cell is created (see
    /// `setup`): the label is the constant string "not added yet" in a font
    /// that never changes, so its fitted size is fixed. `layout` reads this
    /// instead of re-measuring.
    private var badgeFittedSize = NSSize.zero
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
        // Fit the badge ONCE per cell instance (the cell is reused for many
        // rows, but `setup` runs only when it is first created): the label is
        // a constant string in a constant font, so its fitted size never
        // changes. The old code called `sizeToFit()` on every row
        // reconfigure — a full text measurement (CoreText work) for EVERY
        // materialized row on every scroll — even though the result is only
        // ever consulted on the rare visible (untracked) row, and is constant
        // when it is.
        badgeField.sizeToFit()
        badgeFittedSize = badgeField.frame.size
    }

    /// (Re)configures a recycled cell for `row`. `isExpanded` decides the
    /// chevron direction; `toggle` fires when the disclosure is clicked.
    func configure(row: FileBrowserView.Row, isExpanded: Bool, toggle: @escaping (String) -> Void) {
        config = (row.node.path, row.node.isDirectory, row.depth)
        toggleAction = toggle
        let isDirectory = row.node.isDirectory
        nameField.stringValue = row.node.name
        let font = isDirectory ? Self.directoryNameFont : Self.fileNameFont
        // Skip reassignment when the recycled cell already carries this font
        // (rows are reconfigured on every scroll): assigning is only needed
        // when the row kind flipped.
        if nameField.font !== font {
            nameField.font = font
        }
        iconView.image = isDirectory ? Self.folderIcon : Self.fileIcon
        chevronButton.isHidden = !isDirectory
        if isDirectory {
            chevronButton.image = isExpanded ? Self.chevronDown : Self.chevronRight
        }
        badgeField.isHidden = row.node.entry?.kind != .untracked
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
            let badgeWidth = min(badgeFittedSize.width, 90)
            textWidth -= badgeWidth + 8
            badgeField.frame = NSRect(x: bounds.width - badgeWidth - 8, y: (height - badgeFittedSize.height) / 2, width: badgeWidth, height: badgeFittedSize.height)
        }
        nameField.frame = NSRect(x: textX, y: (height - 16) / 2, width: max(textWidth, 8), height: 16)
    }

    @objc private func chevronClicked(_ sender: Any?) {
        if let path = config?.path {
            toggleAction?(path)
        }
    }

    // MARK: Row typography (built once)

    /// The two name fonts, built once: rows reconfigure on every scroll, and
    /// the old code constructed a fresh `NSFont` per call. (Same rationale as
    /// the symbol art below.)
    private static let directoryNameFont = NSFont.systemFont(ofSize: 12)
    private static let fileNameFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

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

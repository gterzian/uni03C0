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
    @State private var selection: String?
    /// Bumped whenever the open file should reload (selection change, or a
    /// change event naming the open file / a turn end).
    @State private var paneToken = 0
    @State private var didExpandAllOnce = false
    /// Memoized flattened rows (see `rows`) — a class so body evaluations can
    /// refresh it without writing `@State` (which would re-invalidate).
    @State private var rowMemo = RowMemo()

    /// First listing auto-expands everything only up to this many files.
    /// Beyond that, a large project starts collapsed at its top level (expand
    /// folders as needed) — a giant auto-expanded tree is never a useful
    /// review surface, and keeping the default row list small bounds the
    /// flatten and the table's change detection for the life of the session.
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
            if path == nil || path == selection {
                paneToken += 1
            }
        }
        .onChange(of: store.version) { _, _ in
            reconcileExpansion()
        }
        .onChange(of: selection) { _, newValue in
            if newValue != nil {
                paneToken += 1
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
            selectedPath: selection,
            onSelect: { selection = $0 },
            onToggleDirectory: { toggleExpansion($0) }
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
    private func reconcileExpansion() {
        guard store.version > 0 else { return }
        if !didExpandAllOnce {
            didExpandAllOnce = true
            expandedDirectories = store.fileCount <= Self.autoExpandFileLimit ? store.directoryPaths : []
        } else {
            expandedDirectories.formIntersection(store.directoryPaths)
        }
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
            if let path = selection, store.fileEntries[path] != nil {
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
            if let path = selection, let entry = store.fileEntries[path] {
                ReadOnlyFilePane(cwd: store.cwd, path: path, kind: entry.kind, reloadToken: paneToken)
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

/// Whole-row tint color by coarse git kind (see the design notes on the tree
/// in `FileBrowserView`): no per-file diff at listing time, and no misleading
/// "deleted sliver" on a file whose only change is a one-line churn. Direction
/// and volume live per file in the content pane, computed on selection.
fileprivate func rowTintColor(for entry: GitStatus.FileEntry?) -> NSColor? {
    switch entry?.kind {
    case .added: NSColor.systemGreen.withAlphaComponent(0.15)
    case .deleted: NSColor.systemRed.withAlphaComponent(0.13)
    case .modified: NSColor.systemOrange.withAlphaComponent(0.09)
    default: nil
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
    let onSelect: (String?) -> Void
    let onToggleDirectory: (String) -> Void

    func makeCoordinator() -> FileTreeCoordinator { FileTreeCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            rows: rows,
            selectedPath: selectedPath,
            onSelect: onSelect,
            onToggleDirectory: onToggleDirectory
        )
    }
}

private final class FileTreeCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 22

    private var tableView: FileTreeTableView!
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
        onSelect: @escaping (String?) -> Void,
        onToggleDirectory: @escaping (String) -> Void
    ) {
        self.onSelect = onSelect
        self.onToggleDirectory = onToggleDirectory
        guard tableView != nil else { return }

        let keys = rows.map { $0.id + Self.kindSuffix($0.node.entry?.kind) }
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
        }
        syncSelection(selectedPath)
    }

    private func syncSelection(_ path: String?) {
        guard path != appliedSelection else { return }
        appliedSelection = path
        applyingSelection = true
        defer { applyingSelection = false }
        if let path, let index = rowIDs.firstIndex(of: path) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
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

    private static func kindSuffix(_ kind: GitStatus.Kind?) -> String {
        switch kind {
        case .added: "A"
        case .deleted: "D"
        case .modified: "M"
        default: "."
        }
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

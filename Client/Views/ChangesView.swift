import AppKit
import Core
import SwiftUI

/// The Changes page — the review surface for the session folder's changes since
/// the session opened (a commit made while it stays open does not clear it). A
/// list of the changed files on the left (the navigation) and, on
/// the right, ONE scrollable viewer holding every file's diff in path order.
/// Scrolling the viewer walks the whole changeset; the list highlights
/// whichever file's section owns the top of the viewport, and clicking a row
/// scrolls the viewer to that file.
///
/// Each file's diff shows the changed region plus a few context lines, with an
/// expand control above and below to read further into the file — the reveal
/// grows in compounding blocks, like the transcript's history fetch. Search
/// covers every line the viewer is currently showing, whether or not it is in
/// the viewport, and re-runs as a file expands.
struct ChangesView: View {
    @Bindable var store: ChangesStore
    /// Whether the Changes page is the visible page. The view stays mounted
    /// while hidden, but the viewer defers its rebuilds (no file IO, git, or
    /// syntax highlighting for an off-screen page).
    var pageActive = true

    /// Height of the floating top chrome (the app's session tabs, the
    /// Session/Changes switch, and the nested Changes sub-nav) that this page
    /// scrolls under. The page itself fills the window's top edge; the floating
    /// file list and find bar are offset by this so they clear the chrome, and
    /// the diff document carries it as its top content inset so the code bleeds
    /// under the chrome instead of stopping below a painted band.
    var topInset: CGFloat = 0

    /// Find-in-diff state for the whole viewer (Cmd+F).
    @State private var search = CodeSearchModel()
    /// The floating file list's minimum width: a comfortable reading width for
    /// the header and short paths before it grows to fit the longest one.
    private let minimumSidebarWidth: CGFloat = 220
    /// The horizontal room the sidebar's `List` rows and header add around
    /// their content (row insets, the header's own padding, and the overlay
    /// scroller), added to the measured content so nothing truncates. Given
    /// generously — a path truncating is the exact failure this width exists
    /// to prevent.
    private let sidebarChromeWidth: CGFloat = 40
    /// The widest thing the file list must show in full (a row's badge + path
    /// + stats, or the header), measured once per changeset.
    @State private var fileListContentWidth: CGFloat = 0
    /// The page's own width, so the list never opens wider than the window.
    @State private var pageWidth: CGFloat = 0
    /// Height of the floating prompt cluster below the diff viewer: the diff
    /// document's bottom inset, so its last lines scroll above the bar.
    var bottomInset: CGFloat = 0
    /// Respect Reduce Motion: the scroll-spy bridge animates the sidebar
    /// highlight, which must become an instant jump when motion is reduced.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The sidebar's own selection, reconciled with the store's scroll-spy
    /// selection. `List(selection:)` needs a local binding so a user click can
    /// request a scroll (via `store.reveal`) while the spy moves the highlight
    /// without re-scrolling.
    @State private var listSelection: String?
    /// The measured height of the floating diff header: the document's top
    /// padding, so the first line starts below it and scrolls up under the
    /// glass.
    @State private var headerHeight: CGFloat = 0

    var body: some View {
        // One full-bleed diff. The file list is not a split-view column: it
        // floats ABOVE the diff while open, so the diff is always the whole
        // page and closing the list reveals the full width.
        ZStack(alignment: .topLeading) {
            diffArea
            if store.isSidebarVisible && !store.entries.isEmpty {
                GeometryReader { proxy in
                    changedList
                        .frame(width: sidebarWidth, height: max(0, proxy.size.height - 16 - topInset))
                        // AppKit Liquid Glass (see `GlassBackground`), not
                        // SwiftUI's `.glassEffect`, which renders through the
                        // hosting tree and re-renders the whole sampled backdrop
                        // whenever the content behind it changes. Same material
                        // and corner radius as every other glass surface.
                        .background {
                            GlassBackground(shape: .roundedRectangle(cornerRadius: WindowChrome.cornerRadius))
                        }
                        .padding(8)
                        // The floating file list is navigation chrome: it sits
                        // clear of the app's floating tab chrome above it.
                        .padding(.top, topInset)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: PageWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(PageWidthKey.self) { pageWidth = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.isSidebarVisible)
        .onAppear {
            reconcileSelection()
            measureFileListContentWidth()
        }
        .onChange(of: pageActive) { _, active in
            if active { reconcileSelection() }
        }
        .onChange(of: store.listVersion) { _, _ in
            reconcileSelection()
            measureFileListContentWidth()
        }
    }

    /// The floating file list's width: as far as the widest file path needs to
    /// read in full, and no further than the window (the list's own 8pt margin
    /// on each side is the only allowance). `fileListContentWidth` is measured
    /// once per changeset; the window clamp is re-evaluated live, so a resize
    /// shrank/grows it without re-measuring.
    private var sidebarWidth: CGFloat {
        let limit = max(0, pageWidth - 16)
        guard limit > 0 else { return minimumSidebarWidth }
        let desired = fileListContentWidth + sidebarChromeWidth
        return min(max(minimumSidebarWidth, desired), limit)
    }

    /// Measures the widest file list row (kind badge + path + stats, or the
    /// untracked note) and the header row, in points, from the same fonts the
    /// rows render with. Called when the changed set moves, never per body
    /// evaluation (a large changeset's paths must not be re-measured every
    /// frame).
    private func measureFileListContentWidth() {
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        }
        func statsWidth(added: Int, deleted: Int, font: NSFont) -> CGFloat {
            var total: CGFloat = 0
            if added > 0 { total += width("+\(added)", font) }
            if deleted > 0 {
                if added > 0 { total += 4 }
                total += width("−\(deleted)", font)
            }
            return total
        }

        let pathFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let statFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let countFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let noteFont = NSFont.systemFont(ofSize: 10)

        // The header: "Changed Files" + count capsule + total stats.
        var widest = width("Changed Files", titleFont)
        if !store.entries.isEmpty {
            widest += 8 + width("\(store.entries.count)", countFont) + 10
        }
        if let total = store.totalStats, total.total > 0 {
            widest += 8 + statsWidth(added: total.added, deleted: total.deleted, font: statFont)
        }

        for entry in store.entries {
            // 12pt badge frame + 6pt HStack spacing + path + 4pt minimum
            // spacer, then the row's stats (or the "new" note).
            var row = 12 + 6 + width(entry.path, pathFont)
            if let stats = entry.stats, stats.added + stats.deleted > 0 {
                row += 4 + statsWidth(added: stats.added, deleted: stats.deleted, font: statFont)
            } else if entry.kind == .untracked {
                row += 4 + width("new", noteFont)
            }
            widest = max(widest, row)
        }
        fileListContentWidth = widest
    }

    // MARK: - Selection

    /// Keeps the selected file valid: keeps it while it is still changed,
    /// otherwise falls back to the first (or clears when nothing changed).
    private func reconcileSelection() {
        guard !store.entries.isEmpty else {
            store.selectedPath = nil
            listSelection = nil
            // No diff to navigate: an open file list would only show its empty
            // state, and the nested sub-nav's toggle disappears with it.
            store.isSidebarVisible = false
            return
        }
        if let selected = store.selectedPath, store.entries.contains(where: { $0.path == selected }) {
            listSelection = selected
            return
        }
        store.selectedPath = store.entries.first?.path
        listSelection = store.selectedPath
    }

    // MARK: - Changed-files list

    private var changedList: some View {
        Group {
            if store.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("No changes")
                        .font(.system(size: 12, weight: .semibold))
                    Text("The working tree matches HEAD.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    // A real sidebar `List`: the platform's own selection
                    // highlight and Liquid Glass sidebar material.
                    List(store.entries, id: \.path, selection: $listSelection) { entry in
                        fileRow(entry)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .tint(Color.secondary)
                    // The scroll spy moves the highlight as the user scrolls
                    // the viewer: keep the row visible, and mirror the spy's
                    // choice into the local selection without requesting a
                    // scroll.
                    .onChange(of: store.selectedPath) { _, path in
                        if listSelection != path { listSelection = path }
                        guard let path else { return }
                        if reduceMotion {
                            proxy.scrollTo(path, anchor: .center)
                        } else {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(path, anchor: .center)
                            }
                        }
                    }
                    // A user (or keyboard) selection asks the viewer to scroll;
                    // a spy-driven selection is already equal to `selectedPath`
                    // and is skipped so it cannot fight the spy.
                    .onChange(of: listSelection) { _, path in
                        guard let path, path != store.selectedPath else { return }
                        store.reveal(path)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            listHeader
        }
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Text("Changed Files")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if !store.entries.isEmpty {
                Text("\(store.entries.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                totalStatsView
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    /// The changeset's total added/deleted lines, beside the file count. Reads
    /// as one summary ("3 files, +120 −34"); hidden when nothing is countable
    /// (untracked-only or binary changes already show their own badge).
    @ViewBuilder
    private var totalStatsView: some View {
        if let total = store.totalStats, total.total > 0 {
            HStack(spacing: 4) {
                if total.added > 0 {
                    Text("+\(total.added)")
                        .foregroundStyle(.green)
                }
                if total.deleted > 0 {
                    Text("−\(total.deleted)")
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Total \(total.added) lines added, \(total.deleted) lines deleted")
        }
    }

    private func fileRow(_ entry: GitStatus.FileEntry) -> some View {
        HStack(spacing: 6) {
            kindBadge(entry.kind)
            Text(entry.path)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            statsView(entry)
        }
        .help("Scroll to \(entry.path)")
        .accessibilityLabel("\(entry.path) — show diff")
    }

    /// Closes the floating file list when the reader clicks back into the
    /// diff. The list is navigation-only, so any click on the diff dismisses
    /// it; the outer ZStack's `.animation` drives the transition.
    private func dismissSidebar() {
        guard store.isSidebarVisible else { return }
        store.isSidebarVisible = false
    }

    // MARK: - Diff viewer

    private var diffArea: some View {
        ZStack(alignment: .topLeading) {
            if store.entries.isEmpty {
                ContentUnavailableView(
                    "No changes",
                    systemImage: "checkmark.circle",
                    description: Text("The working tree matches HEAD. Edit a file and its diff appears here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffBrowserView(
                    store: store,
                    documentVersion: store.documentVersion,
                    revealPath: store.revealPath,
                    revealLine: store.revealLine,
                    onRevealConsumed: { store.consumeReveal() },
                    onTopSectionChanged: { store.setTopSection($0) },
                    pageActive: pageActive,
                    // The document insets by the floating chrome always; the find
                    // bar's measured height (which already includes the chrome)
                    // when it is up.
                    topInset: search.isVisible ? headerHeight : topInset,
                    bottomInset: bottomInset,
                    search: search,
                    onBackgroundClick: { dismissSidebar() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Find-in-diff floats over the document; the sidebar toggle and the
            // selected file's title/position moved to the nested Changes
            // sub-nav (`ChangesSubNav`), under the Session/Changes switch. Only
            // rendered while the find bar is open, so an empty header never
            // reserves a top inset.
            if search.isVisible {
                floatingSearchHeader
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ViewerHeaderHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
        }
        .onPreferenceChange(ViewerHeaderHeightKey.self) { headerHeight = $0 }
    }

    /// Find-in-diff, floating over the code as its own glass capsule (the
    /// window toolbar is gone). The sidebar toggle and the selected file's
    /// title/position live in the nested Changes sub-nav instead.
    private var floatingSearchHeader: some View {
        CodeSearchBar(model: search, placeholder: "Find in diffs…")
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background { GlassBackground(shape: .capsule) }
            .padding(.horizontal, 10)
            // The bar floats directly under the app's tab chrome; `topInset` is
            // its height, so the capsule lands below the chrome. The measured
            // height includes it, so `diffArea` insets the document by it while
            // the find bar is up (and by `topInset` alone otherwise).
            .padding(.top, 8 + topInset)
            .padding(.bottom, 6)
    }

    // MARK: - Shared bits

    private func kindBadge(_ kind: GitStatus.Kind, large: Bool = false) -> some View {
        let letter: String
        let color: Color
        switch kind {
        case .added: letter = "A"; color = .green
        case .modified: letter = "M"; color = .orange
        case .deleted: letter = "D"; color = .red
        case .untracked: letter = "U"; color = .blue
        case .normal: letter = " "; color = .secondary
        }
        return Text(letter)
            .font(.system(size: large ? 10 : 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: large ? 16 : 12, alignment: .center)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func statsView(_ entry: GitStatus.FileEntry) -> some View {
        if let stats = entry.stats, stats.added + stats.deleted > 0 {
            HStack(spacing: 4) {
                if stats.added > 0 {
                    Text("+\(stats.added)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                }
                if stats.deleted > 0 {
                    Text("−\(stats.deleted)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }
            .accessibilityHidden(true)
        } else if entry.kind == .untracked {
            Text("new")
                .font(.system(size: 10))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
        }
    }
}

/// The viewer header's file title, acting as a link to the file's default
/// application. It reads as one accessible link (`.isLink` plus a label that
/// names the action, so VoiceOver announces "link" and activating it opens the
/// file), underlines and shows the pointing-hand cursor on hover, and carries a
/// tooltip. A plain `Button` keeps the keyboard/`Space` activation SwiftUI
/// already gives controls.
struct FileTitleLink: View {
    let path: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .underline(hovering)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .help("Open \(path) in the default application")
        .accessibilityAddTraits(.isLink)
        .accessibilityLabel("Open \(path) in the default application")
    }
}

/// Reports the floating Changes header's height up to `ChangesView`, which
/// passes it to the diff document as its top content inset — so the first line
/// can scroll to the top of the pane, under the header, instead of stopping
/// below it.
private struct ViewerHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the Changes page's own width up to `ChangesView`, so the floating
/// file list can grow to fit the longest path but never beyond the window.
private struct PageWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

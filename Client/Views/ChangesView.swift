import Core
import SwiftUI

/// The Changes page — the third nested page of a session tab, alongside the
/// conversation and the file browser. It is a review surface for exactly the
/// working tree's uncommitted changes: a list of the changed files on the left
/// (the navigation) and, on the right, the diff of the selected file rendered
/// GitHub-PR style — only the changed regions plus a few context lines, one
/// `@@ … @@` header per hunk. Picking a file in the list switches the diff.
///
/// The page is a thin reader of the session's `FileBrowserStore` (the changed
/// list, kinds, and +/− counts are already computed there for the file tree),
/// and reuses `ReadOnlyFilePane` in `.hunks` mode for the diff itself — so the
/// gutter, the syntax highlighting, and above all the pasteboard reference
/// behavior (a copy writes a `CodeReference` pointing at the REAL file and its
/// real line numbers, never at this diff buffer) are the file browser's own,
/// not a parallel implementation.
///
/// The diff HEADER's file name is a link to the full Files page — the diff is
/// a lens, not a destination to copy from. The list itself only navigates the
/// diff.
struct ChangesView: View {
    let store: FileBrowserStore
    /// Whether the Changes page is the visible page. The view stays mounted
    /// while hidden, but the diff pane defers its loads (see
    /// `ReadOnlyFilePane.pageActive`) — no file IO, git show, or highlighting
    /// for an off-screen page.
    var pageActive = true
    /// Opens `path` in the full file browser (switches the session to the
    /// Files page and reveals the file). Supplied by the owning `SessionTab`.
    let onOpenInFiles: (String) -> Void

    /// The file whose diff is shown. View state, keyed per tab by the parent's
    /// `.id(tab.id)`, so it survives page flips but not session switches.
    @State private var selectedPath: String?
    /// Memoized changed-file list (mirrors `FileBrowserView.RowMemo`): the
    /// body reads it many times per pass, and filtering a large dictionary
    /// every read would be O(files) per read.
    @State private var listMemo = ChangedListMemo()
    /// Bumped when a file-change event names the diffed file (or a turn end,
    /// which does not name one), so a live edit to the file being reviewed
    /// re-reads its hunks. The file browser has its own token for its own
    /// selection; sharing one would reload the wrong pane.
    @State private var reloadToken = 0

    /// The changed files in a stable review order (by path). `FileEntry` is a
    /// value type, so the memo holds copies, never the store's dictionary.
    private var changedEntries: [GitStatus.FileEntry] {
        if listMemo.version != store.version {
            listMemo.version = store.version
            listMemo.entries = store.fileEntries.values
                .filter { $0.kind != .normal }
                .sorted { $0.path < $1.path }
        }
        return listMemo.entries
    }

    private var selectedEntry: GitStatus.FileEntry? {
        guard let selectedPath else { return nil }
        return changedEntries.first { $0.path == selectedPath }
    }

    private var selectedIndex: Int {
        guard let selectedPath else { return -1 }
        return changedEntries.firstIndex { $0.path == selectedPath } ?? -1
    }

    var body: some View {
        HStack(spacing: 0) {
            changedList
                .frame(width: 280)
            Divider()
            diffArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { reconcileSelection() }
        // The page became visible: apply the selection policy against the
        // latest snapshot (a hidden mount skipped it) — the mirror of the file
        // browser's activation catch-up.
        .onChange(of: pageActive) { _, active in
            if active { reconcileSelection() }
        }
        // A refresh can add the first change, remove the selected file (it was
        // reverted), or reorder nothing (sort is stable). Keep the selection
        // pointing at a file that still exists.
        .onChange(of: store.version) { _, _ in
            reconcileSelection()
        }
        // Reload the open diff when the agent touches the file it shows (or
        // when a turn settles and any file may have changed). A file the user
        // isn't reviewing must not reload the pane out from under them.
        .onReceive(NotificationCenter.default.publisher(for: GitStatus.didChangeNotification)) { note in
            guard (note.userInfo?["cwd"] as? URL) == store.cwd else { return }
            let path = note.userInfo?["path"] as? String
            if path == nil || path == selectedPath {
                reloadToken &+= 1
            }
        }
    }

    // MARK: - Selection

    /// Points the selection at an existing changed file: keeps it if it is
    /// still changed, otherwise falls back to the first (or clears when there
    /// is nothing changed).
    private func reconcileSelection() {
        let entries = changedEntries
        guard !entries.isEmpty else {
            selectedPath = nil
            return
        }
        if let selectedPath, entries.contains(where: { $0.path == selectedPath }) {
            return
        }
        selectedPath = entries.first?.path
    }

    // MARK: - Changed-files list

    private var changedList: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
            if changedEntries.isEmpty {
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
                // Keeps the selected row visible when the selection changes
                // underneath the user (e.g. the reviewed file was reverted and
                // the fallback picks the first changed file).
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(changedEntries, id: \.path) { entry in
                                fileRow(entry)
                                    .id(entry.path)
                            }
                        }
                        .padding(4)
                    }
                    .onChange(of: selectedPath) { _, path in
                        guard let path else { return }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(path, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Text("Changed Files")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if !changedEntries.isEmpty {
                Text("\(changedEntries.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private func fileRow(_ entry: GitStatus.FileEntry) -> some View {
        let isSelected = entry.path == selectedPath
        return Button {
            selectedPath = entry.path
        } label: {
            HStack(spacing: 6) {
                kindBadge(entry.kind)
                Text(entry.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                statsView(entry)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the diff for \(entry.path)")
        .accessibilityLabel("\(entry.path) — show diff")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Diff pane

    private var diffArea: some View {
        VStack(spacing: 0) {
            diffHeader
            Divider()
            if let entry = selectedEntry {
                ReadOnlyFilePane(
                    cwd: store.cwd,
                    path: entry.path,
                    kind: entry.kind,
                    reloadToken: reloadToken,
                    pageActive: pageActive,
                    mode: .hunks
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No changes",
                    systemImage: "checkmark.circle",
                    description: Text("The working tree matches HEAD. Edit a file and its diff appears here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var diffHeader: some View {
        HStack(spacing: 8) {
            if let entry = selectedEntry {
                kindBadge(entry.kind, large: true)
                Button {
                    onOpenInFiles(entry.path)
                } label: {
                    HStack(spacing: 5) {
                        Text(entry.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the full file in the Files page")
                statsView(entry)
            } else {
                Text("Changes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !changedEntries.isEmpty {
                Text("\(max(selectedIndex, 0) + 1) of \(changedEntries.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(Color(nsColor: .textBackgroundColor))
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

/// Cache for the memoized changed-file list. A class so a body evaluation can
/// refresh it without writing `@State` (which would re-invalidate the view).
@MainActor
private final class ChangedListMemo {
    var version = -1
    var entries: [GitStatus.FileEntry] = []
}

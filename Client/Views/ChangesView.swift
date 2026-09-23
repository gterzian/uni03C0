import Core
import SwiftUI

/// The Changes page — the review surface for the session folder's uncommitted
/// changes. A list of the changed files on the left (the navigation) and, on
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
    let store: ChangesStore
    /// Whether the Changes page is the visible page. The view stays mounted
    /// while hidden, but the viewer defers its rebuilds (no file IO, git, or
    /// syntax highlighting for an off-screen page).
    var pageActive = true

    /// Find-in-diff state for the whole viewer (Cmd+F).
    @State private var search = CodeSearchModel()

    var body: some View {
        HStack(spacing: 0) {
            changedList
                .frame(width: 280)
            Divider()
            diffArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { reconcileSelection() }
        .onChange(of: pageActive) { _, active in
            if active { reconcileSelection() }
        }
        .onChange(of: store.listVersion) { _, _ in
            reconcileSelection()
        }
    }

    // MARK: - Selection

    /// Keeps the selected file valid: keeps it while it is still changed,
    /// otherwise falls back to the first (or clears when nothing changed).
    private func reconcileSelection() {
        guard !store.entries.isEmpty else {
            store.selectedPath = nil
            return
        }
        if let selected = store.selectedPath, store.entries.contains(where: { $0.path == selected }) {
            return
        }
        store.selectedPath = store.entries.first?.path
    }

    // MARK: - Changed-files list

    private var changedList: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(store.entries, id: \.path) { entry in
                                fileRow(entry)
                                    .id(entry.path)
                            }
                        }
                        .padding(4)
                    }
                    // The scroll spy moves the selection as the user scrolls the
                    // viewer: keep the highlighted row visible.
                    .onChange(of: store.selectedPath) { _, path in
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
        let isSelected = entry.path == store.selectedPath
        return Button {
            store.reveal(entry.path)
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
        .help("Scroll to \(entry.path)")
        .accessibilityLabel("\(entry.path) — show diff")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Diff viewer

    private var diffArea: some View {
        VStack(spacing: 0) {
            viewerHeader
            Divider()
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
                    search: search
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var viewerHeader: some View {
        HStack(spacing: 8) {
            if let selected = store.selectedPath {
                // The title IS the open-in-default-app affordance: the viewer
                // shows a diff window, so the title hands the whole file to an
                // editor. Plain text for a deleted file (nothing on disk).
                if store.canOpenInDefaultApp(selected) {
                    FileTitleLink(path: selected) { store.openInDefaultApp(selected) }
                } else {
                    Text(selected)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let index = store.entries.firstIndex(where: { $0.path == selected }) {
                    Text("\(index + 1) of \(store.entries.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("File \(index + 1) of \(store.entries.count)")
                }
            } else {
                Text("Changes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if search.isVisible {
                CodeSearchBar(model: search, placeholder: "Find in diffs…")
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

/// The viewer header's file title, acting as a link to the file's default
/// application. It reads as one accessible link (`.isLink` plus a label that
/// names the action, so VoiceOver announces "link" and activating it opens the
/// file), underlines and shows the pointing-hand cursor on hover, and carries a
/// tooltip. A plain `Button` keeps the keyboard/`Space` activation SwiftUI
/// already gives controls.
private struct FileTitleLink: View {
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

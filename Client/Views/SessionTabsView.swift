import AppKit
import Core
import SwiftUI

/// The tabbed main window: one tab per live session, all sharing the same
/// sandbox settings (each session snapshots `SandboxSettings` at spawn). The
/// first tab is the project the window opened on; the "+" button starts a new
/// session in a folder of the user's choice.
///
/// Non-active tabs show their session's status — the same spinner/stop icons
/// as the toolbar's Stop button — so you can see at a glance which sessions
/// are working. Only the active tab renders its transcript; background tabs
/// keep folding their event stream off the main thread.
struct SessionTabsView: View {
    let initialCwd: URL

    @State private var tabs: [SessionTab] = []
    @State private var activeID: SessionTab.ID?

    init(initialCwd: URL) {
        self.initialCwd = initialCwd
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let active = activeTab {
                SessionContent(tab: active)
            }
            tabShortcuts
        }
        .navigationTitle(activeTab?.cwd.lastPathComponent ?? "uni03C0")
        .toolbar {
            if let active = activeTab {
                SessionToolbar.content(tab: active)
            }
        }
        .task { await bootstrap() }
        .onDisappear { tearDownAll() }
    }

    private var activeTab: SessionTab? {
        guard let activeID else { return tabs.first }
        return tabs.first { $0.id == activeID } ?? tabs.first
    }

    // MARK: - Tab management

    /// Creates the first tab (the project the window opened on) once.
    private func bootstrap() async {
        guard tabs.isEmpty else { return }
        await addTab(cwd: initialCwd)
    }

    /// Creates a session for `cwd`, makes it the active tab, and starts the
    /// agent. The tab (and its empty transcript) appears immediately; the
    /// process + RPC handshake happen in `start()`. The sandbox settings
    /// (and the workspace) are snapshotted per tab at creation, so a new tab
    /// picks up the current values while running sessions keep what they
    /// started with.
    private func addTab(cwd: URL, activate: Bool = true) async {
        let tab = SessionTab(cwd: cwd, projectsRoot: AppState.shared.projectsRoot)
        tabs.append(tab)
        if activate { activeID = tab.id }
        await tab.start()
    }

    private func closeTab(_ tab: SessionTab) {
        // Keep at least one session — a bare "+" window is not a thing.
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if activeID == tab.id {
            // Prefer the tab to the right; fall back to the one on the left.
            activeID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        Task { await tab.stop() }
    }

    private func tearDownAll() {
        let all = tabs
        tabs = []
        activeID = nil
        Task {
            for tab in all { await tab.stop() }
        }
    }

    /// "+" — pick a folder to start a new session in. Any folder works, but
    /// the agent's workspace is the projects folder (every project inside it
    /// is read+write). The panel opens on the right-most tab's folder (a new
    /// session usually continues from the same project area), falling back to
    /// the projects root while no tabs exist yet.
    private func chooseFolderAndAddTab() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Session"
        panel.message = "Choose the folder to start a new agent session in. The agent's workspace is your projects folder — every project inside it is read + write."
        panel.directoryURL = tabs.last?.cwd ?? AppState.shared.projectsRoot
        if panel.runModal() == .OK, let url = panel.url {
            Task { await addTab(cwd: url) }
        }
    }

    private func cycleTab(by delta: Int) {
        guard !tabs.isEmpty, let current = activeTab,
              let index = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        activeID = tabs[(index + delta + tabs.count) % tabs.count].id
    }

    /// Hidden keyboard shortcuts for tab management, Safari-style: Cmd+T
    /// starts a new session, Cmd+1…9 switches to the numbered session, and
    /// Cmd+Shift+[ / Cmd+Shift+] cycle to the previous / next session. The
    /// buttons are zero-size and invisible; only their key equivalents are
    /// live (key equivalents fire even while typing in the prompt input,
    /// matching tabbed-browser behavior).
    private var tabShortcuts: some View {
        ZStack {
            Button("") { chooseFolderAndAddTab() }
                .keyboardShortcut("t", modifiers: .command)
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                Button("") { activeID = tab.id }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("") { cycleTab(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("") { cycleTab(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(tabs) { tab in
                tabPill(tab)
            }
            Button {
                chooseFolderAndAddTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Start a new session in another folder")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// One tab: the session's folder name, its live status icon (spinner
    /// while working, stop glyph when idle — the same icons as the toolbar's
    /// Stop button), and a close button (hidden while it's the only tab).
    private func tabPill(_ tab: SessionTab) -> some View {
        let isActive = tab.id == activeID
        return HStack(spacing: 4) {
            Button {
                activeID = tab.id
            } label: {
                HStack(spacing: 6) {
                    statusIcon(tab)
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)
                    Text(tab.cwd.lastPathComponent)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if tabs.count > 1 {
                Button {
                    closeTab(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(3)
                }
                .buttonStyle(.plain)
                .help("Close this session")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, tabs.count > 1 ? 6 : 10)
        .padding(.vertical, 4)
        .background(
            isActive ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
        .onTapGesture { activeID = tab.id }
        .help(tab.cwd.path)
    }

    /// The same status icons as the toolbar's Stop button: a spinner while the
    /// session is working, the stop glyph when idle.
    @ViewBuilder
    private func statusIcon(_ tab: SessionTab) -> some View {
        if tab.viewModel.isStreaming {
            ProgressView()
                .controlSize(.mini)
        } else {
            Image(systemName: "stop")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
        }
    }
}

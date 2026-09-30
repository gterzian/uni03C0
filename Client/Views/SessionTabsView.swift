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
    /// The measured height of the floating tab panel: the transcript's top
    /// content inset, so conversation content scrolls to the very top and
    /// bleeds under the glass instead of stopping below it.
    @State private var tabPanelHeight: CGFloat = 0

    init(initialCwd: URL) {
        self.initialCwd = initialCwd
    }

    var body: some View {
        // The tab panel FLOATS over the session content: the pills carry their
        // own Liquid Glass, and the content scrolls under them (no painted
        // bar, per Apple's "reduce custom backgrounds in navigation").
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if let active = activeTab {
                    SessionContent(tab: active, topInset: tabPanelHeight)
                }
                tabShortcuts
            }
            tabPanel
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: TabPanelHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .onPreferenceChange(TabPanelHeightKey.self) { tabPanelHeight = $0 }
        // The split view's automatic sidebar toggle lives in the window
        // toolbar; remove it and keep the toggle in the diff panel's own
        // floating chrome instead.
        .toolbar(removing: .sidebarToggle)
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
    /// is read+write). The panel opens on the ACTIVE tab's folder (a new
    /// session usually continues from the project you're looking at), falling
    /// back to the projects root while no tabs exist yet.
    private func chooseFolderAndAddTab() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Session"
        panel.message = "Choose the folder to start a new agent session in. The agent's workspace is your projects folder — every project inside it is read + write."
        panel.directoryURL = activeTab?.cwd ?? AppState.shared.projectsRoot
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

    // MARK: - Tab panel

    /// The whole tab chrome: the outer session tabs (one per folder) plus, for
    /// the ACTIVE session only, its nested page tabs — Session / Changes. The
    /// nested strip lives in the PANEL (not the session content) so it reads as
    /// navigation within the active top-level tab: it hangs directly under the
    /// active pill, shares the panel's background, and disappears when another
    /// session tab is selected (each session keeps its own page choice).
    private var tabPanel: some View {
        // The panel's glass lives on the two capsules (the tab row and the
        // nested Session/Changes switch), each an AppKit `NSGlassEffectView`
        // (see `GlassBackground`) rather than SwiftUI's `.glassEffect`: the
        // SwiftUI modifier renders through the hosting tree and re-renders the
        // whole sampled backdrop (the session window) whenever the streaming
        // content behind it changes.
        VStack(alignment: .leading, spacing: 0) {
            outerTabBar
                .padding(.horizontal, 10)
                .padding(.top, 6)
            if let active = activeTab {
                nestedPageTabs(active)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var outerTabBar: some View {
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
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        // One liquid group: a capsule that gathers the small pills into a
        // single, findable unit. It is sized to its content — never a
        // full-width bar. The one glass surface for the whole tab row (the
        // pills themselves are plain content on it): AppKit Liquid Glass, see
        // `GlassBackground` — the SAME material as the nested page tabs, the
        // composer, and every other glass surface.
        .fixedSize()
        .background { GlassBackground(shape: .capsule) }
    }

    /// Session / Changes — the page tabs of the ACTIVE session, nested under
    /// its outer pill (see `tabPanel`). A real segmented control, so the Liquid
    /// Glass segmented look and the platform's own semantics (selected state,
    /// group traits, keyboard traversal) come for free — the old custom pills
    /// had to stitch those together by hand. A segment has no native badge
    /// slot, so the edited-file count rides in the Changes label.
    private func nestedPageTabs(_ tab: SessionTab) -> some View {
        @Bindable var tab = tab
        return HStack(spacing: 8) {
            // A neutral glass segmented control: the native segmented picker
            // paints its selection in the system accent (too loud here), so
            // this keeps the same floating-pill language as the tabs and marks
            // the selected segment with a quiet primary tint instead.
            HStack(spacing: 0) {
                pageTab("Session", selected: tab.page == .conversation) {
                    tab.page = .conversation
                }
                pageTab(changesTitle(tab.gitChangeCount), selected: tab.page == .changes) {
                    tab.page = .changes
                }
            }
            .padding(2)
            .background { GlassBackground(shape: .capsule) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// One segment of the Session/Changes switch. Neutral by design: a
    /// primary-tint fill marks the selection instead of the accent colour.
    private func pageTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(selected ? Color.accentColor.opacity(0.10) : Color.clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityLabel(title)
    }

    /// The Changes segment's title, carrying the edited-file count when there
    /// is one (the badge the custom pill used to draw).
    private func changesTitle(_ count: Int?) -> String {
        if let count, count > 0 {
            return "Changes (\(count))"
        }
        return "Changes"
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
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    Text(tab.cwd.lastPathComponent)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
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
        // The pills are plain content on the row's single AppKit glass capsule
        // (see `outerTabBar`); the active one carries only a faint accent fill.
        // A per-pill glass would nest glass shapes over the streaming content —
        // another sampled backdrop — and Liquid Glass can't sample glass
        // consistently.
        .background {
            if isActive {
                Capsule().fill(Color.accentColor.opacity(0.12))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { activeID = tab.id }
        .help(tab.cwd.path)
    }

    /// The same status icons as the toolbar's Stop button: a spinner while the
    /// session is working, the stop glyph when idle. The spinner is the AppKit
    /// `NSProgressIndicator` (see `SpinnerView`), never SwiftUI's animated
    /// `ProgressView` — a SwiftUI spinner in the tab bar would keep the whole
    /// window content graph invalidating every frame for the entire stream.
    @ViewBuilder
    private func statusIcon(_ tab: SessionTab) -> some View {
        if tab.viewModel.isStreaming {
            SpinnerView(controlSize: .mini)
                .frame(width: 16)
        } else {
            Image(systemName: "stop")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
        }
    }
}

// MARK: - Tab panel height preference

/// Reports the floating tab panel's height to `SessionTabsView`, which passes
/// it to the transcript as a top content inset — the conversation scrolls
/// under the panel, never hidden behind it.
private struct TabPanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

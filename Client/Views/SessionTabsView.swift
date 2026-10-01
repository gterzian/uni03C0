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
    /// The measured height of the floating top chrome (the tab nav on the left,
    /// the session controls on the right): the transcript's top content inset,
    /// so conversation content scrolls to the very top and bleeds under the
    /// glass instead of stopping below it.
    @State private var topChromeHeight: CGFloat = 0

    init(initialCwd: URL) {
        self.initialCwd = initialCwd
    }

    var body: some View {
        // The whole top bar FLOATS over the session content: the native
        // titlebar is transparent with no toolbar (see `MainWindowTag`), and
        // every control carries its own Liquid Glass, so the content scrolls
        // under it (no painted bar, per Apple's "reduce custom backgrounds in
        // navigation"). The tab nav + page switch sit top-left; the app-level
        // session controls (stop/reload, model, thinking, resume, appearance)
        // sit top-right — the same functional split the old toolbar had.
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if let active = activeTab {
                    SessionContent(tab: active, topInset: topChromeHeight)
                }
                tabShortcuts
            }
            // The floating chrome overlays the content: each control cluster
            // carries its own AppKit Liquid Glass, so the pills blur whatever
            // is behind THEM — there is no backdrop band, content stays sharp
            // right up to the window's top edge.
            topChrome
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: TopChromeHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .onPreferenceChange(TopChromeHeightKey.self) { topChromeHeight = $0 }
        // The titlebar is hidden (see `ClientApp` / `MainWindowTag`), but
        // SwiftUI still reserves its height as a top safe area — that reserved
        // strip is the empty band above the floating chrome. Draw from the
        // window's very top edge instead; the chrome clears the traffic lights
        // with its own leading padding, and the transcript/diff scroll under
        // both. The chrome's measured height (including this padding) is what
        // the content insets by, so nothing hides behind it.
        .ignoresSafeArea(.container, edges: .top)
        // The window title is hidden by the transparent titlebar, but kept for
        // the Window menu / Mission Control.
        .navigationTitle(activeTab?.cwd.lastPathComponent ?? "uni03C0")
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

    // MARK: - Top chrome

    /// The floating top chrome: the tab navigation on the left (outer session
    /// tabs plus the active session's nested Session / Changes switch) and the
    /// app-level session controls on the right. An in-session find bar, when
    /// open, floats between them. Each cluster carries its own AppKit Liquid
    /// Glass (see `GlassBackground`), never SwiftUI's `.glassEffect`: the
    /// SwiftUI modifier renders through the hosting tree and re-renders the
    /// whole sampled backdrop (the session window) whenever the streaming
    /// content behind it changes.
    ///
    /// With the native titlebar transparent and no toolbar, the traffic lights
    /// float at the window's top-left, so the leading padding clears them.
    private var topChrome: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                outerTabBar
                    .padding(.horizontal, 10)
                if let active = activeTab {
                    nestedPageTabs(active)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            if let active = activeTab, active.viewModel.isSearchVisible {
                SessionSearchBar(vm: active.viewModel)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background { GlassBackground(shape: .capsule) }
            }

            Spacer(minLength: 8)

            if let active = activeTab {
                SessionToolbarView(tab: active)
            }
        }
        .padding(.leading, 78)
        .padding(.trailing, 12)
        .padding(.top, 6)
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
    /// its outer pill (see `topChrome`). A real segmented control, so the Liquid
    /// Glass segmented look and the platform's own semantics (selected state,
    /// group traits, keyboard traversal) come for free — the old custom pills
    /// had to stitch those together by hand. A segment has no native badge
    /// slot, so the edited-file count rides in the Changes label.
    private func nestedPageTabs(_ tab: SessionTab) -> some View {
        @Bindable var tab = tab
        // A neutral glass segmented control: the native segmented picker
        // paints its selection in the system accent (too loud here), so
        // this keeps the same floating-pill language as the tabs and marks
        // the selected segment with a quiet primary tint instead.
        return HStack(spacing: 0) {
            pageTab("Session", selected: tab.page == .conversation) {
                tab.page = .conversation
            }
            pageTab(changesTitle(tab.gitChangeCount), selected: tab.page == .changes) {
                tab.page = .changes
            }
        }
        .padding(2)
        .background { GlassBackground(shape: .capsule) }
        .fixedSize()
        // Content-sized: the nested switch hangs under the outer pills and
        // must not stretch the leading cluster into the settings cluster.
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

// MARK: - Top chrome height preference

/// Reports the floating top chrome's height to `SessionTabsView`, which passes
/// it to the transcript as a top content inset — the conversation scrolls
/// under the chrome, never hidden behind it.
private struct TopChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

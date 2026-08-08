import AppKit
import Core
import SwiftUI

/// One project window. With no project chosen (`project.cwd == nil`) shows a
/// picker and spawns nothing; once a project is selected, opens the tabbed
/// session window on that project (the first tab; "+" adds more sessions).
struct MainWindowView: View {
    @Binding var project: ProjectRef

    var body: some View {
        Group {
            // First run / no projects folder chosen: always show the picker,
            // even if window restoration brought back a stale project value.
            if let cwd = project.cwd, AppState.shared.projectsRoot != nil {
                SessionTabsView(initialCwd: cwd)
            } else {
                ProjectPickerView { url in
                    AppState.shared.lastProject = url
                    project = ProjectRef(cwd: url)
                }
            }
        }
        .background(MainWindowTag())
    }
}

/// Tags the window this view lives in, so menu commands and the app
/// delegate's single-window guard can identify the main window (as opposed to
/// the Settings window).
struct MainWindowTag: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.identifier = NSUserInterfaceItemIdentifier(SceneIDs.mainWindow)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A live session for one project: transcript (AppKit) + prompt bar (AppKit-
/// backed for Tab completion) + toolbar menus bound to this session. Used by
/// the menu-bar quick prompt; the main window uses the tabbed
/// `SessionTabsView` instead.
struct SessionView: View {
    let cwd: URL

    @State private var tab: SessionTab?

    init(cwd: URL) {
        self.cwd = cwd
    }

    var body: some View {
        Group {
            if let tab {
                SessionContent(tab: tab)
            } else {
                ProgressView("Starting agent…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(cwd.lastPathComponent)
        .toolbar {
            if let tab {
                SessionToolbar.content(tab: tab)
            }
        }
        .task(id: cwd) { await start() }
        .onDisappear { tearDown() }
    }

    private func start() async {
        // The task restarts when `cwd` changes (picker -> project, or the
        // window's value is replaced): stop any stale session first.
        if let existing = tab, existing.cwd != cwd {
            await existing.stop()
            tab = nil
        }
        guard tab == nil else { return }
        let newTab = SessionTab(cwd: cwd, projectsRoot: AppState.shared.projectsRoot)
        tab = newTab
        await newTab.start()
    }

    private func tearDown() {
        guard let tab else { return }
        self.tab = nil
        Task { await tab.stop() }
    }
}

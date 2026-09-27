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
/// the Settings window). It also removes the split view's automatic
/// sidebar-toggle toolbar item: SwiftUI adds it for `NavigationSplitView`, and
/// `.toolbar(removing:)` does not reliably win, but the toggle belongs in the
/// diff panel's own floating chrome.
struct MainWindowTag: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator {
        private var observer: NSObjectProtocol?
        private weak var observedToolbar: NSToolbar?

        func attach(to view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                view.window?.identifier = NSUserInterfaceItemIdentifier(SceneIDs.mainWindow)
                guard let toolbar = view.window?.toolbar else { return }
                self.observe(toolbar)
                Self.removeToggle(from: toolbar)
            }
        }

        private func observe(_ toolbar: NSToolbar) {
            guard observedToolbar !== toolbar else { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observedToolbar = toolbar
            observer = NotificationCenter.default.addObserver(
                forName: NSToolbar.willAddItemNotification,
                object: toolbar,
                queue: .main
            ) { note in
                guard let toolbar = note.object as? NSToolbar,
                      let item = note.userInfo?[NSToolbarUserInfoKey.itemKey] as? NSToolbarItem,
                      item.itemIdentifier == .toggleSidebar else { return }
                DispatchQueue.main.async {
                    if let index = toolbar.items.firstIndex(of: item) {
                        toolbar.removeItem(at: index)
                    }
                }
            }
        }

        static func removeToggle(from toolbar: NSToolbar) {
            for item in toolbar.items where item.itemIdentifier == .toggleSidebar {
                if let index = toolbar.items.firstIndex(of: item) {
                    toolbar.removeItem(at: index)
                }
            }
        }
    }
}

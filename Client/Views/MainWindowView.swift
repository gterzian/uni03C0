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

import SwiftUI

/// Scene identifiers. The main-window id intentionally differs from the
/// original "main": a stale SwiftUI window-value restoration keyed to the old
/// id was re-opening the previously selected project at launch. A fresh id
/// (and a nil default value) means startup always shows the picker and spawns
/// nothing.
enum SceneIDs {
    static let mainWindow = "main-v2"
}

@main
struct ClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared

    var body: some Scene {
        WindowGroup("uni03C0", id: SceneIDs.mainWindow, for: ProjectRef.self) { $project in
            MainWindowView(project: $project)
        } defaultValue: {
            // First run (no projects folder chosen yet): open on the picker,
            // which includes the sandbox setup fields. Otherwise resume where
            // the user left off.
            ProjectRef(cwd: AppState.shared.projectsRoot == nil ? nil : AppState.shared.lastProject)
        }
        .defaultSize(width: 920, height: 720)
        .commands {
            AppCommands()
        }

        MenuBarExtra("uni03C0", systemImage: "terminal.fill") {
            QuickPromptView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SandboxSettingsView()
        }
    }
}

/// Identifies a project window by its working directory. `cwd == nil` means
/// "no project chosen yet" — the window shows a picker and spawns nothing.
struct ProjectRef: Hashable, Codable {
    var cwd: URL?
}

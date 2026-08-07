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
        WindowGroup("π", id: SceneIDs.mainWindow, for: ProjectRef.self) { $project in
            MainWindowView(project: $project)
        } defaultValue: {
            // Start in the last project that was selected before shutdown, so
            // the app resumes where the user left off. Falls back to the
            // picker when no project has ever been chosen.
            ProjectRef(cwd: AppState.shared.lastProject)
        }
        .defaultSize(width: 920, height: 720)
        .commands {
            AppCommands()
        }

        MenuBarExtra("π", systemImage: "terminal.fill") {
            QuickPromptView()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Identifies a project window by its working directory. `cwd == nil` means
/// "no project chosen yet" — the window shows a picker and spawns nothing.
struct ProjectRef: Hashable, Codable {
    var cwd: URL?
}

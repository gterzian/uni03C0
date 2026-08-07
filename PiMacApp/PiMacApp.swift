import SwiftUI

@main
struct PiNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared

    var body: some Scene {
        WindowGroup("Pi", id: "main", for: ProjectRef.self) { $project in
            MainWindowView(cwd: project.cwd)
        } defaultValue: {
            ProjectRef(cwd: AppState.shared.defaultProject())
        }
        .defaultSize(width: 920, height: 720)
        .commands {
            AppCommands()
        }

        MenuBarExtra("Pi", systemImage: "terminal.fill") {
            QuickPromptView()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Identifies a project window by its working directory.
struct ProjectRef: Hashable, Codable {
    var cwd: URL
}

import AppKit
import SwiftUI

/// App data locations per §8 of the design: the native client's own small
/// footprint lives in the standard Library folders under a bundle-ID-scoped
/// subdirectory; `~/.pi` is pi's and is only read (or mutated via RPC).
enum AppStorage {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.gterzian.client"

    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var cachesDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Main-menu commands (Projects menu lives here; Model/Thinking/Resume are
/// per-window toolbar menus bound to that window's session).
struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var appState = AppState.shared

    var body: some Commands {
        // Single-window app: no File > New / Cmd-N. The app opens its one
        // window at startup; switching projects replaces that window.
        CommandGroup(replacing: .newItem) {}

        CommandMenu("View") {
            FontSizeCommands()
        }

        CommandMenu("Projects") {
            ForEach(appState.projects, id: \.self) { project in
                Button(project.lastPathComponent) {
                    switchToProject(project)
                }
            }
            Divider()
            Button("Sandbox Settings…") {
                openSettings()
            }
            Button("Choose Projects Folder…") {
                appState.chooseProjectsRoot()
            }
        }
    }

    /// Switches the single window to another project: closes the current main
    /// window and opens a fresh one. Never creates a second window.
    private func switchToProject(_ project: URL) {
        appState.lastProject = project
        for window in NSApp.windows where window.identifier?.rawValue == SceneIDs.mainWindow {
            window.close()
        }
        openWindow(id: SceneIDs.mainWindow, value: ProjectRef(cwd: project))
    }
}

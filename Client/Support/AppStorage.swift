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
    @State private var appState = AppState.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: SceneIDs.mainWindow, value: ProjectRef(cwd: nil))
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Projects") {
            Button("New Window") {
                openWindow(id: SceneIDs.mainWindow, value: ProjectRef(cwd: nil))
            }
            Divider()
            ForEach(appState.projects, id: \.self) { project in
                Button(project.lastPathComponent) {
                    appState.lastProject = project
                    openWindow(id: SceneIDs.mainWindow, value: ProjectRef(cwd: project))
                }
            }
            Divider()
            Button("Choose Projects Folder…") {
                appState.chooseProjectsRoot()
            }
        }
    }
}

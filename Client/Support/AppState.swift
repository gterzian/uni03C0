import AppKit
import Foundation
import Observation

/// App-wide state: the one-time "Projects" root folder setting (§7.5) and the
/// last-opened project. Stored as plain UserDefaults keys; no sandbox, so a
/// stored path keeps working across launches.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    private static let projectsRootKey = "projectsRootPath"
    private static let lastProjectKey = "lastProjectPath"

    var projectsRoot: URL? {
        didSet {
            UserDefaults.standard.set(projectsRoot?.path, forKey: Self.projectsRootKey)
        }
    }

    var lastProject: URL? {
        didSet {
            UserDefaults.standard.set(lastProject?.path, forKey: Self.lastProjectKey)
        }
    }

    private init() {
        if let path = UserDefaults.standard.string(forKey: Self.projectsRootKey) {
            projectsRoot = URL(fileURLWithPath: path)
        }
        if let path = UserDefaults.standard.string(forKey: Self.lastProjectKey) {
            lastProject = URL(fileURLWithPath: path)
        }
    }

    /// First-level subdirectories of the projects root, hidden/dotfiles skipped.
    var projects: [URL] {
        guard let root = projectsRoot else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return contents.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let isHidden = url.lastPathComponent.hasPrefix(".")
            return isDir && !isHidden ? url : nil
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Where a new window defaults when no project is selected: the last
    /// explicitly opened project, or nil (the picker is shown, nothing spawns).
    func defaultProject() -> URL? {
        lastProject
    }

    /// Opens the directory picker; stores the result. Not sandboxed, so this
    /// is genuinely this simple.
    func chooseProjectsRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that contains your projects"
        if panel.runModal() == .OK, let url = panel.url {
            projectsRoot = url
        }
    }
}

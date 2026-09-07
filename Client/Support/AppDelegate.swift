import AppKit
import Foundation
import Core

/// Registry of live pi subprocesses so app termination can always signal EOF
/// (finish stdin) to every child — otherwise dev iteration would accumulate
/// orphaned node processes.
@MainActor
enum LiveSessions {
    static var controllers: [ObjectIdentifier: ProcessController] = [:]

    static func register(_ controller: ProcessController) {
        controllers[ObjectIdentifier(controller)] = controller
    }

    static func unregister(_ controller: ProcessController) {
        controllers.removeValue(forKey: ObjectIdentifier(controller))
    }

    static func terminateAll() async {
        let all = Array(controllers.values)
        controllers.removeAll()
        for controller in all {
            await controller.terminate()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register the bundled skills directory in pi's GLOBAL settings, so
        // every session the app spawns can load the app-bundled skills (the
        // `file-reference-links` skill the agent is taught to use). The skill
        // files live in the app bundle (Resources/Skills) — this only writes
        // the pointer to ~/.pi/agent/settings.json and never touches any pi
        // file otherwise. Off the main thread: a once-at-launch file read.
        if let resources = Bundle.main.resourceURL {
            let skills = resources.appendingPathComponent("Skills", isDirectory: true)
            let bundledSkill = skills.appendingPathComponent("file-reference-links/SKILL.md")
            if FileManager.default.fileExists(atPath: bundledSkill.path) {
                Task.detached(priority: .utility) {
                    PiAgentSettings.registerSkillsDirectory(skills)
                }
            }
        }
        // Single-window app: if a second main window ever appears (e.g. via
        // the system Window menu), keep only the newest one. The Settings
        // window is not tagged with the main identifier, so it is exempt.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.closeDuplicateMainWindows()
        }
    }

    private func closeDuplicateMainWindows() {
        let mains = NSApp.windows.filter { $0.identifier?.rawValue == SceneIDs.mainWindow }
        guard mains.count > 1 else { return }
        for window in mains.sorted(by: { $0.windowNumber < $1.windowNumber }).dropFirst() {
            window.close()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !LiveSessions.controllers.isEmpty else { return .terminateNow }
        Task { @MainActor in
            await LiveSessions.terminateAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

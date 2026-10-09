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
        // Apply the persisted appearance (light / dark / match system) before
        // the first window shows, so the initial frame is already correct.
        // `AppearanceSettings.shared` initializes once and pushes the saved
        // mode onto NSApplication.appearance; the toolbar/menu reuse it.
        _ = AppearanceSettings.shared

        // Install the app-bundled agent skills into pi's user skills
        // directory (`~/.pi/agent/skills`), which pi scans by default, so
        // every session the app spawns can load them (the
        // `file-reference-links` skill the agent is taught to use). This
        // deliberately does NOT edit pi's global settings.json: installing at
        // a fixed path keeps the skill's `<location>` — and therefore the
        // system-prompt prefix the provider caches — stable across launches
        // and builds. Runs BEFORE the first session can spawn so the skill is
        // present from its very first request; it is one small file copy.
        if let resources = Bundle.main.resourceURL {
            let skills = resources.appendingPathComponent("Skills", isDirectory: true)
            let bundledSkill = skills.appendingPathComponent("file-reference-links/SKILL.md")
            if FileManager.default.fileExists(atPath: bundledSkill.path) {
                BundledSkill.install(from: skills)
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

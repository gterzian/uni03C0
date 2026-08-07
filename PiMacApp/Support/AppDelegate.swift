import AppKit
import Foundation
import PiCore

/// Registry of live pi subprocesses so app termination can always signal EOF
/// (finish stdin) to every child — otherwise dev iteration would accumulate
/// orphaned node processes.
@MainActor
enum LiveSessions {
    static var controllers: [ObjectIdentifier: PiProcessController] = [:]

    static func register(_ controller: PiProcessController) {
        controllers[ObjectIdentifier(controller)] = controller
    }

    static func unregister(_ controller: PiProcessController) {
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

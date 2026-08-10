import Foundation

/// Announcement strings posted for VoiceOver users (`AccessibilityNotification.
/// Announcement`). Centralized so the wording lives in one place and the view
/// layer just posts.
enum Announcements {
    /// The agent run settled — the user can type again.
    static let agentFinished = "Agent finished working"

    /// A send/stream failure surfaced (auth, preflight, network, …).
    static func error(_ message: String) -> String { "Error: \(message)" }

    /// The agent process dropped.
    static func disconnected(_ message: String) -> String { "Disconnected: \(message)" }
}

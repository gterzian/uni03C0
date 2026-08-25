import Foundation

/// How long a single tool call may run before the client aborts the operation.
///
/// The assistant itself may run for as long as it likes (thinking, generating
/// tool arguments, composing the answer) — but a tool call that executes for
/// longer than this limit is cut off. The timer bounds one tool's execution
/// window: `tool_execution_start` → `tool_execution_end`. A turn that runs many
/// short tools is fine; the limit is per tool call, not per turn.
///
/// This is a runtime *behavior*, not a sandbox or subprocess config, so it is
/// read LIVE at the start of each tool call: changing it in Settings takes
/// effect on the next tool call, without restarting the session. A running
/// tool keeps the limit it started with (the timer is scheduled at
/// `tool_execution_start`).
///
/// `isEnabled = false` (or a non-positive `seconds`) disables the limit
/// entirely — a tool may run as long as it likes.
public struct ToolTimeoutSettings: Sendable, Equatable {
    /// Default limit: 10 minutes.
    public static let defaultSeconds: Int = 600

    /// The limit in seconds. Non-positive means "no limit" (and `isEnabled`
    /// alone is not enough — the stored value must also be positive).
    public var seconds: Int
    /// Whether the timeout is enforced. When false, the limit is off regardless
    /// of the stored `seconds`.
    public var isEnabled: Bool

    public init(seconds: Int = Self.defaultSeconds, isEnabled: Bool = true) {
        self.seconds = seconds
        self.isEnabled = isEnabled
    }

    /// The sensible out-of-the-box value: 10 minutes, enforced.
    public static let defaults = ToolTimeoutSettings()

    /// The effective limit as a `Duration`, or nil when the timeout is
    /// disabled (either `isEnabled` is false or `seconds` is non-positive).
    public var duration: Duration? {
        guard isEnabled, seconds > 0 else { return nil }
        return .seconds(seconds)
    }

    /// A short, user-facing description of the limit ("10 minutes",
    /// "90 seconds"). Used when a tool is aborted so the notice explains why.
    public var displayText: String {
        guard isEnabled, seconds > 0 else { return "no limit" }
        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "\(seconds) seconds"
    }

    // MARK: - Persistence

    private static let secondsKey = "toolTimeout.seconds"
    private static let enabledKey = "toolTimeout.isEnabled"

    public static func load() -> ToolTimeoutSettings {
        let defaults = UserDefaults.standard
        let seconds = defaults.object(forKey: secondsKey) as? Int ?? Self.defaultSeconds
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        return ToolTimeoutSettings(seconds: seconds, isEnabled: enabled)
    }

    public func save() {
        let defaults = UserDefaults.standard
        defaults.set(seconds, forKey: Self.secondsKey)
        defaults.set(isEnabled, forKey: Self.enabledKey)
    }
}

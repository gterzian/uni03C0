import AppKit

/// The user's accessibility display preferences (System Settings →
/// Accessibility → Display), read live from AppKit. Views consult these to
/// adapt motion and contrast; observing `didChange` covers toggles mid-session
/// (e.g. the streaming caret stopping when Reduce Motion is enabled).
///
/// All three are thin wrappers over one AppKit API family
/// (`NSWorkspace`'s accessibility display options), so a change to that API
/// lands in exactly one place.
enum DisplayOptions {
    /// Reduce Motion: streaming animation (caret pulse, text fade) is purely
    /// decorative and is skipped.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Increase Contrast: subtle color is strengthened so color alone never
    /// carries information (caret, user-message highlight, status readout,
    /// failed-card border).
    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Posted to `NSWorkspace.shared.notificationCenter` when any of the
    /// accessibility display options change (Reduce Motion, Increase Contrast,
    /// …).
    static var didChange: Notification.Name {
        NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
    }
}

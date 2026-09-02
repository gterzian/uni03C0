import AppKit

/// The user's accessibility display preferences (System Settings →
/// Accessibility → Display), read live from AppKit. Views consult these to
/// adapt motion and contrast; observing `didChange` covers toggles mid-session
/// (e.g. the streaming caret stopping when Reduce Motion is enabled).
///
/// All three are thin wrappers over one AppKit API family
/// (`NSWorkspace`'s accessibility display options), so a change to that API
/// lands in exactly one place.
///
/// `nonisolated`: the dynamic colors that adapt to contrast/ appearance
/// (`MarkdownText.codeBackground`, `SearchMatchHighlight`, …) capture these
/// inside their `NSColor(name:dynamicProvider:)` closures, and those colors
/// are created on the background pre-measurer as well as the main thread.
/// Reading `NSWorkspace`'s accessibility display options is a thread-safe
/// property read.
enum DisplayOptions {
    /// Reduce Motion: streaming animation (caret pulse, text fade) is purely
    /// decorative and is skipped.
    nonisolated static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Increase Contrast: subtle color is strengthened so color alone never
    /// carries information (caret, user-message highlight, status readout,
    /// failed-card border).
    nonisolated static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Posted to `NSWorkspace.shared.notificationCenter` when any of the
    /// accessibility display options change (Reduce Motion, Increase Contrast,
    /// …).
    nonisolated static var didChange: Notification.Name {
        NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
    }
}

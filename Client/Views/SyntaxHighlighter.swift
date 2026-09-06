import AppKit
import Core
import Highlightr

/// Thin wrapper over Highlightr (highlight.js on JavaScriptCore) for the file
/// browser's content pane.
///
/// Deliberately main-actor-only and synchronous: the highlighted attributed
/// string lands directly in a text view's storage, and Swift's region
/// isolation forbids handing a non-Sendable `NSAttributedString` across an
/// isolation boundary — so highlighting runs on the main thread, guarded by a
/// size cap. Beyond the cap, code renders as plain monospaced text: the
/// "never block the UI" invariant wins over coloring an enormous file (the
/// doc's own fallback for an unrecognized extension, generalized to "too big
/// to color cheaply").
@MainActor
final class SyntaxHighlighter {
    private let highlightr: Highlightr?
    /// Above this UTF-8 size a file is shown uncolored (highlight.js runs in
    /// one synchronous JS pass; ~400KB is comfortably under a frame budget).
    private static let maxHighlightLength = 400_000

    private var appliedDarkTheme: Bool?

    init() {
        highlightr = Highlightr()
        applyTheme(dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    /// The highlight.js language name for a file path, or nil (→ plain text)
    /// for an unrecognized extension. Reuses the same extension map that
    /// `CodeReference` fences with — the names are highlight.js identifiers.
    static func language(forPath path: String) -> String? {
        CodeReference.fenceLanguage(forPath: path)
    }

    /// Highlights `code` as `language`; returns nil when Highlightr failed to
    /// load, the file exceeds the size cap, or the language is nil (callers
    /// fall back to plain monospaced text — never block on detection).
    func highlight(_ code: String, as language: String?) -> NSAttributedString? {
        guard let highlightr, let language else { return nil }
        guard code.utf8.count <= Self.maxHighlightLength else { return nil }
        applyTheme(dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        return highlightr.highlight(code, as: language)
    }

    private func applyTheme(dark: Bool) {
        guard appliedDarkTheme != dark else { return }
        appliedDarkTheme = dark
        guard let highlightr else { return }
        let preferred = dark ? "atom-one-dark" : "xcode"
        if !highlightr.setTheme(to: preferred) {
            // Highlightr's built-in default (pojoaque) is dark and readable;
            // failing to find the preferred theme just keeps it.
            _ = highlightr.setTheme(to: "github")
        }
    }
}

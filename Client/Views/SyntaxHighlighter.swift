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
///
/// The theme is a MATCHED light/dark pair (`atom-one-light` / `atom-one-dark`),
/// re-resolved from the effective appearance on every `highlight` call. Because
/// Highlightr bakes the theme's fixed RGB values into the returned string, the
/// displayed file is re-highlighted when the app's appearance changes —
/// `FilePaneContainer.viewDidChangeEffectiveAppearance` drives that, so a
/// light/dark toggle (or a system appearance change) lands in the code pane
/// without re-reading the file.
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
        // A matched pair from the same family: atom-one-light / atom-one-dark,
        // so token colors keep their relationships when the app switches
        // appearance. Fall back to a same-contrast alternative (github /
        // github-dark) if a theme is ever renamed out of the bundle, then to
        // Highlightr's built-in default as the last resort.
        let preferred = dark ? "atom-one-dark" : "atom-one-light"
        if highlightr.setTheme(to: preferred) { return }
        if highlightr.setTheme(to: dark ? "github-dark" : "github") { return }
        _ = highlightr.setTheme(to: "pojoaque")
    }
}

import AppKit
import Core
import Highlightr

/// Thin wrapper over Highlightr (highlight.js on JavaScriptCore) for the diff
/// viewer's document builder.
///
/// `nonisolated`, NOT main-actor: the diff document builder runs on a worker
/// thread, and highlighting MUST happen there — highlight.js costs roughly
/// 200ms per 1000 lines in one synchronous JS pass, so doing it on the main
/// thread beachballs the app when Changes opens on a large project. The
/// highlighter is confined to the builder (its lock serializes every call), so
/// the non-Sendable `Highlightr`/`JSContext` is never touched concurrently.
/// A file beyond the size cap renders as plain monospaced text: the "never
/// block the UI" invariant wins over coloring an enormous file.
///
/// The theme is a MATCHED light/dark pair (`atom-one-light` / `atom-one-dark`),
/// selected from the caller's `dark` flag. The caller resolves the effective
/// appearance on the main actor and passes it in — nothing here reads MainActor
/// state — and because Highlightr bakes the theme's fixed RGB values into the
/// returned string, a light/dark change is a different `dark`, hence a
/// different highlight.
nonisolated final class SyntaxHighlighter {
    private let highlightr: Highlightr?
    /// Above this UTF-8 size a file is shown uncolored (highlight.js runs in
    /// one synchronous JS pass; ~400KB is comfortably under a frame budget).
    private static let maxHighlightLength = 400_000

    private var appliedDarkTheme: Bool?

    init() {
        highlightr = Highlightr()
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
    func highlight(_ code: String, as language: String?, dark: Bool) -> NSAttributedString? {
        guard let highlightr, let language else { return nil }
        guard code.utf8.count <= Self.maxHighlightLength else { return nil }
        applyTheme(dark: dark)
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

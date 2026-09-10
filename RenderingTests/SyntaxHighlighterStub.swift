import AppKit

/// Stand-in for `Client/Views/SyntaxHighlighter.swift`, which links the
/// Highlightr package (unavailable to the renderer test bundles): the only
/// two members `ReadOnlyFilePane`'s Coordinator calls are these. Rendering
/// tests never exercise highlighting — the pane is driven with already-
/// attributed text.
@MainActor
final class SyntaxHighlighter {
    static func language(forPath path: String) -> String? { nil }

    func highlight(_ code: String, as language: String?) -> NSAttributedString? { nil }
}

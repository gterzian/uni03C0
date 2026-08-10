import AppKit

/// Renders the markdown body of transcript rows — assistant final responses
/// and user messages. Everything else (streaming text, errors, aborts,
/// thinking traces) stays plain in `TranscriptText`.
///
/// Parses with Foundation's CommonMark subset (`AttributedString(markdown:)`),
/// then rebuilds the styled text by hand from the parser's
/// `inlinePresentationIntent` / `presentationIntent` runs. Rebuilding is
/// necessary because the parsed `AttributedString` carries SwiftUI `Font`/
/// `Color` values that AppKit ignores (they vanish in the `NSAttributedString`
/// bridge), but its intent runs describe the markdown structure precisely.
/// Rebuilding by hand also keeps styling tied to `FontSettings` (the app-wide
/// font size) and identical between rendering and measurement, so the measured
/// row height always matches the rendered content.
///
/// Supported: headers, bold, italic, bold+italic, strikethrough, inline code,
/// fenced code blocks (monospaced, with a subtle background), bullet and
/// ordered lists (nested, with hanging indents), blockquotes, and links
/// (clickable — `TextRowView` opens them). Tables are not part of the parser's
/// CommonMark subset and fall back to plain paragraphs.
@MainActor
enum MarkdownText {
    /// Results are cached per (text, font size): the coordinator re-parses
    /// every row each time it scrolls into view (both to render it and to
    /// measure it), and a parse costs ~1ms per KB of source. Bounded — stale
    /// entries from an older font size evict naturally under memory pressure.
    private static let cache = NSCache<NSString, NSAttributedString>()

    /// Renders `markdown` to an attributed string styled for the transcript.
    static func body(text: String, bodySize: CGFloat) -> NSAttributedString {
        guard !text.isEmpty else { return NSAttributedString() }
        let key = "\(bodySize)\u{1F}\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let built = build(text: text, bodySize: bodySize)
        cache.setObject(built, forKey: key, cost: text.utf8.count)
        return built
    }

    private static func build(text: String, bodySize: CGFloat) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: text) else {
            // The parser is CommonMark-tolerant; on the off chance it refuses,
            // render the source verbatim (identical to the old plain path).
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: bodySize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: plainParagraph(),
            ])
        }

        let bodyFont = NSFont.systemFont(ofSize: bodySize)
        let monoFont = NSFont.monospacedSystemFont(ofSize: max(bodySize - 1, 9), weight: .regular)
        let label = NSColor.labelColor

        let result = NSMutableAttributedString()
        // The paragraph separator "\n" between blocks inherits the previous
        // run's attributes, so it terminates the previous paragraph with the
        // previous block's style (spacing between blocks comes from the new
        // block's `paragraphSpacingBefore`).
        var lastRunAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: label,
            .paragraphStyle: plainParagraph(),
        ]
        var lastBlock: [PresentationIntent.IntentType]?

        for run in parsed.runs {
            let block = run.presentationIntent?.components ?? []
            let isNewBlock = block != lastBlock
            let layout = BlockLayout(components: block, bodyFont: bodyFont)

            var runText = String(parsed.characters[run.range])
            if layout.isCodeBlock {
                // The parser includes the code block's trailing newline; drop
                // it so the block's paragraph ends cleanly and the next
                // block's spacing provides the separation.
                if runText.hasSuffix("\n") { runText.removeLast() }
            } else {
                // Newlines between blocks are emitted as separators below;
                // keep only explicit line breaks (two-space hard breaks and
                // soft-wrapped source lines).
                let inline = run.inlinePresentationIntent
                let hasExplicitBreak = inline?.contains(.lineBreak) == true || inline?.contains(.softBreak) == true
                if !hasExplicitBreak {
                    runText = runText.replacingOccurrences(of: "\n", with: "")
                }
            }
            guard !runText.isEmpty else { continue }

            if isNewBlock, result.length > 0, result.string.last != "\n" {
                result.append(NSAttributedString(string: "\n", attributes: lastRunAttrs))
            }

            // Font: code wins, then header size, then inline bold/italic.
            var font = bodyFont
            if layout.headerLevel > 0 {
                font = NSFont.boldSystemFont(ofSize: bodySize + headerBoost(layout.headerLevel))
            }
            if layout.isCodeBlock || run.inlinePresentationIntent?.contains(.code) == true {
                font = monoFont
            }
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { font = withTrait(.boldFontMask, font) }
                if inline.contains(.emphasized) { font = withTrait(.italicFontMask, font) }
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = layout.isCodeBlock ? 1 : 2
            paragraph.lineBreakMode = layout.isCodeBlock ? .byCharWrapping : .byWordWrapping
            paragraph.firstLineHeadIndent = layout.firstLineIndent
            paragraph.headIndent = layout.contentIndent
            if isNewBlock, result.length > 0 {
                if layout.headerLevel > 0 {
                    paragraph.paragraphSpacingBefore = 10
                    paragraph.paragraphSpacing = 4
                } else if layout.isCodeBlock {
                    paragraph.paragraphSpacingBefore = 8
                    paragraph.paragraphSpacing = 6
                } else if layout.isThematicBreak {
                    paragraph.paragraphSpacingBefore = 8
                    paragraph.paragraphSpacing = 8
                } else if !layout.indents.isEmpty {
                    paragraph.paragraphSpacingBefore = 4 // list item
                } else {
                    paragraph.paragraphSpacingBefore = 6
                }
            }

            if isNewBlock, !layout.marker.isEmpty {
                result.append(NSAttributedString(string: layout.marker, attributes: [
                    .font: bodyFont,
                    .foregroundColor: label,
                    .paragraphStyle: paragraph,
                ]))
            }

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: layout.isThematicBreak ? NSColor.secondaryLabelColor : label,
                .paragraphStyle: paragraph,
            ]
            if layout.isCodeBlock || run.inlinePresentationIntent?.contains(.code) == true {
                attrs[.backgroundColor] = codeBackground
            }
            if let inline = run.inlinePresentationIntent, inline.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let url = run.link {
                attrs[.link] = url
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: runText, attributes: attrs))
            lastRunAttrs = attrs
            lastBlock = block
        }
        return result
    }

    /// The layout the current block imposes on its runs: header size, code
    /// styling, and the indent markers for list items / blockquotes.
    ///
    /// The parser's intent chain lists components innermost-first (a nested
    /// list item is `paragraph → listItem → list → listItem → list`), so list
    /// levels are collected in that order and reversed for outermost-first
    /// markers. Only the innermost marker is rendered as text; the outer
    /// markers contribute indentation so nested content lines up under it.
    private struct BlockLayout {
        var headerLevel = 0
        var isCodeBlock = false
        var isThematicBreak = false
        /// Indent markers, outermost first (blockquote ▍s, then list bullets/
        /// numbers), with their measured widths.
        var indents: [(marker: String, width: CGFloat)] = []

        /// The marker rendered at the start of the first line ("" for none).
        var marker: String { indents.last?.marker ?? "" }
        /// Indent of the first line — where the marker starts.
        var firstLineIndent: CGFloat { indents.dropLast().reduce(0) { $0 + $1.width } }
        /// Indent of wrapped lines — past the marker.
        var contentIndent: CGFloat { indents.reduce(0) { $0 + $1.width } }

        init(components: [PresentationIntent.IntentType], bodyFont: NSFont) {
            var quoteDepth = 0
            var listLevels: [(ordered: Bool, ordinal: Int)] = []
            for (index, component) in components.enumerated() {
                switch component.kind {
                case .header(let level):
                    headerLevel = level
                case .codeBlock:
                    isCodeBlock = true
                case .thematicBreak:
                    isThematicBreak = true
                case .blockQuote:
                    quoteDepth += 1
                case .listItem(let ordinal):
                    // The list type immediately follows its item in the chain.
                    let ordered: Bool
                    if index + 1 < components.count, case .orderedList = components[index + 1].kind {
                        ordered = true
                    } else {
                        ordered = false
                    }
                    listLevels.append((ordered, ordinal))
                case .paragraph, .orderedList, .unorderedList,
                     .table, .tableHeaderRow, .tableRow, .tableCell:
                    break
                @unknown default:
                    break
                }
            }

            func measure(_ marker: String) -> CGFloat {
                (marker as NSString).size(withAttributes: [.font: bodyFont]).width
            }
            if quoteDepth > 0 {
                let marker = String(repeating: "▍", count: quoteDepth) + " "
                indents.append((marker, measure(marker)))
            }
            let bullets = ["•", "◦", "▪", "‣"]
            for (depth, level) in listLevels.reversed().enumerated() {
                let marker = level.ordered
                    ? "\(level.ordinal). "
                    : bullets[depth % bullets.count] + " "
                indents.append((marker, measure(marker)))
            }
        }
    }

    /// h1…h6 scale the body font by this much (all bold).
    private static func headerBoost(_ level: Int) -> CGFloat {
        switch level {
        case 1: 6
        case 2: 4
        case 3: 2
        default: 0
        }
    }

    private static func withTrait(_ trait: NSFontTraitMask, _ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: trait)
    }

    /// Subtle gray behind code (inline and blocks), a touch stronger with
    /// Increase Contrast. Dynamic so it adapts to dark/light mode; resolved
    /// per draw, so a mid-session appearance change applies without
    /// re-rendering rows.
    private static let codeBackground = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if DisplayOptions.increaseContrast {
            return dark
                ? NSColor(calibratedWhite: 0.24, alpha: 1.0)
                : NSColor(calibratedWhite: 0.88, alpha: 1.0)
        }
        return dark
            ? NSColor(calibratedWhite: 0.15, alpha: 1.0)
            : NSColor(calibratedWhite: 0.93, alpha: 1.0)
    }

    private static func plainParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        p.lineBreakMode = .byWordWrapping
        return p
    }
}

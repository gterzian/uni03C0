import AppKit

/// Renders the markdown body of transcript rows — assistant responses (final
/// and streaming) and user messages. Everything else (errors, aborts, thinking
/// traces) stays plain in `TranscriptText`.
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
/// Supported: headers, bold, italic, bold+italic, strikethrough, inline code
/// (monospaced with a subtle per-glyph background), fenced code blocks
/// (monospaced, wrapping early to leave `codeBlockRightReserve` at the right
/// edge for the corner copy button — the row draws the full-width card and
/// button from the reported `codeBlocks`), bullet and ordered lists (nested,
/// with hanging indents), blockquotes, and links (clickable — `TextRowView`
/// opens them). Tables are not part of the parser's CommonMark subset and fall
/// back to plain paragraphs.
@MainActor
enum MarkdownText {
    /// The parse result: the styled string plus every fenced code block
    /// (character range within `string`, and the raw content — trailing
    /// newline included — that a copy should deliver).
    final class MarkdownBody {
        let string: NSAttributedString
        let codeBlocks: [(range: NSRange, code: String)]

        init(string: NSAttributedString, codeBlocks: [(range: NSRange, code: String)]) {
            self.string = string
            self.codeBlocks = codeBlocks
        }
    }

    /// Results are cached per (text, font size): the coordinator re-parses
    /// every row each time it scrolls into view (both to render it and to
    /// measure it), and a parse costs ~1ms per KB of source. Bounded — a
    /// streaming turn caches every intermediate prefix (each is used once),
    /// so the cache is cost-limited and evicts the oldest/smallest first;
    /// entries from an older font size also evict naturally.
    private static let cache: NSCache<NSString, MarkdownBody> = {
        let cache = NSCache<NSString, MarkdownBody>()
        cache.countLimit = 400
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    /// Horizontal strip reserved at the right edge of every fenced code block
    /// for the corner copy button — the block's text wraps early so the button
    /// never covers code. `TextRowView` positions the button in this strip and
    /// `CodeCopyButton.size` must fit inside it.
    static let codeBlockRightReserve: CGFloat = 54

    /// Renders `markdown` to an attributed string styled for the transcript.
    static func body(text: String, bodySize: CGFloat) -> MarkdownBody {
        guard !text.isEmpty else { return MarkdownBody(string: NSAttributedString(), codeBlocks: []) }
        let key = "\(bodySize)\u{1F}\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let built = build(text: text, bodySize: bodySize)
        cache.setObject(built, forKey: key, cost: text.utf8.count)
        return built
    }

    private static func build(text: String, bodySize: CGFloat) -> MarkdownBody {
        guard let parsed = try? AttributedString(markdown: text) else {
            // The parser is CommonMark-tolerant; on the off chance it refuses,
            // render the source verbatim (identical to the old plain path).
            return MarkdownBody(
                string: NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: bodySize),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: plainParagraph(),
                ]),
                codeBlocks: []
            )
        }

        let bodyFont = NSFont.systemFont(ofSize: bodySize)
        let monoFont = NSFont.monospacedSystemFont(ofSize: max(bodySize - 1, 9), weight: .regular)
        // Line-height-to-point-size ratio of the body font — used to size the
        // spacer lines between blocks so their height matches the target gap.
        let bodyLineRatio = (bodyFont.ascender - bodyFont.descender + bodyFont.leading) / bodyFont.pointSize
        let label = NSColor.labelColor

        let result = NSMutableAttributedString()
        var codeBlocks: [(range: NSRange, code: String)] = []
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
            // The raw code block content (trailing newline included) for the
            // copy button; nil for non-code runs.
            var codeText: String?
            if layout.isCodeBlock {
                // The parser includes the code block's trailing newline; drop
                // it from the display so the block's paragraph ends cleanly
                // and the next block's spacing provides the separation. The
                // copy button still carries the raw text (trailing newline
                // included), matching what a paste should deliver.
                codeText = runText
                if runText.hasSuffix("\n") { runText.removeLast() }
            } else {
                // Single newlines inside a paragraph (soft breaks) and
                // two-space hard breaks must stay line breaks. The parser
                // emits each as a dedicated run — a soft break's text is a
                // SPACE (the source newline is lost) and a hard break's text
                // is "\n" — so re-emit a real newline for both. Other runs
                // carry boundary newlines that belong to the block separators
                // below and are stripped.
                let inline = run.inlinePresentationIntent
                if inline?.contains(.softBreak) == true || inline?.contains(.lineBreak) == true {
                    runText = "\n"
                } else {
                    runText = runText.replacingOccurrences(of: "\n", with: "")
                }
            }
            guard !runText.isEmpty else { continue }

            if isNewBlock, result.length > 0, result.string.last != "\n" {
                // Terminate the previous paragraph, then insert an empty
                // spacer line whose height is the gap between blocks.
                // paragraphSpacingBefore/After can't do this: on this SDK they
                // inflate EVERY line fragment of a multi-line paragraph (a
                // 16pt line becomes 30pt with 8/6 spacing — verified), not
                // just the paragraph boundary.
                let gap = blockGap(layout)
                let gapFont = NSFont.systemFont(ofSize: max(gap / bodyLineRatio, 1))
                result.append(NSAttributedString(string: "\n", attributes: lastRunAttrs))
                result.append(NSAttributedString(string: "\n", attributes: [.font: gapFont]))
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
            if layout.isCodeBlock {
                // Reserve the corner-button strip so code never wraps under it.
                paragraph.tailIndent = -codeBlockRightReserve
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
            if run.inlinePresentationIntent?.contains(.code) == true {
                // Inline code keeps a per-glyph pill; fenced blocks get their
                // full-width card from the row overlay instead.
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
            let blockRange = NSRange(location: result.length, length: (runText as NSString).length)
            result.append(NSAttributedString(string: runText, attributes: attrs))
            if layout.isCodeBlock, let codeText {
                codeBlocks.append((range: blockRange, code: codeText))
            }
            lastRunAttrs = attrs
            lastBlock = block
        }
        return MarkdownBody(string: result, codeBlocks: codeBlocks)
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

    /// The vertical gap inserted between markdown blocks (as an empty spacer
    /// line whose font height equals the gap).
    private static func blockGap(_ layout: BlockLayout) -> CGFloat {
        if layout.headerLevel > 0 { return 10 }
        if layout.isCodeBlock { return 8 }
        if layout.isThematicBreak { return 8 }
        if !layout.indents.isEmpty { return 4 } // list item
        return 6
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

    /// Subtle gray behind code (inline pill and the full-width card the row
    /// draws over fenced blocks), a touch stronger with Increase Contrast.
    /// Dynamic so it adapts to dark/light mode; resolved per draw, so a
    /// mid-session appearance change applies without re-rendering rows.
    static let codeBackground = NSColor(name: nil) { appearance in
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

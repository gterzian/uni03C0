import AppKit

/// One place for every markdown typography decision in the transcript: the
/// type scale, line height, block spacing, inline-code chip geometry, and the
/// dark/light text palette.
///
/// Every size is a multiple of the base body point size (`FontSettings.bodySize`,
/// 14 by default), so changing View → Font Size scales the whole hierarchy
/// together. `MarkdownText` builds the attributed string from these values and
/// `TranscriptText` measures it with the same ones — that is what keeps the
/// measured row height equal to the rendered height.
///
/// `nonisolated`: the coordinator's background height pre-measurer builds
/// strings off the main actor.
nonisolated enum MarkdownStyle {
    // MARK: Type scale

    static let bodyWeight: NSFont.Weight = .regular
    static let headingWeight: NSFont.Weight = .semibold
    static let boldWeight: NSFont.Weight = .semibold

    /// H1…H6, as a multiple of the body point size.
    static let headingSteps: [CGFloat] = [1.35, 1.2, 1.05, 1.0, 1.0, 1.0]

    /// Mono size for inline code and fenced blocks. 0.92 matches the mono
    /// x-height to the body font's across the system faces.
    static let codeScale: CGFloat = 0.92

    // MARK: Line height (multiple of the run's font size)

    static let bodyLineHeight: CGFloat = 1.5
    static let headingLineHeight: CGFloat = 1.3
    static let codeLineHeight: CGFloat = 1.35

    // MARK: Block spacing (multiple of the body point size)

    static let paragraphGap: CGFloat = 0.6
    static let headingGapAbove: CGFloat = 1.2
    static let headingGapBelow: CGFloat = 0.4
    static let listItemGap: CGFloat = 0.25
    static let codeBlockGap: CGFloat = 0.5
    static let thematicBreakGap: CGFloat = 0.8

    // MARK: Inline-code chip

    static let inlineCodeHorizontalPadding: CGFloat = 2.5
    static let inlineCodeCornerRadius: CGFloat = 3.5
    static let inlineCodeOpacity: CGFloat = 0.07
    /// Marks a run as inline code so `MarkdownTextView` can paint the padded,
    /// rounded chip. A dedicated key (instead of AppKit's `.backgroundColor`,
    /// which fills the bare glyph box) is what buys the padding and radius.
    static let inlineCodeAttribute = NSAttributedString.Key("uni03C0.markdownInlineCode")

    // MARK: Fonts

    static func bodyFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: bodyWeight)
    }

    static func headingFont(level: Int, bodySize: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: bodySize * headingScale(for: level), weight: headingWeight)
    }

    static func codeFont(bodySize: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: bodySize * codeScale, weight: .regular)
    }

    static func headingScale(for level: Int) -> CGFloat {
        guard headingSteps.indices.contains(level - 1) else { return 1 }
        return headingSteps[level - 1]
    }

    /// The semibold face at `font`'s size, preserving monospace and italic —
    /// inline `**bold**` is semibold, not full bold, so emphasis reads without
    /// breaking the body's texture.
    static func semibold(_ font: NSFont) -> NSFont {
        let traits = font.fontDescriptor.symbolicTraits
        let base = traits.contains(.monoSpace)
            ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: boldWeight)
            : NSFont.systemFont(ofSize: font.pointSize, weight: boldWeight)
        return traits.contains(.italic) ? withItalic(base) : base
    }

    /// Adds italic without `NSFontManager` (its shared instance is not
    /// thread-safe, and this runs on the background pre-measurer).
    static func withItalic(_ font: NSFont) -> NSFont {
        let merged = font.fontDescriptor.symbolicTraits.union(.italic)
        let descriptor = font.fontDescriptor.withSymbolicTraits(merged)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// The line height AppKit actually uses for `font` with zero paragraph
    /// spacing: it rounds the ascender/descender up/down to whole points
    /// (verified on this SDK), not the raw `ascender - descender + leading`.
    static func baseLineHeight(of font: NSFont) -> CGFloat {
        ceil(font.ascender) - floor(font.descender) + ceil(font.leading)
    }

    /// The `lineSpacing` that lifts `font`'s natural line height to
    /// `lineHeight * pointSize`. `lineSpacing` is the extra space added on top
    /// of `baseLineHeight(of:)`, which is why the target is expressed relative
    /// to the point size.
    static func lineSpacing(for font: NSFont, lineHeight: CGFloat) -> CGFloat {
        max(lineHeight * font.pointSize - baseLineHeight(of: font), 0)
    }

    // MARK: Colors

    /// Body text: a soft off-white (~86% luminance) in dark mode, near-black
    /// in light mode.
    static let bodyColor = NSColor(name: nil) { appearance in
        isDark(appearance)
            ? NSColor(calibratedWhite: 0.86, alpha: 1)
            : NSColor(calibratedWhite: 0.12, alpha: 1)
    }

    /// Headings: a touch brighter than the body so the hierarchy reads without
    /// shouting.
    static let headingColor = NSColor(name: nil) { appearance in
        isDark(appearance)
            ? NSColor(calibratedWhite: 0.94, alpha: 1)
            : NSColor(calibratedWhite: 0.04, alpha: 1)
    }

    /// Inline-code glyphs stay in the body's color family.
    static let inlineCodeTextColor = bodyColor

    /// The inline chip: ~7% white on dark, ~7% black on light; stronger with
    /// Increase Contrast.
    static let inlineCodeBackground = NSColor(name: nil) { appearance in
        let dark = isDark(appearance)
        let alpha = DisplayOptions.increaseContrast ? 0.16 : inlineCodeOpacity
        return dark
            ? NSColor(calibratedWhite: 1, alpha: alpha)
            : NSColor(calibratedWhite: 0, alpha: alpha)
    }

    /// The fenced-code card behind a whole code block — stronger than the
    /// inline chip so a block reads as a surface.
    static let codeBlockBackground = NSColor(name: nil) { appearance in
        let dark = isDark(appearance)
        if DisplayOptions.increaseContrast {
            return dark
                ? NSColor(calibratedWhite: 0.24, alpha: 1)
                : NSColor(calibratedWhite: 0.88, alpha: 1)
        }
        return dark
            ? NSColor(calibratedWhite: 0.15, alpha: 1)
            : NSColor(calibratedWhite: 0.93, alpha: 1)
    }

    /// Tint behind a table's header row; dynamic so it adapts to dark/light
    /// mode and is resolved per draw.
    static let tableHeaderBackground = NSColor(name: nil) { appearance in
        isDark(appearance)
            ? NSColor(calibratedWhite: 1.0, alpha: 0.09)
            : NSColor(calibratedWhite: 0.0, alpha: 0.05)
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

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
/// with hanging indents), blockquotes, links (clickable — `TextRowView`
/// opens them), and GitHub-style tables (detected before parsing —
/// Foundation's parser has no table extension — and rendered as an
/// `NSTextTable` grid that wraps its cells to fit the row width).
@MainActor
enum MarkdownText {
    /// A plain immutable data holder; `nonisolated` so `build` and the
    /// background pre-measurer (both of which create/read it) can do so from
    /// any thread.
    nonisolated final class MarkdownBody {
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
    ///
    /// `nonisolated(unsafe)`: the whole point of this file being off-main
    /// callable is that the background height pre-measurer parses markdown on
    /// a worker thread. `NSCache` is explicitly documented thread-safe
    /// (it is built for concurrent get/set), so sharing it across the main
    /// thread and the pre-measure task is safe — the `(unsafe)` is only
    /// satisfying the compiler's blanket non-Sendable rule.
    nonisolated(unsafe) private static let cache: NSCache<NSString, MarkdownBody> = {
        let cache = NSCache<NSString, MarkdownBody>()
        cache.countLimit = 400
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    /// Horizontal strip reserved at the right edge of every fenced code block
    /// for the corner copy button — the block's text wraps early so the button
    /// never covers code. `TextRowView` positions the button in this strip and
    /// `CodeCopyButton.size` must fit inside it.
    nonisolated static let codeBlockRightReserve: CGFloat = 54

    /// Renders `markdown` to an attributed string styled for the transcript.
    /// `nonisolated`: called from the main thread for rendering AND from the
    /// coordinator's background pre-measurer for height seeding — both must
    /// produce byte-identical strings (they feed the same measurement).
    nonisolated static func body(text: String, bodySize: CGFloat) -> MarkdownBody {
        guard !text.isEmpty else { return MarkdownBody(string: NSAttributedString(), codeBlocks: []) }
        let key = "\(bodySize)\u{1F}\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let built = build(text: text, bodySize: bodySize)
        cache.setObject(built, forKey: key, cost: text.utf8.count)
        return built
    }

    nonisolated private static func build(text: String, bodySize: CGFloat) -> MarkdownBody {
        // Fast path: no pipe anywhere → no table is possible, so the whole
        // line scan (and its per-message line array) is skipped. This keeps the
        // streaming hot path a single `contains` scan, like before tables.
        guard text.contains("|") else { return buildMarkdown(text, bodySize: bodySize) }
        let segments = tableSegments(in: text)
        // No table blocks detected → the original single-parse path.
        if segments.count == 1, case .markdown = segments[0] {
            return buildMarkdown(text, bodySize: bodySize)
        }
        let result = NSMutableAttributedString()
        var codeBlocks: [(range: NSRange, code: String)] = []
        for segment in segments {
            let piece: MarkdownBody
            switch segment {
            case .markdown(let source):
                piece = buildMarkdown(source, bodySize: bodySize)
            case .table(let table):
                piece = MarkdownBody(string: renderTable(table, bodySize: bodySize), codeBlocks: [])
            }
            guard piece.string.length > 0 else { continue }
            if result.length > 0 { appendSegmentGap(to: result, bodySize: bodySize) }
            let offset = result.length
            result.append(piece.string)
            codeBlocks.append(contentsOf: piece.codeBlocks.map {
                (range: NSRange(location: offset + $0.range.location, length: $0.range.length), code: $0.code)
            })
        }
        return MarkdownBody(string: result, codeBlocks: codeBlocks)
    }

    /// The gap between two independently-rendered segments (a markdown run and
    /// a table, or two markdown runs split by a table). Mirrors the spacer-line
    /// mechanism `buildMarkdown` uses between blocks: a terminating newline
    /// carrying the previous run's attributes, then an empty line whose font
    /// height equals the gap.
    nonisolated private static func appendSegmentGap(to result: NSMutableAttributedString, bodySize: CGFloat) {
        let bodyFont = MarkdownStyle.bodyFont(size: bodySize)
        let bodyLineRatio = MarkdownStyle.baseLineHeight(of: bodyFont) / bodyFont.pointSize
        let gapFont = NSFont.systemFont(ofSize: max(6 / bodyLineRatio, 1))
        let lastAttrs = result.length > 0
            ? result.attributes(at: result.length - 1, effectiveRange: nil)
            : [.font: bodyFont, .foregroundColor: MarkdownStyle.bodyColor, .paragraphStyle: plainParagraph(bodySize: bodySize)]
        result.append(NSAttributedString(string: "\n", attributes: lastAttrs))
        result.append(NSAttributedString(string: "\n", attributes: [.font: gapFont]))
    }

    nonisolated private static func buildMarkdown(_ text: String, bodySize: CGFloat) -> MarkdownBody {
        guard let parsed = try? AttributedString(markdown: text) else {
            // The parser is CommonMark-tolerant; on the off chance it refuses,
            // render the source verbatim (identical to the old plain path).
            return MarkdownBody(
                string: NSAttributedString(string: text, attributes: [
                    .font: MarkdownStyle.bodyFont(size: bodySize),
                    .foregroundColor: MarkdownStyle.bodyColor,
                    .paragraphStyle: plainParagraph(bodySize: bodySize),
                ]),
                codeBlocks: []
            )
        }

        let bodyFont = MarkdownStyle.bodyFont(size: bodySize)
        let monoFont = MarkdownStyle.codeFont(bodySize: bodySize)
        // Line-height-to-point-size ratio of the body font — used to size the
        // spacer lines between blocks so their height matches the target gap.
        let bodyLineRatio = MarkdownStyle.baseLineHeight(of: bodyFont) / bodyFont.pointSize

        let result = NSMutableAttributedString()
        var codeBlocks: [(range: NSRange, code: String)] = []
        // The paragraph separator "\n" between blocks inherits the previous
        // run's attributes, so it terminates the previous paragraph with the
        // previous block's style (spacing between blocks comes from the spacer
        // line inserted below).
        var lastRunAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: MarkdownStyle.bodyColor,
            .paragraphStyle: plainParagraph(bodySize: bodySize),
        ]
        var lastBlock: [PresentationIntent.IntentType]?
        var lastLayout: BlockLayout?

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
                let gap = blockGap(from: lastLayout, to: layout, bodySize: bodySize)
                let gapFont = NSFont.systemFont(ofSize: max(gap / bodyLineRatio, 1))
                result.append(NSAttributedString(string: "\n", attributes: lastRunAttrs))
                result.append(NSAttributedString(string: "\n", attributes: [.font: gapFont]))
            }

            let isInlineCode = run.inlinePresentationIntent?.contains(.code) == true
            // The block's own font governs line height and the marker; inline
            // emphasis only restyles the glyphs.
            let blockFont: NSFont
            let lineHeight: CGFloat
            if layout.isCodeBlock {
                blockFont = monoFont
                lineHeight = MarkdownStyle.codeLineHeight
            } else if layout.headerLevel > 0 {
                blockFont = MarkdownStyle.headingFont(level: layout.headerLevel, bodySize: bodySize)
                lineHeight = MarkdownStyle.headingLineHeight
            } else {
                blockFont = bodyFont
                lineHeight = MarkdownStyle.bodyLineHeight
            }
            var font = isInlineCode ? monoFont : blockFont
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { font = MarkdownStyle.semibold(font) }
                if inline.contains(.emphasized) { font = MarkdownStyle.withItalic(font) }
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = MarkdownStyle.lineSpacing(for: blockFont, lineHeight: lineHeight)
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
                    .foregroundColor: MarkdownStyle.bodyColor,
                    .paragraphStyle: paragraph,
                ]))
            }

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: layout.isThematicBreak
                    ? NSColor.secondaryLabelColor
                    : (layout.headerLevel > 0
                        ? MarkdownStyle.headingColor
                        : (isInlineCode ? MarkdownStyle.inlineCodeTextColor : MarkdownStyle.bodyColor)),
                .paragraphStyle: paragraph,
            ]
            if isInlineCode {
                // The chip's padded, rounded background is painted by
                // `MarkdownTextView`; this key marks the run. Fenced blocks get
                // their full-width card from the row overlay instead.
                attrs[MarkdownStyle.inlineCodeAttribute] = true
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
            lastLayout = layout
        }
        return MarkdownBody(string: result, codeBlocks: codeBlocks)
    }

    // MARK: - Tables

    /// A GitHub-style table block detected in the source (its delimiter row
    /// makes it unambiguous). Foundation's parser has no table extension, so
    /// these are pulled out before parsing and rendered by `renderTable`.
    nonisolated private struct MarkdownTable {
        var headers: [String]
        var alignments: [CellAlignment]
        var rows: [[String]]
    }

    nonisolated private enum CellAlignment { case left, center, right }

    /// A run of source: either plain markdown (parsed by `buildMarkdown`) or a
    /// detected table.
    nonisolated private enum TableSegment {
        case markdown(String)
        case table(MarkdownTable)
    }

    /// Splits the source into markdown runs and table blocks. A table is a
    /// header line followed by a delimiter line (`| --- | :--: |`) with the
    /// same cell count; body rows are the following lines that still contain a
    /// `|`. Lines inside fenced code blocks are never considered.
    nonisolated private static func tableSegments(in text: String) -> [TableSegment] {
        let lines = text.components(separatedBy: "\n")
        var segments: [TableSegment] = []
        var buffer: [String] = []
        var inFence = false
        var fence = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            segments.append(.markdown(buffer.joined(separator: "\n")))
            buffer.removeAll()
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inFence {
                buffer.append(line)
                if trimmed.hasPrefix(fence) { inFence = false }
                i += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence = true
                fence = String(trimmed.prefix(3))
                buffer.append(line)
                i += 1
                continue
            }
            if i + 1 < lines.count,
               let headers = parseTableRow(line),
               let alignments = parseDelimiterRow(lines[i + 1]),
               headers.count == alignments.count,
               !headers.isEmpty {
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count, let cells = parseTableRow(lines[j]) {
                    rows.append(normalize(cells, to: headers.count))
                    j += 1
                }
                flush()
                segments.append(.table(MarkdownTable(headers: headers, alignments: alignments, rows: rows)))
                i = j
                continue
            }
            buffer.append(line)
            i += 1
        }
        flush()
        return segments
    }

    /// Splits a table line into trimmed cells. Returns nil when the line has no
    /// `|` at all (so ordinary prose never starts a table). An escaped `\|`
    /// stays in the cell text for the inline markdown parse to unescape.
    nonisolated private static func parseTableRow(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in line {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                current.append(ch)
                escaped = true
            } else if ch == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current)
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty { cells.removeFirst() }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Parses a GFM delimiter row (`---`, `:---`, `---:`, `:--:`) into
    /// per-column alignments; nil when any cell is not a delimiter.
    nonisolated private static func parseDelimiterRow(_ line: String) -> [CellAlignment]? {
        guard let cells = parseTableRow(line), !cells.isEmpty else { return nil }
        var alignments: [CellAlignment] = []
        for cell in cells {
            guard !cell.isEmpty,
                  cell.contains("-"),
                  cell.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            alignments.append(left && right ? .center : right ? .right : .left)
        }
        return alignments
    }

    nonisolated private static func normalize(_ cells: [String], to count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count > count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    /// Renders a table with `NSTextTable` — a bold, tinted header row with a
    /// hairline under it, then one row per body row. Cells are real text
    /// blocks, so TextKit sizes the columns to their content and scales them to
    /// the row's width: a long cell wraps inside its column instead of pushing
    /// the next column onto its own line, and the table always fits. The
    /// width-dependence lives in the layout, not the attributed string, so the
    /// load-bearing measurement invariant holds (the string is built once per
    /// `(text, bodySize)` and measured/laid out at any width). Cells are inline
    /// markdown, so `**bold**`, `` `code` `` and links work inside a cell.
    nonisolated private static func renderTable(_ table: MarkdownTable, bodySize: CGFloat) -> NSAttributedString {
        let bodyFont = MarkdownStyle.bodyFont(size: bodySize)
        let columnCount = table.headers.count
        // The gap between columns, added as padding on each block's inner edge.
        let columnGap: CGFloat = 12

        let headerCells = table.headers.map {
            renderInlineCell($0, bodySize: bodySize, isHeader: true)
        }
        let bodyRows: [[NSAttributedString]] = table.rows.map { row in
            (0..<columnCount).map {
                renderInlineCell($0 < row.count ? row[$0] : "", bodySize: bodySize, isHeader: false)
            }
        }

        // Natural content widths steer the column proportions; TextKit scales
        // the percentages to the container, so a wide table wraps inside its
        // columns rather than overflowing.
        var natural = [CGFloat](repeating: 0, count: columnCount)
        for (column, cell) in headerCells.enumerated() {
            natural[column] = max(natural[column], cell.size().width)
        }
        for row in bodyRows {
            for (column, cell) in row.enumerated() {
                natural[column] = max(natural[column], cell.size().width)
            }
        }
        let totalNatural = max(natural.reduce(0, +), 1)

        let nsTable = NSTextTable()
        nsTable.numberOfColumns = columnCount
        nsTable.layoutAlgorithm = .automatic
        nsTable.collapsesBorders = false
        nsTable.hidesEmptyCells = false

        let out = NSMutableAttributedString()
        func appendRow(_ cells: [NSAttributedString], isHeader: Bool, row: Int) {
            for column in 0..<columnCount {
                let block = NSTextTableBlock(
                    table: nsTable, startingRow: row, rowSpan: 1,
                    startingColumn: column, columnSpan: 1
                )
                block.setWidth(columnGap / 2, type: .absolute, for: .padding, edge: .minX)
                block.setWidth(columnGap / 2, type: .absolute, for: .padding, edge: .maxX)
                block.setContentWidth(natural[column] / totalNatural * 100, type: .percentage)
                if isHeader {
                    block.backgroundColor = MarkdownStyle.tableHeaderBackground
                    // A hairline under the header stands in for the markdown
                    // delimiter row; the block draws it, so it spans the cell
                    // even when the cell's text wraps.
                    block.setWidth(1, type: .absolute, for: .border, edge: .maxY)
                    block.setBorderColor(NSColor.separatorColor, for: .maxY)
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.lineSpacing = MarkdownStyle.lineSpacing(for: bodyFont, lineHeight: MarkdownStyle.bodyLineHeight)
                paragraph.lineBreakMode = .byWordWrapping
                paragraph.alignment = switch table.alignments[column] {
                case .left: .left
                case .right: .right
                case .center: .center
                }
                let cell = NSMutableAttributedString(attributedString: cells[column])
                if cell.length == 0 {
                    cell.append(NSAttributedString(string: " ", attributes: [.font: bodyFont]))
                }
                cell.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                cell.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: cell.length))
                out.append(cell)
            }
        }
        appendRow(headerCells, isHeader: true, row: 0)
        for (index, row) in bodyRows.enumerated() {
            appendRow(row, isHeader: false, row: index + 1)
        }
        // The last newline only closes the final cell; drop it so the table
        // owns no trailing blank line (the segment assembler adds the gap).
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    /// Renders one table cell's inline markdown (bold/italic/strikethrough/
    /// inline code/links) at the cell's font. Cells carry no block structure,
    /// so this is the inline half of `buildMarkdown` without block handling.
    nonisolated private static func renderInlineCell(_ source: String, bodySize: CGFloat, isHeader: Bool) -> NSAttributedString {
        let baseFont = isHeader
            ? MarkdownStyle.semibold(MarkdownStyle.bodyFont(size: bodySize))
            : MarkdownStyle.bodyFont(size: bodySize)
        let monoFont = MarkdownStyle.codeFont(bodySize: bodySize)
        let baseColor = isHeader ? MarkdownStyle.headingColor : MarkdownStyle.bodyColor
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        let out = NSMutableAttributedString()
        guard !trimmed.isEmpty else {
            // A single space keeps alignment and gives the column a real width.
            return NSAttributedString(string: " ", attributes: [.font: baseFont, .foregroundColor: baseColor])
        }
        guard let parsed = try? AttributedString(markdown: trimmed) else {
            return NSAttributedString(string: trimmed, attributes: [.font: baseFont, .foregroundColor: baseColor])
        }
        for run in parsed.runs {
            let text = String(parsed.characters[run.range]).replacingOccurrences(of: "\n", with: " ")
            guard !text.isEmpty else { continue }
            let isInlineCode = run.inlinePresentationIntent?.contains(.code) == true
            var font = isInlineCode ? monoFont : baseFont
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { font = MarkdownStyle.semibold(font) }
                if inline.contains(.emphasized) { font = MarkdownStyle.withItalic(font) }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: baseColor]
            if isInlineCode { attrs[MarkdownStyle.inlineCodeAttribute] = true }
            if let inline = run.inlinePresentationIntent, inline.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let url = run.link {
                attrs[.link] = url
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        if out.length == 0 {
            return NSAttributedString(string: trimmed, attributes: [.font: baseFont, .foregroundColor: baseColor])
        }
        return out
    }

    /// The layout the current block imposes on its runs: header size, code
    /// styling, and the indent markers for list items / blockquotes.
    ///
    /// The parser's intent chain lists components innermost-first (a nested
    /// list item is `paragraph → listItem → list → listItem → list`), so list
    /// levels are collected in that order and reversed for outermost-first
    /// markers. Only the innermost marker is rendered as text; the outer
    /// markers contribute indentation so nested content lines up under it.
    /// A pure value type (no AppKit state) — `nonisolated` so `build` (which
    /// runs on the background pre-measurer too) can construct it.
    nonisolated private struct BlockLayout {
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

    /// The vertical gap inserted between markdown blocks, as an empty spacer
    /// line whose font height equals the gap. The incoming block sets the gap
    /// (a heading pulls 1.2em above itself, list items sit 0.25em apart); a
    /// heading also caps the space below itself at 0.4em. All values scale
    /// with the body point size.
    nonisolated private static func blockGap(from previous: BlockLayout?, to next: BlockLayout, bodySize: CGFloat) -> CGFloat {
        if let previous, previous.headerLevel > 0 {
            return MarkdownStyle.headingGapBelow * bodySize
        }
        if next.headerLevel > 0 {
            return MarkdownStyle.headingGapAbove * bodySize
        }
        if next.isCodeBlock {
            return MarkdownStyle.codeBlockGap * bodySize
        }
        if next.isThematicBreak {
            return MarkdownStyle.thematicBreakGap * bodySize
        }
        if !next.indents.isEmpty {
            // A list starting after non-list content gets a paragraph gap;
            // consecutive items sit tight.
            return (previous?.indents.isEmpty == false ? MarkdownStyle.listItemGap : MarkdownStyle.paragraphGap) * bodySize
        }
        return MarkdownStyle.paragraphGap * bodySize
    }

    nonisolated private static func plainParagraph(bodySize: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = MarkdownStyle.lineSpacing(
            for: MarkdownStyle.bodyFont(size: bodySize),
            lineHeight: MarkdownStyle.bodyLineHeight
        )
        p.lineBreakMode = .byWordWrapping
        return p
    }
}

/// The transcript's text view. It extends `NSTextView` only to paint
/// inline-code chips: `MarkdownText` tags inline-code runs with
/// `MarkdownStyle.inlineCodeAttribute` (instead of AppKit's `.backgroundColor`,
/// which fills the bare glyph box), and this view draws a padded, rounded chip
/// behind each such run — 2.5pt of horizontal padding and a 3.5pt radius at
/// ~7% opacity, on a single line height so the chip never changes its
/// paragraph's line spacing.
///
/// Drawing happens in `drawBackground` BEFORE `super`: the chip sits under the
/// text, and a search-match `.backgroundColor` painted later by `super` still
/// wins over a chip, so find-in-page stays visible on code.
final class MarkdownTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        drawInlineCodeChips(in: rect)
        super.drawBackground(in: rect)
    }

    private func drawInlineCodeChips(in dirtyRect: NSRect) {
        guard let storage = textStorage,
              let layoutManager,
              let container = textContainer,
              storage.length > 0 else { return }
        let origin = textContainerOrigin
        // Restrict the scan to the dirty glyphs: a long row can hold many code
        // spans and only the visible chips need painting.
        var containerDirty = dirtyRect
        containerDirty.origin.x -= origin.x
        containerDirty.origin.y -= origin.y
        let dirtyGlyphs = layoutManager.glyphRange(forBoundingRect: containerDirty, in: container)
        let dirtyChars = layoutManager.characterRange(forGlyphRange: dirtyGlyphs, actualGlyphRange: nil)
        guard dirtyChars.length > 0 else { return }
        let padding = MarkdownStyle.inlineCodeHorizontalPadding
        let radius = MarkdownStyle.inlineCodeCornerRadius
        MarkdownStyle.inlineCodeBackground.setFill()
        storage.enumerateAttribute(MarkdownStyle.inlineCodeAttribute, in: dirtyChars) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
                let clipped = NSIntersectionRange(lineGlyphs, glyphs)
                guard clipped.length > 0 else { return }
                var chip = layoutManager.boundingRect(forGlyphRange: clipped, in: container)
                chip.origin.x += origin.x
                chip.origin.y += origin.y
                // Horizontal padding only: the chip fills one line height, so
                // it never affects line spacing.
                chip = chip.insetBy(dx: -padding, dy: 0)
                guard chip.intersects(dirtyRect) else { return }
                NSBezierPath(roundedRect: chip, xRadius: radius, yRadius: radius).fill()
            }
        }
    }
}

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
/// with hanging indents), blockquotes, links (clickable — `TextRowView`
/// opens them), and GitHub-style tables (detected before parsing —
/// Foundation's parser has no table extension — and rendered as an aligned
/// grid of columns).
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
        let bodyFont = NSFont.systemFont(ofSize: bodySize)
        let bodyLineRatio = (bodyFont.ascender - bodyFont.descender + bodyFont.leading) / bodyFont.pointSize
        let gapFont = NSFont.systemFont(ofSize: max(6 / bodyLineRatio, 1))
        let lastAttrs = result.length > 0
            ? result.attributes(at: result.length - 1, effectiveRange: nil)
            : [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: plainParagraph()]
        result.append(NSAttributedString(string: "\n", attributes: lastAttrs))
        result.append(NSAttributedString(string: "\n", attributes: [.font: gapFont]))
    }

    nonisolated private static func buildMarkdown(_ text: String, bodySize: CGFloat) -> MarkdownBody {
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
                if inline.contains(.stronglyEmphasized) { font = withTrait([.bold], font) }
                if inline.contains(.emphasized) { font = withTrait([.italic], font) }
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

    /// Renders a table as an aligned grid of text lines: a bold header with a
    /// tinted background, a dashed separator, then one line per row. Columns
    /// are positioned with tab stops at the widest cell's edge, so alignment
    /// is exact (a right-aligned tab stop lands the following text flush at
    /// the column's right edge, a center stop at its middle) regardless of
    /// inline styling; tabs keep the whole table inside the row's single
    /// attributed string (the load-bearing measurement invariant). Cells are
    /// inline markdown, so `**bold**`, `` `code` `` and links work inside a
    /// cell.
    nonisolated private static func renderTable(_ table: MarkdownTable, bodySize: CGFloat) -> NSAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: bodySize)
        let columnCount = table.headers.count
        // The gap between columns, as a fixed point width (it must not depend
        // on the font's space glyph, since the columns are laid out by tab).
        let columnGap: CGFloat = 12

        let headerCells = (0..<columnCount).map {
            renderInlineCell($0 < table.headers.count ? table.headers[$0] : "", bodySize: bodySize, isHeader: true)
        }
        let bodyRows: [[NSAttributedString]] = table.rows.map { row in
            (0..<columnCount).map {
                renderInlineCell($0 < row.count ? row[$0] : "", bodySize: bodySize, isHeader: false)
            }
        }

        var widths = [CGFloat](repeating: 0, count: columnCount)
        for (column, cell) in headerCells.enumerated() {
            widths[column] = max(widths[column], cell.size().width)
        }
        for row in bodyRows {
            for (column, cell) in row.enumerated() {
                widths[column] = max(widths[column], cell.size().width)
            }
        }

        var starts = [CGFloat](repeating: 0, count: columnCount)
        var cursor: CGFloat = 0
        for column in 0..<columnCount {
            starts[column] = cursor
            cursor += widths[column] + columnGap
        }

        func tabStop(for column: Int) -> NSTextTab {
            let alignment: NSTextAlignment = switch table.alignments[column] {
            case .left: .left
            case .right: .right
            case .center: .center
            }
            let location: CGFloat = switch table.alignments[column] {
            case .left: starts[column]
            case .right: starts[column] + widths[column]
            case .center: starts[column] + widths[column] / 2
            }
            return NSTextTab(textAlignment: alignment, location: location, options: [:])
        }

        // A left-aligned first column needs no leading tab (a left tab stop at
        // 0 is skipped by the layout engine, which would jump the cell to the
        // NEXT stop). A right/center first column gets a leading tab whose stop
        // is its own.
        let leadingTab = table.alignments[0] != .left
        var stops: [NSTextTab] = []
        if leadingTab { stops.append(tabStop(for: 0)) }
        for column in 1..<columnCount { stops.append(tabStop(for: column)) }

        let tab = NSAttributedString(string: "\t", attributes: [.font: bodyFont])
        func assemble(_ cells: [NSAttributedString]) -> NSMutableAttributedString {
            let line = NSMutableAttributedString()
            if leadingTab { line.append(tab) }
            line.append(cells[0])
            for column in 1..<columnCount {
                line.append(tab)
                line.append(cells[column])
            }
            return line
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.tabStops = stops

        let dashWidth = ("\u{2500}" as NSString).size(withAttributes: [.font: bodyFont]).width
        let separatorCells = (0..<columnCount).map { column -> NSAttributedString in
            let count = dashWidth > 0 ? max(1, Int(widths[column] / dashWidth)) : 1
            return NSAttributedString(string: String(repeating: "\u{2500}", count: count), attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        }

        let out = NSMutableAttributedString()
        out.append(assemble(headerCells))
        out.addAttribute(.backgroundColor, value: tableHeaderBackground, range: NSRange(location: 0, length: out.length))
        out.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        out.append(assemble(separatorCells))
        out.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        for row in bodyRows {
            out.append(assemble(row))
            out.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        }
        // One line per row, so no trailing blank line; the block gap is added
        // by the segment assembler.
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Renders one table cell's inline markdown (bold/italic/strikethrough/
    /// inline code/links) at the cell's font. Cells carry no block structure,
    /// so this is the inline half of `buildMarkdown` without block handling.
    nonisolated private static func renderInlineCell(_ source: String, bodySize: CGFloat, isHeader: Bool) -> NSAttributedString {
        let baseFont = isHeader ? NSFont.boldSystemFont(ofSize: bodySize) : NSFont.systemFont(ofSize: bodySize)
        let monoFont = NSFont.monospacedSystemFont(ofSize: max(bodySize - 1, 9), weight: .regular)
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        let out = NSMutableAttributedString()
        guard !trimmed.isEmpty else {
            // A single space keeps alignment and gives the column a real width.
            return NSAttributedString(string: " ", attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor])
        }
        guard let parsed = try? AttributedString(markdown: trimmed) else {
            return NSAttributedString(string: trimmed, attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor])
        }
        for run in parsed.runs {
            let text = String(parsed.characters[run.range]).replacingOccurrences(of: "\n", with: " ")
            guard !text.isEmpty else { continue }
            var font = baseFont
            if run.inlinePresentationIntent?.contains(.code) == true { font = monoFont }
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { font = withTrait([.bold], font) }
                if inline.contains(.emphasized) { font = withTrait([.italic], font) }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if run.inlinePresentationIntent?.contains(.code) == true { attrs[.backgroundColor] = codeBackground }
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
            return NSAttributedString(string: trimmed, attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor])
        }
        return out
    }

    /// Tint behind a table's header row; dynamic so it adapts to dark/light
    /// mode and is resolved per draw.
    nonisolated private static let tableHeaderBackground = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.09)
            : NSColor(calibratedWhite: 0.0, alpha: 0.05)
    }

    /// Applies a font trait (bold/italic) without `NSFontManager` — the
    /// shared instance is not thread-safe, and this runs on the background
    /// pre-measurer. The descriptor route (`withSymbolicTraits`) synthesizes
    /// the same faces as `NSFontManager.convert(_:toHaveTrait:)` (verified on
    /// this SDK: same font names, same symbolic traits) and merges into the
    /// font's EXISTING traits, so a bold font gaining italic stays bold+italic
    /// exactly like the old sequential `convert` calls.
    nonisolated private static func withTrait(_ trait: NSFontDescriptor.SymbolicTraits, _ font: NSFont) -> NSFont {
        let merged = font.fontDescriptor.symbolicTraits.union(trait)
        let descriptor = font.fontDescriptor.withSymbolicTraits(merged)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
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

    /// The vertical gap inserted between markdown blocks (as an empty spacer
    /// line whose font height equals the gap).
    nonisolated private static func blockGap(_ layout: BlockLayout) -> CGFloat {
        if layout.headerLevel > 0 { return 10 }
        if layout.isCodeBlock { return 8 }
        if layout.isThematicBreak { return 8 }
        if !layout.indents.isEmpty { return 4 } // list item
        return 6
    }

    /// h1…h6 scale the body font by this much (all bold).
    nonisolated private static func headerBoost(_ level: Int) -> CGFloat {
        switch level {
        case 1: 6
        case 2: 4
        case 3: 2
        default: 0
        }
    }

    /// Subtle gray behind code (inline pill and the full-width card the row
    /// draws over fenced blocks), a touch stronger with Increase Contrast.
    /// Dynamic so it adapts to dark/light mode; resolved per draw, so a
    /// mid-session appearance change applies without re-rendering rows.
    nonisolated static let codeBackground = NSColor(name: nil) { appearance in
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

    nonisolated private static func plainParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        p.lineBreakMode = .byWordWrapping
        return p
    }
}

import AppKit
import XCTest

/// Unit tests for `MarkdownText` — the markdown → attributed-string renderer
/// behind every user/assistant row. Deterministic: no pi process, no network.
final class MarkdownTextTests: XCTestCase {
    private let size: CGFloat = 13

    private func body(_ markdown: String) -> MarkdownText.MarkdownBody {
        MarkdownText.body(text: markdown, bodySize: size)
    }

    // MARK: - Inline styling

    func testBoldItalicBothStrikethroughAndInlineCode() {
        let b = body("**bold** *italic* ***both*** ~~strike~~ `code`")
        XCTAssertEqual(RenderTestHelper.range(of: "bold", in: b.string).location, 0)
        XCTAssertTrue(RenderTestHelper.font(b.string, at: 0, hasTrait: .bold))
        XCTAssertFalse(RenderTestHelper.font(b.string, at: 0, hasTrait: .italic))

        let italicLoc = RenderTestHelper.range(of: "italic", in: b.string).location
        XCTAssertTrue(RenderTestHelper.font(b.string, at: italicLoc, hasTrait: .italic))
        XCTAssertFalse(RenderTestHelper.font(b.string, at: italicLoc, hasTrait: .bold))

        let bothLoc = RenderTestHelper.range(of: "both", in: b.string).location
        XCTAssertTrue(RenderTestHelper.font(b.string, at: bothLoc, hasTrait: .bold))
        XCTAssertTrue(RenderTestHelper.font(b.string, at: bothLoc, hasTrait: .italic))

        let strikeLoc = RenderTestHelper.range(of: "strike", in: b.string).location
        let strike = b.string.attribute(.strikethroughStyle, at: strikeLoc, effectiveRange: nil) as? Int
        XCTAssertEqual(strike, NSUnderlineStyle.single.rawValue)

        let codeLoc = RenderTestHelper.range(of: "code", in: b.string).location
        XCTAssertTrue(RenderTestHelper.font(b.string, at: codeLoc, hasTrait: .monoSpace))
        XCTAssertNotNil(b.string.attribute(.backgroundColor, at: codeLoc, effectiveRange: nil))
    }

    func testMarkdownMarkersAreStripped() {
        let b = body("**bold** and `code`")
        XCTAssertEqual(RenderTestHelper.substring(b.string, NSRange(location: 0, length: 4)), "bold")
        XCTAssertNil(RenderTestHelper.range(of: "**", in: b.string).location != NSNotFound ? "found" : nil)
    }

    // MARK: - Headers

    func testHeadersScaleTheBodyFontAndAreBold() {
        let b = body("# h1\n## h2\n### h3\n#### h4")
        XCTAssertTrue(RenderTestHelper.font(b.string, at: 0, hasTrait: .bold))
        XCTAssertEqual(RenderTestHelper.font(b.string, at: 0)?.pointSize, size + 6, "h1")
        let h2 = RenderTestHelper.range(of: "h2", in: b.string).location
        XCTAssertEqual(RenderTestHelper.font(b.string, at: h2)?.pointSize, size + 4, "h2")
        let h3 = RenderTestHelper.range(of: "h3", in: b.string).location
        XCTAssertEqual(RenderTestHelper.font(b.string, at: h3)?.pointSize, size + 2, "h3")
        let h4 = RenderTestHelper.range(of: "h4", in: b.string).location
        XCTAssertEqual(RenderTestHelper.font(b.string, at: h4)?.pointSize, size, "h4")
    }

    // MARK: - Code blocks

    func testCodeBlockIsMonospacedWithReservedRightStrip() {
        let b = body("```swift\nlet x = 1\n```")
        XCTAssertEqual(b.codeBlocks.count, 1)
        let loc = b.codeBlocks[0].range.location
        XCTAssertTrue(RenderTestHelper.font(b.string, at: loc, hasTrait: .monoSpace))
        XCTAssertEqual(
            RenderTestHelper.paragraph(b.string, at: loc)?.tailIndent,
            -MarkdownText.codeBlockRightReserve
        )
    }

    func testCodeBlockRangesMapToExactContent() {
        let b = body("before\n\n```swift\nlet a = 1\nlet b = 2\n```\n\nafter\n\n```swift\nlet c = 3\n```")
        XCTAssertEqual(b.codeBlocks.count, 2)
        for block in b.codeBlocks {
            // The displayed substring must equal the copy content minus the
            // stripped trailing newline.
            let displayed = RenderTestHelper.substring(b.string, block.range)
            var copy = block.code
            XCTAssertTrue(copy.hasSuffix("\n"), "copy content carries the trailing newline")
            copy.removeLast()
            XCTAssertEqual(displayed, copy)
        }
        XCTAssertFalse(RenderTestHelper.substring(b.string, b.codeBlocks[0].range).contains("before"))
        XCTAssertTrue(RenderTestHelper.substring(b.string, b.codeBlocks[0].range).contains("let b = 2"))
    }

    func testCodeBlockLinesStayTight() {
        // Regression: paragraphSpacingBefore/After on this SDK inflate every
        // line fragment of a multi-line paragraph (a 16pt line became 30pt).
        let b = body("a\n\n```swift\nline one\nline two\nline three\n```\n\nz")
        let (_, view) = RenderTestHelper.layout(b.string, width: 800)
        let glyphs = view.layoutManager!.glyphRange(forCharacterRange: b.codeBlocks[0].range, actualCharacterRange: nil)
        let pitches = RenderTestHelper.linePitches(view, glyphRange: glyphs)
        XCTAssertGreaterThan(pitches.count, 1)
        XCTAssertLessThanOrEqual(pitches.max() ?? .greatestFiniteMagnitude, 17, "code lines must not be inflated")
    }

    func testUnclosedFenceRendersStreamingTailAsCodeBlock() {
        // While streaming, a fence without its closing ``` renders the tail
        // as one code block — the parser's CommonMark behavior.
        let b = body("Here is the code:\n```swift\nlet x = 1\nprint(x)")
        XCTAssertEqual(b.codeBlocks.count, 1)
        XCTAssertTrue(b.codeBlocks[0].code.contains("let x = 1\nprint(x)"))
    }

    // MARK: - Block spacing (regressions)

    func testNoParagraphSpacingAttributes() {
        // Regression: paragraphSpacingBefore/After inflated every line. All
        // spacing must now come from explicit spacer lines.
        let b = body("# header\n\nparagraph one\n\nparagraph two\n\n```swift\nx\n```")
        var location = 0
        while location < b.string.length {
            var effective = NSRange(location: 0, length: 0)
            let ps = b.string.attribute(.paragraphStyle, at: location, effectiveRange: &effective) as? NSParagraphStyle
            XCTAssertEqual(ps?.paragraphSpacingBefore ?? 0, 0, "at \(location)")
            XCTAssertEqual(ps?.paragraphSpacing ?? 0, 0, "at \(location)")
            location = effective.upperBound
        }
    }

    func testBlocksAreSeparatedBySpacerLines() {
        // Two one-line paragraphs separated by a blank line must render with
        // a visible gap (the spacer line) between them, not merged and not
        // with per-line inflation: 16 (line) + ~6 (spacer) + 16 (line) > 32.
        let b = body("aaa\n\nbbb")
        let (used, _) = RenderTestHelper.layout(b.string, width: 800)
        XCTAssertGreaterThan(used.height, 32, "the spacer line must separate the paragraphs")
    }

    // MARK: - Line breaks

    func testSoftBreaksPreserved() {
        // Regression: single newlines inside a paragraph were collapsed to
        // spaces, rendering multi-line messages as one line.
        let b = body("line one\nline two\nline three")
        XCTAssertEqual(RenderTestHelper.ranges(of: "\n", in: b.string).count, 2)
        let (_, view) = RenderTestHelper.layout(b.string, width: 800)
        XCTAssertGreaterThanOrEqual(
            view.layoutManager!.usedRect(for: view.textContainer!).height,
            3 * 14,
            "three lines must render"
        )
    }

    func testHardBreaksPreserved() {
        // Two trailing spaces force a hard break; the parser emits "\n" for it.
        let b = body("a  \nb")
        XCTAssertEqual(RenderTestHelper.substring(b.string, NSRange(location: 0, length: 3)), "a\nb")
    }

    // MARK: - Lists

    func testBulletListMarkersAndHangingIndent() {
        let b = body("- item one\n- item two")
        let first = RenderTestHelper.range(of: "•", in: b.string)
        XCTAssertNotEqual(first.location, NSNotFound, "bullet marker present")
        XCTAssertEqual(RenderTestHelper.ranges(of: "•", in: b.string).count, 2)
        let itemLoc = RenderTestHelper.range(of: "item one", in: b.string).location
        let ps = RenderTestHelper.paragraph(b.string, at: itemLoc)
        XCTAssertGreaterThan(ps?.headIndent ?? 0, 0, "wrapped lines indent past the bullet")
    }

    func testNestedListIndentsAndNestedMarker() {
        let b = body("- outer\n  - inner")
        XCTAssertEqual(RenderTestHelper.ranges(of: "•", in: b.string).count, 1)
        XCTAssertEqual(RenderTestHelper.ranges(of: "◦", in: b.string).count, 1, "nested marker")
        let outer = RenderTestHelper.range(of: "outer", in: b.string).location
        let inner = RenderTestHelper.range(of: "inner", in: b.string).location
        XCTAssertGreaterThan(
            RenderTestHelper.paragraph(b.string, at: inner)?.firstLineHeadIndent ?? 0,
            RenderTestHelper.paragraph(b.string, at: outer)?.firstLineHeadIndent ?? 0,
            "nested item indents deeper"
        )
    }

    func testOrderedListNumbering() {
        let b = body("1. first\n2. second")
        XCTAssertEqual(RenderTestHelper.ranges(of: "1. ", in: b.string).count, 1)
        XCTAssertEqual(RenderTestHelper.ranges(of: "2. ", in: b.string).count, 1)
    }

    // MARK: - Blockquotes

    func testBlockquoteMarker() {
        let b = body("> a quote")
        XCTAssertEqual(RenderTestHelper.ranges(of: "▍", in: b.string).count, 1)
        let quoteLoc = RenderTestHelper.range(of: "a quote", in: b.string).location
        XCTAssertGreaterThan(RenderTestHelper.paragraph(b.string, at: quoteLoc)?.headIndent ?? 0, 0)
    }

    // MARK: - Links

    func testLinkAttributeAndColor() {
        let b = body("[example](https://example.com)")
        let linkLoc = RenderTestHelper.range(of: "example", in: b.string).location
        let link = b.string.attribute(.link, at: linkLoc, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://example.com")
        XCTAssertEqual(
            RenderTestHelper.font(b.string, at: linkLoc)?.pointSize,
            size,
            "link text keeps the body size"
        )
    }

    // MARK: - Thematic break

    func testThematicBreakRendersSeparator() {
        let b = body("a\n\n---\n\nb")
        // The parser materializes the break as a three-em dash character.
        XCTAssertFalse(RenderTestHelper.ranges(of: "⸻", in: b.string).isEmpty)
    }

    // MARK: - Measurement invariant

    func testMeasuredHeightMatchesRenderedHeight() {
        // The load-bearing invariant: the table measures rows with
        // boundingRect and the cell renders with the layout manager — both
        // must agree so rows never clip or pad.
        let md = "# Title\n\nSome **bold** and `inline` text.\n\n- one\n- two\n\n> quote\n\n```swift\nlet x = 1\n```\n\n[link](https://x.com)"
        let b = body(md)
        let (used, _) = RenderTestHelper.layout(b.string, width: 800)
        XCTAssertEqual(
            RenderTestHelper.boundingHeight(b.string, width: 800),
            used.height,
            accuracy: 0.5
        )
    }

    // MARK: - Caching

    func testCachingReturnsTheSameObject() {
        let b1 = body("same text")
        let b2 = body("same text")
        XCTAssertTrue(b1 === b2, "identical (text, size) parses once")
        let other = MarkdownText.body(text: "same text", bodySize: size + 3)
        XCTAssertFalse(b1 === other, "different size is a different entry")
    }

    // MARK: - Empty / degenerate input

    func testEmptyTextYieldsEmptyBody() {
        let b = body("")
        XCTAssertEqual(b.string.length, 0)
        XCTAssertTrue(b.codeBlocks.isEmpty)
    }

    func testWhitespaceOnlyYieldsNoCodeBlocks() {
        let b = body("   \n\n  ")
        XCTAssertTrue(b.codeBlocks.isEmpty)
    }

    func testWeirdUnclosedMarkupRendersVerbatim() {
        // Pathological input must not throw; markers render as literal text.
        let b = body("a ** b * c *** d ` e")
        XCTAssertGreaterThan(b.string.length, 0)
        XCTAssertTrue(RenderTestHelper.substring(b.string, NSRange(location: 0, length: 2)) == "a ")
    }
}

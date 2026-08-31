import AppKit
import XCTest

/// Unit tests for `TranscriptText` — the full row assembly on top of
/// `MarkdownText`: thinking prefix, streaming caret, cache-rate line, the
/// per-role markdown/plain switch, and code-block ranges in the FULL string.
final class TranscriptTextTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontSettings.shared.bodySize = 13
    }

    private func result(
        _ text: String,
        thinking: String? = nil,
        role: TextRowView.Role = .assistant,
        isStreaming: Bool = false,
        cacheHitRate: Double? = nil,
        cacheMiss: Bool = false
    ) -> TranscriptText.AttributedResult {
        TranscriptText.attributedResult(
            text: text,
            thinking: thinking,
            role: role,
            isStreaming: isStreaming,
            cacheHitRate: cacheHitRate,
            cacheMiss: cacheMiss,
            bodySize: FontSettings.shared.bodySize
        )
    }

    // MARK: - Per-role markdown switch

    func testUserMessageRendersMarkdown() {
        let r = result("**bold**", role: .user)
        XCTAssertTrue(RenderTestHelper.font(r.string, at: 0, hasTrait: .bold))
    }

    func testAssistantStreamingRendersMarkdownAndAppendsCaret() {
        let r = result("**bold**", isStreaming: true)
        XCTAssertTrue(RenderTestHelper.font(r.string, at: 0, hasTrait: .bold), "markdown even while streaming")
        XCTAssertEqual(RenderTestHelper.substring(r.string, NSRange(location: r.string.length - 1, length: 1)), "▌")
    }

    func testErrorAndAbortedRowsStayPlain() {
        let plain = "**not markdown**"
        let error = result(plain, role: .error)
        XCTAssertEqual(RenderTestHelper.substring(error.string, NSRange(location: 0, length: 2)), "**")
        let aborted = result(plain, role: .aborted)
        XCTAssertEqual(RenderTestHelper.substring(aborted.string, NSRange(location: 0, length: 2)), "**")
    }

    // MARK: - Thinking prefix + code block offsets

    func testCodeBlockRangesAreOffsetPastThinking() {
        let thinking = "Let me think about it."
        let md = "Text.\n\n```swift\nlet x = 1\n```"
        let r = result(md, thinking: thinking)
        XCTAssertEqual(r.codeBlocks.count, 1)
        // The range must point into the FULL string (thinking run precedes the
        // body), and the substring there must be the displayed code.
        let displayed = RenderTestHelper.substring(r.string, r.codeBlocks[0].range)
        var copy = r.codeBlocks[0].code
        copy.removeLast()
        XCTAssertEqual(displayed, copy)
        XCTAssertGreaterThan(r.codeBlocks[0].range.location, thinking.count, "offset past the thinking run")
        // The copy content matches the code block exactly.
        XCTAssertEqual(r.codeBlocks[0].code, "let x = 1\n")
    }

    func testNoThinkingNoOffset() {
        let r = result("```swift\nx\n```")
        XCTAssertEqual(r.codeBlocks[0].range.location, 0)
    }

    // MARK: - Cache rate line

    func testCacheLineFormatting() {
        let r = result("answer", cacheHitRate: 0.9997)
        let line = RenderTestHelper.substring(r.string, NSRange(location: 0, length: r.string.length))
        XCTAssertTrue(line.contains("⚡ cache 99.97%"), "precision must not round 99.97 to 100")
        XCTAssertFalse(line.contains("large miss"))
    }

    func testCacheLineLargeMissSuffix() {
        let r = result("answer", cacheHitRate: 0.0502, cacheMiss: true)
        XCTAssertTrue(RenderTestHelper.substring(r.string, NSRange(location: 0, length: r.string.length)).contains("⚡ cache 5.02% · large miss"))
    }

    func testCacheLineOnlyOnFinalAssistant() {
        XCTAssertFalse(result("answer", role: .user, cacheHitRate: 0.9).string.string.contains("⚡"), "no cache line on user rows")
        XCTAssertFalse(result("answer", role: .assistant, isStreaming: true, cacheHitRate: 0.9).string.string.contains("⚡"), "no cache line while streaming")
        XCTAssertTrue(result("answer", role: .assistant, cacheHitRate: 0.9).string.string.contains("⚡"))
    }

    // MARK: - Row height invariant

    func testMeasuredHeightMatchesCellContentHeight() {
        let md = "# Title\n\nSome **bold** text that wraps to a second line here please.\n\n```swift\nlet a = 1\nlet b = 2\n```\n\n- one\n- two"
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        row.configure(text: md, thinking: "thinking", role: .assistant, isStreaming: false, cacheHitRate: 0.95, cacheMiss: false)
        row.layoutSubtreeIfNeeded()
        let measured = TranscriptText.measuredHeight(
            text: md, thinking: "thinking", role: .assistant, isStreaming: false, width: 800,
            cacheHitRate: 0.95, cacheMiss: false, bodySize: FontSettings.shared.bodySize
        )
        // contentHeight = usedRect + insets; measuredHeight adds 2pt slack.
        XCTAssertEqual(measured, row.contentHeight, accuracy: 3)
    }

    func testMeasuredHeightIsPositiveForEmptyText() {
        XCTAssertGreaterThan(
            TranscriptText.measuredHeight(text: "", thinking: nil, role: .assistant, isStreaming: false, width: 800, bodySize: FontSettings.shared.bodySize),
            0
        )
    }
}

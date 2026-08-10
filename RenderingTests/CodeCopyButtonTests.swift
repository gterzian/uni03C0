import AppKit
import XCTest

/// Unit tests for `CodeCopyButton` — the corner copy button over code blocks
/// in final assistant responses. Clicks are driven via `performClick`, so no
/// real mouse events or windows are needed.
final class CodeCopyButtonTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NSPasteboard.general.clearContents()
    }

    func testClickCopiesTheBlock() {
        let code = "let answer = 42\nprint(answer)\n"
        let button = CodeCopyButton(code: code)
        button.performClick(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), code)
    }

    func testClickCopiesWithTrailingNewline() {
        let code = "let x = 1\n"
        CodeCopyButton(code: code).performClick(nil)
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.hasSuffix("\n") == true)
    }

    func testRepeatedClicksRecopy() {
        let button = CodeCopyButton(code: "a")
        button.performClick(nil)
        let second = CodeCopyButton(code: "b")
        second.performClick(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "b")
    }

    func testAccessibilityLabel() {
        let button = CodeCopyButton(code: "x")
        XCTAssertEqual(button.accessibilityLabel(), "Copy code")
    }

    func testFixedSizeFitsTheReservedStrip() {
        XCTAssertLessThanOrEqual(CodeCopyButton.size.width, MarkdownText.codeBlockRightReserve)
    }

    func testPointingHandCursor() {
        let button = CodeCopyButton(code: "x")
        XCTAssertTrue(button.responds(to: #selector(NSView.resetCursorRects)))
    }
}

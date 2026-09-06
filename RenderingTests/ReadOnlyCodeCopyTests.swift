import AppKit
import Core
import XCTest

/// Copy behavior of the read-only code view: a selection copy writes BOTH the
/// plain snippet (for other apps) and the full `CodeReference` (path + lines
/// + snippet) on one pasteboard item, with line numbers derived from the
/// buffer so a selection ending at a line boundary never counts the next
/// line (§1.3). Real pasteboard, no mocking — the `CodeCopyButtonTests`
/// posture.
final class ReadOnlyCodeCopyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NSPasteboard.general.clearContents()
    }

    private func makeView(path: String, text: String) -> ReadOnlyCodeTextView {
        let view = ReadOnlyCodeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), textContainer: nil)
        view.load(
            path: path,
            text: NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            ])
        )
        return view
    }

    private func copiedReference() -> CodeReference? {
        guard let data = NSPasteboard.general.data(forType: .codeReference) else { return nil }
        return try? JSONDecoder().decode(CodeReference.self, from: data)
    }

    func testSingleLineSelectionCopiesReference() {
        let view = makeView(path: "/tmp/demo.swift", text: "let answer = 42\n")
        view.setSelectedRange(NSRange(location: 0, length: 15)) // "let answer = 42"
        view.copy(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "let answer = 42",
                       "other apps must still get the plain snippet")
        guard let reference = copiedReference() else {
            return XCTFail("expected the code-reference payload")
        }
        XCTAssertEqual(reference.absolutePath, "/tmp/demo.swift")
        XCTAssertEqual(reference.startLine, 1)
        XCTAssertEqual(reference.endLine, 1)
        XCTAssertEqual(reference.snippet, "let answer = 42")
    }

    func testMultiLineSelectionMapsLineRange() {
        let view = makeView(path: "/tmp/demo.swift", text: "line1\nline2\nline3\n")
        // "line2" spans offsets 6..11; select through the end of "line3" at
        // offset 16 (exclusive) — i.e. "line2\nline3".
        view.setSelectedRange(NSRange(location: 6, length: 11))
        view.copy(nil)

        guard let reference = copiedReference() else {
            return XCTFail("expected the code-reference payload")
        }
        XCTAssertEqual(reference.startLine, 2)
        XCTAssertEqual(reference.endLine, 3)
        XCTAssertEqual(reference.snippet, "line2\nline3")
    }

    func testSelectionEndingAtLineBoundaryDoesNotIncludeNextLine() {
        let view = makeView(path: "/tmp/demo.swift", text: "line1\nline2\nline3\n")
        // Select through the trailing newline of line 2: offsets 6..18
        // ("line2\n"). The end offset falls on the newline, which belongs to
        // line 2 — the phantom empty line 3 must NOT be included.
        view.setSelectedRange(NSRange(location: 6, length: 6))
        view.copy(nil)

        guard let reference = copiedReference() else {
            return XCTFail("expected the code-reference payload")
        }
        XCTAssertEqual(reference.startLine, 2)
        XCTAssertEqual(reference.endLine, 2)
        XCTAssertEqual(reference.snippet, "line2\n")
    }

    func testSelectionThroughFinalNewlineDoesNotAddTrailingPhantomLine() {
        let view = makeView(path: "/tmp/demo.swift", text: "line1\nline2\nline3\n")
        view.setSelectedRange(NSRange(location: 0, length: 18)) // whole buffer incl. final newline
        view.copy(nil)

        guard let reference = copiedReference() else {
            return XCTFail("expected the code-reference payload")
        }
        XCTAssertEqual(reference.startLine, 1)
        XCTAssertEqual(reference.endLine, 3, "a final newline must not create a line 4")
    }

    func testCaretOnlyCopyDoesNotWriteReference() {
        let view = makeView(path: "/tmp/demo.swift", text: "line1\n")
        view.setSelectedRange(NSRange(location: 3, length: 0)) // just a caret
        view.copy(nil) // must not crash, must not write a zero-width reference
        XCTAssertNil(copiedReference())
    }
}

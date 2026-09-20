import AppKit
import Core
import XCTest

/// The Changes (diff) viewer's copy → reference and reveal behavior. The diff
/// document is ONE multi-file buffer: each file's diff lines carry that file's
/// canonical absolute path, so a copy inside the diff must tag a
/// `CodeReference` to the FILE (never to "the diff"), with REAL current-file
/// lines and a snippet that drops the interleaved removed (old-side) lines.
final class DiffViewerReferenceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NSPasteboard.general.clearContents()
    }

    /// The buffer the diff builder produces for two changed files: each file's
    /// diff lines (a removed line then two current lines), joined by newlines.
    /// Display line → real line: [nil, 1, 2, nil, 1, 2].
    private let document = "goneA\nalpha1\nalpha2\ngoneB\nbeta1\nbeta2"

    private func makeView() -> (ReadOnlyCodeTextView, (alpha: NSRange, beta: NSRange)) {
        let view = ReadOnlyCodeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), textContainer: nil)
        view.load(
            path: "",
            text: NSAttributedString(string: document, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            ]),
            lineNumbers: [nil, 1, 2, nil, 1, 2]
        )
        let alpha = NSRange(location: 0, length: ("goneA\nalpha1\nalpha2" as NSString).length)
        let betaStart = ("goneA\nalpha1\nalpha2\n" as NSString).length
        let beta = NSRange(location: betaStart, length: ("goneB\nbeta1\nbeta2" as NSString).length)
        view.setSectionPaths([
            (alpha, "/tmp/proj/Alpha.swift"),
            (beta, "/tmp/proj/Beta.swift"),
        ])
        return (view, (alpha, beta))
    }

    private func copiedReference() -> CodeReference? {
        guard let data = NSPasteboard.general.data(forType: .codeReference) else { return nil }
        return try? JSONDecoder().decode(CodeReference.self, from: data)
    }

    private func range(of needle: String) -> NSRange {
        (document as NSString).range(of: needle)
    }

    func testCopyInsideFirstFileTagsThatFileWithRealLines() {
        let (view, _) = makeView()
        view.setSelectedRange(range(of: "alpha1\nalpha2"))
        view.copy(nil)

        guard let reference = copiedReference() else {
            return XCTFail("expected a reference-tagged copy from the diff")
        }
        XCTAssertEqual(reference.absolutePath, "/tmp/proj/Alpha.swift",
                       "the reference must name the FILE, not the diff")
        XCTAssertEqual(reference.startLine, 1)
        XCTAssertEqual(reference.endLine, 2)
        XCTAssertEqual(reference.snippet, "alpha1\nalpha2",
                       "the removed (old-side) line must not leak into the snippet")
    }

    func testCopyInsideSecondFileRestartsRealLineNumbers() {
        let (view, _) = makeView()
        view.setSelectedRange(range(of: "beta1\nbeta2"))
        view.copy(nil)

        guard let reference = copiedReference() else {
            return XCTFail("expected a reference-tagged copy from the diff")
        }
        XCTAssertEqual(reference.absolutePath, "/tmp/proj/Beta.swift")
        XCTAssertEqual(reference.startLine, 1, "real file lines restart per file")
        XCTAssertEqual(reference.endLine, 2)
        XCTAssertEqual(reference.snippet, "beta1\nbeta2")
    }

    func testCopyOfRemovedLineOnlyFallsBackToPlainText() {
        let (view, _) = makeView()
        view.setSelectedRange(range(of: "goneA"))
        view.copy(nil)

        XCTAssertNil(copiedReference(), "a removed-only selection has no current-file content to reference")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "goneA",
                       "the plain text must still copy")
    }

    func testCopyCrossingIntoAnotherFileClampsToTheOwningFile() {
        let (view, _) = makeView()
        // Start in Alpha, drag through the gap and well into Beta.
        let start = range(of: "alpha2").location
        let end = range(of: "beta2").location + ("beta2" as NSString).length
        view.setSelectedRange(NSRange(location: start, length: end - start))
        view.copy(nil)

        guard let reference = copiedReference() else {
            return XCTFail("expected a reference-tagged copy")
        }
        XCTAssertEqual(reference.absolutePath, "/tmp/proj/Alpha.swift")
        XCTAssertEqual(reference.snippet, "alpha2", "another file's lines must not leak into the snippet")
        XCTAssertEqual(reference.startLine, 2)
        XCTAssertEqual(reference.endLine, 2)
    }

    func testCopyStartingOnALeadingRemovalUsesTheOwningFileLine() {
        let (view, _) = makeView()
        // Beta starts with a removed line; selecting it must anchor at Beta's
        // OWN first real line, never Alpha's last line.
        let start = range(of: "goneB").location
        let end = range(of: "beta1").location + ("beta1" as NSString).length
        view.setSelectedRange(NSRange(location: start, length: end - start))
        view.copy(nil)

        guard let reference = copiedReference() else {
            return XCTFail("expected a reference-tagged copy")
        }
        XCTAssertEqual(reference.absolutePath, "/tmp/proj/Beta.swift")
        XCTAssertEqual(reference.startLine, 1, "must not borrow Alpha's line numbers")
        XCTAssertEqual(reference.endLine, 1)
        XCTAssertEqual(reference.snippet, "beta1")
    }

    func testPrecomputedLineOffsetsMatchTheScan() {
        let text = "line1\nline2\nline3"
        let offsets = ReadOnlyCodeTextView.lineStartOffsets(in: text)
        XCTAssertEqual(offsets, [0, 6, 12])

        let view = ReadOnlyCodeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), textContainer: nil)
        view.load(
            path: "/tmp/offsets.swift",
            text: NSAttributedString(string: text),
            lineStartOffsets: offsets
        )
        XCTAssertEqual(view.lineStartOffsets, offsets, "supplied offsets must be used, not rescanned")
        XCTAssertEqual(view.lineNumber(forIndex: 0), 1)
        XCTAssertEqual(view.lineNumber(forIndex: 6), 2)
        XCTAssertEqual(view.lineNumber(forIndex: 12), 3)
    }

    func testCopyOnAnExpandRowFallsBackToPlainText() {
        let (view, _) = makeView()
        // An expand/placeholder row is outside every section's diff range.
        view.setSectionPaths([])
        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.copy(nil)
        XCTAssertNil(copiedReference())
    }

    // MARK: - Reveal (agent link → diff section at the named line)

    @MainActor
    private func makeContainer() -> CodePaneContainer {
        let container = CodePaneContainer(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        let ns = document as NSString
        let alphaStart = 0
        let alphaEnd = ("goneA\nalpha1\nalpha2" as NSString).length
        let betaStart = alphaEnd + 1
        let betaEnd = ns.length
        container.displayDocument(
            path: "",
            text: NSAttributedString(string: document, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            ]),
            lineNumbers: [nil, 1, 2, nil, 1, 2],
            sections: [
                CodeSection(
                    path: "Alpha.swift", absolutePath: "/tmp/proj/Alpha.swift",
                    lineRange: 1...3, diffLineRange: 1...3,
                    diffCharRange: NSRange(location: alphaStart, length: alphaEnd - alphaStart)
                ),
                CodeSection(
                    path: "Beta.swift", absolutePath: "/tmp/proj/Beta.swift",
                    lineRange: 4...6, diffLineRange: 4...6,
                    diffCharRange: NSRange(location: betaStart, length: betaEnd - betaStart)
                ),
            ]
        )
        return container
    }

    @MainActor
    func testRevealLineLandsOnTheNamedRealLine() {
        let container = makeContainer()
        let beta2 = (document as NSString).range(of: "beta2").location
        XCTAssertEqual(container.characterIndex(forPath: "Beta.swift", line: 2), beta2)
        XCTAssertEqual(container.characterIndex(forPath: "Alpha.swift", line: 1),
                       (document as NSString).range(of: "alpha1").location)
    }

    @MainActor
    func testRevealLineBeyondTheWindowFallsBackToTheSection() {
        let container = makeContainer()
        // A line past the shown window still lands somewhere sane (the last
        // real line of the section), never on another file's same-numbered line.
        let beta2 = (document as NSString).range(of: "beta2").location
        XCTAssertEqual(container.characterIndex(forPath: "Beta.swift", line: 99), beta2)
        XCTAssertEqual(container.characterIndex(forPath: "Beta.swift", line: 1),
                       (document as NSString).range(of: "beta1").location)
    }
}

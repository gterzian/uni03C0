import AppKit
import Core
import XCTest

/// Drives the real file-browser content pane (`FilePaneContainer`, from
/// `ReadOnlyFilePane.swift`) in an offscreen window to pin the reference-jump
/// behavior: a `targetLines` open must anchor the START line at the TOP of the
/// viewport (not just bring it somewhere into view), flash the referenced
/// range with a fading highlight, and keep an anchor — the ruler capsule and
/// the in-text accent bar — after the flash fades. These are the exact
/// behaviors a click on an agent-emitted `pi-file://` link is supposed to
/// produce, so the "file opens at the top" regression can never come back.
final class FilePaneReferenceTests: XCTestCase {
    private let startLine = 858
    private let endLine = 866

    private func paneText() -> NSAttributedString {
        let lines = (1...900).map { "this is line number \($0) of the pane test — padding padding" }
        let text = lines.joined(separator: "\n") + "\n"
        return NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
    }

    /// A container hosting a ~900-line file, laid out in an offscreen window.
    @MainActor
    private func makeContainer() -> FilePaneContainer {
        let container = FilePaneContainer(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        // Let the window/scroll-view settle before the jump (the document
        // view's frame grows on the layout pass after text lands).
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return container
    }

    @MainActor
    private func load(_ container: FilePaneContainer, target: (start: Int, end: Int)?) {
        container.displayContent(path: "/tmp/FilePaneReferenceTests.swift", text: paneText(), preserveScroll: false, targetLines: target)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }

    @MainActor
    func testReferenceJumpAnchorsStartLineAtTheViewportTopAndFlashes() {
        let container = makeContainer()
        load(container, target: (start: startLine, end: endLine))

        // The start line must anchor the TOP of the viewport — deep in the
        // file, never at the top.
        let clip = container.scrollView.contentView
        XCTAssertGreaterThan(clip.bounds.minY, 10000, "the view jumped down into the file (start line at the top)")
        XCTAssertGreaterThan(container.codeView.frame.height, clip.bounds.minY + clip.bounds.height,
                             "content below the viewport remains (the anchor is the start line)")

        // The flash is active and the anchor is set.
        XCTAssertNotNil(container.codeView.revealFlashRect, "flash highlight over the referenced range")
        XCTAssertGreaterThan(container.codeView.revealFlashAlpha, 0.3, "flash is visible, not already faded")
        XCTAssertNotNil(container.codeView.revealAnchorRect, "in-text accent bar")
        let ruler = container.scrollView.verticalRulerView as? CodeLineRulerView
        XCTAssertEqual(ruler?.anchorLine, startLine, "ruler capsule on the first line of the reference")
    }

    @MainActor
    func testFlashFadesAwayButTheAnchorStays() {
        let container = makeContainer()
        load(container, target: (start: startLine, end: endLine))

        // Let the ~0.85s flash finish.
        RunLoop.current.run(until: Date().addingTimeInterval(1.3))

        XCTAssertNil(container.codeView.revealFlashRect, "the flash fades away entirely")
        XCTAssertEqual(container.codeView.revealFlashAlpha, 0, "flash alpha ends at zero")
        XCTAssertNotNil(container.codeView.revealAnchorRect, "the in-text anchor stays after the flash")
        let ruler = container.scrollView.verticalRulerView as? CodeLineRulerView
        XCTAssertEqual(ruler?.anchorLine, startLine, "the ruler anchor still marks the first line")
    }

    @MainActor
    func testPlainReloadClearsFlashAndAnchor() {
        let container = makeContainer()
        load(container, target: (start: startLine, end: endLine))

        // A normal (non-reference) reload clears the reveal chrome.
        container.displayContent(path: "/tmp/other.swift", text: paneText(), preserveScroll: false, targetLines: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertNil(container.codeView.revealFlashRect)
        XCTAssertNil(container.codeView.revealAnchorRect)
        let ruler = container.scrollView.verticalRulerView as? CodeLineRulerView
        XCTAssertNil(ruler?.anchorLine)
    }
}

import AppKit
import XCTest

/// Unit tests for the streaming crossfade in `TextRowView` — the per-batch
/// fade-in of newly appended text.
///
/// The regressions under test both showed up as "weird formatting while
/// streaming that switching tabs heals" (a tab switch rebuilds the row from
/// scratch, so it hides any drift that lives in the text storage):
/// - a batch superseded before its ~0.3s fade finished must be SETTLED to its
///   final colors, not frozen at whatever alpha it had reached. The fade's
///   remaining steps are skipped by the generation guard, and the incremental
///   storage path keeps the prefix's colors, so a frozen region stayed
///   washed-out for the rest of the session — and every superseded batch added
///   another, lighter one (a growing gray block mid-message).
/// - the fade must end on the CAPTURED color object, never
///   `withAlphaComponent(1)`: the semantic colors are not opaque
///   (`labelColor` is alpha ~0.85), so forcing alpha 1 left faded-in text
///   darker than the text around it — reading as stray bold.
///
/// Nothing here spins the run loop unless it says so, so the fade's async
/// steps cannot interleave: the assertions are deterministic.
final class StreamingFadeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontSettings.shared.bodySize = 13
    }

    private func textView(of row: TextRowView) -> NSTextView {
        row.subviews.compactMap { $0 as? NSTextView }.first!
    }

    private func alpha(_ storage: NSTextStorage, at index: Int) -> CGFloat {
        guard let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor else {
            return .nan
        }
        return color.alphaComponent
    }

    /// A streaming row that has already appended one batch, so the next
    /// configure supersedes a fade in flight. `nil` when the crossfade is
    /// disabled by Reduce Motion (there is nothing to assert then).
    private func streamingRow() -> (TextRowView, NSTextStorage)? {
        guard !DisplayOptions.reduceMotion else { return nil }
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        row.configure(text: "alpha", thinking: nil, role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        row.configure(text: "alpha beta", thinking: nil, role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        return (row, textView(of: row).textStorage!)
    }

    // MARK: - The freshly appended batch is the only dim text

    func testAppendedBatchStartsDimAndThePrefixStaysFinal() {
        guard let (_, storage) = streamingRow() else { return }
        XCTAssertEqual(storage.string, "alpha beta▌")
        XCTAssertGreaterThan(alpha(storage, at: 0), 0.5, "already-visible text is never dimmed")
        XCTAssertLessThan(alpha(storage, at: 6), 0.5, "the appended batch fades in from near-invisible")
    }

    // MARK: - A superseded fade settles instead of freezing dim

    func testSupersededFadeSettlesToItsFinalColor() {
        guard let (row, storage) = streamingRow() else { return }
        // Next batch: supersedes the " beta" fade (whose remaining steps the
        // generation guard now skips).
        row.configure(text: "alpha beta gamma", thinking: nil, role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(storage.string, "alpha beta gamma▌")
        XCTAssertGreaterThan(alpha(storage, at: 6), 0.5, "the superseded batch is settled, not frozen dim")
        XCTAssertLessThan(alpha(storage, at: 11), 0.5, "the new batch is the one fading in")
    }

    func testManySupersededBatchesLeaveNoDimTextBehind() {
        guard !DisplayOptions.reduceMotion else { return }
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        var text = "start"
        row.configure(text: text, thinking: nil, role: .assistant, isStreaming: true)
        for index in 0..<12 {
            text += " chunk\(index)"
            row.configure(text: text, thinking: nil, role: .assistant, isStreaming: true)
            row.layoutSubtreeIfNeeded()
        }
        let storage = textView(of: row).textStorage!
        // Only the last batch may still be mid-fade; every earlier one settled.
        let lastBatch = (storage.string as NSString).range(of: " chunk11")
        var dimOutsideLastBatch: [NSRange] = []
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let color = value as? NSColor, color.alphaComponent < 0.5 else { return }
            guard NSIntersectionRange(range, lastBatch).length != range.length else { return }
            dimOutsideLastBatch.append(range)
        }
        XCTAssertTrue(
            dimOutsideLastBatch.isEmpty,
            "superseded batches must settle; dim ranges left behind: \(dimOutsideLastBatch)"
        )
    }

    // MARK: - Settling the message restores every color

    func testSettledMessageHasNoDimText() {
        guard let (row, storage) = streamingRow() else { return }
        row.configure(text: "alpha beta", thinking: nil, role: .assistant, isStreaming: false)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(storage.string, "alpha beta", "the caret leaves on settle")
        for index in 0..<storage.length {
            XCTAssertGreaterThan(alpha(storage, at: index), 0.5, "no dim glyph survives the settle (index \(index))")
        }
    }

    // MARK: - The completed fade lands on the captured color

    func testCompletedFadeRestoresTheCapturedColor() {
        guard let (_, storage) = streamingRow() else { return }
        // The fade steps are main-queue blocks ~0.05s apart: spin the run loop
        // past the last one.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let body = alpha(storage, at: 0)
        let faded = alpha(storage, at: 6)
        XCTAssertEqual(faded, body, accuracy: 0.001, "faded-in text ends at the color of the text around it")
        XCTAssertEqual(faded, NSColor.labelColor.alphaComponent, accuracy: 0.001, "never forced opaque")
    }
}

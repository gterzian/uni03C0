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
        let final = alpha(storage, at: 0)
        XCTAssertGreaterThan(final, 0.5, "already-visible text is never dimmed")
        let appended = alpha(storage, at: 6)
        XCTAssertLessThan(appended, final, "the appended batch fades in from a dimmer color")
        // The fade floors at a legible alpha: the semantic colors are already
        // translucent, so fading toward zero read as the background (the
        // dark-mode thinking-trace bug).
        XCTAssertGreaterThanOrEqual(appended, 0.45, "the appended batch is never unreadable")
    }

    /// The thinking trace is the case that surfaced the dark-mode bug: it is
    /// rendered in `secondaryLabelColor` (alpha ~0.55), so the old absolute
    /// 0.12 fade floor composited to near-background on a dark background. The
    /// newest reasoning glyph must stay legible while it arrives, and the
    /// already-visible trace must sit at its final color.
    func testThinkingStreamNeverFadesToTheBackground() {
        guard !DisplayOptions.reduceMotion else { return }
        let row = TextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        row.configure(text: "", thinking: "reasoning one", role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        row.configure(text: "", thinking: "reasoning one two", role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        let storage = textView(of: row).textStorage!
        XCTAssertGreaterThanOrEqual(
            alpha(storage, at: storage.length - 2),
            0.45,
            "the newest reasoning glyph is dimmed but still readable"
        )
        XCTAssertEqual(
            alpha(storage, at: 0),
            NSColor.secondaryLabelColor.alphaComponent,
            accuracy: 0.02,
            "the already-visible trace sits at its final secondary color"
        )
    }

    // MARK: - A superseded fade settles instead of freezing dim

    func testSupersededFadeSettlesToItsFinalColor() {
        guard let (row, storage) = streamingRow() else { return }
        // Next batch: supersedes the " beta" fade (whose remaining steps the
        // generation guard now skips).
        row.configure(text: "alpha beta gamma", thinking: nil, role: .assistant, isStreaming: true)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(storage.string, "alpha beta gamma▌")
        XCTAssertEqual(alpha(storage, at: 6), alpha(storage, at: 0), accuracy: 0.001, "the superseded batch is settled, not frozen dim")
        XCTAssertLessThan(alpha(storage, at: 11), alpha(storage, at: 0), "the new batch is the one fading in")
        XCTAssertGreaterThanOrEqual(alpha(storage, at: 11), 0.45, "the new batch is still readable")
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
        // The caret (systemBlue, alpha 0.6) and the last batch may still be
        // mid-fade; every EARLIER batch must be settled to the final label
        // color.
        let lastBatch = (storage.string as NSString).range(of: " chunk11")
        let caret = NSRange(location: storage.length - 1, length: 1)
        let final = NSColor.labelColor.alphaComponent
        var unsettled: [NSRange] = []
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let color = value as? NSColor else { return }
            guard NSIntersectionRange(range, lastBatch).length != range.length else { return }
            guard NSIntersectionRange(range, caret).length != range.length else { return }
            if abs(color.alphaComponent - final) > 0.02 { unsettled.append(range) }
        }
        XCTAssertTrue(unsettled.isEmpty, "superseded batches must settle; unsettled ranges: \(unsettled)")
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

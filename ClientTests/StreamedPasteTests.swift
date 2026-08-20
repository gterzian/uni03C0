import XCTest
@testable import Core

/// Tests for `StreamedPaste` — the windowed-paste helpers: a full pasted
/// document lives in a store, and the text view holds only a bounded window of
/// it that slides as the user scrolls. No AppKit, no LLM.
final class StreamedPasteTests: XCTestCase {

    private let budget = 65_536

    // MARK: - initialWindowStart

    func testInitialWindowIsTheTail() {
        XCTAssertEqual(StreamedPaste.initialWindowStart(fullLength: 100_000, budget: budget), 100_000 - budget)
    }

    func testTextFittingInBudgetStartsAtZero() {
        XCTAssertEqual(StreamedPaste.initialWindowStart(fullLength: 50_000, budget: budget), 0)
        XCTAssertEqual(StreamedPaste.initialWindowStart(fullLength: budget, budget: budget), 0)
    }

    func testEmptyTextStartsAtZero() {
        XCTAssertEqual(StreamedPaste.initialWindowStart(fullLength: 0, budget: budget), 0)
    }

    // MARK: - slideWindowStart

    func testSlideUpTowardHead() {
        let full = String(repeating: "x", count: 200_000)
        let start = StreamedPaste.initialWindowStart(fullLength: 200_000, budget: budget)
        XCTAssertEqual(start, 200_000 - budget)
        let next = StreamedPaste.slideWindowStart(fullText: full, windowStart: start, budget: budget, directionUp: true)
        XCTAssertEqual(next, 200_000 - 2 * budget)
    }

    func testSlideUpClampsAtZero() {
        let full = String(repeating: "x", count: 70_000)
        let start = StreamedPaste.initialWindowStart(fullLength: 70_000, budget: budget)
        XCTAssertEqual(start, 70_000 - budget)
        let next = StreamedPaste.slideWindowStart(fullText: full, windowStart: start, budget: budget, directionUp: true)
        XCTAssertEqual(next, 0, "sliding up past the head clamps to the start")
    }

    func testSlideDownTowardTail() {
        let full = String(repeating: "x", count: 200_000)
        let next = StreamedPaste.slideWindowStart(fullText: full, windowStart: 0, budget: budget, directionUp: false)
        XCTAssertEqual(next, budget)
    }

    func testSlideDownClampsAtTail() {
        let full = String(repeating: "x", count: 90_000)
        // Window at the very start; sliding down clamps so the window end
        // never passes the text end.
        let next = StreamedPaste.slideWindowStart(fullText: full, windowStart: 0, budget: budget, directionUp: false)
        XCTAssertEqual(next, 90_000 - budget)
    }

    func testSlideUpFromZeroIsZero() {
        let full = String(repeating: "x", count: 200_000)
        XCTAssertEqual(StreamedPaste.slideWindowStart(fullText: full, windowStart: 0, budget: budget, directionUp: true), 0)
    }

    // MARK: - windowText

    func testWindowTextRespectsBudget() {
        let full = String(repeating: "ab", count: 100_000) // 200k units
        let start = StreamedPaste.initialWindowStart(fullLength: 200_000, budget: budget)
        let window = StreamedPaste.windowText(fullText: full, windowStart: start, budget: budget)
        XCTAssertEqual((window as NSString).length, budget)
        XCTAssertEqual(full.hasSuffix(window), true)
    }

    func testWindowTextAtTopIsTheHead() {
        // Text that fits in the budget: the window at the head is the whole
        // text. ("ab" is TWO UTF-16 units, so 25k repetitions are 50k units —
        // within the 65_536 budget.)
        let full = String(repeating: "ab", count: 25_000)
        let window = StreamedPaste.windowText(fullText: full, windowStart: 0, budget: budget)
        XCTAssertEqual(window, full)
    }

    func testWindowTextIsASubstringOfTheStore() {
        let full = String(repeating: "0123456789", count: 30_000) // 300k units
        let start = StreamedPaste.initialWindowStart(fullLength: 300_000, budget: budget)
        let window = StreamedPaste.windowText(fullText: full, windowStart: start, budget: budget)
        let ns = full as NSString
        XCTAssertEqual(window, ns.substring(with: NSRange(location: start, length: budget)))
    }

    func testWindowTextStartDoesNotSplitSurrogatePair() {
        // A window start that lands BETWEEN the two units of a surrogate pair
        // must move back one unit so the pair is kept WHOLE at the start of
        // the window. The window shifts left and stays budget-sized (the end
        // is computed from the adjusted start, so it never exceeds the
        // budget). Text is ~2× the budget so the window doesn't clamp.
        let full = String(repeating: "q", count: budget - 2) + "🙂" + String(repeating: "r", count: budget)
        let start = budget - 1 // boundary between "🙂"'s units (high at budget-2, low at budget-1)
        let window = StreamedPaste.windowText(fullText: full, windowStart: start, budget: budget)
        XCTAssertTrue(window.unicodeScalars.allSatisfy { !$0.isSurrogate }, "window must be well-formed UTF-16")
        XCTAssertEqual((window as NSString).length, budget, "the window stays budget-sized, shifted left to keep the pair whole")
        XCTAssertTrue(window.hasPrefix("🙂"), "the pair is kept whole at the start of the window")
    }

    func testWindowTextEndDoesNotSplitSurrogatePair() {
        // A budget cut that lands BETWEEN the two units of a surrogate pair
        // must move back one unit, so the window never ends with a lone high
        // surrogate — the pair is left OUT of the window whole (the window is
        // one unit shorter than the budget).
        let full = String(repeating: "q", count: budget - 1) + "🙂" + String(repeating: "r", count: 10)
        let window = StreamedPaste.windowText(fullText: full, windowStart: 0, budget: budget)
        XCTAssertTrue(window.unicodeScalars.allSatisfy { !$0.isSurrogate }, "window must be well-formed UTF-16")
        XCTAssertEqual((window as NSString).length, budget - 1, "the pair is left out whole, so the window is one unit shorter")
        XCTAssertEqual(window, String(repeating: "q", count: budget - 1), "the window ends with plain text, not a split pair")
    }

    func testSlidingWindowsCoverTheStore() {
        // Slide up to the head, then collect every window: each is a substring
        // of the store, and together they cover it (consecutive windows touch
        // or overlap — the clamped final slide overlaps, so the union, not a
        // disjoint tiling, is the invariant).
        let full = String(repeating: "abcdefghij", count: 40_000) // 400k units
        let store = full as NSString
        var start = StreamedPaste.initialWindowStart(fullLength: 400_000, budget: budget)
        var windows: [(location: Int, length: Int)] = []
        while start > 0 {
            let window = StreamedPaste.windowText(fullText: full, windowStart: start, budget: budget)
            XCTAssertEqual(window, store.substring(with: NSRange(location: start, length: (window as NSString).length)), "each window is a substring of the store")
            windows.append((start, (window as NSString).length))
            start = StreamedPaste.slideWindowStart(fullText: full, windowStart: start, budget: budget, directionUp: true)
        }
        let last = StreamedPaste.windowText(fullText: full, windowStart: 0, budget: budget)
        XCTAssertEqual(last, store.substring(with: NSRange(location: 0, length: (last as NSString).length)))
        windows.append((0, (last as NSString).length))

        // The union of the windows covers every unit of the store exactly once
        // or twice (overlap only where the clamped slide doubles back).
        var covered = 0
        for (location, length) in windows.sorted(by: { $0.location < $1.location }) {
            XCTAssertLessThanOrEqual(location, covered + 1, "windows touch or overlap, never gap")
            covered = max(covered, location + length)
        }
        XCTAssertEqual(covered, 400_000, "the windows together cover the whole store")
    }

    // MARK: - adjustedBoundary

    func testAdjustedBoundaryMovesBackOverHighSurrogate() {
        let s = "a🙂b" // units: a(1), 🙂(2), b(1) → length 4
        XCTAssertEqual(StreamedPaste.adjustedBoundary(2, in: s), 1, "boundary between the pair halves moves back")
        XCTAssertEqual(StreamedPaste.adjustedBoundary(3, in: s), 3, "boundary after the pair is untouched")
        XCTAssertEqual(StreamedPaste.adjustedBoundary(0, in: s), 0)
        XCTAssertEqual(StreamedPaste.adjustedBoundary(4, in: s), 4)
    }
}

private extension Unicode.Scalar {
    var isSurrogate: Bool { value >= 0xD800 && value <= 0xDFFF }
}

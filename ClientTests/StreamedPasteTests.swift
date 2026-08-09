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
        let full = String(repeating: "ab", count: 50_000)
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
        // The window start lands exactly inside a surrogate pair: the pair
        // must be kept whole in the window (start moves back one unit).
        let full = String(repeating: "q", count: budget - 1) + "🙂" + String(repeating: "r", count: 10)
        let start = budget - 1 // would split "🙂" (units budget-1, budget)
        let window = StreamedPaste.windowText(fullText: full, windowStart: start, budget: budget)
        XCTAssertTrue(window.unicodeScalars.allSatisfy { !$0.isSurrogate }, "window must be well-formed UTF-16")
        XCTAssertEqual((window as NSString).length, budget + 1, "the pair is included whole, so the window is one unit longer")
        XCTAssertTrue(window.hasSuffix("🙂"), "the emoji ends up in the window")
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

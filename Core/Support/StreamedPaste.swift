import Foundation

/// Pure helpers for windowed pasting of very large text into the prompt input.
///
/// A multi-megabyte paste cannot be laid out in the text view at once
/// (NSTextStorage/NSTextView layout is main-thread-only and O(document)). The
/// pasted text is therefore split into a **store** — the full string, plain
/// data with no layout cost — and a **window** — the slice actually held by
/// the text view, capped at `budget` UTF-16 units. The window starts at the
/// tail (the bottom of the paste, what the user needs first) and slides toward
/// the head or the tail as the user scrolls, so layout stays bounded regardless
/// of the paste size and the main thread is never blocked (the conversation
/// keeps scrolling while the paste is windowed).
///
/// All offsets are UTF-16 (NSString) units, and window boundaries are adjusted
/// so a surrogate pair (an emoji, …) is never split.
public enum StreamedPaste {
    /// The start offset of the initial window: the last `budget` units of the
    /// full text (0 when the text fits in the budget).
    public static func initialWindowStart(fullLength: Int, budget: Int) -> Int {
        max(0, fullLength - budget)
    }

    /// The window start after sliding: toward the head when `directionUp`,
    /// toward the tail otherwise, clamped so the window stays inside the text
    /// and its start never splits a surrogate pair.
    public static func slideWindowStart(fullText: String, windowStart: Int, budget: Int, directionUp: Bool) -> Int {
        let length = (fullText as NSString).length
        let raw: Int
        if directionUp {
            raw = max(0, windowStart - budget)
        } else {
            raw = min(max(0, length - budget), windowStart + budget)
        }
        return adjustedBoundary(raw, in: fullText)
    }

    /// The window text starting at `windowStart`, at most `budget` units. The
    /// start boundary is surrogate-safe (never splits a pair); the end is the
    /// text end or a budget cut (also surrogate-safe).
    public static func windowText(fullText: String, windowStart: Int, budget: Int) -> String {
        let ns = fullText as NSString
        let start = min(adjustedBoundary(windowStart, in: fullText), ns.length)
        let end = adjustedBoundary(start + min(budget, ns.length - start), in: fullText)
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    /// Moves a boundary back one unit when the unit just before it is a high
    /// surrogate (the boundary would split a surrogate pair).
    public static func adjustedBoundary(_ offset: Int, in string: String) -> Int {
        let ns = string as NSString
        guard offset > 0, offset < ns.length else { return offset }
        let last = ns.character(at: offset - 1)
        if last >= 0xD800 && last <= 0xDBFF { return offset - 1 }
        return offset
    }
}

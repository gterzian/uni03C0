
/// The pure windowing behind the diff viewer's PREFETCH syntax highlighting.
///
/// The viewer must never color the line the reader is looking at: the viewport
/// has to arrive on text that is ALREADY rendered, or the visible content
/// changes under the reader as the colors land. This mirrors the transcript's
/// materialized row window — a buffer of content is kept ready beyond each side
/// of the viewport, and when the viewport nears an edge the next block is
/// fetched well past it, compounding like the history fetch. The diff viewer's
/// "content" is syntax color, so the window is a display-line range.
///
/// Pure (no view, no highlighter): `DiffBrowserView.Coordinator` runs the
/// ranges through `DiffHighlighter` and paints them; this decides WHICH lines
/// to paint and WHEN.
public enum DiffHighlightPlan {
    /// The first prefetch block, then doubled up to `blockMax`.
    public static let blockStart = 400
    public static let blockMax = 4000
    /// The buffer kept colored beyond the viewport, in viewports (mirroring
    /// `TranscriptView`'s `bufferViewports`).
    public static let bufferViewports = 3
    /// The buffer never shrinks below this many display lines, so a tiny
    /// viewport still prefetches a screenful either way.
    public static let minBuffer = 240

    /// The display-line window that has been colored so far. `start`/`end` are
    /// 1-based and inclusive; `end == 0` means nothing has been colored yet.
    public struct State: Equatable, Sendable {
        public var start: Int
        public var end: Int
        /// The next compounding prefetch block.
        public var block: Int

        public init(start: Int = 0, end: Int = 0, block: Int = DiffHighlightPlan.blockStart) {
            self.start = start
            self.end = end
            self.block = block
        }
    }

    /// The buffer (in display lines) to keep colored beyond each side of a
    /// viewport that spans `viewportLines` display lines.
    public static func buffer(viewportLines: Int) -> Int {
        max(viewportLines * bufferViewports, minBuffer)
    }

    /// Whether the viewport is close enough to an edge of the colored window
    /// that the next block must be fetched NOW (not after a settle delay, or a
    /// fast scroll reaches plain text first). A window that does not exist yet
    /// always needs a fetch; an edge already at the document boundary cannot
    /// grow, so it never triggers one.
    public static func needsPrefetch(state: State, visible: ClosedRange<Int>, total: Int) -> Bool {
        guard state.end > 0 else { return true }
        let buffer = buffer(viewportLines: visible.upperBound - visible.lowerBound + 1)
        if state.start > 1, visible.lowerBound - state.start <= buffer { return true }
        if state.end < total, state.end - visible.upperBound <= buffer { return true }
        return false
    }

    /// Advances the window so `visible` sits inside it with a buffer to spare,
    /// returning the display-line ranges to color now (empty = nothing to do)
    /// and the new state.
    ///
    /// The window only ever grows toward the viewport. A jump that lands
    /// entirely outside it (search, reveal, the edit cycle, a scrollbar drag)
    /// opens a fresh window around the viewport: the skipped region was never
    /// on screen, and scrolling back into it re-colors it.
    public static func step(
        state: State,
        visible: ClosedRange<Int>,
        total: Int
    ) -> (ranges: [ClosedRange<Int>], state: State) {
        guard total > 0, visible.lowerBound >= 1 else { return ([], state) }
        let buffer = buffer(viewportLines: visible.upperBound - visible.lowerBound + 1)
        var result = state
        var ranges: [ClosedRange<Int>] = []

        if state.end == 0 || visible.lowerBound > state.end || visible.upperBound < state.start {
            // First pass, or a jump landed outside the window: open a fresh
            // window around the viewport.
            let reach = max(buffer, blockStart)
            result.start = max(1, visible.lowerBound - reach)
            result.end = min(total, visible.upperBound + reach)
            result.block = blockStart
            ranges = [result.start...result.end]
        } else {
            // Extend toward whichever edge the viewport approaches, by one
            // compounding block that reaches WELL past it.
            let block = state.block
            var extended = false
            if visible.lowerBound - state.start <= buffer {
                let newStart = max(1, state.start - block)
                if newStart < state.start {
                    ranges.append(newStart...(state.start - 1))
                    result.start = newStart
                    extended = true
                }
            }
            if state.end - visible.upperBound <= buffer {
                let newEnd = min(total, state.end + block)
                if newEnd > state.end {
                    ranges.append((state.end + 1)...newEnd)
                    result.end = newEnd
                    extended = true
                }
            }
            if extended { result.block = min(block * 2, blockMax) }
        }
        return (ranges, result)
    }
}

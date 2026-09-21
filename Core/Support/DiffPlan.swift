/// One item in a changed file's rendered diff layout: a run of full-array
/// display lines to render, or an expand control standing in for a hidden gap.
/// Pure value type, so the store computes a plan from the changed-line indices
/// without materializing the file, and a test can pin the exact layout.
public enum DiffRenderItem: Equatable, Sendable {
    /// Render these 0-based full-array display-line indices.
    case lines(ClosedRange<Int>)
    /// A control over a hidden gap. `gap` is the gap's 0-based first index (its
    /// stable identity for the expansion map); `hidden` its current length.
    case expand(gap: Int, hidden: Int)
}

/// The pure layout math behind the Changes viewer: turn a file's changed-line
/// indices into the exact list of line runs and expand controls to render.
///
/// The file's display lines are the interleaved diff (every real current-file
/// line with removed lines re-inserted). Only the changed regions plus a few
/// context lines are shown; the unchanged gaps between them collapse to one
/// expand control each, so a file whose changes sit far apart is a handful of
/// hunks rather than the whole file. Expansion reveals a gap in compounding
/// blocks, half from each edge, so a click never dumps thousands of lines.
public enum DiffPlan {
    /// Per-gap reveal counters: gap 0-based lower bound → lines revealed so far.
    public typealias Expansion = [Int: Int]

    /// Context lines kept around every changed run.
    public static let baseContext = 3
    /// A single changed run is initially capped to this many lines (a large new
    /// file would otherwise open as its whole contents).
    public static let initialRunCap = 80
    /// The first expansion block, then doubled up to `expandBlockMax`.
    public static let expandBlockStart = 40
    public static let expandBlockMax = 4000

    /// The next compounding reveal block: 40, 80, 160, … capped.
    public static func nextBlock(_ current: Int) -> Int {
        guard current > 0 else { return expandBlockStart }
        return min(current * 2, expandBlockMax)
    }

    /// The full render plan for a file, given its 1-based `added`/`removed`
    /// display indices (the form `LoadedFileDiff` carries) and the current
    /// per-gap expansion.
    public static func renderItems(
        added: [Int],
        removed: [Int],
        count: Int,
        expansion: Expansion,
        context: Int = baseContext,
        initialCap: Int = initialRunCap
    ) -> [DiffRenderItem] {
        guard count > 0 else { return [] }
        // Work in 0-based indices internally; the input is 1-based display lines.
        let runs = changedRuns(added: added, removed: removed, count: count)
        var shown: [ClosedRange<Int>] = []
        for run in runs {
            let lo = max(0, run.lowerBound - context)
            var hi = min(count - 1, run.upperBound + context)
            if hi - lo + 1 > initialCap { hi = lo + initialCap - 1 }
            appendMerged(&shown, lo...hi)
        }
        if shown.isEmpty {
            // Defensive: no changed lines (an edge the loader never produces for
            // a shown diff). Open the head so the section still has content.
            shown = [0...min(count - 1, initialCap - 1)]
        }

        var expanded = shown
        // The residual of each original gap, keyed by that gap's ORIGINAL lower
        // bound. The key must stay stable across expansions: the residual's own
        // lower bound moves as lines are revealed, so using it as the identity
        // would make every click after the first a no-op.
        var residuals: [(id: Int, range: ClosedRange<Int>)] = []
        for gap in gaps(between: shown, count: count) {
            let revealed = expansion[gap.lowerBound] ?? 0
            let length = gapLength(gap)
            let top = min((revealed + 1) / 2, length)
            let bottom = min(revealed / 2, length - top)
            if top > 0 { appendMerged(&expanded, gap.lowerBound...(gap.lowerBound + top - 1)) }
            if bottom > 0 { appendMerged(&expanded, (gap.upperBound - bottom + 1)...gap.upperBound) }
            let residualStart = gap.lowerBound + top
            let residualEnd = gap.upperBound - bottom
            if residualStart <= residualEnd {
                residuals.append((gap.lowerBound, residualStart...residualEnd))
            }
        }
        let merged = merge(expanded)

        var items: [DiffRenderItem] = []
        var queue = residuals[...]
        for range in merged {
            while let residual = queue.first, residual.range.upperBound < range.lowerBound {
                items.append(.expand(gap: residual.id, hidden: gapLength(residual.range)))
                queue.removeFirst()
            }
            items.append(.lines(range))
        }
        while let residual = queue.first {
            items.append(.expand(gap: residual.id, hidden: gapLength(residual.range)))
            queue.removeFirst()
        }
        return items
    }

    /// Maximal runs of changed display lines, as 0-based ranges, from the
    /// ascending 1-based `added`/`removed` index arrays.
    public static func changedRuns(added: [Int], removed: [Int], count: Int) -> [ClosedRange<Int>] {
        var indices: [Int] = []
        indices.reserveCapacity(added.count + removed.count)
        var i = 0, j = 0
        while i < added.count || j < removed.count {
            if j >= removed.count { indices.append(added[i]); i += 1 }
            else if i >= added.count { indices.append(removed[j]); j += 1 }
            else if added[i] <= removed[j] { indices.append(added[i]); i += 1 }
            else { indices.append(removed[j]); j += 1 }
        }
        var result: [ClosedRange<Int>] = []
        for oneBased in indices {
            let index = oneBased - 1
            guard index >= 0, index < count else { continue }
            if let last = result.last, index <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, index)
            } else {
                result.append(index...index)
            }
        }
        return result
    }

    /// The hidden gaps (0-based ranges) between ascending, non-overlapping
    /// shown ranges, including the head and the tail.
    public static func gaps(between ranges: [ClosedRange<Int>], count: Int) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        var cursor = 0
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if cursor < range.lowerBound { result.append(cursor...(range.lowerBound - 1)) }
            cursor = max(cursor, range.upperBound + 1)
        }
        if cursor < count { result.append(cursor...(count - 1)) }
        return result
    }

    public static func gapLength(_ gap: ClosedRange<Int>) -> Int {
        gap.upperBound - gap.lowerBound + 1
    }

    public static func merge(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<Int>] = [sorted[0]]
        for range in sorted.dropFirst() {
            let last = result[result.count - 1]
            if range.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    static func appendMerged(_ ranges: inout [ClosedRange<Int>], _ range: ClosedRange<Int>) {
        ranges = merge(ranges + [range])
    }
}

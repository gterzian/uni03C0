import Foundation

/// Pure navigation over a diff's changed-line runs for Cmd+Up / Cmd+Down in
/// the Changes viewer. Kept in Core (no AppKit) so the choice is unit-testable
/// from `ClientTests`; the viewer turns the returned DISPLAY line into a
/// scroll. Mirrors `TranscriptCycler`: the cycle is anchored at the viewport
/// top and always moves STRICTLY above/below it, so standing on an edit and
/// pressing Down moves to the next edit, never re-showing the same one.
public enum DiffEditCycler {
    /// The start display lines of the changed-line runs, ascending. `added`
    /// and `removed` are 1-based display line numbers, each ascending; runs of
    /// consecutive lines (an added block, a mixed hunk) collapse into ONE stop,
    /// so a 40-line addition is a single Cmd+Down step rather than 40.
    public static func editStops(added: [Int], removed: [Int]) -> [Int] {
        var stops: [Int] = []
        var i = 0, j = 0
        var previous: Int?
        while i < added.count || j < removed.count {
            let next: Int
            if j >= removed.count {
                next = added[i]; i += 1
            } else if i >= added.count {
                next = removed[j]; j += 1
            } else if added[i] <= removed[j] {
                next = added[i]; i += 1
            } else {
                next = removed[j]; j += 1
            }
            // A new stop only when this line starts a fresh run: the first
            // line, or one not adjacent to the previous changed line.
            if let previous, next == previous || next == previous + 1 {
                // still the same run
            } else {
                stops.append(next)
            }
            previous = next
        }
        return stops
    }

    /// The first stop strictly below `line`, or nil when there is none.
    public static func next(after line: Int, stops: [Int]) -> Int? {
        stops.first { $0 > line }
    }

    /// The last stop strictly above `line`, or nil when there is none.
    public static func previous(before line: Int, stops: [Int]) -> Int? {
        stops.last { $0 < line }
    }
}

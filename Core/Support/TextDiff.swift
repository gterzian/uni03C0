import Foundation

/// One line in a line-based diff, GitHub-style: removed lines red, added
/// lines green, context lines plain.
public enum DiffLineKind: Hashable, Sendable {
    case same
    case removed
    case added
}

public struct DiffLine: Hashable, Sendable {
    public let kind: DiffLineKind
    public let text: String

    public init(kind: DiffLineKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// A pure, line-based text diff. Used by the edit-tool card to render
/// oldText/newText changes as a red/green view, and deliberately free of any
/// AppKit dependency so it is fully unit-testable.
///
/// Algorithm: trim the common prefix and suffix (edits touch the middle of a
/// file, so this shrinks the problem to almost nothing), then an LCS dynamic
/// program over the remaining middle. A size guard bounds the DP matrix: for
/// pathological inputs the middle falls back to a whole-block replace (all old
/// lines removed, then all new lines added) — still correct, just less pretty.
public enum TextDiff {
    /// Cap on the LCS middle-matrix size (cells). Beyond this the middle is
    /// emitted as a whole-block replace. 4M Int32 cells ≈ 16MB peak, freed
    /// after the call.
    public static let maxLCSCells = 4_000_000

    public static func diff(old: String, new: String) -> [DiffLine] {
        diff(oldLines: lines(of: old), newLines: lines(of: new))
    }

    public static func diff(oldLines: [String], newLines: [String]) -> [DiffLine] {
        var result: [DiffLine] = []
        var old = oldLines
        var new = newLines

        // Common prefix: identical lines at the top are context.
        var prefix = 0
        let minPrefixCount = min(old.count, new.count)
        while prefix < minPrefixCount, old[prefix] == new[prefix] {
            prefix += 1
        }
        for i in 0..<prefix {
            result.append(DiffLine(kind: .same, text: old[i]))
        }
        old = Array(old.dropFirst(prefix))
        new = Array(new.dropFirst(prefix))

        // Common suffix: identical lines at the bottom are context.
        var suffix = 0
        let minSuffixCount = min(old.count, new.count)
        while suffix < minSuffixCount, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let middleOld = Array(old.dropLast(suffix))
        let middleNew = Array(new.dropLast(suffix))
        appendMiddleDiff(middleOld, middleNew, to: &result)

        for i in 0..<suffix {
            result.append(DiffLine(kind: .same, text: old[old.count - suffix + i]))
        }
        return result
    }

    // MARK: - Middle

    private static func appendMiddleDiff(_ old: [String], _ new: [String], to result: inout [DiffLine]) {
        if old.isEmpty {
            for line in new { result.append(DiffLine(kind: .added, text: line)) }
            return
        }
        if new.isEmpty {
            for line in old { result.append(DiffLine(kind: .removed, text: line)) }
            return
        }
        // Size guard: whole-block replace for huge middles.
        if old.count * new.count > maxLCSCells {
            for line in old { result.append(DiffLine(kind: .removed, text: line)) }
            for line in new { result.append(DiffLine(kind: .added, text: line)) }
            return
        }

        // LCS length table, flat Int32 (bounded by maxLCSCells).
        let n = old.count
        let m = new.count
        let stride = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * stride)
        for i in 1...n {
            let row = i * stride
            let prevRow = (i - 1) * stride
            for j in 1...m {
                if old[i - 1] == new[j - 1] {
                    table[row + j] = table[prevRow + (j - 1)] + 1
                } else {
                    table[row + j] = max(table[prevRow + j], table[row + (j - 1)])
                }
            }
        }

        // Backtrack from the bottom-right, collecting operations in reverse
        // (ops[0] is the LAST operation of the diff). On equal LCS values the
        // added arm is preferred so that, after the reversal, a substitution
        // renders as removed lines followed by added lines (GitHub order)
        // rather than interleaved.
        var ops: [DiffLine] = []
        var i = n
        var j = m
        while i > 0, j > 0 {
            if old[i - 1] == new[j - 1] {
                ops.append(DiffLine(kind: .same, text: old[i - 1]))
                i -= 1
                j -= 1
            } else if table[(i - 1) * stride + j] > table[i * stride + (j - 1)] {
                ops.append(DiffLine(kind: .removed, text: old[i - 1]))
                i -= 1
            } else {
                ops.append(DiffLine(kind: .added, text: new[j - 1]))
                j -= 1
            }
        }
        while i > 0 {
            ops.append(DiffLine(kind: .removed, text: old[i - 1]))
            i -= 1
        }
        while j > 0 {
            ops.append(DiffLine(kind: .added, text: new[j - 1]))
            j -= 1
        }
        result.append(contentsOf: ops.reversed())
    }

    // MARK: - Hunks

    /// One line of a unified-diff hunk, annotated with the 1-based line number
    /// it has on the old and/or new side. `oldLine` is nil for an added line
    /// and `newLine` is nil for a removed line; a context (`.same`) line
    /// carries both.
    public struct HunkLine: Hashable, Sendable {
        public let kind: DiffLineKind
        public let text: String
        public let oldLine: Int?
        public let newLine: Int?

        public init(kind: DiffLineKind, text: String, oldLine: Int?, newLine: Int?) {
            self.kind = kind
            self.text = text
            self.oldLine = oldLine
            self.newLine = newLine
        }
    }

    /// A run of changes plus `context` unchanged lines on either side — the
    /// unit a GitHub-style unified diff shows. `oldStart`/`newStart` are the
    /// first line of the run on each side (matching the `@@ -a,b +c,d @@`
    /// header), and the counts are the number of old-side / new-side lines the
    /// hunk covers.
    public struct Hunk: Hashable, Sendable {
        public let oldStart: Int
        public let oldCount: Int
        public let newStart: Int
        public let newCount: Int
        public let lines: [HunkLine]

        public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [HunkLine]) {
            self.oldStart = oldStart
            self.oldCount = oldCount
            self.newStart = newStart
            self.newCount = newCount
            self.lines = lines
        }
    }

    /// Splits the line diff into hunks with `context` unchanged lines around
    /// each change. Two changes closer than `2 * context` unchanged lines
    /// merge into one hunk (the standard rule); a gap at least that large
    /// starts a new hunk, which is what lets the Changes page show only the
    /// parts of a file that actually changed instead of the whole buffer.
    public static func hunks(old: String, new: String, context: Int = 3) -> [Hunk] {
        hunks(oldLines: lines(of: old), newLines: lines(of: new), context: context)
    }

    public static func hunks(oldLines: [String], newLines: [String], context: Int = 3) -> [Hunk] {
        let diff = diff(oldLines: oldLines, newLines: newLines)
        guard !diff.isEmpty else { return [] }
        let context = max(0, context)

        // Annotate each line with its old/new number and remember the counters
        // BEFORE each line, so a hunk's header start is exact even when the
        // hunk opens with an addition or a deletion.
        var annotated: [HunkLine] = []
        annotated.reserveCapacity(diff.count)
        var oldBefore = [Int]()
        var newBefore = [Int]()
        oldBefore.reserveCapacity(diff.count + 1)
        newBefore.reserveCapacity(diff.count + 1)
        var oldCounter = 1
        var newCounter = 1
        for line in diff {
            oldBefore.append(oldCounter)
            newBefore.append(newCounter)
            switch line.kind {
            case .same:
                annotated.append(HunkLine(kind: .same, text: line.text, oldLine: oldCounter, newLine: newCounter))
                oldCounter += 1
                newCounter += 1
            case .removed:
                annotated.append(HunkLine(kind: .removed, text: line.text, oldLine: oldCounter, newLine: nil))
                oldCounter += 1
            case .added:
                annotated.append(HunkLine(kind: .added, text: line.text, oldLine: nil, newLine: newCounter))
                newCounter += 1
            }
        }

        let changed = diff.indices.filter { diff[$0].kind != .same }
        guard !changed.isEmpty else { return [] }

        // Expand each change by `context` and merge overlapping/adjacent runs.
        var ranges: [(start: Int, end: Int)] = []
        for index in changed {
            let start = max(0, index - context)
            let end = min(diff.count - 1, index + context)
            if let last = ranges.last, start <= last.end + 1 {
                ranges[ranges.count - 1].end = max(last.end, end)
            } else {
                ranges.append((start, end))
            }
        }

        return ranges.map { range in
            let slice = annotated[range.start...range.end]
            let oldCount = slice.reduce(0) { $0 + ($1.oldLine != nil ? 1 : 0) }
            let newCount = slice.reduce(0) { $0 + ($1.newLine != nil ? 1 : 0) }
            return Hunk(
                oldStart: oldBefore[range.start],
                oldCount: oldCount,
                newStart: newBefore[range.start],
                newCount: newCount,
                lines: Array(slice)
            )
        }
    }

    /// Splits text into lines. A trailing newline is not a line of its own
    /// (diff semantics), and a trailing CR is stripped from each line so CRLF
    /// files diff cleanly against LF text.
    static func lines(of text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }
}

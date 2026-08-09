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

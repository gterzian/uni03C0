import Core
import Foundation

/// One changed file's fully loaded diff, ready to render. Produced OFF the
/// main thread by `DiffLoader`; only the finished value crosses back. `lines`
/// holds the file's full interleaved diff — every real line of the current
/// file with removed lines re-inserted at their original position — so the
/// viewer can slice any window out of it (the top/bottom expansion) without
/// re-running the diff.
nonisolated struct LoadedFileDiff: Equatable, Sendable {
    let path: String
    let kind: GitStatus.Kind
    let lines: [DiffLine]
    /// Real current-file line of each display line (`nil` for a removed line,
    /// which belongs to the old side).
    let lineNumbers: [Int?]
    /// Old-file line of each display line (`nil` for same/added lines, which
    /// belong to the current side). The gutter shows this for a removed (red)
    /// line, which has no current-file number, so a red diff still reads as a
    /// numbered line rather than a blank row.
    let oldLineNumbers: [Int?]
    /// Display indices of added / removed lines (drives the green/red line
    /// overlay and the Cmd+Up / Cmd+Down edit stops).
    let added: [Int]
    let removed: [Int]
    /// A reason the diff is not renderable (unreadable / no baseline). `lines`
    /// is empty when this is set.
    let message: String?

    var displayLineCount: Int { lines.count }

    /// The first…last display index that actually changed, or nil when there is
    /// no change to anchor the initial window on (an empty/added/deleted file
    /// uses its whole extent).
    var changeRange: ClosedRange<Int>? {
        let changed = added + removed
        guard let low = changed.min(), let high = changed.max() else { return nil }
        return low...high
    }
}

/// Loads one changed file's diff off the main thread: file IO, the `git show`
/// for the old side, and `TextDiff` all run on the caller's executor so the
/// only main-thread work is handing the finished value to the store.
nonisolated enum DiffLoader {
    static func load(cwd: URL, entry: GitStatus.FileEntry) async -> LoadedFileDiff {
        let name = (entry.path as NSString).lastPathComponent
        switch entry.kind {
        case .deleted:
            guard let head = await GitStatus.headContent(of: entry.path, cwd: cwd) else {
                return unreadable(entry, "No committed content for \(name).")
            }
            let lines = splitLines(head)
            // A deleted file is all old-side: its lines number 1…n on the old
            // side, and the gutter shows that number.
            let numbers = realLineNumbers(count: lines.count)
            return LoadedFileDiff(
                path: entry.path,
                kind: entry.kind,
                lines: lines.map { DiffLine(kind: .removed, text: $0) },
                lineNumbers: numbers,
                oldLineNumbers: numbers,
                added: [],
                removed: lineIndexRange(count: lines.count),
                message: nil
            )
        case .added, .untracked:
            guard let text = GitStatus.currentContent(of: entry.path, cwd: cwd) else {
                return unreadable(entry, "Couldn't read \(name).")
            }
            let lines = splitLines(text)
            return LoadedFileDiff(
                path: entry.path,
                kind: entry.kind,
                lines: lines.map { DiffLine(kind: .added, text: $0) },
                lineNumbers: realLineNumbers(count: lines.count),
                oldLineNumbers: [],
                added: lineIndexRange(count: lines.count),
                removed: [],
                message: nil
            )
        case .modified:
            guard let text = GitStatus.currentContent(of: entry.path, cwd: cwd) else {
                return unreadable(entry, "Couldn't read \(name).")
            }
            guard let old = await GitStatus.headContent(of: entry.path, cwd: cwd) else {
                // No HEAD baseline (edge): show the current file uncolored.
                let lines = splitLines(text)
                return LoadedFileDiff(
                    path: entry.path, kind: entry.kind,
                    lines: lines.map { DiffLine(kind: .same, text: $0) },
                    lineNumbers: realLineNumbers(count: lines.count),
                    oldLineNumbers: [],
                    added: [], removed: [], message: nil
                )
            }
            let diff = interleaved(old: old, new: text)
            return LoadedFileDiff(
                path: entry.path, kind: entry.kind,
                lines: diff.lines,
                lineNumbers: diff.lineNumbers,
                oldLineNumbers: diff.oldLineNumbers,
                added: diff.added,
                removed: diff.removed,
                message: nil
            )
        case .normal:
            return unreadable(entry, "\(name) has no changes.")
        }
    }

    private static func unreadable(_ entry: GitStatus.FileEntry, _ message: String) -> LoadedFileDiff {
        LoadedFileDiff(
            path: entry.path, kind: entry.kind,
            lines: [], lineNumbers: [], oldLineNumbers: [], added: [], removed: [], message: message
        )
    }

    /// Splits text into lines with diff semantics: a trailing newline is not a
    /// line of its own, and a trailing CR is stripped.
    nonisolated static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// 1…count as ints (empty for count 0).
    private static func lineIndexRange(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return Array(1...count)
    }

    /// 1…count as optional ints (empty for count 0).
    private static func realLineNumbers(count: Int) -> [Int?] {
        guard count > 0 else { return [] }
        return (1...count).map(Optional.init)
    }

    /// Builds the GitHub-style interleaved view of a modification: every real
    /// current-file line in order, with each run of removed lines re-inserted
    /// where it was. Returns the display lines, the REAL line number of each
    /// (`nil` for a removed line), the OLD-file line of each removed line
    /// (`nil` otherwise), and the 1-based display indices that are added /
    /// removed.
    nonisolated static func interleaved(old: String, new: String) -> (lines: [DiffLine], lineNumbers: [Int?], oldLineNumbers: [Int?], added: [Int], removed: [Int]) {
        let diff = TextDiff.diff(old: old, new: new)
        var lineNumbers: [Int?] = []
        var oldLineNumbers: [Int?] = []
        var added: [Int] = []
        var removed: [Int] = []
        var newLine = 0
        var oldLine = 0
        for (index, line) in diff.enumerated() {
            switch line.kind {
            case .same:
                newLine += 1
                oldLine += 1
                lineNumbers.append(newLine)
                oldLineNumbers.append(nil)
            case .added:
                newLine += 1
                lineNumbers.append(newLine)
                oldLineNumbers.append(nil)
                added.append(index + 1)
            case .removed:
                oldLine += 1
                lineNumbers.append(nil)
                oldLineNumbers.append(oldLine)
                removed.append(index + 1)
            }
        }
        return (diff, lineNumbers, oldLineNumbers, added, removed)
    }
}


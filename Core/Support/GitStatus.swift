import Foundation
import Subprocess
import System

/// Git plumbing behind the file browser and the "N edited" gating button.
///
/// The app itself is not sandboxed (the seatbelt policy applies to agent
/// subprocesses only), so spawning git from here is unconstrained; the spawns
/// go through `Subprocess` — the same package `ProcessController` already uses
/// — with read-only commands only. `--no-optional-locks` on `status` keeps
/// git from refreshing/writing the index, so these calls never contend with
/// git the agent itself may be running in the same worktree.
///
/// Path model: for v1 the session folder is assumed to be the git repo root —
/// `FileEntry.path` values and the `git show HEAD:<path>` argument are both
/// relative to `cwd`. (A session started in a repo subdirectory would need
/// `git rev-parse --show-toplevel` translation; out of scope, noted in the
/// design review.)
public enum GitStatus {
    // MARK: - Types

    /// Added/deleted LINE counts of a changed path relative to its baseline.
    /// Attached to `FileEntry` for exactly the paths the batched numstat pass
    /// could count (see `classify`); nil means "not countable in that pass" —
    /// untracked, committed-identical, or a binary whose numstat counters are
    /// `-` — never "zero changes".
    public struct DiffStats: Hashable, Sendable {
        public let added: Int
        public let deleted: Int

        public init(added: Int, deleted: Int) {
            self.added = added
            self.deleted = deleted
        }
    }

    /// One classified project file (the tree's leaf model).
    public struct FileEntry: Hashable, Sendable {
        /// Path relative to the repo/tab root.
        public let path: String
        public let kind: Kind
        /// The file's added/deleted line counts when the batched diff pass
        /// could compute them; nil for paths with no countable baseline diff
        /// (normal, untracked, binaries). The tree's deletion-vs-addition
        /// fill behind the file name is derived from this.
        public let stats: DiffStats?

        public init(path: String, kind: Kind, stats: DiffStats? = nil) {
            self.path = path
            self.kind = kind
            self.stats = stats
        }
    }

    public enum Kind: Hashable, Sendable {
        /// Tracked, unchanged since HEAD.
        case normal
        /// Tracked, changed since HEAD. The kind is deliberately coarse (no
        /// staged/unstaged split); the actual added/deleted line counts live
        /// in `FileEntry.stats`, computed by one batched numstat pass — never
        /// a `git show` + diff subprocess per file. The content pane computes
        /// the interleaved added/deleted lines for the ONE selected file.
        case modified
        /// Tracked, new since HEAD — the whole file is new content (staged
        /// `A`, or staged-then-edited `AM`, which counts as added here even
        /// though the agent's later worktree edits may delete lines — those
        /// deletions show up in `stats`).
        case added
        /// In HEAD, absent from the working tree.
        case deleted
        /// Never `git add`ed — no HEAD baseline exists to score it against,
        /// so it is called out as "not added yet" instead of being measured.
        case untracked
    }

    /// Posted whenever a session's agent tool touched a file on disk
    /// (`edit`/`write`, or the turn settled). Payload keys: `"cwd"` (the URL
    /// of the session folder) and `"path"` (the file that changed, or nil when
    /// the whole turn settled and any file may have changed). A payload is
    /// needed (unlike `FontSettings.didChangeNotification`, which posts no
    /// payload) because more than one project's file browser window can be
    /// open at once, each caring only about its own `cwd`.
    public static let didChangeNotification = Notification.Name("GitStatus.didChange")

    // MARK: - Plumbing

    private static let gitExecutable = "/usr/bin/git"
    /// Generous cap for collected stdout; `ls-files` output on huge monorepos
    /// is the largest thing we read.
    private static let outputLimit = 64 << 20

    /// Runs a read-only git command and returns stdout on success (exit 0),
    /// nil on any failure (including "not a git repository").
    private static func gitOutput(_ args: [String], cwd: URL) async -> String? {
        do {
            let result = try await Subprocess.run(
                .path(FilePath(gitExecutable)),
                arguments: Arguments(args),
                workingDirectory: FilePath(cwd.path),
                output: .string(limit: outputLimit),
                error: .discarded
            )
            guard result.terminationStatus.isSuccess else { return nil }
            return result.standardOutput
        } catch {
            return nil
        }
    }

    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: - Listing + classification

    /// Every file the user would consider part of the project:
    /// `git ls-files --cached --others --exclude-standard` — tracked paths
    /// (regardless of on-disk state) plus untracked paths that aren't
    /// ignored, with `.git`/`node_modules`/build output already excluded by
    /// git's own rules. `core.quotepath=false` keeps non-ASCII names raw,
    /// and the same C-style unquote as the status parser is applied so the
    /// two lists agree even when a name forces quoting (control characters).
    public static func trackedAndVisiblePaths(at cwd: URL) async -> [String] {
        guard let out = await gitOutput(
            ["-c", "core.quotepath=false", "ls-files", "--cached", "--others", "--exclude-standard"],
            cwd: cwd
        ) else { return [] }
        return splitLines(out).map(Self.unquote)
    }

    /// One parsed `--porcelain=v1` status line: the two-character XY code and
    /// the path with porcelain's C-style quoting undone. The branch header
    /// line (`## …`) and unmerged section markers parse to nil.
    public static func parsePorcelainLine(_ line: String) -> (code: String, path: String)? {
        guard !line.hasPrefix("##"), line.count >= 4 else { return nil }
        let code = String(line.prefix(2))
        let rest = line.dropFirst(3)
        guard !rest.isEmpty else { return nil }
        return (code, unquote(String(rest)))
    }

    /// Undoes `--porcelain=v1`'s C-style quoting of unusual paths.
    private static func unquote(_ path: String) -> String {
        guard path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 else { return path }
        let inner = String(path.dropFirst().dropLast())
        guard inner.contains("\\") else { return inner }
        var out = ""
        var index = inner.startIndex
        while index < inner.endIndex {
            let char = inner[index]
            if char == "\\" {
                let next = inner.index(after: index)
                guard next < inner.endIndex else { break }
                let escaped = inner[next]
                switch escaped {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "a": out.append("\u{7}")
                case "b": out.append("\u{8}")
                case "f": out.append("\u{C}")
                case "v": out.append("\u{B}")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default:
                    // Octal escapes (\NNN) are vanishingly rare in source
                    // trees; keep the backslash verbatim rather than
                    // misdecoding.
                    out.append("\\")
                    out.append(escaped)
                }
                index = inner.index(after: next)
            } else {
                out.append(char)
                index = inner.index(after: index)
            }
        }
        return out
    }

    /// Coarse class of a file from its porcelain XY code. `.normal` never
    /// comes out of a status line — it is the default for a listed path that
    /// status does not mention at all.
    public enum StatusClass: Hashable, Sendable {
        case normal, modified, added, deleted, untracked
    }

    public static func statusClass(forPorcelainCode code: String) -> StatusClass {
        let significant = code.replacingOccurrences(of: " ", with: "")
        if significant == "??" { return .untracked }
        if significant.contains("D") { return .deleted }
        if significant.contains("A") { return .added }
        return .modified
    }

    // MARK: - Diff stats (per-file +/−, batched)

    /// One `git diff -z --numstat` record: `"<added>\t<deleted>\t<path>"`
    /// with the path RAW (the `-z` form never C-style-quotes it, so a path
    /// containing tabs is the whole remainder of the record). Parses to nil
    /// for binary entries, whose counters are `-` and don't read as integers.
    public static func parseNumstatRecord(_ record: String) -> (path: String, stats: DiffStats)? {
        let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let added = Int(parts[0]),
              let deleted = Int(parts[1])
        else { return nil }
        return (String(parts[2]), DiffStats(added: added, deleted: deleted))
    }

    /// The batched line-count pass behind `classify`: per-path added/deleted
    /// counts from TWO `git diff --numstat` runs — the worktree delta
    /// (`git diff`, index→worktree) and the staged delta (`git diff --cached`,
    /// HEAD→index), the worktree delta winning when both would count a path
    /// (an `MM` file's two passes overlap). Two git calls total, no content
    /// reads, no subprocess per file — this is what paints each file name's
    /// deletion-vs-addition fill without the slow per-file listing. The
    /// worktree-first rule keeps the fill on the AGENT'S live edits: a staged
    /// file the agent then changed scores its worktree delta (deletions
    /// included), while a staged-only file scores against HEAD — and in a
    /// repo with no commits yet the staged pass still counts new files
    /// against the empty tree, so a freshly `git add`ed file reads as all
    /// additions rather than vanishing. Untracked paths never appear in
    /// either pass (they have no baseline).
    private static func diffStatsByPath(at cwd: URL) async -> [String: DiffStats] {
        var stats: [String: DiffStats] = [:]
        for staged in [false, true] {
            let args = staged
                ? ["-c", "core.quotepath=false", "--no-optional-locks", "diff", "-z", "--no-renames", "--cached", "--numstat"]
                : ["-c", "core.quotepath=false", "--no-optional-locks", "diff", "-z", "--no-renames", "--numstat"]
            guard let out = await gitOutput(args, cwd: cwd) else { continue }
            for record in out.split(separator: "\0") where !record.isEmpty {
                guard let parsed = parseNumstatRecord(String(record)) else { continue }
                if stats[parsed.path] == nil {
                    stats[parsed.path] = parsed.stats
                }
            }
        }
        return stats
    }

    /// Count of changed paths for the gating badge — nil when the folder is
    /// not a git repository (or git errored). This is a porcelain LINE count
    /// only: no file content is read or diffed, so it stays cheap even when
    /// hundreds of files changed.
    public static func changedFileCount(at cwd: URL) async -> Int? {
        guard let out = await gitOutput(
            ["-c", "core.quotepath=false", "--no-optional-locks", "status", "--porcelain=v1"],
            cwd: cwd
        ) else { return nil }
        return splitLines(out).filter { !$0.hasPrefix("##") }.count
    }

    /// Lists every project file (per `trackedAndVisiblePaths`) and classifies
    /// it via `git status --porcelain=v1`, then attaches per-path added/
    /// deleted line counts from one batched two-pass numstat
    /// (`diffStatsByPath`) — three or four read-only git calls in total, NO
    /// subprocess per file and no per-file content diffs, so the listing
    /// stays instant even with hundreds of changed files. The tree's
    /// deletion-vs-addition fill comes from `FileEntry.stats`; the content
    /// pane still computes the exact interleaved added/deleted lines for the
    /// ONE selected file, on demand.
    public static func classify(at cwd: URL) async -> [FileEntry] {
        let listed = await trackedAndVisiblePaths(at: cwd)
        let raw = await gitOutput(
            ["-c", "core.quotepath=false", "--no-optional-locks", "status", "--porcelain=v1"],
            cwd: cwd
        ) ?? ""

        var classByPath: [String: StatusClass] = [:]
        for line in splitLines(raw) {
            guard let parsed = parsePorcelainLine(line) else { continue }
            classByPath[parsed.path] = statusClass(forPorcelainCode: parsed.code)
        }

        // The diff pass pays for itself only when a path has a countable
        // baseline change — a tree with nothing but untracked additions (or
        // nothing at all) skips it: untracked files never appear in a git
        // diff, so both numstat runs would be wasted.
        var needsStats = false
        for cls in classByPath.values where cls != .untracked {
            needsStats = true
            break
        }
        let statsByPath = needsStats ? await diffStatsByPath(at: cwd) : [:]

        // Union of listed and status-reported paths, so a status-only entry
        // (staged change to a path that ls-files already dropped — the
        // staged-deletion gap is the named exception) still shows.
        var allPaths = Set(listed)
        allPaths.formUnion(classByPath.keys)

        var entries: [FileEntry] = []
        for path in allPaths.sorted() {
            let cls = classByPath[path] ?? .normal
            switch cls {
            case .normal:
                entries.append(FileEntry(path: path, kind: .normal))
            case .untracked:
                entries.append(FileEntry(path: path, kind: .untracked))
            case .added:
                entries.append(FileEntry(path: path, kind: .added, stats: statsByPath[path]))
            case .deleted:
                entries.append(FileEntry(path: path, kind: .deleted, stats: statsByPath[path]))
            case .modified:
                entries.append(FileEntry(path: path, kind: .modified, stats: statsByPath[path]))
            }
        }
        return entries
    }

    // MARK: - Content

    /// Reads a working-tree file (path relative to `cwd`) as UTF-8 text.
    /// Synchronous file IO — callers invoke this off the main thread.
    public static func currentContent(of path: String, cwd: URL) -> String? {
        let url = URL(fileURLWithPath: path, relativeTo: cwd)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The file's committed content at HEAD (`git show HEAD:<path>`); nil for
    /// untracked files and paths outside HEAD (the deleted-file content pane
    /// loads this).
    public static func headContent(of path: String, cwd: URL) async -> String? {
        await gitOutput(["show", "HEAD:\(path)"], cwd: cwd)
    }
}

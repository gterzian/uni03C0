import Foundation
import Subprocess
import System

/// Git plumbing behind the Changes viewer and the "N edited" gating button.
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

    /// Posted whenever a session's git state may have changed: an agent tool
    /// touched a file on disk (`edit`/`write`, or the turn settled), or the
    /// app re-entered the foreground / opened a review surface to re-check a
    /// change pi never saw (a `git commit` run in a terminal). Payload keys:
    /// `"cwd"` (the URL of the session folder) and `"path"` (the file that
    /// changed, or nil when the whole turn settled, the app returned, or any
    /// file may have changed). A payload is needed (unlike
    /// `FontSettings.didChangeNotification`, which posts no payload) because
    /// more than one project's Changes viewer can be open at once, each
    /// caring only about its own `cwd`.
    public static let didChangeNotification = Notification.Name("GitStatus.didChange")

    // MARK: - Turn baseline

    /// Git's well-known empty-tree object id. Used as the diff baseline for a
    /// repository with no commits yet, so a turn's first changes still diff
    /// from "nothing" instead of failing on an unborn `HEAD`.
    public static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// The commit to diff a turn against: the live `HEAD`, or `emptyTree` when
    /// the repository has no commits (a fresh `git init`). Captured once at the
    /// start of a user turn and then kept — so a commit the agent makes
    /// mid-turn moves `HEAD` without emptying the Changes viewer; only the next
    /// turn re-baselines.
    public static func resolveHead(at cwd: URL) async -> String {
        guard let out = await gitOutput(["rev-parse", "--verify", "--quiet", "HEAD"], cwd: cwd) else {
            return emptyTree
        }
        let sha = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? emptyTree : sha
    }

    /// Resolves an explicit baseline, or falls back to the live `HEAD` when the
    /// caller has not pinned one (before the first user turn).
    private static func resolvedBase(_ base: String?, at cwd: URL) async -> String {
        if let base, !base.isEmpty { return base }
        return await resolveHead(at: cwd)
    }

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

    /// Every path git does not track yet (`--others --exclude-standard`), with
    /// the same C-style unquote as the listing. `git diff` never reports these,
    /// so `classify` unions them in separately.
    public static func untrackedPaths(at cwd: URL) async -> Set<String> {
        guard let out = await gitOutput(
            ["-c", "core.quotepath=false", "ls-files", "--others", "--exclude-standard"],
            cwd: cwd
        ) else { return [] }
        return Set(splitLines(out).map(Self.unquote))
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
    /// counts against the SAME baseline the diff viewer renders —
    /// `base`→working tree (`git diff <base>`), so a file's `+N −M` in the
    /// sidebar always matches the red/green in its diff. One git call, no
    /// content reads, no subprocess per file. `base` is always a concrete
    /// tree-ish (`classify` resolves an unborn `HEAD` to `emptyTree`), so there
    /// is no separate `--cached` fallback.
    private static func diffStatsByPath(at cwd: URL, base: String) async -> [String: DiffStats] {
        guard let out = await gitOutput(
            ["-c", "core.quotepath=false", "--no-optional-locks", "diff", "-z", "--no-renames", "--numstat", base],
            cwd: cwd
        ) else { return [:] }
        var stats: [String: DiffStats] = [:]
        for record in out.split(separator: "\0") where !record.isEmpty {
            guard let parsed = parseNumstatRecord(String(record)) else { continue }
            stats[parsed.path] = parsed.stats
        }
        return stats
    }

    /// Count of paths changed since `base` for the gating badge — nil when the
    /// folder is not a git repository (or git errored). Tracked changes come
    /// from one `git diff --name-status`; untracked files are added from a
    /// second listing (a diff never reports them). No file content is read, so
    /// it stays cheap even when hundreds of files changed. `base` should be the
    /// same turn baseline the Changes viewer uses, so the badge and the viewer
    /// never disagree.
    public static func changedFileCount(at cwd: URL, base: String? = nil) async -> Int? {
        let reference = await resolvedBase(base, at: cwd)
        guard let out = await gitOutput(
            ["-c", "core.quotepath=false", "--no-optional-locks", "diff", "-z", "--no-renames", "--name-status", reference],
            cwd: cwd
        ) else { return nil }
        let tracked = parseNameStatusZ(out).count
        let untracked = await untrackedPaths(at: cwd)
        return tracked + untracked.count
    }

    /// One parsed `--name-status -z` record: the status letter (`A`/`M`/`D`/
    /// `T`/`U`) and the raw path. The `-z` form never C-style-quotes, so a path
    /// with tabs/spaces is intact. Renames are disabled by the caller, so every
    /// record is exactly two NUL-terminated fields.
    public static func parseNameStatusZ(_ output: String) -> [(code: String, path: String)] {
        guard !output.isEmpty else { return [] }
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if fields.last == "" { fields.removeLast() }
        var records: [(code: String, path: String)] = []
        var index = 0
        while index + 1 < fields.count {
            records.append((fields[index], fields[index + 1]))
            index += 2
        }
        return records
    }

    /// Lists every project file (per `trackedAndVisiblePaths`), classifies what
    /// changed since `base` via one `git diff --name-status` (untracked files
    /// unioned in separately), then attaches per-path added/deleted line counts
    /// from one batched numstat (`diffStatsByPath`) — a handful of read-only
    /// git calls in total, NO subprocess per file and no per-file content
    /// diffs. `base` is the turn baseline (`nil` means the live `HEAD`); a
    /// commit the agent makes mid-turn therefore does not clear the view. The
    /// tree's deletion-vs-addition fill comes from `FileEntry.stats`.
    public static func classify(at cwd: URL, base: String? = nil) async -> [FileEntry] {
        let reference = await resolvedBase(base, at: cwd)
        let listed = await trackedAndVisiblePaths(at: cwd)
        let untracked = await untrackedPaths(at: cwd)
        let raw = await gitOutput(
            ["-c", "core.quotepath=false", "--no-optional-locks", "diff", "-z", "--no-renames", "--name-status", reference],
            cwd: cwd
        ) ?? ""

        var classByPath: [String: StatusClass] = [:]
        for record in parseNameStatusZ(raw) {
            classByPath[record.path] = statusClass(forPorcelainCode: record.code)
        }
        for path in untracked {
            classByPath[path] = .untracked
        }

        // The diff pass pays for itself only when a path has a countable
        // baseline change — a tree with nothing but untracked additions (or
        // nothing at all) skips it: untracked files never appear in a git
        // diff, so the numstat run would be wasted.
        var needsStats = false
        for cls in classByPath.values where cls != .untracked {
            needsStats = true
            break
        }
        let statsByPath = needsStats ? await diffStatsByPath(at: cwd, base: reference) : [:]

        // Union of listed and diff-reported paths, so a path git lists but no
        // longer reports (or vice versa) still shows.
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

    /// The file's content at `reference` (`git show <reference>:<path>`); nil
    /// for untracked files and paths outside the revision. The Changes viewer
    /// passes the turn baseline, so a file committed mid-turn still diffs
    /// against the content it had when the turn began.
    public static func content(of path: String, at reference: String, cwd: URL) async -> String? {
        await gitOutput(["show", "\(reference):\(path)"], cwd: cwd)
    }
}

import Core
import Foundation
import Observation

// MARK: - File tree data (off the main actor)

/// One file-tree node. A CLASS (not a struct) on purpose: the tree is built
/// once per refresh, off the main thread, and the view's flattened row list
/// holds REFERENCES to nodes. A value-type node with a `children: [TreeNode]`
/// array would deep-copy its entire subtree into every row of the flatten —
/// the multi-hundred-megabyte footprint and the multi-second stalls on large
/// projects. Class nodes make the flatten O(rows) with no copies.
nonisolated final class FileTreeNode: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let entry: GitStatus.FileEntry?
    let children: [FileTreeNode]

    init(name: String, path: String, isDirectory: Bool, entry: GitStatus.FileEntry?, children: [FileTreeNode]) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.entry = entry
        self.children = children
    }
}

/// The immutable result of one listing pass — everything the view needs,
/// produced off the main thread and swapped in as one value.
nonisolated struct FileTreeSnapshot: Sendable {
    let fileEntries: [String: GitStatus.FileEntry]
    let rootNodes: [FileTreeNode]
    let directoryPaths: Set<String>
    let fileCount: Int
}

/// Runs one listing pass ENTIRELY off the main thread: the git classification
/// (`GitStatus.classify`), the by-path index, the directory set, and the
/// recursive tree build over tens of thousands of paths. Only the finished
/// snapshot crosses back to the main thread.
nonisolated struct FileTreeBuilder {
    static func build(cwd: URL) async -> FileTreeSnapshot {
        let entries = await GitStatus.classify(at: cwd)
        var entriesByPath: [String: GitStatus.FileEntry] = [:]
        entriesByPath.reserveCapacity(entries.count)
        for entry in entries {
            entriesByPath[entry.path] = entry
        }
        let paths = entries.map(\.path).sorted()
        return FileTreeSnapshot(
            fileEntries: entriesByPath,
            rootNodes: buildTree(paths: paths, prefix: "", entries: entriesByPath),
            directoryPaths: directoryPaths(from: paths),
            fileCount: entries.count
        )
    }

    private static func directoryPaths(from paths: [String]) -> Set<String> {
        var directories: Set<String> = []
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            var prefix: [String] = []
            for component in components.dropLast() {
                prefix.append(component)
                directories.insert(prefix.joined(separator: "/"))
            }
        }
        return directories
    }

    /// Builds the tree from a flat path list: directories are purely
    /// structural nodes with no status of their own; only files carry one.
    private static func buildTree(paths: [String], prefix: String, entries: [String: GitStatus.FileEntry]) -> [FileTreeNode] {
        var directories: [String: [String]] = [:]
        var files: [String] = []
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard let head = components.first else { continue }
            if components.count == 1 {
                files.append(path)
            } else {
                directories[head, default: []].append(components.dropFirst().joined(separator: "/"))
            }
        }
        var nodes: [FileTreeNode] = []
        for name in directories.keys.sorted() {
            let childPrefix = prefix.isEmpty ? name : prefix + "/" + name
            nodes.append(FileTreeNode(
                name: name,
                path: childPrefix,
                isDirectory: true,
                entry: nil,
                children: buildTree(paths: directories[name] ?? [], prefix: childPrefix, entries: entries)
            ))
        }
        for path in files.sorted() {
            let fullPath = prefix.isEmpty ? path : prefix + "/" + path
            nodes.append(FileTreeNode(
                name: (path as NSString).lastPathComponent,
                path: fullPath,
                isDirectory: false,
                entry: entries[fullPath],
                children: []
            ))
        }
        return nodes
    }
}

// MARK: - The store

/// The file browser's data store — the file-side mirror of `TranscriptStore`.
///
/// It owns the session folder's classified file data and does ALL the
/// processing off the main thread (git listing, indexing, directory set, the
/// whole tree build — on a large project that build used to run on the main
/// thread at session start and stalled the UI before Files was even opened).
/// The view is ephemeral and only ever reads the finished snapshot (a
/// virtualized table over a cheap flattened row list); it never builds or
/// copies the tree.
///
/// Like the transcript store it belongs to the SESSION (`SessionTab` owns it),
/// lives for the whole tab, starts warm as soon as the session opens, and
/// refreshes itself off the main thread whenever the agent touches files —
/// whether or not the Files page is the one being shown.
@MainActor
@Observable
final class FileBrowserStore {
    let cwd: URL

    // The published snapshot (read by the view; Observation re-renders it).
    private(set) var fileEntries: [String: GitStatus.FileEntry] = [:]
    private(set) var rootNodes: [FileTreeNode] = []
    private(set) var directoryPaths: Set<String> = []
    private(set) var fileCount = 0
    private(set) var isLoading = true
    /// Bumped on every snapshot swap. The view memoizes its flattened rows on
    /// (version, expansion), so a body re-evaluation that touches neither is
    /// O(1).
    private(set) var version = 0

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshInFlight = false
    /// Debounce: a burst of agent edits collapses into one listing pass.
    @ObservationIgnored private static let refreshSettleDelay: Duration = .milliseconds(350)

    @ObservationIgnored private var changeObserver: NSObjectProtocol?

    init(cwd: URL) {
        self.cwd = cwd
        // Stay warm: agent file changes (`GitStatus.didChangeNotification`,
        // posted by the owning SessionTab) refresh this store's data off the
        // main thread even while the Files page isn't the visible page —
        // exactly how a background session's transcript keeps folding.
        changeObserver = NotificationCenter.default.addObserver(
            forName: GitStatus.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard (note.userInfo?["cwd"] as? URL) == cwd else { return }
            MainActor.assumeIsolated {
                self.scheduleRefresh()
            }
        }
    }

    /// Stops the store: unregisters the change observer and cancels any
    /// pending refresh. Called by the owning tab on close.
    func stop() {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Debounced refresh. Callers: the session's file-change signal and the
    /// Files view's warm-up.
    func scheduleRefresh(immediate: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if !immediate {
                try? await Task.sleep(for: Self.refreshSettleDelay)
            }
            guard !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    /// One full refresh. The git listing + the whole tree build run on a
    /// detached task (`FileTreeBuilder` is nonisolated); the finished snapshot
    /// is swapped in here on the main actor (Observation re-renders any view
    /// reading it). A cancelled refresh leaves the previous snapshot intact.
    func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        guard !Task.isCancelled else { return }
        let cwd = self.cwd
        let snapshot = await Task.detached(priority: .userInitiated) {
            await FileTreeBuilder.build(cwd: cwd)
        }.value
        guard !Task.isCancelled else { return }
        fileEntries = snapshot.fileEntries
        rootNodes = snapshot.rootNodes
        directoryPaths = snapshot.directoryPaths
        fileCount = snapshot.fileCount
        isLoading = false
        version &+= 1
    }
}

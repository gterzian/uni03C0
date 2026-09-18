import Core
import Foundation
import Observation
import SwiftUI

/// A one-shot "append this text to the prompt input" request, used when
/// restoring queued steering into the input. The `id` distinguishes a new
/// request from a stale one when the view re-renders (the coordinator records
/// the last id it applied).
struct RestoreRequest: Equatable {
    let id: UUID
    let text: String
}

/// The nested page a session tab shows — the conversation, the read-only
/// file browser for the session's folder, or the Changes review surface (the
/// uncommitted diff of that folder). A "tab within the tab": switching pages
/// swaps the transcript area for the file viewer or the diff, while the prompt
/// bar and the chrome below stay put — so tagging a reference and pasting it
/// into the prompt happens in the same window.
enum SessionPage: Hashable {
    case conversation
    case files
    case changes
}

/// One live session — one tab in the tabbed main window (also used by the
/// single-session view and the menu-bar quick prompt). Owns the
/// `SessionViewModel` (connection, RPC commands, UI state) plus the small bits
/// of per-session UI state SwiftUI reads: the recent-sessions list for the
/// Resume menu, the history sheet flag, the sending flag, and the prompt
/// draft (used to restore queued steering into the input for editing).
///
/// All tabs share the same sandbox settings: each session snapshots
/// `SandboxSettings` at spawn (`SessionViewModel.init`), so a new tab uses the
/// current settings while running sessions keep the sandbox they started with.
@MainActor
@Observable
final class SessionTab: Identifiable {
    let id = UUID()
    let cwd: URL
    let viewModel: SessionViewModel
    /// The file browser's data store — the file-side mirror of `viewModel.store`
    /// (the transcript store): it owns this folder's classified file data,
    /// processes it off the main thread, and stays warm for the whole life of
    /// the tab. The Files view is ephemeral and reads from it; it never builds
    /// or copies the tree on the main thread.
    let fileBrowser: FileBrowserStore

    var recentSessions: [SessionListing.Summary] = []
    var showingHistory = false
    var isSending = false
    /// Mirror of the prompt input's text, so "edit queued steering" can
    /// restore a queued message into the input.
    var promptDraft = ""
    /// One-shot restore requests (queued steering back into the input). The
    /// restore APPENDS to whatever is already in the input — a quick push
    /// back — and never disturbs an in-flight streamed paste (which keeps
    /// pushing to the front). Cleared on application (see
    /// `PromptInputView.onRestoreConsumed`), so it can never re-apply.
    var restoreRequest: RestoreRequest?
    /// Height of the prompt input. Auto-grows with content until the user
    /// drags the resize handle, which pins it (`promptHeightIsCustom`).
    var promptHeight: CGFloat = PromptBarMetrics.defaultHeight
    /// True once the user has dragged the resize handle: the height is then
    /// user-fixed and no longer follows the content.
    var promptHeightIsCustom = false

    /// Prevents stopping a tab twice (close + window teardown) — a stopped
    /// session's process is gone and must not be terminated again.
    @ObservationIgnored private var hasStopped = false

    /// Observer for `Notification.Name.openFileReference` — a click on an
    /// agent-emitted `pi-file://` link in this tab's transcript. NEW lifecycle
    /// surface (unlike `onFilesChanged`, which is a plain closure property,
    /// `SessionTab` registers no NotificationCenter observer of its own
    /// today), so it must be removed in `stop()` symmetrically with
    /// `FileBrowserStore.stop()` removing its own observer.
    @ObservationIgnored private var openReferenceObserver: NSObjectProtocol?

    /// Number of files with uncommitted changes in this session's folder
    /// (`git status --porcelain` line count), nil when the folder isn't a git
    /// repo or the first check hasn't completed. Drives the count badge on
    /// the nested Files page tab (the old "N edited" review gate). Refreshed
    /// once at init (a project that already had uncommitted changes before
    /// the app opened shows the badge immediately) and debounced after every
    /// agent file change (§2.2).
    var gitChangeCount: Int?
    private var gitCountTask: Task<Void, Never>?

    /// Which nested page this tab currently shows (the Session / Files /
    /// Changes tabs in the tab panel). Persists across outer tab switches —
    /// the view re-materializes on return, the page choice does not.
    var page: SessionPage = .conversation

    init(cwd: URL, projectsRoot: URL?) {
        self.cwd = cwd
        self.viewModel = SessionViewModel(cwd: cwd, projectsRoot: projectsRoot)
        self.fileBrowser = FileBrowserStore(cwd: cwd)
        // When an abort ends the turn, queued steering is appended back into
        // the prompt input (a push-back that coexists with any in-flight
        // streamed paste, which keeps pushing to the front).
        viewModel.onRestoreSteeringToInput = { [weak self] text in
            self?.restoreRequest = RestoreRequest(id: UUID(), text: text)
        }
        // Accessibility: announce when the agent's work settles, so a
        // VoiceOver user gets the same "done, you can type" signal the
        // visual UI gives.
        viewModel.onAgentSettled = {
            AccessibilityNotification.Announcement(Announcements.agentFinished).post()
        }
        // File-change sync: one signal drives everything that reacts to a file
        // changing on disk — the count badge on the Files page tab (updated
        // here, the closure already runs with the tab in scope) and the file
        // browser (reached via a NotificationCenter post keyed by `cwd`, since
        // the browser is a nested page that never holds a reference back to
        // this tab). Per-`edit`/`write` calls fire with the path; the settle
        // fires with nil.
        viewModel.onFilesChanged = { [weak self] path in
            guard let self else { return }
            self.fileStateMayHaveChanged(path: path)
        }
        // A click on an agent-emitted file reference in the transcript (posted
        // by the transcript coordinator, which has no SessionTab): switch to
        // the Files page and open the referenced file there. cwd-scoped and
        // delivered on the main queue, exactly like FileBrowserStore's own
        // observer — this tab only reacts to links naming ITS folder.
        openReferenceObserver = NotificationCenter.default.addObserver(
            forName: .openFileReference,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard (note.userInfo?["cwd"] as? URL) == self.cwd else { return }
            guard let link = note.userInfo?["link"] as? FileReferenceLink else { return }
            MainActor.assumeIsolated {
                self.openFileReference(link)
            }
        }
        scheduleGitCountRefresh(immediate: true)
    }

    /// Opens a clicked agent file reference: flip to the Files page (a pure
    /// visibility flip — both pages stay mounted) and hand the link to the
    /// file browser store, which selects the file, asks the tree to reveal it,
    /// and arms the content pane to land on the reference's line.
    private func openFileReference(_ link: FileReferenceLink) {
        page = .files
        fileBrowser.openReference(link)
    }

    /// Opens a whole file in the full file browser — the Changes page's
    /// "click a file name" action. Flips to the Files page (a visibility flip;
    /// the browser stays mounted) and selects/reveals the file through the
    /// same store path a `pi-file` reference uses, minus the line target.
    func openInFileBrowser(_ path: String) {
        page = .files
        fileBrowser.openReference(FileReferenceLink(path: path))
    }

    func start() async {
        LiveSessions.register(viewModel.controller)
        await viewModel.start()
        reloadSessions()
        // Warm the file listing the moment the session opens — the git work
        // runs off the main thread inside the store, so a large project never
        // stalls the session open, and the Files page (and its count) is ready
        // when first shown.
        fileBrowser.scheduleRefresh(immediate: true)
    }

    func stop() async {
        guard !hasStopped else { return }
        hasStopped = true
        LiveSessions.unregister(viewModel.controller)
        gitCountTask?.cancel()
        if let openReferenceObserver {
            NotificationCenter.default.removeObserver(openReferenceObserver)
            self.openReferenceObserver = nil
        }
        fileBrowser.stop()
        await viewModel.stop()
    }

    /// Re-checks this folder's git state after something pi did not observe:
    /// the app returned to the foreground, the session became the active tab,
    /// or the user opened the Files / Changes review surface. Drives the same
    /// signal an agent file event does, so the store's snapshot (tree +
    /// changed list + count badge) and the open content pane can never
    /// disagree with the working tree.
    func refreshWorkingTree() {
        // Deferred one main-queue turn: the callers are SwiftUI update handlers
        // (onReceive/onChange), and the fan-out mutates other views' state
        // (pane reload tokens, the store's snapshot). Mutating that synchronously
        // from inside an update is undefined behavior.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.fileStateMayHaveChanged(path: nil)
        }
    }

    /// Fan-out for "this folder may have changed on disk": re-count the
    /// changed files (the tab badges) and post the cwd-keyed notification
    /// that refreshes the file browser store and reloads the open panes. `path`
    /// is the touched file, or nil when the change is unknown / any file may
    /// have changed (a turn settle, a return to the app).
    private func fileStateMayHaveChanged(path: String?) {
        scheduleGitCountRefresh()
        NotificationCenter.default.post(
            name: GitStatus.didChangeNotification,
            object: nil,
            userInfo: ["cwd": cwd, "path": path as Any]
        )
    }

    func reloadSessions() {
        recentSessions = SessionListing.recentSessions(for: cwd, limit: 10)
    }

    /// Re-computes `gitChangeCount` — debounced so a burst of rapid edits
    /// (a codegen script writing dozens of files) collapses into one porcelain
    /// scan 350ms after the last event rather than one per file. The scan
    /// itself runs off the main actor (GitStatus is nonisolated async); only
    /// the result lands back here.
    private func scheduleGitCountRefresh(immediate: Bool = false) {
        gitCountTask?.cancel()
        let cwd = self.cwd
        let task = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard !Task.isCancelled else { return }
            let count = await GitStatus.changedFileCount(at: cwd)
            self?.gitChangeCount = count
        }
        gitCountTask = task
    }
}

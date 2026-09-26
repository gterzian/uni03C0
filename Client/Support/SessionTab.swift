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

/// The nested page a session tab shows — the conversation or the Changes
/// review surface (the uncommitted diff of the session folder). A "tab within
/// the tab": switching swaps the transcript area for the diff, while the
/// prompt bar and the chrome below stay put — so tagging a reference and
/// pasting it into the prompt happens in the same window.
enum SessionPage: Hashable {
    case conversation
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
    /// The Changes page's data store and diff model — it owns this folder's
    /// changed-file list, loads each file's diff off the main thread, and stays
    /// warm for the whole life of the tab. The view is ephemeral and only ever
    /// reads the finished document.
    let changes: ChangesStore

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
    /// agent-emitted `pi-file://` link in this tab's transcript. It scrolls the
    /// Changes viewer to that file when the file is part of the changeset.
    @ObservationIgnored private var openReferenceObserver: NSObjectProtocol?

    /// Number of files with uncommitted changes in this session's folder
    /// (`git status --porcelain` line count), nil when the folder isn't a git
    /// repo or the first check hasn't completed. Drives the count badge on
    /// the nested Changes page tab (the old "N edited" review gate). Refreshed
    /// once at init (a project that already had uncommitted changes before
    /// the app opened shows the badge immediately) and debounced after every
    /// agent file change (§2.2).
    var gitChangeCount: Int?
    private var gitCountTask: Task<Void, Never>?

    /// Which nested page this tab currently shows (the Session / Changes tabs
    /// in the tab panel). Persists across outer tab switches — the view
    /// re-materializes on return, the page choice does not.
    var page: SessionPage = .conversation

    init(cwd: URL, projectsRoot: URL?) {
        self.cwd = cwd
        self.viewModel = SessionViewModel(cwd: cwd, projectsRoot: projectsRoot)
        self.changes = ChangesStore(cwd: cwd)
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
        // changing on disk — the count badge on the Changes page tab (updated
        // here, the closure already runs with the tab in scope) and the file
        // browser (reached via a NotificationCenter post keyed by `cwd`, since
        // the browser is a nested page that never holds a reference back to
        // this tab). Per-`edit`/`write` calls fire with the path; the settle
        // fires with nil.
        viewModel.onFilesChanged = { [weak self] path in
            guard let self else { return }
            self.fileStateMayHaveChanged(path: path)
        }
        // A user turn begins: pin the Changes viewer's baseline to the commit
        // `HEAD` names right now, so a commit the agent makes mid-turn does not
        // clear the diff. Fired before the prompt is sent, and the git work is
        // deferred off the send path (a main-actor Task), so it never delays
        // the prompt reaching pi.
        viewModel.onTurnStarted = { [weak self] in
            Task { [weak self] in await self?.changes.beginTurn() }
        }
        // A click on an agent-emitted file reference in the transcript (posted
        // by the transcript coordinator, which has no SessionTab): switch to the
        // Changes page and scroll the viewer to the referenced file when it has
        // uncommitted changes. cwd-scoped and delivered on the main queue,
        // exactly like ChangesStore's own observer — this tab only reacts to
        // links naming ITS folder.
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

    /// Opens a clicked agent file reference: flip to the Changes page (a pure
    /// visibility flip) and scroll its viewer to the referenced file — landing
    /// on the referenced line when the link named one and that line is part of
    /// the shown diff window. A reference to a file with no uncommitted change
    /// has no diff section to land on (the viewer is the only file surface) and
    /// is left alone: the agent is taught to reference only changed files.
    private func openFileReference(_ link: FileReferenceLink) {
        guard changes.entries.contains(where: { $0.path == link.path }) else { return }
        page = .changes
        changes.reveal(link.path, line: link.startLine)
    }

    func start() async {
        LiveSessions.register(viewModel.controller)
        await viewModel.start()
        reloadSessions()
        // Warm the changes listing the moment the session opens — the git work
        // runs off the main thread inside the store, so a large project never
        // stalls the session open, and the Changes page (and its count) is ready
        // when first shown.
        changes.scheduleRefresh(immediate: true)
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
        changes.stop()
        await viewModel.stop()
    }

    /// Re-checks this folder's git state after something pi did not observe:
    /// the app returned to the foreground, the session became the active tab,
    /// or the user opened the Changes review surface. Drives the same signal an
    /// agent file event does, so the store's snapshot (changed list + count
    /// badge) and the diff viewer can never disagree with the working tree.
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

    /// Badge-only refresh for a tab switch: re-count the changed files without
    /// reloading every diff. A tab switch remounts the incoming session's
    /// Changes page, so re-reading and re-diffing the whole changeset on every
    /// switch is pure recompute — the diff store re-syncs on a pi file event,
    /// on app activation, and when a review surface opens. Deferred like
    /// `refreshWorkingTree` (called from a SwiftUI update handler).
    func refreshGitCount() {
        Task { @MainActor [weak self] in
            self?.scheduleGitCountRefresh()
        }
    }

    /// Fan-out for "this folder may have changed on disk": re-count the
    /// changed files (the tab badge) and post the cwd-keyed notification that
    /// refreshes the Changes store (changed list + diffs). `path` is the touched
    /// file, or nil when the change is unknown / any file may have changed (a
    /// turn settle, a return to the app).
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
            // Same turn baseline as the viewer, so the badge and the changed
            // list can never disagree (a mid-turn commit keeps counting).
            let base = self?.changes.baseline
            let count = await GitStatus.changedFileCount(at: cwd, base: base)
            self?.gitChangeCount = count
        }
        gitCountTask = task
    }
}

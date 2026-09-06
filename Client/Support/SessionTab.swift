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

/// The nested page a session tab shows — the conversation, or the read-only
/// file browser for the session's folder. A "tab within the tab": switching
/// pages swaps the transcript area for the file viewer, while the prompt bar
/// and the chrome below stay put — so tagging a reference and pasting it into
/// the prompt happens in the same window.
enum SessionPage: Hashable {
    case conversation
    case files
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

    /// Number of files with uncommitted changes in this session's folder
    /// (`git status --porcelain` line count), nil when the folder isn't a git
    /// repo or the first check hasn't completed. Drives the count badge on
    /// the nested Files page tab (the old "N edited" review gate). Refreshed
    /// once at init (a project that already had uncommitted changes before
    /// the app opened shows the badge immediately) and debounced after every
    /// agent file change (§2.2).
    var gitChangeCount: Int?
    private var gitCountTask: Task<Void, Never>?

    /// Which nested page this tab currently shows (the Session / Files tabs in
    /// the tab panel). Persists across outer tab switches — the view
    /// re-materializes on return, the page choice does not.
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
            self.scheduleGitCountRefresh()
            NotificationCenter.default.post(
                name: GitStatus.didChangeNotification,
                object: nil,
                userInfo: ["cwd": self.cwd, "path": path as Any]
            )
        }
        scheduleGitCountRefresh(immediate: true)
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
        fileBrowser.stop()
        await viewModel.stop()
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

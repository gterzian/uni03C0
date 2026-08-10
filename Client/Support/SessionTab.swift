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

    var recentSessions: [SessionListing.Summary] = []
    var showingHistory = false
    var isSending = false
    /// Mirror of the prompt input's text, so "edit queued steering" can
    /// restore a queued message into the input.
    var promptDraft = ""
    /// One-shot restore requests (queued steering back into the input). The
    /// restore APPENDS to whatever is already in the input — a quick push
    /// back — and never disturbs an in-flight streamed paste (which keeps
    /// pushing to the front).
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

    init(cwd: URL, projectsRoot: URL?) {
        self.cwd = cwd
        self.viewModel = SessionViewModel(cwd: cwd, projectsRoot: projectsRoot)
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
            AccessibilityNotification.Announcement("Agent finished working").post()
        }
    }

    func start() async {
        LiveSessions.register(viewModel.controller)
        await viewModel.start()
        reloadSessions()
    }

    func stop() async {
        guard !hasStopped else { return }
        hasStopped = true
        LiveSessions.unregister(viewModel.controller)
        await viewModel.stop()
    }

    func reloadSessions() {
        recentSessions = SessionListing.recentSessions(for: cwd, limit: 10)
    }
}

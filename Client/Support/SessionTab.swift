import Core
import Foundation
import Observation

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

    /// Prevents stopping a tab twice (close + window teardown) — a stopped
    /// session's process is gone and must not be terminated again.
    @ObservationIgnored private var hasStopped = false

    init(cwd: URL, projectsRoot: URL?) {
        self.cwd = cwd
        self.viewModel = SessionViewModel(cwd: cwd, projectsRoot: projectsRoot)
        // When an abort ends the turn, queued steering is returned to the
        // prompt input instead of being sent.
        viewModel.onRestoreSteeringToInput = { [weak self] text in
            self?.promptDraft = text
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

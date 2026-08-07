import AppKit
import Core
import SwiftUI

/// One project window. With no project chosen (`project.cwd == nil`) shows a
/// picker and spawns nothing; once a project is selected, creates the session.
struct MainWindowView: View {
    @Binding var project: ProjectRef

    var body: some View {
        Group {
            if let cwd = project.cwd {
                SessionView(cwd: cwd)
            } else {
                ProjectPickerView { url in
                    AppState.shared.lastProject = url
                    project = ProjectRef(cwd: url)
                }
            }
        }
    }
}

/// A live session for one project: transcript (AppKit) + prompt bar (AppKit-
/// backed for Tab completion) + toolbar menus bound to this session.
struct SessionView: View {
    let cwd: URL

    @State private var viewModel: SessionViewModel?
    @State private var recentSessions: [SessionListing.Summary] = []
    @State private var isSending = false
    @State private var showingHistory = false

    var body: some View {
        VStack(spacing: 0) {
            if let viewModel {
                ZStack {
                    TranscriptView(viewModel: viewModel)
                        .background(Color(nsColor: .textBackgroundColor))
                    if viewModel.isReloading {
                        // In-app spinner while the store rebuilds the whole
                        // history off the main thread (no system beachball).
                        ProgressView("Reloading session…")
                            .controlSize(.small)
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if viewModel.isFetchingOlder {
                        // Small spinner pinned to the top of the conversation
                        // while the coordinator fetches a block of older
                        // history (scrolling up).
                        VStack {
                            ProgressView()
                                .controlSize(.small)
                                .padding(6)
                                .background(.regularMaterial, in: Capsule())
                            Spacer()
                        }
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }

                Divider()

                PromptInputView(
                    cwd: cwd,
                    isEnabled: inputEnabled(viewModel),
                    onSubmit: submit,
                    onAbort: { Task { try? await viewModel.abort() } }
                )
                .frame(height: 104)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                SessionStatusBar(viewModel: viewModel)
            } else {
                ProgressView("Starting agent…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(cwd.lastPathComponent)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let viewModel {
                    stopButton(viewModel)
                    reloadButton(viewModel)
                    resumeMenu(viewModel)
                }
            }
        }
        .task(id: cwd) { await start() }
        .onDisappear { tearDown() }
        .sheet(isPresented: $showingHistory) {
            if let viewModel {
                SessionHistorySheet(cwd: cwd, viewModel: viewModel)
            }
        }
    }

    private func inputEnabled(_ vm: SessionViewModel) -> Bool {
        !vm.isStreaming && vm.connectionState == .connected && !isSending
    }

    private func submit(_ text: String) {
        guard let viewModel, !viewModel.isStreaming else { return }
        isSending = true
        Task {
            defer { isSending = false }
            try? await viewModel.sendPrompt(text)
        }
    }

    private func start() async {
        // The task restarts when `cwd` changes (picker -> project, or the
        // window's value is replaced): stop any stale session first.
        if let existing = viewModel, existing.cwd != cwd {
            LiveSessions.unregister(existing.controller)
            await existing.stop()
            viewModel = nil
        }
        guard viewModel == nil else { return }
        let vm = SessionViewModel(cwd: cwd)
        viewModel = vm
        LiveSessions.register(vm.controller)
        await vm.start()
        reloadSessions()
    }

    private func tearDown() {
        if let viewModel {
            LiveSessions.unregister(viewModel.controller)
            Task { await viewModel.stop() }
        }
        viewModel = nil
    }

    private func reloadSessions() {
        recentSessions = SessionListing.recentSessions(for: cwd, limit: 10)
    }

    // MARK: Toolbar

    /// Persistent stop button: spinner while a turn is in flight, disabled
    /// when idle. Same action as Esc in the prompt bar.
    private func stopButton(_ vm: SessionViewModel) -> some View {
        Button {
            Task { try? await vm.abort() }
        } label: {
            if vm.isStreaming {
                Label {
                    Text("Stop")
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                Label("Stop", systemImage: "stop")
            }
        }
        .disabled(!vm.isStreaming)
        .help("Abort the current operation (Esc)")
    }

    private func reloadButton(_ vm: SessionViewModel) -> some View {
        Button {
            Task { await vm.reload() }
        } label: {
            Label("Reload", systemImage: "arrow.clockwise")
        }
        .help("Reload the current session from disk (get_state → switch_session)")
    }

    private func resumeMenu(_ vm: SessionViewModel) -> some View {
        Menu {
            if recentSessions.isEmpty {
                Text("No sessions yet")
            }
            ForEach(recentSessions) { session in
                Button {
                    Task { await vm.switchSession(session.path) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(session.title)
                        Text(relativeTime(session.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Button("View Full History…") { showingHistory = true }
            Button("Refresh List") { reloadSessions() }
        } label: {
            Label("Resume", systemImage: "clock.arrow.circlepath")
        }
        .help("Resume a previous session for this project")
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

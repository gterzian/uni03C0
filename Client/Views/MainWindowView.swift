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
    /// Mirror of the prompt input's text, so "edit queued steering" can
    /// restore a queued message into the input.
    @State private var promptDraft = ""

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

                if viewModel.hasQueuedSteering {
                    queuedSteeringBar(viewModel)
                }

                PromptInputView(
                    cwd: cwd,
                    isEnabled: inputEnabled(viewModel),
                    fontSize: FontSettings.shared.bodySize,
                    draft: promptDraft,
                    onDraftChange: { promptDraft = $0 },
                    onSubmit: submit,
                    onAbort: { Task { try? await viewModel.abort() } }
                )
                .frame(height: 104)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                ProgressView("Starting agent…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(cwd.lastPathComponent)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let viewModel {
                    contextLabel(viewModel)
                    stopButton(viewModel)
                    reloadButton(viewModel)
                    modelMenu(viewModel)
                    thinkingMenu(viewModel)
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
        // The prompt bar stays enabled while a turn is in flight: with work
        // ongoing, Return queues a steering message instead of sending. It is
        // disabled only while disconnected / sending, or until both a model
        // and a thinking level have been chosen.
        vm.connectionState == .connected && !isSending && vm.model != nil && vm.thinkingLevel != nil
    }

    private func submit(_ text: String) {
        guard let viewModel, viewModel.model != nil, viewModel.thinkingLevel != nil else { return }
        if viewModel.isStreaming {
            // Work is ongoing — don't interrupt it or start a separate turn.
            // Queue as a steering message; the whole queue is flushed as one
            // combined prompt when the turn settles.
            viewModel.queueSteering(text)
        } else {
            isSending = true
            Task {
                defer { isSending = false }
                try? await viewModel.sendPrompt(text)
            }
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
        // When an abort ends the turn, queued steering is returned to the
        // prompt input instead of being sent.
        vm.onRestoreSteeringToInput = { text in
            self.promptDraft = text
        }
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

    /// Banner above the prompt bar while steering messages are queued: one
    /// row per queued message, each with an edit button (restores the message
    /// into the input so Return re-queues the edited version) and a delete
    /// button. The whole queue is flushed as ONE prompt when the turn settles.
    private func queuedSteeringBar(_ vm: SessionViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Steering queued — sent when the current work finishes", systemImage: "tray.and.arrow.down.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(Array(vm.queuedSteering.enumerated()), id: \.offset) { index, message in
                HStack(spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        // Edit: restore this message into the input and drop it
                        // from the queue; Return re-queues the edited version.
                        promptDraft = message
                        vm.removeQueuedSteering(at: index)
                    } label: {
                        Image(systemName: "pencil.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Edit this queued message")
                    Button {
                        vm.removeQueuedSteering(at: index)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Discard this queued message")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func reloadSessions() {
        recentSessions = SessionListing.recentSessions(for: cwd, limit: 10)
    }

    // MARK: Toolbar

    /// Context-window usage at the leading edge of the toolbar, so the runtime
    /// status reads at a glance without a bar under the prompt input. Plain
    /// text, not a Label — toolbars collapse labels to icon-only.
    private func contextLabel(_ vm: SessionViewModel) -> some View {
        let percent = vm.contextUsage?.percent
        let text = percent.map { "\(Int(round($0)))%" } ?? "–"
        return Text("ctx: \(text)")
            .help("Context window usage")
    }

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

    /// Model picker: the current model's name shown beside the icon; a
    /// "choose model" prompt until one is set (sending is disabled until
    /// then).
    private func modelMenu(_ vm: SessionViewModel) -> some View {
        Menu {
            if vm.availableModels.isEmpty {
                Text("No models available")
            }
            ForEach(vm.availableModels) { model in
                Button {
                    Task { try? await vm.setModel(model.provider ?? "", model.id) }
                } label: {
                    if vm.model?.id == model.id {
                        Label(model.name ?? model.id, systemImage: "checkmark")
                    } else {
                        Text(model.name ?? model.id)
                    }
                }
            }
        } label: {
            Label(vm.model?.name ?? vm.model?.id ?? "Choose model…", systemImage: "cpu")
        }
        .help("Switch model")
    }

    /// Thinking-level picker: current level shown beside the icon; a "choose
    /// thinking level" prompt until one is set.
    private func thinkingMenu(_ vm: SessionViewModel) -> some View {
        Menu {
            if vm.availableThinkingLevels.isEmpty {
                Text("No thinking levels available")
            }
            ForEach(vm.availableThinkingLevels, id: \.self) { level in
                Button {
                    Task { try? await vm.setThinkingLevel(level) }
                } label: {
                    if vm.thinkingLevel == level {
                        Label(level, systemImage: "checkmark")
                    } else {
                        Text(level)
                    }
                }
            }
        } label: {
            Label(vm.thinkingLevel ?? "Choose thinking level…", systemImage: "brain")
        }
        .help("Set thinking level")
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

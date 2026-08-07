import AppKit
import PiCore
import SwiftUI

/// One project window: transcript (AppKit) + prompt bar (AppKit-backed for Tab
/// completion) + toolbar menus bound to this window's session.
struct MainWindowView: View {
    let cwd: URL

    @State private var viewModel: SessionViewModel?
    @State private var recentSessions: [SessionListing.Summary] = []
    @State private var isSending = false

    var body: some View {
        VStack(spacing: 0) {
            if let viewModel {
                TranscriptView(entries: viewModel.entries)
                    .background(Color(nsColor: .textBackgroundColor))

                Divider()

                PromptInputView(
                    cwd: cwd,
                    isEnabled: inputEnabled(viewModel),
                    onSubmit: submit
                )
                .frame(height: 104)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                ProgressView("Starting pi…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(cwd.lastPathComponent)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let viewModel {
                    reloadButton(viewModel)
                    modelMenu(viewModel)
                    thinkingMenu(viewModel)
                    resumeMenu(viewModel)
                }
            }
        }
        .task { await start() }
        .onDisappear { tearDown() }
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

    private func reloadButton(_ vm: SessionViewModel) -> some View {
        Button {
            Task { await vm.reload() }
        } label: {
            Label("Reload", systemImage: "arrow.clockwise")
        }
        .help("Reload the current session from disk (get_state → switch_session)")
    }

    private func modelMenu(_ vm: SessionViewModel) -> some View {
        Menu {
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
            Label(vm.model?.name ?? vm.model?.id ?? "Model", systemImage: "cpu")
        }
        .help("Switch model")
    }

    private func thinkingMenu(_ vm: SessionViewModel) -> some View {
        Menu {
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
            Label(vm.thinkingLevel ?? "Thinking", systemImage: "brain")
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

import Core
import SwiftUI

/// The window-toolbar items for one live session, shared by the tabbed main
/// window (`SessionTabsView`): Stop, Reload, the model + thinking-level
/// pickers, and the Resume menu — all bound to the session in `tab`.
enum SessionToolbar {
    @ToolbarContentBuilder
    static func content(tab: SessionTab) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            stopButton(tab.viewModel)
            reloadButton(tab.viewModel)
            modelMenu(tab.viewModel)
            thinkingMenu(tab.viewModel)
            resumeMenu(tab)
        }
    }

    /// Persistent stop button: spinner while a turn is in flight, disabled
    /// when idle. Same action as Esc anywhere in the window. Its icons are
    /// also what the tab bar shows on non-active tabs.
    private static func stopButton(_ vm: SessionViewModel) -> some View {
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

    private static func reloadButton(_ vm: SessionViewModel) -> some View {
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
    private static func modelMenu(_ vm: SessionViewModel) -> some View {
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
    /// thinking level" prompt until one is set. The menu offers exactly the
    /// levels pi reports via `get_available_thinking_levels` — the same list
    /// the terminal TUI's selector shows — so the checkmarked choice always
    /// matches what pi actually uses. No levels are invented or merged in.
    private static func thinkingMenu(_ vm: SessionViewModel) -> some View {
        return Menu {
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

    /// Resume menu: the current session (the one the live process has open) is
    /// checkmarked, so the dropdown shows the live choice.
    private static func resumeMenu(_ tab: SessionTab) -> some View {
        let currentFile = tab.viewModel.sessionFile?.standardizedFileURL
        return Menu {
            if tab.recentSessions.isEmpty {
                Text("No sessions yet")
            }
            ForEach(tab.recentSessions) { session in
                let isCurrent = session.path.standardizedFileURL == currentFile
                Button {
                    Task { await tab.viewModel.switchSession(session.path) }
                } label: {
                    HStack(spacing: 6) {
                        // Checkmark marks the session the live process has open;
                        // other rows get a clock glyph in the same slot so the
                        // leading edge lines up.
                        Image(systemName: isCurrent ? "checkmark" : "clock")
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title)
                            Text(relativeTime(session.timestamp))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            Button("View Full History…") { tab.showingHistory = true }
            Button("Refresh List") { tab.reloadSessions() }
        } label: {
            Label("Resume", systemImage: "clock.arrow.circlepath")
        }
        .help("Resume a previous session for this project")
    }

    private static func relativeTime(_ date: Date) -> String {
        guard date != .distantPast else { return "unknown date" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

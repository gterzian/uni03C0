import Core
import SwiftUI

/// One session's app-level controls, rendered as floating Liquid Glass pills in
/// the main window's top chrome — the controls that used to live in the window
/// toolbar: Stop / Reload, the model + thinking-level pickers, the Resume menu,
/// and the app-wide appearance menu. Each functional group is its own capsule
/// (Liquid Glass groups by function, not by a painted bar), matching the
/// floating tab chrome on the left. The native titlebar is transparent and has
/// no toolbar; this view IS the top-right chrome.
struct SessionToolbarView: View {
    @Bindable var tab: SessionTab

    var body: some View {
        let vm = tab.viewModel
        HStack(spacing: 8) {
            glassGroup {
                stopButton(vm)
                reloadButton(vm)
            }
            glassGroup {
                modelMenu(vm)
                thinkingMenu(vm)
            }
            glassGroup {
                resumeMenu(tab)
            }
            glassGroup {
                AppearanceMenuButton()
            }
        }
        // The native toolbar used to render these as icon-only items; keep the
        // same compact language in the custom capsules. Plain buttons and
        // plain menu labels (no bezel) so they read as content on the glass.
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        // Match the system toolbar's control weight: an icon-only plain label
        // otherwise draws at the (small) default label font and the pills read
        // as tiny next to the tab chrome. Explicit size AND control size, since
        // a borderless `Menu` does not inherit a font reliably.
        .font(.system(size: 17, weight: .medium))
        .controlSize(.large)
    }

    /// One functional group on a single capsule. The material is the app-wide
    /// Liquid Glass (`GlassBackground`), never SwiftUI's `.glassEffect`.
    private func glassGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 14) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background { GlassBackground(shape: .capsule) }
    }

    /// Persistent stop button: spinner while a turn is in flight, disabled
    /// when idle. Same action as Esc anywhere in the window. Its icons are
    /// also what the tab bar shows on non-active tabs.
    private func stopButton(_ vm: SessionViewModel) -> some View {
        Button {
            Task { try? await vm.abort() }
        } label: {
            if vm.isStreaming {
                Label {
                    Text("Stop")
                } icon: {
                    // AppKit spinner, not SwiftUI `ProgressView`: a SwiftUI
                    // spinner animates the hosting view's graph every frame
                    // for the whole turn (see `SpinnerView`).
                    SpinnerView()
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

    /// Model picker: the current model shown beside the icon (the icon-only
    /// label style renders just the cpu glyph here; the current name is on the
    /// composer's status pill). A "choose model" prompt until one is set
    /// (sending is disabled until then).
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
    /// thinking level" prompt until one is set. The menu offers exactly the
    /// levels pi reports via `get_available_thinking_levels` — the same list
    /// the terminal TUI's selector shows — so the checkmarked choice always
    /// matches what pi actually uses. No levels are invented or merged in.
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

    /// Resume menu: the current session (the one the live process has open) is
    /// checkmarked, so the dropdown shows the live choice.
    private func resumeMenu(_ tab: SessionTab) -> some View {
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

    private func relativeTime(_ date: Date) -> String {
        guard date != .distantPast else { return "unknown date" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// The in-session find field, a floating glass capsule in the top chrome.
/// Searches the SESSION's store data (every folded row, materialized or not);
/// typing is debounced in the view model so a burst of keystrokes launches one
/// query. Enter cycles to the next match while the field is active, Esc closes.
/// The transcript scrolls to each match (pulling older history into the window
/// as needed) and only the matched term is highlighted in yellow.
struct SessionSearchBar: View {
    @Bindable var vm: SessionViewModel

    var body: some View {
        HStack(spacing: 8) {
            SearchField(
                text: $vm.searchQuery,
                placeholder: "Find in session…",
                onEnter: { vm.nextSearchMatch() },
                onEscape: { vm.closeSearch() }
            )
            .frame(width: 200)
            .onChange(of: vm.searchQuery) { _, q in vm.updateSearchQuery(q) }
            let trimmed = vm.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if vm.isSearching {
                    // Batched search in progress: the total is unknown
                    // until the whole session is covered, so show the
                    // current position with a spinner instead of a final
                    // count. Cycling still works on the partial results.
                    HStack(spacing: 4) {
                        if vm.searchMatches.isEmpty {
                            Text("searching…")
                        } else {
                            Text("\(vm.searchCurrentIndex + 1) of")
                        }
                        SpinnerView(controlSize: .mini)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if vm.searchMatches.isEmpty {
                    Text("no matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(vm.searchCurrentIndex + 1)/\(vm.searchMatches.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help(LocalizedStringKey(vm.searchMatches.indices.contains(vm.searchCurrentIndex)
                            ? vm.searchMatches[vm.searchCurrentIndex].snippet
                            : ""))
                }
            }
            Button { vm.nextSearchMatch() } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(vm.searchMatches.isEmpty)
            .help("Next match (↩)")
            Button { vm.previousSearchMatch() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(vm.searchMatches.isEmpty)
            .help("Previous match")
            // Case-sensitive matching, unticked by default. Toggling
            // re-runs the current query immediately (the match list and
            // highlight follow the new sensitivity). fixedSize keeps the
            // checkbox+label from being compressed/clipped.
            Toggle(isOn: Binding(
                get: { vm.isCaseSensitive },
                set: { vm.setCaseSensitive($0) }
            )) {
                Text("Aa")
                    .font(.system(size: 10, weight: .semibold))
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .fixedSize()
            .help("Case-sensitive")
            Button { vm.closeSearch() } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close (esc)")
        }
    }
}

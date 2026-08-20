import Core
import SwiftUI

/// The window-toolbar items for one live session, shared by the tabbed main
/// window (`SessionTabsView`): the in-session find field, Stop, Reload, the
/// model + thinking-level pickers, and the Resume menu — all bound to the
/// session in `tab`.
enum SessionToolbar {
    @ToolbarContentBuilder
    static func content(tab: SessionTab) -> some ToolbarContent {
        // In-session find (Cmd+F): lives in the toolbar immediately LEFT of
        // the Stop button so it never covers the transcript. Enter cycles
        // forward, Shift+Enter backward, Esc closes.
        if tab.viewModel.isSearchVisible {
            ToolbarItem(placement: .primaryAction) {
                SessionSearchBar(vm: tab.viewModel)
            }
        }
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

    /// The in-session find field, in the toolbar. Searches the SESSION's
    /// store data (every folded row, materialized or not); typing is debounced
    /// in the view model so a burst of keystrokes launches one query. Enter
    /// cycles to the next match while the field is active, Esc closes. The
    /// transcript scrolls to each match (pulling older history into the
    /// window as needed) and only the matched term is highlighted in yellow.
    private struct SessionSearchBar: View {
        @Bindable var vm: SessionViewModel

        var body: some View {
            HStack(spacing: 8) {
                SearchField(
                    text: $vm.searchQuery,
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
                            ProgressView()
                                .controlSize(.mini)
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
                // checkbox+label from being compressed/clipped in the toolbar.
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
                // A visual divider at the right edge separates the find
                // component from the Stop / activity buttons that follow.
                Divider()
                    .frame(height: 18)
                    .padding(.leading, 2)
            }
        }
    }

    /// An AppKit `NSSearchField` for the toolbar find bar. Chosen over the
    /// SwiftUI `TextField` because it takes keyboard focus RELIABLY
    /// (`window.makeFirstResponder` — SwiftUI's `@FocusState` is flaky inside
    /// a toolbar item, so typing right after Cmd+F didn't land), it has no
    /// blue focus ring on activation (`focusRingType = .none`), and the
    /// magnifier + clear button come built in. Enter (its action) and Esc
    /// (`cancelOperation`) are intercepted via the field editor's `doCommandBy`;
    /// arrow keys fall through untouched — cycling is Enter's job, and only
    /// while the field is active.
    private struct SearchField: NSViewRepresentable {
        @Binding var text: String
        var onEnter: () -> Void
        var onEscape: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(text: $text, onEnter: onEnter, onEscape: onEscape)
        }

        func makeNSView(context: Context) -> NSSearchField {
            let field = NSSearchField()
            field.placeholderString = "Find in session…"
            field.font = .systemFont(ofSize: 12)
            field.bezelStyle = .roundedBezel
            field.focusRingType = .none
            field.delegate = context.coordinator
            field.target = context.coordinator
            field.action = #selector(Coordinator.searchAction)
            field.stringValue = text
            // The toolbar item is inserted asynchronously (with an animation),
            // so the field may not be in a window yet when this runs. Retry a
            // few times across the insertion; after that, never touch focus
            // again (the user can click elsewhere in the transcript).
            for delay in [0.0, 0.08, 0.2, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak field] in
                    guard let field, field.window != nil else { return }
                    if field.window?.firstResponder !== field {
                        field.window?.makeFirstResponder(field)
                    }
                }
            }
            return field
        }

        func updateNSView(_ nsView: NSSearchField, context: Context) {
            if nsView.stringValue != text {
                nsView.stringValue = text
            }
        }

        final class Coordinator: NSObject, NSSearchFieldDelegate {
            var text: Binding<String>
            var onEnter: () -> Void
            var onEscape: () -> Void

            init(text: Binding<String>, onEnter: @escaping () -> Void, onEscape: @escaping () -> Void) {
                self.text = text
                self.onEnter = onEnter
                self.onEscape = onEscape
            }

            func controlTextDidChange(_ obj: Notification) {
                if let field = obj.object as? NSSearchField {
                    text.wrappedValue = field.stringValue
                }
            }

            /// Esc (cancelOperation) closes the bar. Arrow keys are NOT
            /// intercepted here — Enter is the match cycler, and only while
            /// the search field is active.
            func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                    onEscape()
                    return true
                }
                return false
            }

            @objc func searchAction(_ sender: Any) {
                onEnter()
            }
        }
    }
}

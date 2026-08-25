import Core
import SwiftUI

/// Shared metrics for the prompt bar height: the auto-grow minimum/maximum
/// and the resize-handle clamp. The default matches the old fixed height.
enum PromptBarMetrics {
    static let minHeight: CGFloat = 64
    static let maxHeight: CGFloat = 400
    static let defaultHeight: CGFloat = 104

    static func clamp(_ height: CGFloat) -> CGFloat {
        // Round to whole points: fractional drag deltas would otherwise jitter
        // the layer-backed input between pixel-rounded frames.
        min(max(round(height), minHeight), maxHeight)
    }
}

/// The live content of one session: transcript (AppKit) + prompt bar (AppKit-
/// backed for Tab completion) + queued-steering banner. No lifecycle of its
/// own — the owning view (`SessionTabsView`) starts and stops the session and
/// owns the toolbar.
struct SessionContent: View {
    @Bindable var tab: SessionTab

    var body: some View {
        let vm = tab.viewModel
        VStack(spacing: 0) {
            ZStack {
                TranscriptView(viewModel: vm)
                    .background(Color(nsColor: .textBackgroundColor))
                if vm.isReloading {
                    // In-app spinner while the store rebuilds the whole
                    // history off the main thread (no system beachball).
                    ProgressView("Reloading session…")
                        .controlSize(.small)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                if vm.isFetchingOlder {
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
                // The session-bound command shortcuts (Cmd+F find, Cmd+G /
                // Shift+Cmd+G cycling, Cmd+R reload) are handled by the
                // transcript coordinator's local key monitor, which reads the
                // ACTIVE tab's view model at event time — hidden SwiftUI
                // shortcut buttons captured the first tab's vm and kept firing
                // it after a tab switch. Only app-wide shortcuts (no per-tab
                // state) stay here. The find bar itself lives in the window
                // toolbar, left of the Stop button — never over the transcript,
                // so it can't block content.
                // Cmd+= increases the conversation font — Apple lists
                // Command-= as equivalent to Shift-Command-+ for "increase
                // size" (the View menu carries the visible item).
                Button("") {
                    FontSettings.shared.bodySize = min(FontSettings.shared.bodySize + 1, 28)
                }
                    .keyboardShortcut("=", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }

            Divider()

            // Error surfacing: a disconnected agent or the last send failure
            // (auth/preflight/network) — never silently swallowed.
            if case .disconnected(let message) = vm.connectionState {
                errorBanner("Disconnected: \(message)", dismiss: nil)
            } else if let error = vm.lastError {
                errorBanner(error, dismiss: { vm.lastError = nil })
            }

            if vm.hasQueuedSteering {
                queuedSteeringBar(vm)
            }

            // The resize handle pins the height (and disables auto-grow);
            // until then the input grows with its content, clamped by
            // PromptBarMetrics.
            PromptResizeHandle(
                currentHeight: tab.promptHeight,
                onBegan: { tab.promptHeightIsCustom = true },
                onResize: { tab.promptHeight = PromptBarMetrics.clamp($0) }
            )

            PromptInputView(
                cwd: tab.cwd,
                sessionID: tab.id,
                isEnabled: inputEnabled(vm),
                fontSize: FontSettings.shared.bodySize,
                viewModel: vm,
                draft: tab.promptDraft,
                restoreRequest: tab.restoreRequest,
                onRestoreConsumed: { tab.restoreRequest = nil },
                onDraftChange: { tab.promptDraft = $0 },
                onSubmit: submit,
                onAbort: { Task { try? await vm.abort() } },
                onContentHeightChange: { needed in
                    // Auto-grow with content until the user has pinned the
                    // height with the resize handle. Always at least the
                    // minimum, so a cleared prompt snaps back to a compact bar.
                    guard !tab.promptHeightIsCustom else { return }
                    tab.promptHeight = PromptBarMetrics.clamp(max(needed, PromptBarMetrics.minHeight))
                }
            )
            .frame(height: tab.promptHeight)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $tab.showingHistory) {
            SessionHistorySheet(cwd: tab.cwd, viewModel: vm)
        }
        .onChange(of: vm.lastError) { _, error in
            if let error {
                AccessibilityNotification.Announcement(Announcements.error(error)).post()
            }
        }
        .onChange(of: vm.connectionState) { _, state in
            if case .disconnected(let message) = state {
                AccessibilityNotification.Announcement(Announcements.disconnected(message)).post()
            }
        }
    }

    private func inputEnabled(_ vm: SessionViewModel) -> Bool {
        // The prompt bar stays enabled while a turn is in flight: with work
        // ongoing, Return queues a steering message instead of sending. It is
        // disabled only while disconnected / sending, or until both a model
        // and a thinking level have been chosen.
        vm.connectionState == .connected && !tab.isSending && vm.model != nil && vm.thinkingLevel != nil
    }

    private func submit(_ text: String) {
        let vm = tab.viewModel
        guard vm.model != nil, vm.thinkingLevel != nil else { return }
        if vm.isStreaming {
            // Work is ongoing — don't interrupt it or start a separate turn.
            // Queue as a steering message; the whole queue is flushed as one
            // combined prompt when the turn settles.
            vm.queueSteering(text)
        } else {
            tab.isSending = true
            Task {
                defer { tab.isSending = false }
                try? await vm.sendPrompt(text)
            }
        }
    }

    /// Red error banner above the prompt bar: stream/connection failures and
    /// rejected sends. `dismiss` nil = persistent (the agent is gone).
    private func errorBanner(_ text: String, dismiss: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.08))
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
                        // Restore: append this message to whatever is already
                        // in the input (a push-back that leaves an in-flight
                        // streamed paste alone) and drop it from the queue;
                        // Return then sends the combined input.
                        tab.restoreRequest = RestoreRequest(id: UUID(), text: message)
                        vm.removeQueuedSteering(at: index)
                    } label: {
                        Image(systemName: "pencil.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Append this message to the prompt")
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
}

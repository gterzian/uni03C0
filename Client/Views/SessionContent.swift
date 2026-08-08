import Core
import SwiftUI

/// The live content of one session: transcript (AppKit) + prompt bar (AppKit-
/// backed for Tab completion) + queued-steering banner. No lifecycle of its
/// own — the owning view (`SessionView` or `SessionTabsView`) starts and stops
/// the session and owns the toolbar.
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
            }

            Divider()

            if vm.hasQueuedSteering {
                queuedSteeringBar(vm)
            }

            PromptInputView(
                cwd: tab.cwd,
                isEnabled: inputEnabled(vm),
                fontSize: FontSettings.shared.bodySize,
                statusText: statusText(vm),
                draft: tab.promptDraft,
                onDraftChange: { tab.promptDraft = $0 },
                onSubmit: submit,
                onAbort: { Task { try? await vm.abort() } }
            )
            .frame(height: 104)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $tab.showingHistory) {
            SessionHistorySheet(cwd: tab.cwd, viewModel: vm)
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
                        tab.promptDraft = message
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

    /// The live status readout shown in very light gray at the bottom-right of
    /// the prompt input: context-window usage, the current model, and the
    /// current thinking level. Composed here from the session's observable
    /// state (SwiftUI re-evaluates on change), so the AppKit prompt bar just
    /// displays the string.
    private func statusText(_ vm: SessionViewModel) -> String {
        var parts: [String] = []
        if let percent = vm.contextUsage?.percent {
            parts.append("ctx \(Int(percent.rounded()))%")
        }
        if let name = vm.model?.name ?? vm.model?.id {
            parts.append(name)
        }
        if let level = vm.thinkingLevel {
            parts.append(level)
        }
        return parts.joined(separator: " · ")
    }
}

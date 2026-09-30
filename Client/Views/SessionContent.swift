import AppKit
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
    /// Height of the floating tab panel above this content. The conversation
    /// transcript insets by it so rows scroll under the glass; the Changes
    /// page (a split view with its own sidebar and header) is pushed below it.
    var topInset: CGFloat = 0
    /// The measured height of the floating prompt cluster (banners + resize
    /// handle + input): the transcript's bottom content inset and the Changes
    /// page's bottom padding.
    @State private var promptBarHeight: CGFloat = 0

    var body: some View {
        let vm = tab.viewModel
        // The pages fill the whole content area; the prompt cluster FLOATS
        // over their bottom edge (content scrolls and bleeds under it) instead
        // of stacking below and shrinking the transcript's frame.
        ZStack(alignment: .bottom) {
            // Two pages stay mounted so switching between them is a pure
            // visibility flip, never a rebuild:
            //  - The transcript must NOT be torn down on a page switch: a
            //    re-created transcript used to show a blank conversation until
            //    a tab switch forced a reload (the reported bug). It stays
            //    alive and hidden while the Changes page is up;
            //    `isPageActive` gates its per-delta work (zero while hidden,
            //    one catch-up pass on return — the occlusion machinery).
            //  - The Changes viewer is kept alive the same way so its state
            //    (scroll position, per-file expansion, selection) survives page
            //    switches and its warm listing starts as soon as the session
            //    does; it defers its git refreshes and diff loads while hidden
            //    behind the conversation, so switching to it is a visibility
            //    flip and it never loads a diff off-screen.
            ZStack {
                conversationPage
                    .opacity(tab.page == .conversation ? 1 : 0)
                    .allowsHitTesting(tab.page == .conversation)
                    .accessibilityHidden(tab.page != .conversation)
                // The Changes page stays mounted so switching to it is a pure
                // visibility flip, never a rebuild; it defers its diff loads and
                // rebuilds while hidden behind the conversation. The
                // `GeometryReader` pins it to the slot's CONCRETE size before the
                // representables are measured, so the unbounded document text
                // view can never inflate the page past its slot (belt to the
                // `sizeThatFits` braces on the viewer).
                GeometryReader { proxy in
                    ChangesView(store: tab.changes, pageActive: tab.page == .changes, bottomInset: promptBarHeight)
                        .id(tab.id)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
                // The Changes page owns its own floating diff header and a
                // sidebar, so it sits BELOW the tab panel. It extends to the
                // bottom edge (the diff document carries the prompt bar as a
                // bottom inset) so the code bleeds under the floating bar.
                .padding(.top, topInset)
                .opacity(tab.page == .changes ? 1 : 0)
                .allowsHitTesting(tab.page == .changes)
                .accessibilityHidden(tab.page != .changes)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            floatingPromptBar(vm)
        }
        .onPreferenceChange(PromptBarHeightKey.self) { promptBarHeight = $0 }
        .sheet(isPresented: $tab.showingHistory) {
            SessionHistorySheet(cwd: tab.cwd, viewModel: vm)
        }
        // Opening a review surface re-checks the working tree: the changed list
        // is only as fresh as the store's last snapshot, and an out-of-band
        // change (a git command run in a terminal) produces no pi file event to
        // refresh it. The viewer's own live diff then can never disagree with
        // the list beside it. The full re-check runs when the app returns to the
        // foreground and when a review surface opens; a TAB switch only
        // re-counts the badge (the count is visible on every page) — reloading
        // every diff on a switch is the tab-switch recompute, and the incoming
        // tab's viewer re-applies its cached document instead.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            tab.refreshWorkingTree()
        }
        .onChange(of: tab.id) { _, _ in
            tab.refreshGitCount()
        }
        .onChange(of: tab.page) { _, page in
            if page != .conversation { tab.refreshWorkingTree() }
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

    /// The floating prompt cluster: banners, the resize handle, and the input
    /// as ONE glass surface pinned to the content's bottom edge. Content
    /// scrolls/bleeds under its masked top; the transcript's bottom inset is
    /// its measured height, so nothing important hides behind it.
    private func floatingPromptBar(_ vm: SessionViewModel) -> some View {
        VStack(spacing: 0) {
            // Error surfacing: a disconnected agent or the last send failure
            // (auth/preflight/network) — never silently swallowed. As an
            // overlay in the floating cluster it no longer resizes the
            // transcript's frame on every appear/disappear.
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
            // PromptBarMetrics. It floats as part of the cluster rather than
            // sitting as a separate hairline strip above the input.
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
                    // height with the resize handle. Grow only: a re-measure
                    // when the input merely gains focus must never shrink the
                    // bar; a cleared prompt snaps back to the compact minimum.
                    guard !tab.promptHeightIsCustom else { return }
                    if needed <= 0 {
                        tab.promptHeight = PromptBarMetrics.minHeight
                    } else {
                        tab.promptHeight = PromptBarMetrics.clamp(
                            max(tab.promptHeight, needed, PromptBarMetrics.minHeight)
                        )
                    }
                }
            )
            .frame(height: tab.promptHeight)
            // The composer's Liquid Glass surface, as a BACKGROUND so the focus
            // system never treats the glass as the focused control.
            //
            // AppKit Liquid Glass (`NSGlassEffectView`, see `GlassBackground`),
            // NOT SwiftUI's `.glassEffect`: the SwiftUI modifier renders through
            // the hosting tree and re-renders the whole sampled backdrop (the
            // session) whenever the content behind it changes — the whole-window
            // Quartz Debug tint during a stream and while scrolling.
            //
            // NOTE: never wrap this chain in a `GlassEffectContainer`. The
            // container captures its content to render; the composer is an
            // `NSViewRepresentable` (a live `NSTextView`), and capturing it
            // blanks the view and breaks typing.
            .background {
                GlassBackground(shape: .roundedRectangle(cornerRadius: WindowChrome.cornerRadius))
            }
            // The model / context / thinking readout, on the composer's own
            // glass at the bottom-right — no glass of its own (a nested second
            // glass would have to sample the composer's glass, which Liquid
            // Glass cannot do consistently). A separate view so a context-usage
            // poll re-renders only the pill, never the session body.
            .overlay(alignment: .bottomTrailing) {
                PromptStatusPill(vm: vm)
                    .padding(.trailing, 8)
                    .padding(.bottom, 5)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: PromptBarHeightKey.self, value: proxy.size.height)
            }
        }
    }

    /// The model / context / thinking readout at the composer's bottom-right,
    /// drawn on the composer's own Liquid Glass (it deliberately carries no
    /// glass of its own — see `floatingPromptBar`). A separate view so a
    /// context-usage poll re-renders only this pill, never the whole session
    /// body.
    private struct PromptStatusPill: View {
        let vm: SessionViewModel

        var body: some View {
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .accessibilityLabel(text)
            }
        }

        private var text: String {
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

    /// The conversation page: transcript (AppKit) + its in-page overlays.
    /// Kept mounted across page switches (hidden while the Changes page is up)
    /// so the transcript's coordinator, per-session height caches, and scroll
    /// position survive — rebuilding it per switch was the blank-transcript
    /// bug (a fresh table was never told to render already-stored rows until a
    /// tab switch forced a reload).
    private var conversationPage: some View {
        let vm = tab.viewModel
        return ZStack {
            // No SwiftUI background behind the transcript: the AppKit scroll
            // view/table now draw the opaque page colour themselves (see
            // `TranscriptView.makeScrollView`). A clear AppKit surface over a
            // SwiftUI fill made the compositor blend two surfaces across the
            // whole streaming area.
            TranscriptView(viewModel: vm, isPageActive: tab.page == .conversation, topInset: topInset, bottomInset: promptBarHeight)
            if vm.isReloading {
                // In-app spinner while the store rebuilds the whole
                // history off the main thread (no system beachball).
                // AppKit spinner (see `SpinnerView`), never SwiftUI's
                // animated `ProgressView` — this overlay sits inside the
                // window content hosting view, so a SwiftUI spinner would
                // keep the whole shell graph invalidating per frame for
                // the entire rebuild.
                HStack(spacing: 6) {
                    SpinnerView()
                    Text("Reloading session…")
                        .font(.system(size: 11))
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            if vm.isFetchingOlder {
                // Small spinner pinned to the top of the conversation
                // while the coordinator fetches a block of older
                // history (scrolling up). AppKit spinner, as above.
                VStack {
                    SpinnerView()
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // Liquid Glass so the banner's text never fights the conversation/diff
        // behind it; the red tint rides the glass instead of a flat fill.
        // AppKit glass — see `GlassBackground`.
        .background {
            GlassBackground(
                shape: .roundedRectangle(cornerRadius: WindowChrome.cornerRadius),
                tint: NSColor.systemRed.withAlphaComponent(0.35)
            )
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
        .background { GlassBackground(shape: .roundedRectangle(cornerRadius: WindowChrome.cornerRadius)) }
    }
}

/// Reports the floating prompt cluster's height to `SessionContent`, which
/// passes it to the transcript as a bottom content inset (and pads the Changes
/// page by it) so nothing hides behind the floating bar.
private struct PromptBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

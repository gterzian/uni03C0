import AppKit
import Core
import SwiftUI

/// The prompt bar: an `NSTextView` (multi-line, internal scroll) with
/// Tab-triggered local-filesystem path completion (§4). Completion is a
/// borderless child window so the text view keeps keyboard focus and handles
/// Tab/arrows/Return/Esc itself — no key-focus fights with a popover.
struct PromptInputView: NSViewRepresentable {
    typealias Coordinator = PromptCoordinator

    let cwd: URL
    let isEnabled: Bool
    let fontSize: CGFloat
    /// Live status readout (context %, model, thinking level) shown in very
    /// light gray at the bottom-right inside the prompt bar. Empty hides it.
    let statusText: String
    /// Mirror of the input's text (kept in sync by `onDraftChange`), used to
    /// restore queued steering into the input for editing.
    let draft: String
    /// One-shot "append this text to the input" requests (queued steering
    /// restored after an abort / from the banner). Applied exactly once per
    /// unique `id`; appends at the end and never disturbs an in-flight
    /// streamed paste.
    let restoreRequest: RestoreRequest?
    let onDraftChange: (String) -> Void
    let onSubmit: (String) -> Void
    let onAbort: () -> Void
    /// Reports the height the input's content needs (grows as text wraps), so
    /// the owning view can auto-grow the prompt bar.
    let onContentHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> PromptCoordinator {
        PromptCoordinator(
            cwd: cwd,
            onSubmit: onSubmit,
            onAbort: onAbort,
            onDraftChange: onDraftChange,
            onContentHeightChange: onContentHeightChange
        )
    }

    func makeNSView(context: Context) -> PromptContainerView {
        let container = PromptContainerView()
        container.textView.promptHandler = context.coordinator
        context.coordinator.attach(container: container)
        return container
    }

    func updateNSView(_ nsView: PromptContainerView, context: Context) {
        context.coordinator.cwd = cwd
        context.coordinator.isEnabled = isEnabled
        // Refresh the action closures: the representable is reused across tab
        // switches (same structural identity), so the coordinator must target
        // the currently active session, not the one it was created for.
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onAbort = onAbort
        context.coordinator.onDraftChange = onDraftChange
        context.coordinator.onContentHeightChange = onContentHeightChange
        nsView.textView.isEditable = isEnabled && !context.coordinator.pasteActive
        nsView.textView.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
        nsView.statusLabel.stringValue = statusText
        nsView.statusLabel.isHidden = statusText.isEmpty
        if nsView.textView.font?.pointSize != fontSize {
            nsView.textView.font = .systemFont(ofSize: fontSize)
        }
        // An external draft is applied only when it differs from the last
        // mirrored value. `lastMirroredDraft` shares its buffer with
        // `tab.promptDraft` (both hold the same String value), so the equality
        // check is O(1) when in sync — never a per-frame O(document) compare
        // (which jittered the resize drag on large prompts). While a paste is
        // windowed the text view shows a slice of the full store — the draft
        // (the full text) legitimately differs, so the sync is suppressed and
        // the window is never clobbered.
        if !context.coordinator.pasteActive, draft != context.coordinator.lastMirroredDraft {
            context.coordinator.setText(draft, in: nsView)
            // Re-seed with the draft's own value (same buffer as the owning
            // view's copy) so the fast path holds across re-renders.
            context.coordinator.lastMirroredDraft = draft
        }
        // One-shot restores: append the queued text at the end (push-back).
        // Guarded by the request id so a re-render never appends twice.
        if let restore = restoreRequest, restore.id != context.coordinator.lastRestoreID {
            context.coordinator.lastRestoreID = restore.id
            context.coordinator.appendText(restore.text, in: nsView)
        }
    }
}

// MARK: - Container

final class PromptContainerView: NSView {
    let textView = PromptTextView()
    /// Very-light-gray status readout pinned to the bottom-right inside the
    /// prompt bar: context %, model, thinking level. Purely decorative — it
    /// never intercepts clicks or keys. The scroll view's bottom inset
    /// reserves a strip taller than this label, so text can never scroll
    /// underneath it.
    let statusLabel = NSTextField(labelWithString: "")
    /// Small spinner shown while a windowed paste is active.
    let streamingIndicator = NSProgressIndicator()
    /// Dismisses a windowed paste (✕ next to the spinner): empties the input
    /// and exits windowed mode.
    let pasteClearButton = NSButton()
    let scrollView = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        // The input is rounded to match the window's own corner radius — the
        // old bezel border left square corners that clashed with the window's
        // rounded bottom edge. The background + border colors are dynamic
        // (light/dark), so they're applied via `applyInputAppearance` and
        // refreshed when the appearance changes.
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        // Reserve the bottom strip for the status readout so typed text never
        // scrolls under it. 26pt clears the label (top edge ~16pt up) by ~10pt
        // even for descenders on the last line.
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 26, right: 0)

        textView.isEditable = true
        textView.isRichText = false
        textView.drawsBackground = false
        // No automatic text-system features: the prompt carries code and
        // pasted text, so autocorrect, smart quotes/dashes, link detection and
        // — critically — continuous spell checking are all off. The spell
        // checker runs on a background queue (NSTextCheckingOperationQueue)
        // and CoreNLP's language-ID asserts on large pastes, crashing the app
        // (verified).
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = .systemFont(ofSize: 13)
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        statusLabel.isHidden = true

        streamingIndicator.style = .spinning
        streamingIndicator.controlSize = .small
        streamingIndicator.isHidden = true
        streamingIndicator.translatesAutoresizingMaskIntoConstraints = false

        pasteClearButton.isBordered = false
        pasteClearButton.title = "✕"
        pasteClearButton.font = .systemFont(ofSize: 9)
        pasteClearButton.contentTintColor = .secondaryLabelColor
        pasteClearButton.isHidden = true
        pasteClearButton.translatesAutoresizingMaskIntoConstraints = false
        pasteClearButton.toolTip = "Discard the pasted text"

        addSubview(scrollView)
        addSubview(statusLabel)
        addSubview(streamingIndicator)
        addSubview(pasteClearButton)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            streamingIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            streamingIndicator.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            pasteClearButton.trailingAnchor.constraint(equalTo: streamingIndicator.leadingAnchor, constant: -6),
            pasteClearButton.centerYAnchor.constraint(equalTo: streamingIndicator.centerYAnchor),
        ])
        applyInputAppearance()
    }

    /// The window's corner radius, matched by the prompt input so the two
    /// read as one surface instead of a square field poking into a rounded
    /// window.
    private static let cornerRadius: CGFloat = 10

    /// Rounds the input and paints its background/border. Layer colors don't
    /// follow the effective appearance automatically, so this re-runs on
    /// light/dark changes.
    private func applyInputAppearance() {
        guard let layer = scrollView.layer else { return }
        layer.cornerRadius = Self.cornerRadius
        layer.borderWidth = 1
        layer.borderColor = NSColor.separatorColor.cgColor
        layer.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer.masksToBounds = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyInputAppearance()
    }
}

// MARK: - Text view

final class PromptTextView: NSTextView {
    weak var promptHandler: PromptCoordinator?

    override func keyDown(with event: NSEvent) {
        if let handler = promptHandler, handler.handleKey(event, in: self) {
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Coordinator

final class PromptCoordinator: NSObject, NSTextViewDelegate {
    /// The text view never holds more than this many UTF-16 units of a pasted
    /// document. Pastes above this size become a windowed paste (the full text
    /// lives in a store, a bounded window in the text view), so layout stays
    /// bounded and the main thread is never blocked — the conversation keeps
    /// scrolling while the paste is windowed.
    private static let pasteWindowBudget = 65_536

    var cwd: URL
    var isEnabled = true
    var onSubmit: (String) -> Void
    var onAbort: () -> Void
    var onDraftChange: (String) -> Void
    var onContentHeightChange: (CGFloat) -> Void

    private weak var container: PromptContainerView?
    private var completionWindow: CompletionWindowController?
    private var completionItems: [String] = []
    private var completionSelected = 0
    private var tokenStart: Int?
    /// Local key monitor making Esc abort whenever the main window is front,
    /// not just when the prompt input has focus. Falls back to the text view's
    /// own Esc handling (completion dismiss → abort) when it is first
    /// responder, so nothing double-fires.
    ///
    /// `nonisolated(unsafe)`: installed only on the main thread (from `attach`),
    /// and deinit runs only after the last reference is dropped — so the read
    /// from the nonisolated deinit never races the write.
    private nonisolated(unsafe) var escapeMonitor: Any?

    init(
        cwd: URL,
        onSubmit: @escaping (String) -> Void,
        onAbort: @escaping () -> Void,
        onDraftChange: @escaping (String) -> Void,
        onContentHeightChange: @escaping (CGFloat) -> Void
    ) {
        self.cwd = cwd
        self.onSubmit = onSubmit
        self.onAbort = onAbort
        self.onDraftChange = onDraftChange
        self.onContentHeightChange = onContentHeightChange
    }

    deinit {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    func attach(container: PromptContainerView) {
        self.container = container
        container.textView.delegate = self
        completionWindow = CompletionWindowController()
        completionWindow?.parentView = container
        installEscapeMonitor()
        container.pasteClearButton.target = self
        container.pasteClearButton.action = #selector(clearPasteButtonClicked)
        // The paste-window slides and the spinner track the scroll position.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(streamScrollDidChange),
            name: NSView.boundsDidChangeNotification,
            object: container.scrollView.contentView
        )
    }

    @objc private func streamScrollDidChange() {
        updateStreamingIndicator()
        slidePasteWindow()
    }

    /// Esc aborts the in-flight turn (thinking + tools) whenever this window is
    /// key, regardless of where focus is. It defers to the text view when the
    /// prompt input has focus (Esc there dismisses path completion first), and
    /// passes through while a popup menu or sheet is up so Esc closes those
    /// instead of aborting.
    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            guard let self, let container = self.container, let window = container.window else { return event }
            // Window not front (or a sheet is up): let the key window handle Esc.
            guard window.isKeyWindow, window.attachedSheet == nil else { return event }
            // A VISIBLE popup-menu-level window means a dropdown (or the path
            // completion list) is tracking: let Esc close it instead of
            // aborting. NB: ordered-out windows are still in NSApp.windows —
            // the completion window lives hidden at .popUpMenu level for the
            // whole session and would otherwise swallow every Esc.
            guard !NSApp.windows.contains(where: { $0.level == .popUpMenu && $0.isVisible }) else { return event }
            // Prompt input has focus: its own Esc handling (completion → abort)
            // runs; don't fire the abort twice.
            if window.firstResponder === container.textView { return event }
            self.onAbort()
            // After aborting, focus the prompt input so typing can start
            // immediately (the next Return sends, or queues as steering if the
            // turn hasn't fully settled yet).
            container.window?.makeFirstResponder(container.textView)
            return nil
        }
    }

    var textView: PromptTextView? { container?.textView }

    // MARK: - Key handling (returns true if consumed)

    func handleKey(_ event: NSEvent, in textView: NSTextView) -> Bool {
        switch event.keyCode {
        case 48: // Tab
            if completionActive {
                moveSelection(by: 1)
                return true
            }
            if isEnabled, tryCompletePath(in: textView) {
                return true
            }
            return false

        case 125: // Down
            if completionActive {
                moveSelection(by: 1)
                return true
            }
            return false

        case 126: // Up
            if completionActive {
                moveSelection(by: -1)
                return true
            }
            return false

        case 36: // Return
            if completionActive {
                commitCompletion(in: textView)
                return true
            }
            if event.modifierFlags.contains(.shift) {
                return false // default: insert newline
            }
            if isEnabled {
                submit(from: textView)
                return true
            }
            return false

        case 53: // Escape
            if completionActive {
                dismissCompletion()
                return true
            }
            // Esc aborts the in-flight turn (thinking + tools); idle is a
            // harmless no-op on the pi side. The text view already has focus.
            onAbort()
            return true

        case 8: // C
            // Ctrl+C clears the draft (terminal-style interrupt); Cmd+C still
            // copies via the default key binding.
            if event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command) {
                textView.string = ""
                onDraftChange("")
                return true
            }
            return false

        default:
            return false
        }
    }

    var completionActive: Bool {
        completionWindow?.isVisible == true && tokenStart != nil
    }

    // MARK: - Completion

    private func tryCompletePath(in textView: NSTextView) -> Bool {
        guard let (range, fragment) = currentPathToken(in: textView) else { return false }
        guard PathCompletion.isPathLike(fragment) else { return false }

        let candidates = PathCompletion.candidates(for: fragment, cwd: cwd)
        guard !candidates.isEmpty else { return false } // let Tab do its normal thing

        if candidates.count == 1 {
            replaceToken(range, with: candidates[0], in: textView)
            return true
        }

        tokenStart = range.location
        completionItems = candidates
        completionSelected = 0
        showCompletionWindow()
        return true
    }

    private func currentPathToken(in textView: NSTextView) -> (NSRange, String)? {
        let text = textView.string as NSString
        let cursor = textView.selectedRange().location
        guard cursor > 0, cursor <= text.length else { return nil }
        var start = cursor
        while start > 0 {
            let ch = text.character(at: start - 1)
            if ch == 32 || ch == 9 || ch == 10 || ch == 13 { break }
            start -= 1
        }
        guard start < cursor else { return nil }
        let range = NSRange(location: start, length: cursor - start)
        return (range, text.substring(with: range))
    }

    private func replaceToken(_ range: NSRange, with replacement: String, in textView: NSTextView) {
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        let newCursor = range.location + (replacement as NSString).length
        textView.setSelectedRange(NSRange(location: newCursor, length: 0))
        tokenStart = nil
    }

    private func moveSelection(by delta: Int) {
        guard !completionItems.isEmpty else { return }
        completionSelected = (completionSelected + delta + completionItems.count) % completionItems.count
        completionWindow?.selectRow(completionSelected)
    }

    private func commitCompletion(in textView: NSTextView) {
        guard completionActive, let start = tokenStart,
              completionItems.indices.contains(completionSelected) else {
            dismissCompletion()
            return
        }
        let replacement = completionItems[completionSelected]
        let cursor = textView.selectedRange().location
        let range = NSRange(location: start, length: cursor - start)
        dismissCompletion()
        replaceToken(range, with: replacement, in: textView)
    }

    private func showCompletionWindow() {
        guard let textView, let completionWindow, let start = tokenStart else { return }
        let cursorRect = textView.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
        completionWindow.show(items: completionItems, cursorScreenRect: cursorRect, in: textView)
    }

    private func dismissCompletion() {
        completionWindow?.hide()
        tokenStart = nil
        completionItems = []
    }

    /// The id of the last applied restore request (one-shot append).
    var lastRestoreID: UUID?

    // MARK: - Text replacement (e.g. restoring queued steering for editing)

    func setText(_ text: String, in container: PromptContainerView) {
        dismissCompletion()
        let textView = container.textView
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        container.window?.makeFirstResponder(textView)
    }

    /// Appends text at the end of the input (push-back) — used when queued
    /// steering is restored. Goes through the text system (`insertText`), so
    /// undo, the caret, the draft mirror, and the scroll behavior all stay
    /// consistent. During a windowed paste the text is appended to the store
    /// (and the window re-shown at the new tail), so a submit includes it.
    func appendText(_ text: String, in container: PromptContainerView) {
        guard !text.isEmpty else { return }
        dismissCompletion()
        if pasteActive {
            appendToPasteStore(text)
            container.window?.makeFirstResponder(container.textView)
            return
        }
        let textView = container.textView
        let end = (textView.string as NSString).length
        textView.insertText(text, replacementRange: NSRange(location: end, length: 0))
        textView.setSelectedRange(NSRange(location: end + (text as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        container.window?.makeFirstResponder(textView)
    }

    // MARK: - Submit

    private func submit(from textView: NSTextView) {
        dismissCompletion()
        // A windowed paste submits the FULL store; otherwise the text view
        // holds the whole input.
        let source = pasteActive ? (pasteFullText ?? textView.string) : textView.string
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearPasteWindow()
            return
        }
        textView.string = ""
        clearPasteWindow()
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        onDraftChange("")
        lastMirroredDraft = ""
        // The prompt cleared: report an empty content height so the bar snaps
        // back to its minimum (unless the user has pinned it).
        onContentHeightChange(0)
        onSubmit(trimmed)
    }

    /// The height the input's content currently needs: laid-out text plus the
    /// vertical container inset. Deterministic (no frame reliance) so it can be
    /// measured right inside `textDidChange`.
    private func contentHeight(of textView: NSTextView) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return 0 }
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2 + 6
    }

    /// The last draft value mirrored up to the owning view. `onDraftChange`
    /// and this property are set from the SAME String value, so the owning
    /// view's copy (`tab.promptDraft`) shares its buffer here — the
    /// `draft != lastMirroredDraft` check in `updateNSView` then short-circuits
    /// in O(1). Without this, every update (e.g. at drag frequency while
    /// resizing) rebuilt the text view's string and compared two buffers
    /// O(document) — the jiggle on large prompts.
    var lastMirroredDraft = ""

    // MARK: - Windowed paste (large pastes)

    /// The full pasted document — the "store". Kept as plain string data,
    /// never laid out; the text view holds only a bounded window of it.
    private var pasteFullText: String?
    /// Start offset (UTF-16) of the window currently in the text view.
    private var pasteWindowStart = 0
    /// True while a windowed paste is active: the input is read-only (editing
    /// a slice would desync it from the store), the spinner is shown, and
    /// Enter submits the full store.
    private(set) var pasteActive = false
    /// Re-entrancy guard for window slides (the re-anchor scroll re-fires the
    /// scroll observer).
    private var isSlidingPaste = false
    /// Cooldown so the re-anchor scroll (which can land at a window edge)
    /// never immediately re-triggers a slide in the opposite direction.
    private var lastSlideTime: TimeInterval = 0

    /// Enters windowed mode for a very large paste: the full text (prefix +
    /// replacement + suffix) is stored, the text view shows only the last
    /// `pasteWindowBudget` units scrolled to the bottom, and the input is
    /// disabled. Scrolling slides the window; Enter submits the full store.
    private func beginWindowedPaste(range: NSRange, replacement: String) {
        guard let textView, let storage = textView.textStorage else { return }
        dismissCompletion()
        let current = textView.string as NSString
        let prefix = current.substring(to: range.location)
        let suffix = current.substring(from: range.location + range.length)
        let full = prefix + replacement + suffix

        let start = StreamedPaste.initialWindowStart(
            fullLength: (full as NSString).length,
            budget: Self.pasteWindowBudget
        )
        let window = StreamedPaste.windowText(fullText: full, windowStart: start, budget: Self.pasteWindowBudget)

        pasteFullText = full
        pasteWindowStart = start
        pasteActive = true
        updateEditableState()

        storage.setAttributedString(NSAttributedString(string: window))
        let end = (window as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        container?.window?.makeFirstResponder(textView)

        // The draft is the FULL text (the submit source), mirrored once.
        let mirrored = full
        onDraftChange(mirrored)
        lastMirroredDraft = mirrored

        // The bar goes to its maximum; the windowed content scrolls internally.
        onContentHeightChange(PromptBarMetrics.maxHeight)
        updateStreamingIndicator()
    }

    /// Slides the window when the user scrolls to the top or bottom of the
    /// materialized slice, keeping the reading position continuous. Layout is
    /// bounded to the window budget regardless of the paste size, so the main
    /// thread is never blocked and the conversation keeps scrolling.
    private func slidePasteWindow() {
        guard !isSlidingPaste, pasteActive, let full = pasteFullText,
              let scrollView = container?.scrollView else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSlideTime > 0.25 else { return } // the re-anchor scroll
        isSlidingPaste = true
        defer { isSlidingPaste = false }

        let fullLength = (full as NSString).length
        let budget = Self.pasteWindowBudget
        let oldStart = pasteWindowStart
        let docHeight = scrollView.documentView?.frame.height ?? 0
        let visible = scrollView.documentVisibleRect

        if visible.minY <= 2, oldStart > 0 {
            // Near the top: slide toward the head; the old window's first line
            // (offset oldStart - newStart in the new window) stays at the top.
            let newStart = StreamedPaste.slideWindowStart(fullText: full, windowStart: oldStart, budget: budget, directionUp: true)
            replaceWindow(from: newStart, anchor: .top(offset: oldStart - newStart))
            lastSlideTime = now
        } else if docHeight - visible.maxY <= 2, oldStart + budget < fullLength {
            // Near the bottom: slide toward the tail; the new window's first
            // line anchors to the viewport top, so the content flows like
            // paging down.
            let newStart = StreamedPaste.slideWindowStart(fullText: full, windowStart: oldStart, budget: budget, directionUp: false)
            replaceWindow(from: newStart, anchor: .top(offset: 0))
            lastSlideTime = now
        }
    }

    private enum PasteAnchor {
        case top(offset: Int) // pin the line at `offset` to the viewport top
    }

    /// Replaces the text view's content with the window at `newStart` and
    /// re-anchors so reading stays continuous.
    private func replaceWindow(from newStart: Int, anchor: PasteAnchor) {
        guard let full = pasteFullText, let textView, let scrollView = container?.scrollView else { return }
        let window = StreamedPaste.windowText(fullText: full, windowStart: newStart, budget: Self.pasteWindowBudget)
        pasteWindowStart = newStart
        textView.textStorage?.setAttributedString(NSAttributedString(string: window))
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        guard let offset = anchorOffset(anchor) else { return }
        guard let y = lineY(forCharacterOffset: offset, in: textView) else { return }
        // Pin the anchor line to the viewport top (both slide directions page
        // from the top: up-slides pin the old window's first line, down-slides
        // pin the new window's first line).
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateStreamingIndicator()
    }

    private func anchorOffset(_ anchor: PasteAnchor) -> Int? {
        switch anchor {
        case .top(let offset):
            return offset
        }
    }

    /// The document-coordinate Y of the line containing `charOffset`.
    private func lineY(forCharacterOffset offset: Int, in textView: NSTextView) -> CGFloat? {
        guard let layoutManager = textView.layoutManager else { return nil }
        let length = (textView.string as NSString).length
        guard length > 0 else { return 0 }
        let clamped = min(max(0, offset), length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: clamped)
        return layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    /// Appends text to the paste store and re-windows to the new tail (used
    /// for queued-steering restores and a second large paste while windowed).
    private func appendToPasteStore(_ text: String) {
        guard pasteActive, var full = pasteFullText else { return }
        full += text
        pasteFullText = full
        let newStart = StreamedPaste.initialWindowStart(fullLength: (full as NSString).length, budget: Self.pasteWindowBudget)
        replaceWindow(from: newStart, anchor: .top(offset: 0))
        // The window now ends at the store's end; show the appended text.
        scrollToBottom()
        let mirrored = full
        onDraftChange(mirrored)
        lastMirroredDraft = mirrored
    }

    /// Scrolls the input's scroll view to the bottom of its document.
    private func scrollToBottom() {
        guard let scrollView = container?.scrollView,
              let document = scrollView.documentView else { return }
        let target = max(0, document.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Exits windowed mode: the input becomes editable again, the spinner and
    /// clear button hide. Callers that clear the paste also empty the text
    /// view.
    private func clearPasteWindow() {
        pasteActive = false
        pasteFullText = nil
        pasteWindowStart = 0
        updateEditableState()
        updateStreamingIndicator()
    }

    /// The paste spinner + clear button: visible whenever a windowed paste is
    /// active (the text view shows a slice of a larger document).
    private func updateStreamingIndicator() {
        guard let container else { return }
        let show = pasteActive
        let indicator = container.streamingIndicator
        if show != !indicator.isHidden {
            indicator.isHidden = !show
            if show {
                indicator.startAnimation(nil)
            } else {
                indicator.stopAnimation(nil)
            }
        }
        container.pasteClearButton.isHidden = !show
    }

    /// The text view is editable only when the session is enabled AND no
    /// windowed paste is active (editing a slice would desync it from the
    /// store).
    private func updateEditableState() {
        guard let textView = container?.textView else { return }
        textView.isEditable = isEnabled && !pasteActive
    }

    /// Dismisses a windowed paste (the ✕ next to the spinner): empties the
    /// input and exits windowed mode.
    @objc private func clearPasteButtonClicked() {
        guard pasteActive, let textView = container?.textView else { return }
        textView.string = ""
        clearPasteWindow()
        onDraftChange("")
        lastMirroredDraft = ""
        onContentHeightChange(0)
    }

    // MARK: - NSTextViewDelegate

    /// Intercepts very large text insertions (paste / drop) before the text
    /// system applies them: the full text goes into a store and only a bounded
    /// window is shown, so a multi-megabyte paste never blocks the main thread.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacement = replacementString,
              (replacement as NSString).length > Self.pasteWindowBudget else {
            return true
        }
        if pasteActive {
            // A second huge paste while one is windowed: append to the store
            // and re-window to the new tail.
            appendToPasteStore(replacement)
            return false
        }
        beginWindowedPaste(range: affectedCharRange, replacement: replacement)
        return false
    }

    func textDidChange(_ notification: Notification) {
        // Keep the insertion point visible while typing: when the user has
        // scrolled up in a long prompt, NSTextView can leave new text below
        // the fold, so typing appears to hide part of the prompt. Scroll the
        // minimum needed to reveal the caret.
        if let textView {
            if pasteActive {
                // Window replacements are driven by the scroll observer
                // (slidePasteWindow): no caret yank, no draft mirror, no height
                // report. The draft already holds the full store.
                return
            }
            textView.scrollRangeToVisible(textView.selectedRange())
            // Mirror the draft up so "edit queued steering" can restore it.
            // The same String value feeds onDraftChange and
            // lastMirroredDraft, keeping the updateNSView sync check O(1).
            let mirrored = textView.string
            onDraftChange(mirrored)
            lastMirroredDraft = mirrored
            // Report the content height so the owning view can auto-grow the
            // prompt bar as the text wraps to more lines.
            onContentHeightChange(contentHeight(of: textView))
        }
        // Live-refilter while the completion list is showing.
        guard completionActive, let textView else { return }
        guard let (range, fragment) = currentPathToken(in: textView) else {
            dismissCompletion()
            return
        }
        let candidates = PathCompletion.candidates(for: fragment, cwd: cwd)
        if candidates.isEmpty {
            dismissCompletion()
            return
        }
        tokenStart = range.location
        completionItems = candidates
        completionSelected = min(completionSelected, candidates.count - 1)
        completionWindow?.show(items: candidates, cursorScreenRect: textView.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil), in: textView)
        completionWindow?.selectRow(completionSelected)
    }

    func textDidEndEditing(_ notification: Notification) {
        dismissCompletion()
    }
}

// MARK: - Completion window

/// Borderless, non-key child window with a single-column table. Keyboard
/// events stay in the text view (this window never becomes key); the
/// coordinator drives selection.
final class CompletionWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var parentView: NSView?

    private let window: NSWindow
    private let tableView = NSTableView()
    private var items: [String] = []

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.level = .popUpMenu
        window.backgroundColor = NSColor.windowBackgroundColor
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true // keyboard-only completion for v1

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: .init("candidate"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        window.contentView = scrollView
    }

    var isVisible: Bool { window.isVisible }

    func show(items: [String], cursorScreenRect: NSRect, in textView: NSTextView) {
        self.items = items
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)

        let height = min(CGFloat(items.count) * 22 + 4, 220)
        let width: CGFloat = 380
        var frame = NSRect(x: cursorScreenRect.minX, y: cursorScreenRect.minY - height - 6, width: width, height: height)

        if let screen = textView.window?.screen {
            let visible = screen.visibleFrame
            if frame.minY < visible.minY {
                frame.origin.y = cursorScreenRect.maxY + 6
            }
            if frame.maxX > visible.maxX {
                frame.origin.x = visible.maxX - width
            }
            if frame.maxY > visible.maxY {
                frame.origin.y = visible.maxY - height
            }
        }
        window.setFrame(frame, display: true)
        if let parent = parentView?.window {
            parent.addChildWindow(window, ordered: .above)
        }
        window.orderFront(nil)
    }

    func selectRow(_ index: Int) {
        guard items.indices.contains(index) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    func hide() {
        if let parent = parentView?.window {
            parent.removeChildWindow(window)
        }
        window.orderOut(nil)
    }

    // MARK: - Data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("candidate")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.lineBreakMode = .byTruncatingMiddle
            return field
        }()
        cell.stringValue = items[row]
        return cell
    }
}

// MARK: - Resize handle

/// A thin draggable strip above the prompt bar. Dragging up makes the input
/// taller (clamped by `PromptBarMetrics`); the first drag also pins the height
/// so the bar stops auto-growing with content.
///
/// Implemented as a SwiftUI `DragGesture` (not an AppKit view) so event
/// delivery is guaranteed inside the SwiftUI hierarchy, and the start height is
/// captured once per drag so the delta never double-counts across re-renders.
struct PromptResizeHandle: View {
    let currentHeight: CGFloat
    let onBegan: () -> Void
    let onResize: (CGFloat) -> Void

    @State private var isDragging = false
    @State private var dragStartHeight: CGFloat = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary.opacity(isDragging ? 0.7 : 0.4))
                .frame(width: 28, height: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 8)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartHeight = currentHeight
                        onBegan()
                    }
                    // SwiftUI y grows downward, so dragging up is a negative
                    // translation → taller bar.
                    onResize(dragStartHeight - value.translation.height)
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Drag to resize the prompt input")
    }
}

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
    let onDraftChange: (String) -> Void
    let onSubmit: (String) -> Void
    let onAbort: () -> Void

    func makeCoordinator() -> PromptCoordinator {
        PromptCoordinator(cwd: cwd, onSubmit: onSubmit, onAbort: onAbort, onDraftChange: onDraftChange)
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
        nsView.textView.isEditable = isEnabled
        nsView.textView.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
        nsView.statusLabel.stringValue = statusText
        nsView.statusLabel.isHidden = statusText.isEmpty
        if nsView.textView.font?.pointSize != fontSize {
            nsView.textView.font = .systemFont(ofSize: fontSize)
        }
        // An external draft (e.g. "edit queued steering" restored the text)
        // is applied only when it differs from what's already in the input, so
        // typing — which mirrors into `draft` — never clobbers the draft.
        if nsView.textView.string != draft {
            context.coordinator.setText(draft, in: nsView)
        }
    }
}

// MARK: - Container

final class PromptContainerView: NSView {
    let textView = PromptTextView()
    /// Very-light-gray status readout pinned to the bottom-right inside the
    /// prompt bar: context %, model, thinking level. Purely decorative — it
    /// never intercepts clicks or keys.
    let statusLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()

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
        // scrolls under it.
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 16, right: 0)

        textView.isEditable = true
        textView.isRichText = false
        textView.drawsBackground = false
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

        addSubview(scrollView)
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
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
    var cwd: URL
    var isEnabled = true
    var onSubmit: (String) -> Void
    var onAbort: () -> Void
    var onDraftChange: (String) -> Void

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

    init(cwd: URL, onSubmit: @escaping (String) -> Void, onAbort: @escaping () -> Void, onDraftChange: @escaping (String) -> Void) {
        self.cwd = cwd
        self.onSubmit = onSubmit
        self.onAbort = onAbort
        self.onDraftChange = onDraftChange
    }

    deinit {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }

    func attach(container: PromptContainerView) {
        self.container = container
        container.textView.delegate = self
        completionWindow = CompletionWindowController()
        completionWindow?.parentView = container
        installEscapeMonitor()
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
            // harmless no-op on the pi side.
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

    // MARK: - Text replacement (e.g. restoring queued steering for editing)

    func setText(_ text: String, in container: PromptContainerView) {
        dismissCompletion()
        let textView = container.textView
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        container.window?.makeFirstResponder(textView)
    }

    // MARK: - Submit

    private func submit(from textView: NSTextView) {
        dismissCompletion()
        let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        textView.string = ""
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        onDraftChange("")
        onSubmit(trimmed)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        // Keep the insertion point visible while typing: when the user has
        // scrolled up in a long prompt, NSTextView can leave new text below
        // the fold, so typing appears to hide part of the prompt. Scroll the
        // minimum needed to reveal the caret.
        if let textView {
            textView.scrollRangeToVisible(textView.selectedRange())
            // Mirror the draft up so "edit queued steering" can restore it.
            onDraftChange(textView.string)
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

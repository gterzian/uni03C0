import AppKit
import PiCore
import SwiftUI

/// The prompt bar: an `NSTextView` (multi-line, internal scroll) with
/// Tab-triggered local-filesystem path completion (§4). Completion is a
/// borderless child window so the text view keeps keyboard focus and handles
/// Tab/arrows/Return/Esc itself — no key-focus fights with a popover.
struct PromptInputView: NSViewRepresentable {
    typealias Coordinator = PromptCoordinator

    let cwd: URL
    let isEnabled: Bool
    let onSubmit: (String) -> Void
    let onAbort: () -> Void

    func makeCoordinator() -> PromptCoordinator {
        PromptCoordinator(cwd: cwd, onSubmit: onSubmit, onAbort: onAbort)
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
        nsView.textView.isEditable = isEnabled
        nsView.textView.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
    }
}

// MARK: - Container

final class PromptContainerView: NSView {
    let textView = PromptTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder

        textView.isEditable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.font = .systemFont(ofSize: 13)
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
    private let onSubmit: (String) -> Void
    private let onAbort: () -> Void

    private weak var container: PromptContainerView?
    private var completionWindow: CompletionWindowController?
    private var completionItems: [String] = []
    private var completionSelected = 0
    private var tokenStart: Int?

    init(cwd: URL, onSubmit: @escaping (String) -> Void, onAbort: @escaping () -> Void) {
        self.cwd = cwd
        self.onSubmit = onSubmit
        self.onAbort = onAbort
    }

    func attach(container: PromptContainerView) {
        self.container = container
        container.textView.delegate = self
        completionWindow = CompletionWindowController()
        completionWindow?.parentView = container
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

    // MARK: - Submit

    private func submit(from textView: NSTextView) {
        dismissCompletion()
        let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        textView.string = ""
        onSubmit(trimmed)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
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

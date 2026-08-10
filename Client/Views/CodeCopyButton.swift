import AppKit

/// The small corner "copy" button over each fenced code block in a final
/// assistant response. A ghost icon button (no fill until hover) so it blends
/// into the code card instead of reading as a separate control; clicking
/// copies the block and swaps the icon for a "Copied" label for a moment.
final class CodeCopyButton: NSButton {
    /// Must fit inside `MarkdownText.codeBlockRightReserve` (the strip the
    /// code text wraps early to leave at the block's right edge).
    static let size = NSSize(width: 40, height: 20)

    private let code: String
    private var copied = false
    private var hovered = false
    private var revertTimer: Timer?
    private var trackingArea: NSTrackingArea?

    init(code: String) {
        self.code = code
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(copyPressed)
        toolTip = "Copy code"
        setAccessibilityLabel("Copy code")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Subtle rounded backdrop on hover / while showing the feedback.
        if hovered || copied {
            let rect = bounds.insetBy(dx: 5, dy: 3)
            NSColor.secondaryLabelColor.withAlphaComponent(copied ? 0.22 : 0.14).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        if copied {
            let label = "Copied"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(
                at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                withAttributes: attributes
            )
        } else if let icon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") {
            // Tint with the current (dynamic) secondary color via a symbol
            // palette so the icon adapts to dark/light mode.
            let config = NSImage.SymbolConfiguration(paletteColors: [NSColor.secondaryLabelColor])
            guard let tinted = icon.withSymbolConfiguration(config) else { return }
            let rect = NSRect(x: bounds.midX - 6, y: bounds.midY - 6, width: 12, height: 12)
            tinted.draw(in: rect)
        }
    }

    @objc private func copyPressed() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        copied = true
        needsDisplay = true
        revertTimer?.invalidate()
        revertTimer = Timer.scheduledTimer(timeInterval: 1.4, target: self, selector: #selector(revertCopied), userInfo: nil, repeats: false)
    }

    @objc private func revertCopied() {
        copied = false
        needsDisplay = true
    }
}

import AppKit
import PiCore

/// A read-only, selectable multi-line text cell for user/assistant messages.
/// Backed by an `NSTextView` (selectable text, correct wrapping); the table
/// supplies the row height via `measuredHeight(forWidth:)`, and `layout()`
/// sizes the text view to match so content is never clipped.
final class TextRowView: NSView {
    enum Role {
        case user
        case assistant
    }

    private let textView = NSTextView()
    private var role: Role = .assistant

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 8
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.autoresizingMask = [.width]
        addSubview(textView)
    }

    func configure(text: String, thinking: String?, role: Role, isStreaming: Bool) {
        self.role = role
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping

        let bodyFont = NSFont.systemFont(ofSize: 13)
        let bodyColor: NSColor
        switch role {
        case .user: bodyColor = .labelColor
        case .assistant: bodyColor = .labelColor
        }

        let attributed = NSMutableAttributedString()

        if let thinking, !thinking.isEmpty {
            let thinkStyle = NSMutableParagraphStyle()
            thinkStyle.lineSpacing = 1
            let think = NSAttributedString(
                string: "💭 " + thinking,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: thinkStyle,
                ]
            )
            attributed.append(think)
            attributed.append(NSAttributedString(string: "\n\n", attributes: [.paragraphStyle: paragraph]))
        }

        attributed.append(NSAttributedString(
            string: text,
            attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: paragraph,
            ]
        ))

        if isStreaming {
            attributed.append(NSAttributedString(
                string: "▌",
                attributes: [
                    .font: bodyFont,
                    .foregroundColor: NSColor.systemBlue,
                ]
            ))
        }

        textView.textStorage?.setAttributedString(attributed)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else { return }
        let width = max(bounds.width, 320)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let height = used + textView.textContainerInset.height * 2
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(height, bounds.height))
    }
}

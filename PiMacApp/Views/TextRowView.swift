import AppKit
import PiCore

/// Single source of truth for how transcript text is styled and measured.
/// The renderer (`TextRowView`) and the height measurer both go through this,
/// so the measured row height exactly matches the rendered content — no blank
/// space at the bottom of a streaming row, no clipping.
enum TranscriptText {
    /// lineFragmentPadding 8 each side.
    static let horizontalPadding: CGFloat = 16
    /// textContainerInset 6 top + 6 bottom.
    static let verticalInset: CGFloat = 12

    static func attributedString(
        text: String,
        thinking: String?,
        role: TextRowView.Role,
        isStreaming: Bool
    ) -> NSAttributedString {
        let body = NSMutableParagraphStyle()
        body.lineSpacing = 2
        body.lineBreakMode = .byWordWrapping
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let bodyColor: NSColor = role == .user ? .labelColor : .labelColor

        let result = NSMutableAttributedString()

        if let thinking, !thinking.isEmpty {
            let thinkStyle = NSMutableParagraphStyle()
            thinkStyle.lineSpacing = 1
            thinkStyle.lineBreakMode = .byWordWrapping
            result.append(NSAttributedString(string: "💭 " + thinking, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: thinkStyle,
            ]))
            // Only separate thinking from text when there is actual text; while
            // thinking (empty text) the cursor sits directly after the thinking
            // so pin-to-bottom shows the reasoning stream, not blank space.
            if !text.isEmpty {
                result.append(NSAttributedString(string: "\n\n", attributes: [.paragraphStyle: body]))
            }
        }
        if !text.isEmpty {
            result.append(NSAttributedString(string: text, attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: body,
            ]))
        }
        if isStreaming {
            result.append(NSAttributedString(string: "▌", attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.systemBlue,
            ]))
        }
        return result
    }

    static func measuredHeight(
        text: String,
        thinking: String?,
        role: TextRowView.Role,
        isStreaming: Bool,
        width: CGFloat
    ) -> CGFloat {
        let attributed = attributedString(text: text, thinking: thinking, role: role, isStreaming: isStreaming)
        guard attributed.length > 0 else { return 30 }
        let usableWidth = max(width - horizontalPadding, 60)
        let bounds = attributed.boundingRect(
            with: NSSize(width: usableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // +2px slack so the text view's layout-manager height never exceeds the
        // measured height (which would clip the last line).
        return ceil(bounds.height) + verticalInset + 2
    }
}

/// A read-only, selectable multi-line text cell for user/assistant messages.
/// Backed by an `NSTextView` (selectable text, correct wrapping); the table
/// supplies the row height via `TranscriptText.measuredHeight`, and `layout()`
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
        textView.textStorage?.setAttributedString(
            TranscriptText.attributedString(text: text, thinking: thinking, role: role, isStreaming: isStreaming)
        )
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

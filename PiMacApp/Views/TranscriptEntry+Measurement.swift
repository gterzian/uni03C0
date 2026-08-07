import AppKit
import PiCore

/// Deterministic height measurement for transcript rows. Must stay in sync
/// with how `TextRowView` / `ToolCallCardView` render. Cached per
/// (id, width) in the transcript coordinator's `HeightCache`, so measurement
/// runs once per genuine content change — never per frame.
extension TranscriptEntryKind {
    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        switch self {
        case .userMessage(let text):
            return Self.textHeight(text, font: .systemFont(ofSize: 13), width: width, verticalInset: 12)

        case .assistantMessage(let text, let thinking, _):
            var height = Self.textHeight(text, font: .systemFont(ofSize: 13), width: width, verticalInset: 12)
            if !thinking.isEmpty {
                height += Self.textHeight(thinking, font: .systemFont(ofSize: 12), width: width - 16, verticalInset: 0) + 14
            }
            return max(height, 30)

        case .toolCall(let card):
            return Self.toolCallHeight(card, width: width)
        }
    }

    /// Matches TextRowView: lineFragmentPadding 8 each side, textContainerInset
    /// vertical `verticalInset` (6 top + 6 bottom = 12).
    private static func textHeight(
        _ text: String,
        font: NSFont,
        width: CGFloat,
        verticalInset: CGFloat
    ) -> CGFloat {
        guard !text.isEmpty else { return verticalInset + font.pointSize }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
        ])
        let usableWidth = max(width - 16, 60)
        let bounds = attributed.boundingRect(
            with: NSSize(width: usableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.height) + verticalInset
    }

    /// Matches ToolCallCardView layout: header + args (≤2 lines) + output
    /// (≤12 lines) + padding.
    private static func toolCallHeight(_ card: ToolCallCard, width: CGFloat) -> CGFloat {
        var height: CGFloat = 10 + 18 + 6 // padding + header + spacing

        if !card.arguments.isEmpty {
            height += 15 + 6 // one arg line + spacing
        }
        if !card.output.isEmpty {
            let lineHeight: CGFloat = 15
            let lines = min(lineCount(card.output), 12)
            height += CGFloat(lines) * lineHeight + 6
        } else if card.state == .running {
            height += 18 // placeholder "running…" row
        }
        return max(height + 10, 44)
    }

    private static func lineCount(_ string: String) -> Int {
        var count = 1
        for scalar in string.unicodeScalars where scalar == "\n" {
            count += 1
        }
        return count
    }
}

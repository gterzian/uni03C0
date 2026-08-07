import AppKit
import PiCore

/// Deterministic height measurement for transcript rows, driven entirely by
/// `TranscriptText` so measurement always matches rendering exactly. Cached per
/// (id, width) in the transcript coordinator's `HeightCache`; the streaming
/// row's entry is invalidated (at a throttled rate) as deltas arrive.
extension TranscriptEntryKind {
    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        switch self {
        case .userMessage(let text):
            return TranscriptText.measuredHeight(text: text, thinking: nil, role: .user, isStreaming: false, width: width)

        case .assistantMessage(let text, let thinking, let isStreaming):
            return TranscriptText.measuredHeight(text: text, thinking: thinking, role: .assistant, isStreaming: isStreaming, width: width)

        case .toolCall(let card):
            return Self.toolCallHeight(card, width: width)
        }
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

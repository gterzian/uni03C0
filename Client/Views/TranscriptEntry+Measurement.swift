import AppKit
import Core
import SwiftUI

/// Deterministic height measurement for transcript rows, driven entirely by
/// `TranscriptText` so measurement always matches rendering exactly. Cached per
/// (id, width) in the transcript coordinator's `HeightCache`; the streaming
/// row's entry is invalidated (at a throttled rate) as deltas arrive.
extension TranscriptEntry {
    /// Measures the whole row: the kind's content plus the per-turn cache line
    /// (which is entry-level data, not part of the kind).
    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        switch kind {
        case .userMessage(let text):
            return TranscriptText.measuredHeight(text: text, thinking: nil, role: .user, isStreaming: false, width: width)

        case .assistantMessage(let text, let thinking, let isStreaming):
            return TranscriptText.measuredHeight(text: text, thinking: thinking, role: .assistant, isStreaming: isStreaming, width: width, cacheHitRate: cacheHitRate, cacheMiss: cacheMiss)

        case .errorMessage(let text):
            return TranscriptText.measuredHeight(text: text, thinking: nil, role: .error, isStreaming: false, width: width)

        case .abortedMessage(let text):
            return TranscriptText.measuredHeight(text: text, thinking: nil, role: .aborted, isStreaming: false, width: width)

        case .toolCall(let card):
            return Self.toolCallHeight(card, width: width)
        }
    }

    /// Measures the real SwiftUI card layout via `NSHostingController`
    /// `sizeThatFits` — the previous line-counting estimate drifted from the
    /// actual 11pt monospaced layout and left whitespace whenever a card
    /// expanded or collapsed.
    private static func toolCallHeight(_ card: ToolCallCard, width: CGFloat) -> CGFloat {
        let view = AnyView(ToolCallCardView(
            card: card,
            isInitiallyExpanded: ToolCardExpansion.shared.isExpanded(card.id)
        ))
        let controller = NSHostingController(rootView: view)
        let size = controller.sizeThatFits(in: NSSize(width: max(width, 320), height: .greatestFiniteMagnitude))
        // Round up so the table never clips the last line.
        return max(ceil(size.height), 44)
    }
}


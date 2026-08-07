import AppKit
import Core
import SwiftUI

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

/// Shared expansion state for tool-call cards, keyed by card id. The card's
/// expand button toggles it (through the coordinator, so the row re-measures);
/// `toolCallHeight` reads it. Lives here because it only affects measurement
/// and presentation, not the wire protocol.
final class ToolCardExpansion {
    static let shared = ToolCardExpansion()
    private var expanded: Set<String> = []

    func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    func isExpanded(_ id: String) -> Bool { expanded.contains(id) }
}

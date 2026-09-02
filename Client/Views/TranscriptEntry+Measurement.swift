import AppKit
import Core
import SwiftUI

/// Deterministic height measurement for transcript rows, driven entirely by
/// `TranscriptText` so measurement always matches rendering exactly. Cached per
/// (id, width) in the transcript coordinator's `HeightCache`; the streaming
/// row's entry is invalidated (at a throttled rate) as deltas arrive.
///
/// `nonisolated` on `measuredHeight(forWidth:bodySize:)`: the coordinator
/// measures text rows on a background thread (see `TranscriptView`'s
/// pre-measurer) AND on the main thread (the synchronous cache-miss path in
/// `heightOfRow`), and both paths must produce identical heights — `bodySize`
/// is passed explicitly so the caller resolves `FontSettings` on its own
/// thread and the two paths can never read different sizes.
extension TranscriptEntry {
    /// Measures the whole row: the kind's content plus the per-turn cache line
    /// (which is entry-level data, not part of the kind).
    ///
    /// Text rows are measured with pure AppKit string measurement, safe on any
    /// thread. Tool cards are NOT: their height comes from a real SwiftUI
    /// layout (`NSHostingController.sizeThatFits`), which must run on the main
    /// thread, so the coordinator's background pre-measurer skips them and
    /// they always fall back to this main-thread path.
    nonisolated func measuredHeight(forWidth width: CGFloat, bodySize: CGFloat) -> CGFloat {
        switch kind {
        case .userMessage(let text):
            return TranscriptText.measuredHeight(text: text, thinking: nil, role: .user, isStreaming: false, width: width, bodySize: bodySize)

        case .assistantMessage(let text, let thinking, let isStreaming):
            return TranscriptText.measuredHeight(text: text, thinking: thinking, role: .assistant, isStreaming: isStreaming, width: width, cacheHitRate: cacheHitRate, cacheMiss: cacheMiss, bodySize: bodySize)

        case .errorMessage(let text):
            return TranscriptText.measuredHeight(text: text, thinking: nil, role: .error, isStreaming: false, width: width, bodySize: bodySize)

        case .abortedMessage(let text):
            return TranscriptText.measuredHeight(text: text, thinking: nil, role: .aborted, isStreaming: false, width: width, bodySize: bodySize)

        case .toolCall(let card):
            // Tool-card heights need a real SwiftUI `NSHostingController`
            // layout, which is main-thread-only. The coordinator's background
            // pre-measurer never schedules tool cards (`isPremeasurable`
            // filters them), so this branch only ever runs on the main
            // thread — the assumeIsolated asserts exactly that contract.
            return MainActor.assumeIsolated { Self.toolCallHeight(card, width: width) }
        }
    }

    /// Measures the real SwiftUI card layout via `NSHostingController`
    /// `sizeThatFits` — the previous line-counting estimate drifted from the
    /// actual 11pt monospaced layout and left whitespace whenever a card
    /// expanded or collapsed.
    ///
    /// The measurer is REUSED, not created per query: creating an
    /// `NSHostingController` builds a whole SwiftUI graph (StackLayout /
    /// ViewLayoutEngine / `_FlexFrameLayout` in samples), and tool-card heights
    /// are invalidated on every output delta, so a per-query controller turned
    /// each 0.25s streaming batch into a fresh graph construction on the main
    /// thread. One long-lived controller whose `rootView` is swapped per
    /// measurement keeps the cost down to the actual SwiftUI layout pass.
    private static func toolCallHeight(_ card: ToolCallCard, width: CGFloat) -> CGFloat {
        let measurer = ToolCardMeasurer.shared
        return measurer.height(of: card, width: width)
    }
}

/// A single reusable `NSHostingController` for tool-card height measurement.
/// Main-thread only (the coordinator's `heightOfRow` and the card's
/// `updateVisibleCell` path both run on main), so no locking is needed.
private final class ToolCardMeasurer {
    static let shared = ToolCardMeasurer()

    /// One controller, never shown; `rootView` is swapped per measurement so
    /// the SwiftUI graph is built once for the life of the app.
    private let controller = NSHostingController(rootView: AnyView(EmptyView()))

    func height(of card: ToolCallCard, width: CGFloat) -> CGFloat {
        controller.rootView = AnyView(ToolCallCardView(
            card: card,
            isInitiallyExpanded: ToolCardExpansion.shared.isExpanded(card.id)
        ))
        let size = controller.sizeThatFits(in: NSSize(width: max(width, 320), height: .greatestFiniteMagnitude))
        // Round up so the table never clips the last line, plus 2pt slack: the
        // card's rendered height can transiently exceed sizeThatFits (streaming
        // output grows between batched height updates) and the hosting view is
        // clipped to the row, so an under-measure would truncate the card.
        return max(ceil(size.height), 44) + 2
    }
}

import Foundation

/// Pure navigation over a transcript's rows for the Cmd+Up / Cmd+Down
/// user-message cycle in the transcript view. Kept in Core (no AppKit) so the
/// cycling decision is unit-testable from `ClientTests` — the transcript
/// coordinator just turns the returned store index into a scroll.
///
/// The cycle is anchored at the viewport's top row and always moves STRICTLY
/// above/below it: standing on a user message and pressing Down moves to the
/// one after it, never re-showing the same one. A nil result means "no user
/// message in that direction" — the caller falls back to the top of the
/// conversation (Up) or the live tail (Down).
public enum TranscriptCycler {

    /// Whether an entry kind counts as a user message for the cycle.
    public static func isUserMessage(_ kind: TranscriptEntryKind) -> Bool {
        if case .userMessage = kind { return true }
        return false
    }

    /// The store index of the previous user message STRICTLY above `anchor`,
    /// or nil when there is none. `entryAt` returns the entry at a store
    /// index, or nil past the end of the conversation.
    public static func previousUserMessage(anchor: Int, entryAt: (Int) -> TranscriptEntry?) -> Int? {
        for i in stride(from: anchor - 1, through: 0, by: -1) {
            if let entry = entryAt(i), isUserMessage(entry.kind) {
                return i
            }
        }
        return nil
    }

    /// The store index of the next user message STRICTLY below `anchor`, or
    /// nil when there is none (the caller jumps to the live tail).
    public static func nextUserMessage(anchor: Int, count: Int, entryAt: (Int) -> TranscriptEntry?) -> Int? {
        guard anchor + 1 < count else { return nil }
        for i in (anchor + 1)..<count {
            if let entry = entryAt(i), isUserMessage(entry.kind) {
                return i
            }
        }
        return nil
    }
}

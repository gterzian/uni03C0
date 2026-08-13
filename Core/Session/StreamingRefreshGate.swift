import Foundation

/// The batched-refresh decision for the streaming tail row, extracted from the
/// transcript coordinator (`applyModelChanges`) so it is unit-testable with
/// the exact same code the app runs.
///
/// pi pushes a delta per token; re-rendering the streaming row on every delta
/// re-measures the whole (possibly huge) growing text each time — the 100%-CPU
/// path seen in samples. The gate allows a refresh only:
///  - immediately when a NEW streaming message starts (its first chunk), or
///  - when the content changed AND `batchInterval` has elapsed since the last
///    refresh (a hard cap: ~4 refreshes/sec regardless of delta rate), or
///  - when the message settles (the streaming→final flag flip must render
///    immediately, even if the text is unchanged — the blinking caret must not
///    persist).
/// Between refreshes the row renders its last-batch content; the store's newer
/// deltas simply wait for the next batch.
public struct StreamingRefreshGate {
    public let batchInterval: TimeInterval

    public private(set) var lastStreamedID: String?
    public private(set) var lastStreamedContent: (text: String, thinking: String)?
    public private(set) var lastStreamedWasStreaming = false
    /// Wall-clock (systemUptime) of the last refresh; drives the interval gate.
    public private(set) var lastStreamedAt: TimeInterval = 0

    public init(batchInterval: TimeInterval = 0.25) {
        self.batchInterval = batchInterval
    }

    /// Decides whether the streaming assistant row's current content should be
    /// re-rendered now, updating the gate's state as a side effect — a verbatim
    /// extraction of the coordinator's inline decision.
    public mutating func shouldRefresh(entryID: String, text: String, thinking: String, isStreaming: Bool, now: TimeInterval) -> Bool {
        var shouldRefresh = false
        if lastStreamedID != entryID {
            // A new streaming message: show its first chunk immediately.
            lastStreamedID = entryID
            lastStreamedContent = (text, thinking)
            lastStreamedWasStreaming = isStreaming
            shouldRefresh = true
        } else if let last = lastStreamedContent,
                  last.text != text || last.thinking != thinking || lastStreamedWasStreaming != isStreaming {
            // The flag flip (streaming → final) MUST re-render even when the
            // text is unchanged — otherwise the cell keeps the old streaming
            // version with its blinking caret forever. Live content batches at
            // the hard interval; final content renders immediately.
            shouldRefresh = !isStreaming || now - lastStreamedAt >= batchInterval
        }
        if shouldRefresh {
            lastStreamedAt = now
            lastStreamedContent = (text, thinking)
            lastStreamedWasStreaming = isStreaming
        }
        return shouldRefresh
    }

    /// The batched refresh decision for a RUNNING tool card at the tail (its
    /// output streams into the card; refresh at the same hard interval so bash
    /// output doesn't repaint per delta).
    public func shouldRefreshRunningToolCard(now: TimeInterval) -> Bool {
        now - lastStreamedAt >= batchInterval
    }
}

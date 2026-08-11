import AppKit
import Core
import SwiftUI

/// The transcript: an `NSTableView` wrapped in `NSViewRepresentable`.
///
/// Deliberately NOT driven by SwiftUI re-renders — this is the whole point of
/// the AppKit choice. The SwiftUI body never reads the transcript entries, so
/// a streamed delta does not invalidate the SwiftUI graph at all. Updates flow
/// store → coordinator directly.
///
/// ## History grows down, older history is revealed upward
///
/// The full history lives in `TranscriptStore` (off the main thread); the
/// coordinator materializes a window `[windowStart, windowEnd)` of store
/// indices into the table (`numberOfRows` is the window size,
/// `row == storeIndex - windowStart`).
///
/// - **The tail always grows:** `windowEnd` tracks the store and streams in via
///   cheap `insertRows` at the bottom. Scrolling down is therefore always fast,
///   and the front (the live tail) is never popped.
/// - **Old history is evictable, never lost:** `windowStart` decreases as older
///   history is prepended (scroll up) and *increases again* when the user
///   scrolls back down and rows above a buffer are no longer needed — the rows
///   leave the table and their cached heights are dropped. The store keeps the
///   full conversation, so a later scroll-up re-materializes them instantly
///   (no RPC round trip). The buffer (a few viewports) keeps fast re-scrolling
///   smooth.
/// - **Older history is fetched in compounding blocks:** when the viewport
///   nears the top of the fetched region, a spinner appears at the top of the
///   conversation and a block of history is prepended. Each successive fetch is
///   larger (compounding), so sustained scrolling eventually pulls the entire
///   conversation into memory.
///
/// Session switch / reload is a store `generation` bump → full reload
/// positioned at the tail.
struct TranscriptView: NSViewRepresentable {
    let viewModel: SessionViewModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView(viewModel: viewModel)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // The representable's inputs are stable (same viewModel reference);
        // handle a window-value swap defensively.
        if context.coordinator.viewModel !== viewModel {
            context.coordinator.rebind(viewModel: viewModel)
        }
    }
}

// MARK: - Coordinator

final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private let heights = HeightCache()
    weak var viewModel: SessionViewModel?
    private var isApplying = false
    /// Streaming batching: the tail row is refreshed at most every
    /// `streamBatchInterval` seconds (a few words for a typical stream), and
    /// the new chunk crossfades in. The interval is a HARD cap — a per-delta
    /// word gate made fast streams re-layout the whole (possibly huge)
    /// streaming row on nearly every delta, which is the 100%-CPU path in
    /// samples.
    private let streamBatchInterval: TimeInterval = 0.25
    private var lastStreamedAt: TimeInterval = 0
    /// The tail entry (by id) whose streaming content was last rendered, and
    /// that content. Thinking streams on its own (empty text), so BOTH text
    /// and thinking are compared when deciding whether a new chunk is big
    /// enough to show — otherwise thinking deltas never trigger a refresh.
    private var lastStreamedID: String?
    private var lastStreamedContent: (text: String, thinking: String)?
    /// Whether the last render was a streaming one — the flag flip to final
    /// must re-render the cell even when the text is unchanged (otherwise the
    /// old streaming version, caret included, blinks forever).
    private var lastStreamedWasStreaming = false
    /// Coalesced async scroll-to-bottom (tile + scroll happen once per run-loop
    /// turn at most, after the table has laid out).
    private var scrollToBottomPending = false

    /// The materialized window over store indices: table row `r` displays
    /// `store.entry(at: windowStart + r)`. `windowEnd` only ever increases —
    /// the streaming tail is never popped. `windowStart` decreases when older
    /// history is prepended (scroll up) and increases when the user scrolls
    /// back down and rows above the buffer are evicted. The store keeps the
    /// full conversation, so evicted rows re-materialize instantly on a later
    /// scroll-up (no RPC round trip).
    private var windowStart = 0
    private var windowEnd = 0
    private var lastGeneration: UInt64 = 0

    /// Rows kept materialized above the viewport while the user scrolls down
    /// (so scrolling back up doesn't immediately stall). Beyond this, older
    /// rows are evicted from the window and their heights dropped.
    private let bufferViewports = 3
    private let minBufferRows = 30
    /// True while a deferred eviction is pending (drives mutual exclusion with
    /// the compounding history fetch).
    private var isEvictingOlder = false

    /// Size of the next upward history fetch, in rows. Compounding: doubles
    /// after every fetch so sustained scrolling eventually pulls everything.
    private var fetchBlock = 0
    private let fetchBlockMax = 600

    /// True while a block of older history is being measured/prepended (drives
    /// the spinner at the top of the conversation).
    private var isFetchingOlder = false

    /// Whether the window is actually on screen. When it's occluded,
    /// minimized, or the app is hidden, the coordinator does ZERO per-delta
    /// rendering work — the store keeps folding off-main, but nothing touches
    /// the table. On becoming visible again it catches up in one pass.
    private var isWindowVisible = true
    /// Set when a store change arrives while invisible, so a single catch-up
    /// pass happens on return to the foreground (rather than every delta).
    private var needsCatchUp = false

    /// Whether the user is pinned to the tail and wants to auto-follow. Once
    /// they scroll up, this turns off so streaming doesn't keep yanking them
    /// back down; it re-engages only when they return to the bottom.
    private var isFollowing = true
    /// Last viewport bottom edge (document y), for detecting scroll direction.
    private var lastVisibleMaxY: CGFloat = 0

    /// How many rows currently fit in the viewport (or a sane default).
    private func viewportRows() -> Int {
        guard let tableView else { return 20 }
        return max(tableView.rows(in: tableView.visibleRect).length, 1)
    }

    /// Rows materialized at the tail on load / reload (a few screens).
    private func initialChunkRows() -> Int {
        max(40, viewportRows() * 5)
    }

    func makeScrollView(viewModel: SessionViewModel) -> NSScrollView {
        self.viewModel = viewModel

        let tv = TranscriptTableView()
        tv.headerView = nil
        tv.selectionHighlightStyle = .none
        tv.usesAutomaticRowHeights = false // we own height, not AppKit layout
        tv.intercellSpacing = .zero
        tv.backgroundColor = .clear
        tv.rowHeight = 24
        tv.allowsColumnReordering = false

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        column.width = 640
        tv.addTableColumn(column)

        // VoiceOver: the table is the conversation; rows carry their own
        // per-role labels (see TextRowView).
        tv.setAccessibilityElement(true)
        tv.setAccessibilityRole(.table)
        tv.setAccessibilityLabel("Conversation")
        tv.setAccessibilityHelp("The conversation with the agent. Arrow-Down jumps to the latest message.")

        let sv = TranscriptScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false

        tableView = tv
        scrollView = sv
        tv.dataSource = self
        tv.delegate = self

        // Arrow-Down jumps to the bottom of the conversation in one step (and
        // re-engages following). Scrolling the transcript takes key focus so
        // Down works right after a trackpad scroll — focus otherwise stays on
        // the prompt bar.
        tv.onArrowDown = { [weak self] in
            self?.jumpToBottom()
        }
        sv.onUserScroll = { [weak self] in
            guard let self, let window = self.tableView.window,
                  window.firstResponder !== self.tableView else { return }
            window.makeFirstResponder(self.tableView)
        }

        // Fetch older history (and refresh the tail) on scroll.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Pause rendering while the window is off-screen (occluded, minimized,
        // or the app is hidden); catch up on return. Occlusion changes fire
        // once per state transition, so this is cheap in steady state.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(visibilityMayHaveChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        nc.addObserver(self, selector: #selector(visibilityMayHaveChanged), name: NSWindow.didMiniaturizeNotification, object: nil)
        nc.addObserver(self, selector: #selector(visibilityMayHaveChanged), name: NSWindow.didDeminiaturizeNotification, object: nil)
        nc.addObserver(self, selector: #selector(visibilityMayHaveChanged), name: NSApplication.didHideNotification, object: nil)
        nc.addObserver(self, selector: #selector(visibilityMayHaveChanged), name: NSApplication.didUnhideNotification, object: nil)

        // Re-measure all rows when the user changes the font size (View menu).
        nc.addObserver(self, selector: #selector(fontSizeDidChange), name: FontSettings.didChangeNotification, object: nil)

        viewModel.onTranscriptChange = { [weak self] in
            self?.applyModelChanges()
        }
        let store = viewModel.store
        lastGeneration = store.currentGeneration
        windowStart = max(0, store.count - initialChunkRows())
        windowEnd = store.count
        fetchBlock = max(initialChunkRows() / 2, 20)
        applyModelChanges() // initial state (usually empty; populate happens after)

        return sv
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func rebind(viewModel: SessionViewModel) {
        self.viewModel?.onTranscriptChange = nil
        self.viewModel = viewModel
        viewModel.onTranscriptChange = { [weak self] in
            self?.applyModelChanges()
        }
        resetToTail(viewModel.store)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        max(0, windowEnd - windowStart)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let storeIndex = windowStart + row
        guard let entry = viewModel?.store.entry(at: storeIndex) else { return nil }
        return makeCell(for: entry, in: tableView)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let store = viewModel?.store else { return 24 }
        let storeIndex = windowStart + row
        guard storeIndex >= 0, storeIndex < store.count, let entry = store.entry(at: storeIndex) else { return 24 }
        let width = max(tableView.bounds.width, 320)
        let height = heights.height(for: entry.id, width: width) {
            entry.measuredHeight(forWidth: width)
        }
        // TEMP diagnostics for the top-cut chase.
        let prefix = (Self.label(of: entry) as NSString).substring(to: min(20, (Self.label(of: entry) as NSString).length))
        Self.debugLog("ROW id=\(String(entry.id.prefix(8))) w=\(width) h=\(height) text=\(prefix.replacingOccurrences(of: "\n", with: "\\n"))")
        return height
    }

    private static func label(of entry: TranscriptEntry) -> String {
        switch entry.kind {
        case .userMessage(let t), .errorMessage(let t), .abortedMessage(let t): return t
        case .assistantMessage(let t, _, _): return t
        case .toolCall(let c): return "[tool \(c.toolName)]"
        }
    }

    /// Set PI_DEBUG_TOP_CUT=1 to enable the top-cut diagnostics (they append
    /// per-row geometry to /tmp/topcut.log — off by default because they fire
    /// on every layout).
    private static var topCutDebugEnabled: Bool {
        ProcessInfo.processInfo.environment["PI_DEBUG_TOP_CUT"] == "1"
    }

    private static func debugLog(_ entry: String) {
        if let handle = FileHandle(forWritingAtPath: "/tmp/topcut.log") {
            handle.seekToEndOfFile()
            handle.write((entry + "\n").data(using: .utf8)!)
            try? handle.close()
        } else {
            try? (entry + "\n").write(toFile: "/tmp/topcut.log", atomically: true, encoding: .utf8)
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false // read-only transcript
    }

    // MARK: - Store → table

    /// Called on every store change. Always materializes newly streamed tail
    /// rows (cheap append; does not disturb a scrolled-up viewport, and rows
    /// above stay cached). Follows + refreshes the streaming row only when
    /// pinned to the bottom.
    func applyModelChanges() {
        guard let viewModel, !isApplying else { return }
        // Zero rendering while off-screen: just record that work is pending.
        // Visibility is re-queried fresh on every delta — occlusion
        // notifications are asynchronous and can be missed (a background
        // window covered by other windows), so a stale flag must never leave
        // the per-delta render running while nothing is on screen.
        let visible = isOnScreen()
        isWindowVisible = visible
        guard visible else {
            needsCatchUp = true
            return
        }
        isApplying = true
        defer { isApplying = false }
        let store = viewModel.store

        let generation = store.currentGeneration
        if generation != lastGeneration {
            resetToTail(store)
            return
        }

        let newCount = store.count
        var didAppend = false

        // The store is otherwise append-only; the only shrink is a turn-start
        // placeholder dropped when a turn aborts before any message_start.
        // reloadData is fine here — heights are cached and it's rare.
        if newCount < windowEnd {
            windowEnd = newCount
            tableView.reloadData()
            return
        }

        // Materialize the newly streamed tail (cheap, O(added)). Inserting at
        // the end never shifts the rows above, so a scrolled-up viewport is
        // untouched.
        if newCount > windowEnd {
            let oldEnd = windowEnd
            windowEnd = newCount
            let tableRange = (oldEnd - windowStart)..<(newCount - windowStart)
            for i in oldEnd..<newCount {
                if let entry = store.entry(at: i) {
                    heights.invalidate(entry.id)
                }
            }
            tableView.insertRows(at: IndexSet(integersIn: tableRange), withAnimation: [])
            didAppend = true
        }

        // Deliberately NO jump-to-bottom on send: the scroll stays exactly
        // where the user left it (they may be reading history while a queued
        // steering message is flushed). The tail still streams in off-screen;
        // following re-engages only when the user returns to the bottom.
        guard isFollowing else { return }

        // Batched in-place refresh of streaming rows: a few words at a time,
        // not every delta, crossfaded in. Tool cards are now created the
        // moment the model starts writing a call, so the still-streaming
        // assistant text is NOT always the last row — refresh the last
        // streaming text row AND the tail row (a tool card / final message)
        // separately. We seed each cached height from the cell's own layout
        // rather than invalidating it first (invalidation can make the row
        // flicker between the cell-derived and the re-measured height on
        // successive ticks), so rows only ever grow — never oscillate.
        let now = ProcessInfo.processInfo.systemUptime
        var didRefresh = false
        var rowsToRefresh = IndexSet()

        // 1. The last streaming assistant row. Once the message settles it
        // stays matched by `lastStreamedID`, so its final text is rendered
        // even when it is no longer the tail.
        var streamingRow = -1
        var streamingEntry: TranscriptEntry?
        for i in (windowStart..<windowEnd).reversed() {
            if let e = store.entry(at: i), e.kind.isStreaming || e.id == lastStreamedID {
                streamingRow = i - windowStart
                streamingEntry = e
                break
            }
        }
        if let streamingEntry, streamingRow >= 0,
           case .assistantMessage(let text, let thinking, let isStreaming) = streamingEntry.kind {
            var shouldRefresh = false
            if lastStreamedID != streamingEntry.id {
                // A new streaming message: show its first chunk immediately.
                lastStreamedID = streamingEntry.id
                lastStreamedContent = (text, thinking)
                lastStreamedWasStreaming = isStreaming
                shouldRefresh = true
            } else if let last = lastStreamedContent,
                      last.text != text || last.thinking != thinking || lastStreamedWasStreaming != isStreaming {
                // The flag flip (streaming → final) MUST re-render even when
                // the text is unchanged — otherwise the cell keeps the old
                // streaming version with its blinking caret forever. Live
                // content batches at the hard interval; final content renders
                // immediately.
                shouldRefresh = !isStreaming || now - lastStreamedAt >= streamBatchInterval
            }
            if shouldRefresh {
                lastStreamedAt = now
                lastStreamedContent = (text, thinking)
                lastStreamedWasStreaming = isStreaming
                rowsToRefresh.insert(streamingRow)
            }
        }

        // 2. The tail row, when it isn't the streaming row above: a running
        // tool card streams args/output; a finished one shows its final state.
        let lastRow = windowEnd - windowStart - 1
        if lastRow >= 0, lastRow != streamingRow,
           let lastEntry = store.entry(at: windowEnd - 1) {
            var shouldRefresh = false
            if case .toolCall(let card) = lastEntry.kind {
                if card.state != .running {
                    // Tool finished: show the final state and output now.
                    shouldRefresh = true
                } else {
                    // Running tool cards stream output like text; batch at the
                    // same interval so bash output doesn't repaint per delta.
                    shouldRefresh = now - lastStreamedAt >= streamBatchInterval
                }
            }
            if shouldRefresh {
                rowsToRefresh.insert(lastRow)
            }
        }

        if !rowsToRefresh.isEmpty {
            // Batch the height changes, the follow-scroll, and the fade into
            // one display pass so AppKit renders only the final state (rows
            // grown + scrolled) — never an intermediate "row taller but not
            // scrolled yet" frame that reads as a bounce.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for row in rowsToRefresh {
                let storeIndex = windowStart + row
                if let entry = store.entry(at: storeIndex) {
                    if !updateVisibleCell(at: row, with: entry) {
                        heights.invalidate(entry.id)
                    }
                }
            }
            tableView.noteHeightOfRows(withIndexesChanged: rowsToRefresh)
            followTail()
            CATransaction.commit()
            didRefresh = true
        }

        if didAppend && !didRefresh {
            followTail()
        }
    }

    /// Called on scroll. Refreshes the tail row's height when the user reaches
    /// the bottom (it may have grown while they were scrolled up), and fetches
    /// older history when they near the top of the fetched region.
    @objc private func scrollViewDidScroll(_ note: Notification) {
        reconcileOnScroll()
    }

    private func reconcileOnScroll() {
        guard let viewModel, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        let store = viewModel.store
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }

        let firstVisibleStore = windowStart + visible.location

        // Follow toggle, direction-aware. The programmatic follow-scroll (from
        // followTail) always scrolls DOWN toward the bottom, so it never
        // disengages. Only an actual scroll UP (visible max-y decreasing while
        // away from the bottom) breaks out of following; returning to the
        // bottom re-engages.
        let maxY = scrollView.documentVisibleRect.maxY
        let goingUp = maxY < lastVisibleMaxY - 1
        lastVisibleMaxY = maxY
        if goingUp && !isNearBottom(threshold: 8) {
            isFollowing = false
        } else if isNearBottom(threshold: 4) {
            isFollowing = true
        }

        // At the tail: refresh the streaming row's height so content that grew
        // while the user was scrolled up renders correctly. (No scroll here —
        // the user is navigating on their own.)
        if isNearBottom(threshold: 4) {
            let lastRow = windowEnd - windowStart - 1
            if lastRow >= 0, let lastEntry = store.entry(at: windowEnd - 1) {
                if !updateVisibleCell(at: lastRow, with: lastEntry) {
                    heights.invalidate(lastEntry.id)
                }
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: lastRow))
            }
        }

        // Evict first (the user scrolled down past the buffer), then fetch
        // (they neared the top of the window). The two are mutually exclusive
        // by construction — near-top vs far-from-top.
        checkEvictOlder(store: store, firstVisibleStore: firstVisibleStore, visible: visible)
        checkFetchOlder(store: store, firstVisibleStore: firstVisibleStore, visible: visible)
    }

    /// Whether the viewport's bottom edge is within `threshold` px of the
    /// bottom of the document content (i.e. there's little or nothing to scroll
    /// down to).
    private func isNearBottom(threshold: CGFloat) -> Bool {
        guard let documentView = scrollView.documentView else { return true }
        let visibleMaxY = scrollView.documentVisibleRect.maxY
        return documentView.frame.height - visibleMaxY <= threshold
    }

    // MARK: - Fetching older history (compounding, with spinner)

    /// Evicts materialized rows above the viewport once they exceed the buffer
    /// (the user scrolled back down through history they'd pulled in). The
    /// store keeps the full conversation, so re-scrolling up re-materializes
    /// them instantly; only the view's rows and cached heights are dropped,
    /// and the streaming tail (the front of the window) is never touched.
    private func checkEvictOlder(store: TranscriptStore, firstVisibleStore: Int, visible: NSRange) {
        guard !isEvictingOlder, !isFetchingOlder, windowStart > 0 else { return }
        let rowsAbove = firstVisibleStore - windowStart
        let buffer = max(viewportRows() * bufferViewports, minBufferRows)
        guard rowsAbove > buffer else { return }
        isEvictingOlder = true
        // Defer to the next run-loop turn (like the fetch) so the scroll event
        // finishes before the table is reshaped.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.evictOlder()
            self.isEvictingOlder = false
        }
    }

    /// Removes the rows above the buffer from the top of the window, drops
    /// their cached heights, and re-anchors the viewport so the visible
    /// content doesn't move. Recomputes everything from the current geometry
    /// (the scroll may have moved since the check was deferred).
    private func evictOlder() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        let firstVisibleStore = windowStart + visible.location
        let rowsAbove = firstVisibleStore - windowStart
        let buffer = max(viewportRows() * bufferViewports, minBufferRows)
        guard rowsAbove > buffer else { return }
        let drop = rowsAbove - buffer
        guard drop > 0, windowStart + drop <= windowEnd else { return }

        let anchorRow = visible.location
        let anchorOffset = tableView.rect(ofRow: anchorRow).origin.y - tableView.visibleRect.origin.y

        // Drop the cached heights for the evicted rows; a later re-fetch
        // re-measures them.
        for i in windowStart..<(windowStart + drop) {
            if let entry = viewModel?.store.entry(at: i) {
                heights.invalidate(entry.id)
            }
        }
        windowStart += drop
        tableView.removeRows(at: IndexSet(integersIn: 0..<drop), withAnimation: [])
        tableView.tile()

        // Re-anchor the first previously-visible row to its old screen offset.
        let row = anchorRow - drop
        guard row >= 0, row < (windowEnd - windowStart) else { return }
        let rowY = tableView.rect(ofRow: row).origin.y
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, rowY - anchorOffset)))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // The last fetch was given back: restart the compounding block so a
        // re-scroll-up starts small instead of pulling a huge block.
        fetchBlock = max(initialChunkRows() / 2, 20)
    }

    /// If the viewport is near the top of the fetched region and more history
    /// exists above, fetch the next (compounding) block. Shows the spinner, lets
    /// it paint, then prepends the block and re-anchors the viewport.
    private func checkFetchOlder(store: TranscriptStore, firstVisibleStore: Int, visible: NSRange) {
        guard windowStart > 0 else { return } // whole conversation already fetched
        guard !isFetchingOlder, !isEvictingOlder else { return }
        let margin = max(4, visible.length / 3)
        guard firstVisibleStore - windowStart <= margin else { return }

        // Capture the anchor row and its on-screen offset so the viewport
        // doesn't jump when the new rows are inserted above it.
        let anchorStore = firstVisibleStore
        let anchorOffset = tableView.rect(ofRow: visible.location).origin.y - tableView.visibleRect.origin.y

        let block = fetchBlock
        let newStart = max(0, windowStart - block)
        let fetched = windowStart - newStart
        guard fetched > 0 else { return }
        fetchBlock = min(fetchBlock * 2, fetchBlockMax)

        isFetchingOlder = true
        viewModel?.isFetchingOlder = true

        // Yield so the spinner paints, then prepend on the next run-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.prependHistory(fetched, anchorStore: anchorStore, anchorOffset: anchorOffset)
            self.isFetchingOlder = false
            self.viewModel?.isFetchingOlder = false
        }
    }

    /// Prepends `fetched` rows (older history) at the top of the table and
    /// re-anchors the viewport to the same store row at the same pixel offset.
    private func prependHistory(_ fetched: Int, anchorStore: Int, anchorOffset: CGFloat) {
        guard fetched > 0 else { return }
        windowStart -= fetched
        tableView.insertRows(at: IndexSet(integersIn: 0..<fetched), withAnimation: [])
        tableView.tile()
        let row = anchorStore - windowStart
        guard row >= 0, row < (windowEnd - windowStart) else { return }
        let rowY = tableView.rect(ofRow: row).origin.y
        let targetY = rowY - anchorOffset
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func resetToTail(_ store: TranscriptStore) {
        let count = store.count
        let chunk = initialChunkRows()
        windowStart = max(0, count - chunk)
        windowEnd = count
        fetchBlock = max(chunk / 2, 20)
        lastGeneration = store.currentGeneration
        isFetchingOlder = false
        isEvictingOlder = false
        isFollowing = true
        viewModel?.isFetchingOlder = false
        tableView.reloadData()
        scheduleScrollToBottom()
    }

    private func scheduleScrollToBottom() {
        guard !scrollToBottomPending else { return }
        scrollToBottomPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollToBottomPending = false
            self.tableView.tile()
            self.scrollView.scrollToBottom()
        }
    }

    /// Reconfigures the visible cell for `row` and seeds its cached height from
    /// the SAME function `heightOfRow` uses on a cache miss
    /// (`entry.measuredHeight(forWidth:)`), so the fast path and the
    /// authoritative path can never disagree about a row's height. The cell is
    /// resized to that height BEFORE layout, so its text view never lays out
    /// inside a stale (too-short) frame — the original source of the top-cut.
    /// Returns false if the cell isn't currently visible, in which case the
    /// caller should invalidate the height so it falls back to a measurement.
    @discardableResult
    private func updateVisibleCell(at row: Int, with entry: TranscriptEntry) -> Bool {
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return false }
        let width = max(tableView.bounds.width, 320)

        if cell is TextRowView {
            // Single source of truth: identical to what heightOfRow computes on
            // a cache miss. (One measuredHeight per batched refresh — the
            // original 100%-CPU bug was per-DELTA with no batching; this is
            // throttled to `streamBatchInterval`, so the cost is bounded and
            // the cell's already-rendered pixels are still reused.)
            let measured = entry.measuredHeight(forWidth: width)

            // A reused cell can still hold a stale (wider) frame after a
            // window resize. Render AND measure at the real width: a stale
            // frame would wrap the text wider (fewer lines), under-report the
            // height, and the row would then render short — the taller text
            // overflows upward and the message's top is clipped.
            if abs(cell.frame.width - width) > 1 {
                cell.frame.size.width = width
            }
            // Resize height BEFORE layout: laying out inside a stale
            // (too-short) frame is what produced the top-cut — the text view's
            // content height could exceed the container, and only the bottom
            // slice of it was ever visible.
            if abs(cell.frame.height - measured) > 0.5 {
                cell.frame.size.height = measured
            }

            configure(cell, with: entry, in: tableView)
            cell.layoutSubtreeIfNeeded()

            heights.store(entry.id, width: width, height: measured)
            if Self.topCutDebugEnabled {
                Self.debugLog("STORE id=\(String(entry.id.prefix(8))) w=\(width) h=\(measured)")
            }
            return true
        }

        // Tool cards: reconfigured in place (args/output stream into the card),
        // but their heights are invalidated and re-measured by `heightOfRow` —
        // the card's content changes shape too often to seed cheaply
        // (expansion included).
        configure(cell, with: entry, in: tableView)
        cell.layoutSubtreeIfNeeded()
        heights.invalidate(entry.id)
        return true
    }

    /// Recomputes whether the window is on screen. When it transitions from
    /// invisible → visible, performs a single catch-up render pass for anything
    /// that streamed while hidden.
    @objc private func visibilityMayHaveChanged() {
        let wasVisible = isWindowVisible
        isWindowVisible = isOnScreen()
        guard !wasVisible && isWindowVisible else { return }
        // Single catch-up pass for anything that streamed while hidden.
        needsCatchUp = false
        applyModelChanges()
    }

    /// Whether the window is actually on screen: not app-hidden, not
    /// miniaturized, and not completely occluded by other windows. Queried
    /// fresh (never cached), so a missed occlusion notification can't leave
    /// rendering running while nothing is visible.
    private func isOnScreen() -> Bool {
        let window = tableView.window
        let appHidden = NSApp.isHidden
        let miniaturized = window?.isMiniaturized ?? false
        let occluded = !(window?.occlusionState.contains(.visible) ?? true)
        return !appHidden && !miniaturized && !occluded
    }

    /// Font size changed (View → Font Size): the height cache is keyed by
    /// content+width, so it is stale now. Clear it and re-render all
    /// materialized rows; heights and cells both read `TranscriptText`, so
    /// measured and rendered sizes stay in sync.
    @objc private func fontSizeDidChange() {
        heights.clear()
        tableView.reloadData()
    }

    /// Anchors the bottom of the last (streaming) row to the bottom of the
    /// viewport, synchronously, using the row's actual laid-out geometry so it
    /// can't lag behind the height update. This is what keeps the tail text
    /// steady as it grows.
    private func followTail() {
        let lastRow = windowEnd - windowStart - 1
        guard lastRow >= 0 else { return }
        tableView.tile()
        let rowRect = tableView.rect(ofRow: lastRow)
        let targetY = rowRect.maxY - scrollView.contentView.bounds.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, targetY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Cells

    private func makeCell(for entry: TranscriptEntry, in tableView: NSTableView) -> NSView {
        switch entry.kind {
        case .userMessage(let text):
            let view = tableView.makeView(withIdentifier: .textRow, owner: nil) as? TextRowView ?? TextRowView()
            view.identifier = .textRow
            view.configure(text: text, thinking: nil, role: .user, isStreaming: false)
            return view
        case .assistantMessage(let text, let thinking, let isStreaming):
            let view = tableView.makeView(withIdentifier: .textRow, owner: nil) as? TextRowView ?? TextRowView()
            view.identifier = .textRow
            view.configure(text: text, thinking: thinking, role: .assistant, isStreaming: isStreaming, cacheHitRate: entry.cacheHitRate, cacheMiss: entry.cacheMiss)
            return view
        case .errorMessage(let text):
            let view = tableView.makeView(withIdentifier: .textRow, owner: nil) as? TextRowView ?? TextRowView()
            view.identifier = .textRow
            view.configure(text: text, thinking: nil, role: .error, isStreaming: false)
            return view
        case .abortedMessage(let text):
            let view = tableView.makeView(withIdentifier: .textRow, owner: nil) as? TextRowView ?? TextRowView()
            view.identifier = .textRow
            view.configure(text: text, thinking: nil, role: .aborted, isStreaming: false)
            return view
        case .toolCall(let card):
            let view = tableView.makeView(withIdentifier: .toolRow, owner: nil) as? ToolCallHostView ?? ToolCallHostView()
            view.identifier = .toolRow
            view.configure(card: card) { [weak self] in
                self?.toggleToolCard(card.id)
            }
            return view
        }
    }

    private func configure(_ cell: NSView, with entry: TranscriptEntry, in tableView: NSTableView) {
        switch entry.kind {
        case .userMessage(let text):
            (cell as? TextRowView)?.configure(text: text, thinking: nil, role: .user, isStreaming: false)
        case .assistantMessage(let text, let thinking, let isStreaming):
            (cell as? TextRowView)?.configure(text: text, thinking: thinking, role: .assistant, isStreaming: isStreaming, cacheHitRate: entry.cacheHitRate, cacheMiss: entry.cacheMiss)
        case .errorMessage(let text):
            (cell as? TextRowView)?.configure(text: text, thinking: nil, role: .error, isStreaming: false)
        case .abortedMessage(let text):
            (cell as? TextRowView)?.configure(text: text, thinking: nil, role: .aborted, isStreaming: false)
        case .toolCall(let card):
            (cell as? ToolCallHostView)?.configure(card: card) { [weak self] in
                self?.toggleToolCard(card.id)
            }
        }
    }

    // MARK: - Streaming fade, arrow-down, tool-card expansion

    /// Arrow-Down: jump to the tail in one step and re-engage following. The
    /// tail row is refreshed first so content that grew while scrolled up
    /// renders at its true height before the jump.
    private func jumpToBottom() {
        isFollowing = true
        let lastRow = windowEnd - windowStart - 1
        if lastRow >= 0, let lastEntry = viewModel?.store.entry(at: windowEnd - 1) {
            if !updateVisibleCell(at: lastRow, with: lastEntry) {
                heights.invalidate(lastEntry.id)
            }
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: lastRow))
        }
        scheduleScrollToBottom()
    }

    /// Expand/collapse a tool card: flip the shared expansion registry (which
    /// `toolCallHeight` reads), then re-measure just that row.
    private func toggleToolCard(_ id: String) {
        ToolCardExpansion.shared.toggle(id)
        guard let store = viewModel?.store else { return }
        var row: Int?
        for i in windowStart..<windowEnd where store.entry(at: i)?.id == id {
            row = i - windowStart
            break
        }
        guard let row else { return }
        heights.invalidate(id)
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }
}

// MARK: - Transcript table

/// The transcript table. Arrow-Down jumps to the bottom of the conversation in
/// one step (rather than the default line-by-line key navigation), so a
/// scrolled-up user gets back to the live tail with one keypress.
final class TranscriptTableView: NSTableView {
    var onArrowDown: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 125 { // Down arrow
            onArrowDown?()
            return
        }
        super.keyDown(with: event)
    }
}

/// The transcript scroll view. `onUserScroll` fires only for real wheel
/// events (never for programmatic follow-scrolls), so scrolling the transcript
/// can take key focus for Arrow-Down without fighting the prompt bar.
final class TranscriptScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}

// MARK: - Scroll helpers

extension NSScrollView {
    func scrollToBottom() {
        guard let documentView else { return }
        let point = NSPoint(
            x: 0,
            y: max(0, documentView.frame.height - contentView.bounds.height)
        )
        contentView.scroll(to: point)
        reflectScrolledClipView(contentView)
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let textRow = NSUserInterfaceItemIdentifier("textRow")
    static let toolRow = NSUserInterfaceItemIdentifier("toolRow")
}

import AppKit
import PiCore
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
///   cheap `insertRows` at the bottom. Scrolling down is therefore always fast.
/// - **Fetched history is kept in memory:** `windowStart` only ever *decreases*.
///   Rows (and their measured heights) are never dropped, so once revealed, a
///   row stays in the height cache and scrolling back to it is instant.
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
    /// Throttle for in-place row refreshes (streaming text AND tool cards):
    /// deltas arrive far faster than the eye needs, and each refresh is a full
    /// CoreText re-measure + cell re-layout. Coalescing to ~20Hz keeps every
    /// delta O(1) and leaves the main thread free to actually paint.
    private let refreshInterval: TimeInterval = 0.05
    private var lastRefresh: TimeInterval = 0
    /// Coalesced async scroll-to-bottom (tile + scroll happen once per run-loop
    /// turn at most, after the table has laid out).
    private var scrollToBottomPending = false

    /// The materialized window over store indices: table row `r` displays
    /// `store.entry(at: windowStart + r)`. `windowStart` only decreases (older
    /// history is prepended); `windowEnd` only increases (tail streams in).
    private var windowStart = 0
    private var windowEnd = 0
    private var lastGeneration: UInt64 = 0

    /// Size of the next upward history fetch, in rows. Compounding: doubles
    /// after every fetch so sustained scrolling eventually pulls everything.
    private var fetchBlock = 0
    private let fetchBlockMax = 600

    /// True while a block of older history is being measured/prepended (drives
    /// the spinner at the top of the conversation).
    private var isFetchingOlder = false

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

        let tv = NSTableView()
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

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false

        tableView = tv
        scrollView = sv
        tv.dataSource = self
        tv.delegate = self

        // Fetch older history (and refresh the tail) on scroll.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

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
        return heights.height(for: entry.id, width: width) {
            entry.kind.measuredHeight(forWidth: width)
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

        // Re-engage following when the user just sent a message, and jump them
        // to the bottom even if they were scrolled up (explicit send = they
        // want to see the response).
        let appendedUserMessage = didAppend && {
            if let last = store.entry(at: newCount - 1), case .userMessage = last.kind { return true }
            return false
        }()
        if appendedUserMessage {
            isFollowing = true
            followTail()
            return
        }

        // Follow (scroll the streaming tail down) only while following is
        // engaged. It's engaged by default and disengaged the moment the user
        // scrolls up; re-engaged when they return to the bottom or send.
        guard isFollowing else { return }

        // Throttled in-place refresh of the streaming row. We seed its cached
        // height from the cell's own layout rather than invalidating it first
        // (invalidation can make the row flicker between the cell-derived and
        // the re-measured height on successive ticks), so the row only ever
        // grows — never oscillates.
        let now = ProcessInfo.processInfo.systemUptime
        var didRefresh = false
        if now - lastRefresh >= refreshInterval {
            lastRefresh = now
            let lastRow = windowEnd - windowStart - 1
            if let lastEntry = store.entry(at: windowEnd - 1) {
                // Batch the height change and the follow-scroll into one
                // display pass so AppKit renders only the final state (row
                // grown + scrolled) — never the intermediate "row taller but
                // not scrolled yet" frame that reads as a bounce.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if !updateVisibleCell(at: lastRow, with: lastEntry) {
                    heights.invalidate(lastEntry.id)
                }
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: lastRow))
                followTail()
                CATransaction.commit()
                didRefresh = true
            }
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

    /// If the viewport is near the top of the fetched region and more history
    /// exists above, fetch the next (compounding) block. Shows the spinner, lets
    /// it paint, then prepends the block and re-anchors the viewport.
    private func checkFetchOlder(store: TranscriptStore, firstVisibleStore: Int, visible: NSRange) {
        guard windowStart > 0 else { return } // whole conversation already fetched
        guard !isFetchingOlder else { return }
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
    /// the cell's own layout (avoids a duplicate CoreText measure — that was
    /// the 100%-CPU hot path). Returns false if the cell isn't currently
    /// visible, in which case the caller should invalidate the height so it
    /// falls back to a measurement.
    @discardableResult
    private func updateVisibleCell(at row: Int, with entry: TranscriptEntry) -> Bool {
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return false }
        configure(cell, with: entry, in: tableView)
        cell.layoutSubtreeIfNeeded()
        if let textRow = cell as? TextRowView {
            let width = max(tableView.bounds.width, 320)
            heights.store(entry.id, width: width, height: textRow.contentHeight + 2)
            return true
        }
        return true // non-text cells: heightOfRow recomputes cheaply via cache miss
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
            view.configure(text: text, thinking: thinking, role: .assistant, isStreaming: isStreaming)
            return view
        case .toolCall(let card):
            let view = tableView.makeView(withIdentifier: .toolRow, owner: nil) as? ToolCallHostView ?? ToolCallHostView()
            view.identifier = .toolRow
            view.configure(card: card)
            return view
        }
    }

    private func configure(_ cell: NSView, with entry: TranscriptEntry, in tableView: NSTableView) {
        switch entry.kind {
        case .userMessage(let text):
            (cell as? TextRowView)?.configure(text: text, thinking: nil, role: .user, isStreaming: false)
        case .assistantMessage(let text, let thinking, let isStreaming):
            (cell as? TextRowView)?.configure(text: text, thinking: thinking, role: .assistant, isStreaming: isStreaming)
        case .toolCall(let card):
            (cell as? ToolCallHostView)?.configure(card: card)
        }
    }
}

// MARK: - Height cache

/// Never remeasure text on every layout pass. Cache height keyed by
/// content+width, invalidate only on genuine change. Grows only as history is
/// revealed and is never evicted — fetched rows stay in memory so scrolling
/// back down is always fast.
final class HeightCache {
    private struct Entry {
        var width: CGFloat
        var height: CGFloat
    }

    private var cache: [String: Entry] = [:]

    func height(for id: String, width: CGFloat, measure: () -> CGFloat) -> CGFloat {
        if let cached = cache[id], abs(cached.width - width) < 0.5 {
            return cached.height
        }
        let height = measure()
        cache[id] = Entry(width: width, height: height)
        return height
    }

    func invalidate(_ id: String) {
        cache.removeValue(forKey: id)
    }

    /// Pre-seeds the cache from an authoritative source (e.g. the visible
    /// cell's own layout) so later `height(for:width:measure:)` calls hit
    /// without running the measure closure.
    func store(_ id: String, width: CGFloat, height: CGFloat) {
        cache[id] = Entry(width: width, height: height)
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

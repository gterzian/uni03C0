import AppKit
import PiCore
import SwiftUI

/// The transcript: an `NSTableView` wrapped in `NSViewRepresentable`.
///
/// Deliberately NOT driven by SwiftUI re-renders — this is the whole point of
/// the AppKit choice. The SwiftUI body never reads the transcript entries, so
/// a streamed delta does not invalidate the SwiftUI graph at all. Updates flow
/// model → coordinator directly: the view model calls `onTranscriptChange`,
/// and the coordinator applies AppKit-native incremental operations:
///
/// - appended rows → `insertRows(at:withAnimation:)`
/// - a row whose content changed in place (the streaming row, almost always)
///   → reconfigure the visible cell + `noteHeightOfRows(withIndexesChanged:)`,
///   which re-measures only that row — nothing below it re-lays-out
/// - wholesale changes (session switch / history rebuild) → `reloadData()`
///
/// No diffable data source: on macOS its `reloadItems` degenerates to
/// `reloadFromSnapshot → _reloadData`, a full re-tile + full height pass on
/// every delta — the exact hot path the TUI profiled.
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
    private var entries: [TranscriptEntry] = []
    private var known: [String: TranscriptEntry] = [:]
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

        viewModel.onTranscriptChange = { [weak self] in
            self?.applyModelChanges()
        }
        applyModelChanges() // initial state (usually empty; populate happens after)

        return sv
    }

    func rebind(viewModel: SessionViewModel) {
        self.viewModel?.onTranscriptChange = nil
        self.viewModel = viewModel
        viewModel.onTranscriptChange = { [weak self] in
            self?.applyModelChanges()
        }
        applyModelChanges()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        return makeCell(for: entries[row], in: tableView)
    }

    // MARK: - Model → table (main actor)

    func applyModelChanges() {
        guard let viewModel, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        let newEntries = viewModel.entries
        guard newEntries != entries else { return }

        // Anchor state captured BEFORE the mutation. A pending coalesced scroll
        // means the user is pinned even if the viewport hasn't landed yet.
        var wasAtBottom = scrollView.isNearBottom(threshold: 4) || scrollToBottomPending
        let previousOffset = scrollView.contentView.bounds.origin
        let oldIDs = entries.map(\.id)
        let newIDs = newEntries.map(\.id)

        // Our live flow is: appends + the last row mutating in place. A session
        // switch replaces everything (different ids), which we treat as a full
        // reload — rare, so the cost is fine.
        var common = 0
        while common < oldIDs.count, common < newIDs.count, oldIDs[common] == newIDs[common] {
            common += 1
        }
        if common != oldIDs.count || newIDs.count < oldIDs.count {
            applyFullReload(newEntries, wasAtBottom: wasAtBottom, previousOffset: previousOffset)
            return
        }

        // In-place content changes within the common prefix (the streaming row,
        // tool-card output). ALL of these are throttled to ~20Hz: each delta is
        // O(1) work, and the cell re-layout + height re-measure run once per
        // tick. Off-tick deltas just advance the model.
        var changedRows = IndexSet()
        let now = ProcessInfo.processInfo.systemUptime
        let refreshDue = now - lastRefresh >= refreshInterval
        for i in 0..<common {
            let entry = newEntries[i]
            if known[entry.id]?.kind != entry.kind {
                known[entry.id] = entry
                if refreshDue {
                    changedRows.insert(i)
                    heights.invalidate(entry.id)
                    updateVisibleCell(at: i, with: entry)
                }
            } else {
                known[entry.id] = entry
            }
        }
        if refreshDue { lastRefresh = now }

        // Appended rows (new messages / tool cards) — cheap, apply immediately.
        var appended = false
        if newIDs.count > oldIDs.count {
            let range = oldIDs.count..<newIDs.count
            for i in range {
                known[newIDs[i]] = newEntries[i]
                heights.invalidate(newIDs[i])
            }
            tableView.insertRows(at: IndexSet(integersIn: range), withAnimation: [])
            appended = true
        }

        // Height invalidation for the changed row(s) only — nothing below
        // re-measures or re-lays-out.
        if !changedRows.isEmpty {
            tableView.noteHeightOfRows(withIndexesChanged: changedRows)
        }

        entries = newEntries

        if wasAtBottom && (appended || !changedRows.isEmpty) {
            scheduleScrollToBottom()
        } else if !wasAtBottom {
            restoreOffset(previousOffset)
        }
    }

    /// Sticky-or-follow scroll anchoring.
    ///
    /// Follow: coalesce into a single async tile+scroll per run-loop turn, so
    /// `documentView.frame.height` is current (after layout) and the viewport
    /// lands exactly on the bottom — no under-scroll that silently un-pins the
    /// user mid-stream, no per-delta tile.
    ///
    /// Sticky: restore the exact previous offset; append-only updates never
    /// shift it, but a session-switch reload might.
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

    private func restoreOffset(_ offset: CGPoint) {
        let docHeight = scrollView.documentView?.frame.height ?? 0
        let maxY = max(0, docHeight - scrollView.contentView.bounds.height)
        let y = min(offset.y, maxY)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func applyFullReload(_ newEntries: [TranscriptEntry], wasAtBottom: Bool, previousOffset: CGPoint) {
        let newIDs = Set(newEntries.map(\.id))
        for entry in newEntries {
            if known[entry.id]?.kind != entry.kind {
                heights.invalidate(entry.id)
            }
            known[entry.id] = entry
        }
        for stale in known.keys where !newIDs.contains(stale) {
            known.removeValue(forKey: stale)
        }
        entries = newEntries
        tableView.reloadData()
        if wasAtBottom {
            scheduleScrollToBottom()
        } else {
            restoreOffset(previousOffset)
        }
    }

    private func updateVisibleCell(at row: Int, with entry: TranscriptEntry) {
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        configure(cell, with: entry, in: tableView)
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard entries.indices.contains(row) else { return 24 }
        let entry = entries[row]
        let width = max(tableView.bounds.width, 320)
        return heights.height(for: entry.id, width: width) {
            entry.kind.measuredHeight(forWidth: width)
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false // read-only transcript
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
/// content+width, invalidate only on genuine change.
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
}

// MARK: - Scroll anchoring

extension NSScrollView {
    func isNearBottom(threshold: CGFloat) -> Bool {
        guard let documentView else { return true }
        let visibleMaxY = documentVisibleRect.maxY
        return documentView.frame.height - visibleMaxY <= threshold
    }

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

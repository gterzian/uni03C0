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
    /// Throttle for streaming-row refreshes: deltas arrive far faster than the
    /// eye needs. Re-measuring and re-laying the growing row is the dominant
    /// cost while streaming, so coalesce to ~20Hz instead of every delta.
    private let streamingRefreshInterval: TimeInterval = 0.05
    private var lastStreamingRefresh: TimeInterval = 0

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

        // Anchor state captured BEFORE the mutation: whether the user was
        // pinned to the bottom, and the exact scroll offset. After applying,
        // either re-pin to the true bottom (flow along) or restore the offset
        // exactly (sticky), whichever the user was doing.
        let wasAtBottom = scrollView.isNearBottom(threshold: 4)
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
        // tool-card state changes). Streaming rows are throttled: both the cell
        // reconfigure and the height re-measure happen at ~20Hz, so each delta
        // is O(1) work. Non-streaming changes (e.g. a tool card finishing) apply
        // immediately.
        var changedRows = IndexSet()
        let now = ProcessInfo.processInfo.systemUptime
        let refreshDue = now - lastStreamingRefresh >= streamingRefreshInterval
        for i in 0..<common {
            let entry = newEntries[i]
            if known[entry.id]?.kind != entry.kind {
                known[entry.id] = entry
                let isStreamingRow = entry.kind.isStreaming
                if !isStreamingRow || refreshDue {
                    changedRows.insert(i)
                    heights.invalidate(entry.id)
                    updateVisibleCell(at: i)
                    if isStreamingRow { lastStreamingRefresh = now }
                }
            } else {
                known[entry.id] = entry
            }
        }

        // Appended rows.
        if newIDs.count > oldIDs.count {
            let range = oldIDs.count..<newIDs.count
            for i in range {
                known[newIDs[i]] = newEntries[i]
                heights.invalidate(newIDs[i])
            }
            tableView.insertRows(at: IndexSet(integersIn: range), withAnimation: [])
        }

        // Height invalidation for the changed row(s) only — nothing below
        // re-measures or re-lays-out.
        if !changedRows.isEmpty {
            tableView.noteHeightOfRows(withIndexesChanged: changedRows)
        }

        entries = newEntries
        restoreScroll(wasAtBottom: wasAtBottom, previousOffset: previousOffset)
    }

    /// Sticky-or-follow scroll anchoring.
    ///
    /// - If the user was at the bottom: force the table to recompute its
    ///   document frame from the updated row heights (otherwise
    ///   `documentView.frame.height` is stale and we under-scroll by the
    ///   streaming row's growth, which silently un-pins the user), then scroll
    ///   to the true bottom so the viewport flows along with new content.
    /// - Otherwise: restore the exact previous offset, so reading position is
    ///   preserved no matter what changed (append-only updates never shift it,
    ///   but a session-switch reload might).
    private func restoreScroll(wasAtBottom: Bool, previousOffset: CGPoint) {
        if wasAtBottom {
            tableView.tile()
            scrollView.scrollToBottom()
        } else {
            let docHeight = scrollView.documentView?.frame.height ?? 0
            let maxY = max(0, docHeight - scrollView.contentView.bounds.height)
            let y = min(previousOffset.y, maxY)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
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
        restoreScroll(wasAtBottom: wasAtBottom, previousOffset: previousOffset)
    }

    private func updateVisibleCell(at row: Int) {
        guard entries.indices.contains(row),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        configure(cell, with: entries[row], in: tableView)
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

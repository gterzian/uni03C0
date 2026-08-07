import AppKit
import PiCore
import SwiftUI

/// The transcript: an `NSTableView` (row virtualization + cell reuse) wrapped
/// in `NSViewRepresentable`. This is the one deliberate AppKit component in
/// the app, and it exists for three reasons (per the design):
///
/// 1. Cost of rendering is a function of *visible row count*, never total
///    transcript length — `heightOfRow` is only asked for visible rows.
/// 2. A streaming delta on the last message invalidates only that row's
///    height (`reconfigureItems`, not `reloadData`) — nothing below it
///    re-measures or re-lays-out.
/// 3. Scroll position is explicitly preserved unless the user was already at
///    the bottom: `wasAtBottom` is captured *before* the snapshot is applied
///    and `scrollToBottom()` happens *after*, in the completion handler.
struct TranscriptView: NSViewRepresentable {
    let entries: [TranscriptEntry]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.apply(entries)
    }
}

// MARK: - Coordinator

final class Coordinator: NSObject, NSTableViewDelegate {
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var dataSource: NSTableViewDiffableDataSource<Int, String>!
    private let heights = HeightCache()
    private var known: [String: TranscriptEntry] = [:]

    func makeScrollView() -> NSScrollView {
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
        tv.delegate = self
        configureDataSource()
        return sv
    }

    private func configureDataSource() {
        dataSource = NSTableViewDiffableDataSource<Int, String>(tableView: tableView) {
            [weak self] tableView, _, _, id in
            self?.makeCell(for: id, in: tableView) ?? NSView()
        }
    }

    // MARK: Applying snapshots

    func apply(_ entries: [TranscriptEntry]) {
        // Anchor state captured BEFORE the mutation.
        let wasAtBottom = scrollView.isNearBottom(threshold: 4)

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(entries.map(\.id), toSection: 0)

        // Rows whose content changed in place (the streaming row, almost
        // always) get reconfigured — not reloaded. This is what avoids a full
        // relayout pass on every streamed delta.
        var reconfigure: [String] = []
        let ids = Set(entries.map(\.id))
        for entry in entries {
            if let old = known[entry.id] {
                if old.kind != entry.kind {
                    reconfigure.append(entry.id)
                    heights.invalidate(entry.id)
                }
            } else {
                heights.invalidate(entry.id)
            }
            known[entry.id] = entry
        }
        for stale in known.keys where !ids.contains(stale) {
            known.removeValue(forKey: stale)
        }
        if !reconfigure.isEmpty {
            // AppKit's diffable snapshots reload only the identified rows (the
            // iOS `reconfigureItems` API doesn't exist on macOS); either way
            // the untouched rows are not re-laid-out.
            snapshot.reloadItems(reconfigure)
        }

        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, wasAtBottom else { return }
            self.scrollView.scrollToBottom()
        }
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let id = dataSource.itemIdentifier(forRow: row),
              let entry = known[id] else { return 24 }
        let width = max(tableView.bounds.width, 320)
        return heights.height(for: id, width: width) {
            entry.kind.measuredHeight(forWidth: width)
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false // read-only transcript
    }

    // MARK: Cells

    private func makeCell(for id: String, in tableView: NSTableView) -> NSView {
        guard let entry = known[id] else { return NSView() }
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

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
/// Tab switch to a visited session restores its materialized window and
/// viewport position (each session's position is captured on the way out and
/// restored on return — see `saveCurrentSessionState`/`restoreScrollState`); a
/// first visit or a same-session reload (`store` `generation` bump) is a full
/// reload positioned at the tail.
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

/// One session's transcript position, captured when the user switches away and
/// restored when they switch back. The window is the coordinator's
/// materialized `[windowStart, windowEnd)` of store indices; the viewport is
/// anchored by the first visible store index plus its pixel offset from the
/// viewport's top edge, so the restoration is robust to anything that
/// streamed or re-measured while the session was in the background.
private struct SessionScrollState {
    var windowStart: Int
    var isFollowing: Bool
    var anchorStoreIndex: Int?
    var anchorPixelOffset: CGFloat
    var fetchBlock: Int
}

// MARK: - Coordinator

final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var tableView: NSTableView!
    var scrollView: NSScrollView!
    /// Local key monitor making Cmd+Up / Cmd+Down cycle through the user's
    /// messages from anywhere in the window — Cmd+Up to the previous one,
    /// Cmd+Down to the next one (or, past the last, all the way to the live
    /// tail) — the always-works jump, regardless of focus/selection. Plain
    /// Arrow-Up/Down deliberately do NOT jump: they scroll the transcript
    /// like the wheel (see `arrowScrollMonitor`). Deferred to EDITABLE text
    /// views (the prompt input, the find field), which use Cmd+Up/Down to
    /// move the insertion point to the beginning/end of their own text.
    ///
    /// `nonisolated(unsafe)`: installed only on the main thread (from
    /// `makeScrollView`), and deinit runs only after the last reference is
    /// dropped — so the read from the nonisolated deinit never races the
    /// write.
    private nonisolated(unsafe) var cmdJumpMonitor: Any?
    /// Local key monitor making the arrow/Home/End/Page keys scroll the
    /// transcript — plain Up/Down a few rows (the wheel feel), Fn+Up/Down and
    /// Page Up/Down a full page, Fn+Left/Home to the beginning, Fn+Right/End
    /// to the tail — from anywhere in the window, NOT a jump. The table only
    /// has key focus right after a scroll, and the rows' non-editable text
    /// views swallow arrows, so a window-level monitor is the only place the
    /// keys always reach the conversation. Deferred to EDITABLE text views
    /// (the prompt input, the find field), which use the arrows for their own
    /// caret/page navigation, and to open dropdowns/sheets, like the Cmd+Down
    /// handling. Same lifecycle rules as `cmdJumpMonitor`.
    private nonisolated(unsafe) var arrowScrollMonitor: Any?
    /// Local key monitor handling the session-bound command shortcuts — Cmd+F
    /// (toggle the find bar), Cmd+G / Shift+Cmd+G (cycle matches), Cmd+R
    /// (reload) — from anywhere in the window. These read `viewModel` AT EVENT
    /// TIME, never captured at render time, so they always act on the ACTIVE
    /// tab: a SwiftUI `.keyboardShortcut` on a hidden button inside
    /// `SessionContent` captured the first tab's view model and kept firing it
    /// after a tab switch, so Cmd+F silently toggled the FIRST tab's find bar
    /// while another tab was active (the reported bug). Unlike Cmd+Up/Down
    /// and the arrows, these are NOT deferred to editable text views — like
    /// menu key equivalents they work while typing in the prompt input or the
    /// find field (Cmd+F from the input opens find; Cmd+G from the field
    /// cycles). Same lifecycle rules as `cmdJumpMonitor`.
    private nonisolated(unsafe) var sessionShortcutMonitor: Any?
    /// The ACTIVE session's height cache (an element of `heightsBySession`).
    private var heights = HeightCache()
    /// Per-session height caches. Row ids are only unique WITHIN a session, so
    /// a session switch must never serve the previous session's cached heights
    /// — but it must also NOT discard the measurements: clearing the cache on
    /// switch and letting `reloadData()` re-measure every row synchronously on
    /// the main thread (full CoreText glyph encode per row) was the
    /// session-switch beachball in samples. Each session keeps its own cache,
    /// so switching BACK to a visited session reuses its heights; an LRU over
    /// the most recently used sessions bounds memory.
    private var heightsBySession: [ObjectIdentifier: HeightCache] = [:]
    private var sessionLRU: [ObjectIdentifier] = []
    private let maxCachedSessions = 6
    weak var viewModel: SessionViewModel?
    private var isApplying = false
    /// Streaming batching: the tail row is refreshed at most every
    /// `batchInterval` seconds (a few words for a typical stream), and the new
    /// chunk crossfades in. The interval is a HARD cap — a per-delta word gate
    /// made fast streams re-layout the whole (possibly huge) streaming row on
    /// nearly every delta, which is the 100%-CPU path in samples. The decision
    /// itself lives in `StreamingRefreshGate` (Core) so it is unit-testable
    /// with the same code the app runs.
    private var streamGate = StreamingRefreshGate(batchInterval: 0.25)
    /// Coalesced async scroll-to-bottom / scroll-to-anchor (tile + scroll
    /// happen once per run-loop turn at most, after the table has laid out).
    private var positionPending = false

    /// Each visited session's transcript position, keyed like `heightsBySession`
    /// (by `ObjectIdentifier`). Captured on rebind when the user switches away;
    /// restored when they switch back — a tab switch never dumps a visited
    /// session at the tail. Bounded by the same LRU as `heightsBySession`
    /// (pruned in `activateSessionCache`).
    private var scrollStateBySession: [ObjectIdentifier: SessionScrollState] = [:]

    /// The materialized window over store indices: table row `r` displays
    /// `store.entry(at: windowStart + r)`. `windowEnd` only ever increases —
    /// the streaming tail is never popped. `windowStart` decreases when older
    /// history is prepended (scroll up) and increases when the user scrolls
    /// back down and rows above the buffer are evicted. The store keeps the
    /// full conversation, so evicted rows re-materialize instantly on a later
    /// scroll-up (no RPC round trip).
    var windowStart = 0
    private var windowEnd = 0
    private var lastGeneration: UInt64 = 0

    /// Rows kept materialized above the viewport while the user scrolls down
    /// (so scrolling back up doesn't immediately stall). Beyond this, older
    /// rows are evicted from the window and their heights dropped.
    private let bufferViewports = 3
    private let minBufferRows = 30
    /// How far one plain Arrow keypress scrolls the transcript — a few rows,
    /// "like scrolling", not a page jump. Scales with the viewport (`scrollByArrow`).
    private let arrowScrollStep: CGFloat = 80
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
    var isFollowing = true
    /// Last viewport bottom edge (document y), for detecting scroll direction.
    private var lastVisibleMaxY: CGFloat = 0
    /// The last row render width (the table column width). When it changes
    /// (a window resize), the table's row rects keep the OLD width's heights
    /// while the cells re-lay out at the new width — the text wraps more, gets
    /// taller than the stale short rects, and overflows upward, clipping the
    /// row's top. `reconcileOnScroll` detects the change and re-queries every
    /// row height (the (id, width)-keyed HeightCache re-measures only the rows
    /// whose width actually changed).
    private var lastRowWidth: CGFloat = 0

    /// The store row ids that currently contain a search match, and the id of
    /// the current match — drive the yellow term backdrops. Rebuilt whenever
    /// the view model's match list changes (`onSearchResultsChanged`). The
    /// query itself is tracked too, so a query change that leaves the match
    /// set identical (same rows) still re-renders the highlighted ranges.
    private var searchMatchRowIDs: Set<String> = []
    private var currentSearchRowID: String?
    private var lastSearchQuery: String?

    /// Mid-search highlight refreshes are coalesced to at most this often: a
    /// `reloadData` per search batch re-typesets every visible row's markdown
    /// (the batch loop can land a batch every few ms on a large session),
    /// which saturates the main thread and freezes scrolling while the
    /// spinner is up. The search completion always flushes below, so the
    /// final highlights are never stale. Same cadence as the streaming gate.
    private static let searchHighlightRefreshInterval: TimeInterval = 0.25
    private var lastSearchHighlightRefresh: TimeInterval = 0

    /// How many rows currently fit in the viewport (or a sane default).
    private func viewportRows() -> Int {
        guard let tableView else { return 20 }
        return max(tableView.rows(in: tableView.visibleRect).length, 1)
    }

    /// The width rows actually RENDER at: the table column's width. Measuring
    /// at `tableView.bounds.width` over-reports — the bounds include the
    /// scroller gutter (legacy scroller, ~32pt) — so the text wraps NARROWER
    /// than measured, the row renders short, and the taller text overflows
    /// upward: the top-cut. The column is the source of truth for the render
    /// width; the 320 floor matches the measurement's usable-width floor.
    private func rowWidth(in tableView: NSTableView) -> CGFloat {
        max(tableView.tableColumns.first?.width ?? tableView.bounds.width, 320)
    }

    /// Rows materialized at the tail on load / reload (a few screens).
    private func initialChunkRows() -> Int {
        max(40, viewportRows() * 5)
    }

    func makeScrollView(viewModel: SessionViewModel) -> NSScrollView {
        self.viewModel = viewModel
        activateSessionCache(viewModel)

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
        tv.setAccessibilityHelp("The conversation with the agent. Arrow keys scroll; Fn+Arrows/Page keys page; Home/End go to the start/end; Cmd+Up/Down cycle between your messages, and Cmd+Down past the last one goes to the live tail.")

        let sv = TranscriptScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false

        tableView = tv
        scrollView = sv
        tv.dataSource = self
        tv.delegate = self
        lastRowWidth = rowWidth(in: tv)

        // Scrolling the transcript takes key focus (so VoiceOver and keyboard
        // users land on the conversation); plain Arrow-Up/Down are handled
        // window-level by `arrowScrollMonitor`, not by table key navigation.
        sv.onUserScroll = { [weak self] in
            guard let self else { return }
            // A real wheel scroll is the user taking over navigation: the
            // user-message cycle restarts from the viewport position. Cleared
            // before the focus guards so it applies whether or not the table
            // already holds key focus.
            self.cycleAnchor = nil
            guard let window = self.tableView.window,
                  window.firstResponder !== self.tableView else { return }
            // Don't steal focus while the find bar is up: typing in the search
            // field must keep working even as the transcript scrolls under it.
            if self.viewModel?.isSearchVisible == true { return }
            window.makeFirstResponder(self.tableView)
        }
        // Cmd+Up / Cmd+Down cycle through the user's messages — Cmd+Up to the
        // previous one, Cmd+Down to the next one (or, past the last, all the
        // way to the live tail) — from anywhere in the window, regardless of
        // focus/selection (plain arrows scroll instead, see below). Deferred
        // to EDITABLE text views (the prompt input, the find field), which
        // use Cmd+Up/Down to move the insertion point to the beginning/end of
        // their own text, and to open dropdowns/sheets, like the prompt's Esc
        // handling.
        cmdJumpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 125 || event.keyCode == 126, // Down / Up
                  event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option),
                  !event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.shift) else { return event }
            guard let self, let window = self.tableView?.window else { return event }
            // Window not front (or a sheet is up): let the key window handle it.
            guard window.isKeyWindow, window.attachedSheet == nil else { return event }
            // A visible popup-menu-level window (a dropdown / the completion
            // list) is tracking: don't steal the key from it.
            guard !NSApp.windows.contains(where: { $0.level == .popUpMenu && $0.isVisible }) else { return event }
            if let editor = window.firstResponder as? NSTextView, editor.isEditable {
                return event
            }
            if event.keyCode == 126 {
                self.jumpToPreviousUserMessage()
            } else {
                self.jumpToNextUserMessage()
            }
            return nil
        }
        // Arrow keys scroll the transcript, following the standard text-scroll
        // conventions: plain Up/Down move a few rows (the wheel feel), Fn+Up/
        // Fn+Down and the Page Up/Down keys move one page, Fn+Left / Home go
        // to the beginning, Fn+Right / End to the tail — from anywhere in the
        // window, so they work right after a trackpad scroll (focus otherwise
        // stays on the prompt bar or a row's text view). This is "like
        // scrolling", NOT a jump: Cmd+Up/Cmd+Down above are the jumps to the
        // top/tail. Deferred to EDITABLE text views (the prompt input, the
        // find field), which use the arrows for their own caret/page
        // navigation, and to open dropdowns/sheets, like the Cmd+Down handling.
        arrowScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Scope: plain / Fn arrows and the Home/End/Page keys. Cmd/Option/
            // Ctrl/Shift-modified keys fall through untouched (Cmd+Up/Down is
            // the jump monitor above; Option+arrows are text-editing in fields).
            let flags = event.modifierFlags
            guard !flags.contains(.command), !flags.contains(.option),
                  !flags.contains(.control), !flags.contains(.shift) else { return event }
            let isFn = flags.contains(.function)
            enum ScrollAction { case lines(Int), page(Int), top, tail }
            let scroll: ScrollAction?
            switch event.keyCode {
            case 126: // Up / Fn+Up
                scroll = isFn ? .page(-1) : .lines(-1)
            case 125: // Down / Fn+Down
                scroll = isFn ? .page(1) : .lines(1)
            case 123 where isFn, 115: // Fn+Left / Home: beginning of conversation
                scroll = .top
            case 124 where isFn, 119: // Fn+Right / End: tail
                scroll = .tail
            case 116: // Page Up
                scroll = .page(-1)
            case 121: // Page Down
                scroll = .page(1)
            default:
                return event
            }
            guard let self, let window = self.tableView?.window else { return event }
            // Window not front (or a sheet is up): let the key window handle it.
            guard window.isKeyWindow, window.attachedSheet == nil else { return event }
            // A visible popup-menu-level window (a dropdown / the completion
            // list) is tracking: don't steal the key from it.
            guard !NSApp.windows.contains(where: { $0.level == .popUpMenu && $0.isVisible }) else { return event }
            if let editor = window.firstResponder as? NSTextView, editor.isEditable {
                return event
            }
            switch scroll {
            case .lines(let d): self.scrollByArrow(CGFloat(d))
            case .page(let d): self.scrollByPage(CGFloat(d))
            case .top: self.jumpToTop()
            case .tail: self.jumpToBottom()
            case nil: break
            }
            return nil
        }

        // Cmd+F / Cmd+G / Shift+Cmd+G / Cmd+R — the session-bound command
        // shortcuts, handled here (not as SwiftUI hidden buttons) so they
        // always act on the ACTIVE tab: the coordinator's `viewModel` is
        // re-pointed on every rebind, and the monitor reads it at event time.
        // See the property comment on `sessionShortcutMonitor`.
        sessionShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = event.keyCode
            guard key == 3 || key == 5 || key == 15, // F / G / R
                  event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option),
                  !event.modifierFlags.contains(.control) else { return event }
            let isShift = event.modifierFlags.contains(.shift)
            guard let self, let window = self.tableView?.window else { return event }
            // Window not front (or a sheet is up): let the key window handle it.
            guard window.isKeyWindow, window.attachedSheet == nil else { return event }
            // A visible popup-menu-level window (a dropdown / the completion
            // list) is tracking: don't steal the key from it.
            guard !NSApp.windows.contains(where: { $0.level == .popUpMenu && $0.isVisible }) else { return event }
            guard let vm = self.viewModel else { return event }
            switch key {
            case 3: // Cmd+F: toggle the find bar (closing clears the query).
                vm.toggleSearch()
            case 5: // Cmd+G / Shift+Cmd+G: cycle matches while the bar is up.
                guard vm.isSearchVisible else { return event }
                if isShift {
                    vm.previousSearchMatch()
                } else {
                    vm.nextSearchMatch()
                }
            case 15: // Cmd+R: reload the session from disk.
                Task { await vm.reload() }
            default:
                return event
            }
            return nil
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
        viewModel.onSearchJump = { [weak self] storeIndex in
            self?.scrollToStoreIndex(storeIndex)
        }
        viewModel.onSearchResultsChanged = { [weak self] in
            self?.refreshSearchHighlight()
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
        if let cmdJumpMonitor {
            NSEvent.removeMonitor(cmdJumpMonitor)
        }
        if let arrowScrollMonitor {
            NSEvent.removeMonitor(arrowScrollMonitor)
        }
        if let sessionShortcutMonitor {
            NSEvent.removeMonitor(sessionShortcutMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    func rebind(viewModel: SessionViewModel) {
        // Capture the session we're leaving BEFORE swapping it out: switching
        // back to it must land on the same window + viewport, not the tail.
        saveCurrentSessionState()
        self.viewModel?.onTranscriptChange = nil
        self.viewModel?.onSearchJump = nil
        self.viewModel?.onSearchResultsChanged = nil
        self.viewModel = viewModel
        activateSessionCache(viewModel)
        viewModel.onTranscriptChange = { [weak self] in
            self?.applyModelChanges()
        }
        viewModel.onSearchJump = { [weak self] storeIndex in
            self?.scrollToStoreIndex(storeIndex)
        }
        viewModel.onSearchResultsChanged = { [weak self] in
            self?.refreshSearchHighlight()
        }
        if let saved = scrollStateBySession[ObjectIdentifier(viewModel)] {
            restoreScrollState(saved, store: viewModel.store)
        } else {
            // First visit (or a session whose state was pruned/cleared): start
            // at the tail, exactly as before.
            resetToTail(viewModel.store)
        }
    }

    /// Points `heights` at the cache for `session`, creating it on first
    /// visit, and prunes the least-recently-used caches beyond the cap. Called
    /// on every session bind/rebind (tab switch), so switching back to a
    /// previously-visited session reuses the heights it was measured at — the
    /// reload that follows never re-measures a row whose content is unchanged.
    private func activateSessionCache(_ session: SessionViewModel) {
        let key = ObjectIdentifier(session)
        sessionLRU.removeAll { $0 == key }
        sessionLRU.append(key)
        if let cached = heightsBySession[key] {
            heights = cached
        } else {
            let fresh = HeightCache()
            heightsBySession[key] = fresh
            heights = fresh
        }
        while sessionLRU.count > maxCachedSessions {
            let evicted = sessionLRU.removeFirst()
            heightsBySession.removeValue(forKey: evicted)
            scrollStateBySession.removeValue(forKey: evicted)
        }
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
        return rowHeight(for: entry, width: rowWidth(in: tableView))
    }

    /// The height the table should use for a row. Settled rows go through the
    /// (id, width, content) height cache. STREAMING rows also go through the
    /// cache — but seeded by the renderer, not measured here on every query:
    /// the table asks `heightOfRow` on every tile/scroll/`noteHeightOfRows`,
    /// and each query used to re-measure the whole (possibly huge) streaming
    /// text from scratch — the 100%-CPU path in samples. The table's height
    /// must match what the CELL renders (the last batched refresh), so the
    /// cached height the renderer seeded is authoritative even while the store
    /// has newer, not-yet-rendered content; serving the store's newest would
    /// pad the row above a shorter cell. A miss happens only before a row's
    /// first render (or after eviction) — measure and seed then.
    private func rowHeight(for entry: TranscriptEntry, width: CGFloat) -> CGFloat {
        if entry.kind.isStreaming {
            if let cached = heights.heightIfPresent(for: entry.id, width: width) {
                return cached
            }
            let height = entry.measuredHeight(forWidth: width)
            heights.store(entry.id, width: width, height: height, tag: Self.contentTag(for: entry))
            return height
        }
        return heights.height(for: entry.id, width: width, tag: Self.contentTag(for: entry)) {
            entry.measuredHeight(forWidth: width)
        }
    }

    /// The content fingerprint a text row's height was measured for. The cache
    /// is (id, width)-keyed, but a streaming row's content changes every delta
    /// while its height is only re-seeded on the 0.25s batched refresh — the
    /// tag lets the renderer reuse a height that is still valid (same content)
    /// and re-measure only on genuine change. Includes the cache-line fields
    /// (they render under the final message, so they affect the height) and the
    /// streaming flag (the caret adds a line's worth of width pressure).
    private static func contentTag(for entry: TranscriptEntry) -> String? {
        switch entry.kind {
        case .userMessage(let text):
            return "u\u{1F}\(text)"
        case .assistantMessage(let text, let thinking, let isStreaming):
            let rate = entry.cacheHitRate.map { String($0) } ?? "-"
            return "a\(isStreaming ? 1 : 0)\u{1F}\(text)\u{1F}\(thinking)\u{1F}\(rate)\u{1F}\(entry.cacheMiss ? 1 : 0)"
        case .errorMessage(let text):
            return "e\u{1F}\(text)"
        case .abortedMessage(let text):
            return "b\u{1F}\(text)"
        case .toolCall:
            return nil // tool cards invalidate instead (output/expansion shape)
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
            var appendedUserMessage = false
            let tableRange = (oldEnd - windowStart)..<(newCount - windowStart)
            for i in oldEnd..<newCount {
                if let entry = store.entry(at: i) {
                    heights.invalidate(entry.id)
                    if case .userMessage = entry.kind { appendedUserMessage = true }
                }
            }
            tableView.insertRows(at: IndexSet(integersIn: tableRange), withAnimation: [])
            didAppend = true
            // A freshly sent prompt (or a queued-steering flush) echoes the
            // user's message into the store: jump to the tail and re-engage
            // following so the response streams into view. The followTail
            // below does the actual scroll; setting isFollowing first lets the
            // streaming refresh run for the new turn-start placeholder.
            if appendedUserMessage {
                isFollowing = true
            }
        }

        // Turn-end tool-card settles (abort/error/truncation): the store
        // flips any in-flight tool card from `.running` to `.failed` in place
        // (pi sends no `tool_execution_end` for an interrupted tool). The card
        // may not be the tail — a notice row can follow it — so refresh every
        // VISIBLE card whose rendered state no longer matches the store
        // (off-screen rows re-render with the new state when scrolled into
        // view). This must run even when NOT following: the user may be
        // reading history while a command runs and aborts it.
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        if visibleRows.length > 0 {
            let visibleRange = visibleRows.location..<(visibleRows.location + visibleRows.length)
            for row in visibleRange {
                let storeIndex = windowStart + row
                guard let entry = store.entry(at: storeIndex),
                      case .toolCall(let card) = entry.kind,
                      card.state != .running,
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ToolCallHostView,
                      cell.renderedCardID == card.id,
                      cell.renderedCardState != card.state else { continue }
                updateVisibleCell(at: row, with: entry)
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            }
        }

        // A prompt was just sent: the append above already re-engaged
        // following, so the tail streams into view from the first echo.
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
            if let e = store.entry(at: i), e.kind.isStreaming || e.id == streamGate.lastStreamedID {
                streamingRow = i - windowStart
                streamingEntry = e
                break
            }
        }
        if let streamingEntry, streamingRow >= 0,
           case .assistantMessage(let text, let thinking, let isStreaming) = streamingEntry.kind {
            // Batched by `StreamingRefreshGate` (a hard 0.25s cap, plus the
            // first chunk of a new message and the streaming→final flag flip)
            // — re-rendering per delta is the 100%-CPU path.
            if streamGate.shouldRefresh(entryID: streamingEntry.id, text: text, thinking: thinking, isStreaming: isStreaming, now: now) {
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
                    shouldRefresh = streamGate.shouldRefreshRunningToolCard(now: now)
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

        // A column-width change (window resize) leaves the table's row rects at
        // the old width's heights: the cells re-lay out at the new width, wrap
        // more, and their text overflows upward past the stale short rects —
        // the row's top is clipped ("cut off as if scrolled down"). Streaming
        // happens to heal it via the per-delta `noteHeightOfRows`; an abort
        // (or any settled state) freezes it forever. Re-query every materialized
        // row's height when the render width changes; the cache is
        // (id, width)-keyed, so only the width-changed rows actually re-measure.
        let width = rowWidth(in: tableView)
        if abs(width - lastRowWidth) > 0.5 {
            lastRowWidth = width
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
        }

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
            // A user-message cycle / search jump queued behind this load
            // (the spinner was already up) lands now that the window grew.
            self.flushDeferredMaterialize()
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

    // MARK: - Per-session scroll position

    /// Captures the current session's window and viewport position so a later
    /// tab switch back to it restores exactly where the user left off. Called
    /// on every rebind BEFORE the view model is swapped. The viewport is
    /// anchored by the first visible store index plus its pixel offset from
    /// the viewport's top edge, so restoration is robust to height changes
    /// (streaming rows, re-measures) that happened while the session was away.
    private func saveCurrentSessionState() {
        guard let viewModel else { return }
        let key = ObjectIdentifier(viewModel)
        let visible = tableView.rows(in: tableView.visibleRect)
        var anchorStoreIndex: Int?
        var anchorPixelOffset: CGFloat = 0
        if visible.length > 0 {
            let row = visible.location
            anchorStoreIndex = windowStart + row
            anchorPixelOffset = tableView.rect(ofRow: row).origin.y - tableView.visibleRect.origin.y
        }
        scrollStateBySession[key] = SessionScrollState(
            windowStart: windowStart,
            isFollowing: isFollowing,
            anchorStoreIndex: anchorStoreIndex,
            anchorPixelOffset: anchorPixelOffset,
            fetchBlock: fetchBlock
        )
    }

    /// Restores a previously-visited session's materialized window and
    /// viewport position instead of dumping it at the tail. The store kept
    /// folding while the session was in the background, so only the window END
    /// is extended to include the rows that streamed since — the restored
    /// viewport stays put and the new tail sits below it. Heights are not
    /// cleared: `activateSessionCache` already swapped in this session's cache
    /// on rebind, so `reloadData` re-measures only rows whose content changed.
    private func restoreScrollState(_ saved: SessionScrollState, store: TranscriptStore) {
        let count = store.count
        windowStart = min(max(0, saved.windowStart), count)
        windowEnd = max(windowStart, count)
        fetchBlock = saved.fetchBlock
        lastGeneration = store.currentGeneration
        isFollowing = saved.isFollowing
        isFetchingOlder = false
        isEvictingOlder = false
        viewModel?.isFetchingOlder = false
        searchMatchRowIDs = []
        currentSearchRowID = nil
        lastSearchQuery = nil
        cycleAnchor = nil
        tableView.reloadData()
        if saved.isFollowing {
            scheduleScrollToBottom()
        } else {
            scheduleScrollToAnchor(storeIndex: saved.anchorStoreIndex, pixelOffset: saved.anchorPixelOffset)
        }
    }

    /// Defers a scroll to the anchored store index (a restored viewport) to
    /// the next run-loop turn, once `reloadData` has laid the table out. Falls
    /// back to the tail when the anchor is missing or no longer in the window
    /// (e.g. the store shrank under it).
    private func scheduleScrollToAnchor(storeIndex: Int?, pixelOffset: CGFloat) {
        guard !positionPending else { return }
        positionPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.positionPending = false
            self.tableView.tile()
            guard let storeIndex else {
                self.scrollView.scrollToBottom()
                return
            }
            let row = storeIndex - self.windowStart
            guard row >= 0, row < (self.windowEnd - self.windowStart) else {
                self.scrollView.scrollToBottom()
                return
            }
            let rowY = self.tableView.rect(ofRow: row).origin.y
            let targetY = max(0, rowY - pixelOffset)
            self.scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            self.lastVisibleMaxY = self.scrollView.documentVisibleRect.maxY
        }
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
        // A reload rebuilds the whole history: any previously-saved position is
        // meaningless, so the next visit to this session starts at the tail.
        cycleAnchor = nil
        if let vm = viewModel {
            scrollStateBySession.removeValue(forKey: ObjectIdentifier(vm))
        }
        // Heights are NOT cleared here: they live per-session (`heights` was
        // already swapped to this session's cache by `activateSessionCache` on
        // rebind, and a same-session reload keeps its cache — the content tag
        // re-measures only rows whose text actually changed). Clearing on
        // switch re-measured every row synchronously on the main thread — the
        // session-switch beachball in samples.
        // The same applies to search-match rows: ids from the previous session
        // would paint stale yellow backdrops on the new one. The view model's
        // match list still holds the old session's row ids (the session
        // switched underneath it), so drop the coordinator's copy rather than
        // re-derive it.
        searchMatchRowIDs = []
        currentSearchRowID = nil
        lastSearchQuery = nil
        tableView.reloadData()
        scheduleScrollToBottom()
    }

    private func scheduleScrollToBottom() {
        guard !positionPending else { return }
        positionPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.positionPending = false
            self.tableView.tile()
            self.scrollView.scrollToBottom()
            // Re-seed the direction detector: the first user scroll after a
            // restore must be compared against the restored position, not a
            // stale one from the previous session.
            self.lastVisibleMaxY = self.scrollView.documentVisibleRect.maxY
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
        // The table can transiently hold fewer rows than the window (e.g. a
        // visibility catch-up racing a session-switch reload); view(atColumn:)
        // RAISES on an out-of-range row instead of returning nil.
        guard row >= 0, row < tableView.numberOfRows else { return false }
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return false }
        let width = rowWidth(in: tableView)

        if cell is TextRowView {
            let tag = Self.contentTag(for: entry)

            if entry.kind.isStreaming, let textRow = cell as? TextRowView {
                // STREAMING rows: the height comes from the cell's own layout
                // manager, never from a full CoreText measure. `configure`
                // replaces only the appended tail of the text storage
                // (see `TextRowView.applyAttributedString`), so the layout
                // manager lays out incrementally — only the newly-appended
                // characters are typeset — whereas `measuredHeight` re-typesets
                // the WHOLE growing text from scratch via `boundingRect`, which
                // is pathologically slow on newline-heavy text (~400ms for 13k
                // chars): at the 0.25s batch rate that saturated the main
                // thread at 100% in samples. The layout-manager height IS what
                // renders, so the table and the cell agree by construction (the
                // measured/rendered invariant holds within the 2pt slack).
                // Configure + lay out FIRST (the row frame is resized after;
                // layout computes the full usedRect regardless of the frame),
                // then read the authoritative height and re-seed the cache.
                if heights.cached(for: entry.id, width: width)?.tag != tag {
                    if abs(cell.frame.width - width) > 1 {
                        cell.frame.size.width = width
                    }
                    configure(cell, with: entry, in: tableView)
                    cell.layoutSubtreeIfNeeded()
                    // +2 to match `TranscriptText.measuredHeight`'s slack so
                    // the settled-row re-measure (boundingRect, once per
                    // message) lands on the same height — no jump at settle.
                    let measured = textRow.contentHeight + 2
                    if abs(cell.frame.height - measured) > 0.5 {
                        cell.frame.size.height = measured
                    }
                    heights.store(entry.id, width: width, height: measured, tag: tag)
                }
                return true
            }

            // Settled rows: the exact height from the authoritative measure,
            // content-aware (cached once per content — re-measured only on
            // genuine change, never per table query).
            let measured = heights.height(for: entry.id, width: width, tag: tag) {
                entry.measuredHeight(forWidth: width)
            }

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
        // Font size is app-wide: every session's cached heights were measured
        // at the old size, so every cache must go.
        for cache in heightsBySession.values {
            cache.clear()
        }
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

    /// Jumps the transcript to a store index (a search match). The store holds
    /// the FULL conversation, so a match above the materialized window just
    /// needs rows materialized — no RPC round trip. Fetches history so the
    /// match lands below a buffer (fluid scrolling up from it), keeps the
    /// streaming tail (the full bottom) in the window, then scrolls the row
    /// into the middle of the viewport.
    func scrollToStoreIndex(_ storeIndex: Int) {
        cancelOngoingScroll()
        guard let row = materialize(storeIndex: storeIndex, completion: .centered) else { return }
        // A search jump is a deliberate position — stop following; the user
        // returning to the bottom re-engages it.
        isFollowing = false
        cycleAnchor = nil
        tableView.tile()
        let rowRect = tableView.rect(ofRow: row)
        let targetY = rowRect.midY - scrollView.contentView.bounds.height / 2
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, targetY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        lastVisibleMaxY = scrollView.documentVisibleRect.maxY
    }

    /// How a jump re-lands after a deferred materialization: user-message
    /// landings anchor at the top (`jumpToUserMessage`), search jumps center
    /// (`scrollToStoreIndex`).
    private enum MaterializeCompletion {
        case userMessage
        case centered
    }

    /// A jump whose materialization was deferred behind the loading spinner;
    /// landed once the in-flight prepend completes.
    private var deferredMaterialize: (storeIndex: Int, completion: MaterializeCompletion)?

    /// Fetches of more than this many rows are deferred one run-loop turn with
    /// the loading spinner up, so a slow measurement (big text rows, tool
    /// cards) shows the spinner instead of a silent main-thread freeze. The
    /// cycle's boundary fetch (~40 rows) and far search jumps both exceed it.
    private static let largeMaterializeThreshold = 25

    /// Makes `storeIndex` part of the materialized window, prepending older
    /// history above it as needed, and returns its table row. The store holds
    /// the FULL conversation, so a row above the materialized window just
    /// needs rows materialized — no RPC round trip. History is fetched so the
    /// target lands below a buffer (fluid scrolling up from it), and the
    /// streaming tail (the full bottom) stays in the window. Shared by the
    /// search jump and the Cmd+Up/Down user-message cycle.
    ///
    /// A large fetch is DEFERRED: the loading spinner is raised, the prepend
    /// runs on the next run-loop turn (so the spinner paints before the
    /// synchronous measurement), and the caller re-lands via `completion`.
    /// In that case nil is returned now and the landing happens later.
    private func materialize(storeIndex: Int, completion: MaterializeCompletion) -> Int? {
        guard let store = viewModel?.store, store.count > 0 else { return nil }
        let clamped = min(max(0, storeIndex), store.count - 1)
        if clamped < windowStart {
            // Prepend history in one go so the target sits `buffer` rows below
            // the new top (the same re-anchor-free prepend as the compounding
            // fetch, but targeted — the destination is the target row, not the
            // old viewport).
            let buffer = max(viewportRows() * 2, 40)
            let targetStart = max(0, clamped - buffer)
            let fetched = windowStart - targetStart
            guard fetched > 0 else { return nil }
            if fetched > Self.largeMaterializeThreshold, !isEvictingOlder {
                scheduleDeferredMaterialize(targetStart: targetStart, fetched: fetched,
                                            storeIndex: clamped, completion: completion)
                return nil
            }
            prependMaterialized(targetStart: targetStart, fetched: fetched)
        }
        let row = clamped - windowStart
        guard row >= 0, row < (windowEnd - windowStart) else { return nil }
        return row
    }

    /// Prepends `fetched` rows at the top of the materialized window (rows
    /// above the viewport never shift it) and restarts the compounding block.
    private func prependMaterialized(targetStart: Int, fetched: Int) {
        windowStart = targetStart
        tableView.insertRows(at: IndexSet(integersIn: 0..<fetched), withAnimation: [])
        tableView.tile()
        // The compounding block restarts small: this fetch covered the gap.
        fetchBlock = max(initialChunkRows() / 2, 20)
    }

    /// Defers a large materialization behind the loading spinner (the same
    /// `isFetchingOlder` the compounding scroll-fetch raises): raise the
    /// spinner, prepend on the next run-loop turn so it paints first, then
    /// re-land the jump. A second jump arriving while one is deferred rides on
    /// the same prepend (`deferredMaterialize`).
    private func scheduleDeferredMaterialize(targetStart: Int, fetched: Int, storeIndex: Int, completion: MaterializeCompletion) {
        if isFetchingOlder {
            // A load is already in flight (a scroll-fetch or an earlier
            // deferred materialization); the in-flight prepend — or the
            // re-materialize it triggers — will cover this target too.
            deferredMaterialize = (storeIndex, completion)
            return
        }
        isFetchingOlder = true
        viewModel?.isFetchingOlder = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isFetchingOlder = false
            self.viewModel?.isFetchingOlder = false
            self.prependMaterialized(targetStart: targetStart, fetched: fetched)
            self.flushDeferredMaterialize()
            switch completion {
            case .userMessage: self.jumpToUserMessage(storeIndex)
            case .centered: self.scrollToStoreIndex(storeIndex)
            }
        }
    }

    /// Lands a jump that queued behind an in-flight load once that load's
    /// prepend has grown the window (re-deferring if it still needs more
    /// history). Called by both loaders' completions.
    private func flushDeferredMaterialize() {
        guard let pending = deferredMaterialize else { return }
        deferredMaterialize = nil
        switch pending.completion {
        case .userMessage: jumpToUserMessage(pending.storeIndex)
        case .centered: scrollToStoreIndex(pending.storeIndex)
        }
    }

    /// Re-renders the yellow search-term highlights after the match list, the
    /// current match, or the query changed. Term backgrounds don't change
    /// heights, so a plain reload of the materialized window suffices (heights
    /// stay cached and the scroll position is preserved).
    private func refreshSearchHighlight() {
        guard let viewModel else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if viewModel.isSearching {
            // Coalesce while the search runs: a reloadData per batch
            // re-typesets every visible row's markdown (and deriving the match
            // id set is O(matches)), which saturates the main thread and
            // freezes scrolling. Inside the window, skip even the set
            // derivation; the completion (isSearching false, below) always
            // flushes the final state.
            if now - lastSearchHighlightRefresh < Self.searchHighlightRefreshInterval {
                return
            }
        }
        let ids = Set(viewModel.searchMatches.map(\.rowID))
        let current = viewModel.searchMatches.indices.contains(viewModel.searchCurrentIndex)
            ? viewModel.searchMatches[viewModel.searchCurrentIndex].rowID
            : nil
        let query = viewModel.searchQuery
        guard ids != searchMatchRowIDs || current != currentSearchRowID || query != lastSearchQuery else { return }
        searchMatchRowIDs = ids
        currentSearchRowID = current
        lastSearchQuery = query
        if viewModel.isSearching {
            lastSearchHighlightRefresh = now
        }
        tableView.reloadData()
    }

    // MARK: - Cells

    private func makeCell(for entry: TranscriptEntry, in tableView: NSTableView) -> NSView {
        // Search state for this row: the live query (nil when the find bar is
        // closed or this row has no match) drives the yellow term highlight;
        // the current match uses a stronger shade. Matches are tracked by row
        // id so the flag is stable across streaming mutations of the same
        // entry.
        let query = searchMatchRowIDs.contains(entry.id) ? viewModel?.searchQuery : nil
        let isCurrent = currentSearchRowID == entry.id
        let caseSensitive = viewModel?.isCaseSensitive ?? false
        let view: NSView
        switch entry.kind {
        case .userMessage(let text):
            let v = tableView.makeView(withIdentifier: .textRow, owner: nil) as? TextRowView ?? TextRowView()
            v.identifier = .textRow
            v.configure(text: text, thinking: nil, role: .user, isStreaming: false, searchQuery: query, searchCaseSensitive: caseSensitive, isCurrentSearchMatch: isCurrent)
            view = v
        case .assistantMessage(let text, let thinking, let isStreaming):
            let v = tableView.makeView(withIdentifier: .textRow, owner: nil) as? TextRowView ?? TextRowView()
            v.identifier = .textRow
            v.configure(text: text, thinking: thinking, role: .assistant, isStreaming: isStreaming, cacheHitRate: entry.cacheHitRate, cacheMiss: entry.cacheMiss, searchQuery: query, searchCaseSensitive: caseSensitive, isCurrentSearchMatch: isCurrent)
            view = v
        case .errorMessage(let text):
            let v = tableView.makeView(withIdentifier: .textRow, owner: nil) as? TextRowView ?? TextRowView()
            v.identifier = .textRow
            v.configure(text: text, thinking: nil, role: .error, isStreaming: false, searchQuery: query, searchCaseSensitive: caseSensitive, isCurrentSearchMatch: isCurrent)
            view = v
        case .abortedMessage(let text):
            let v = tableView.makeView(withIdentifier: .textRow, owner: nil) as? TextRowView ?? TextRowView()
            v.identifier = .textRow
            v.configure(text: text, thinking: nil, role: .aborted, isStreaming: false, searchQuery: query, searchCaseSensitive: caseSensitive, isCurrentSearchMatch: isCurrent)
            view = v
        case .toolCall(let card):
            let v = tableView.makeView(withIdentifier: .toolRow, owner: nil) as? ToolCallHostView ?? ToolCallHostView()
            v.identifier = .toolRow
            v.configure(card: card, searchQuery: query, searchCaseSensitive: caseSensitive, isCurrentSearchMatch: isCurrent) { [weak self] in
                self?.toggleToolCard(card.id)
            }
            view = v
        }
        // A recycled cell keeps the PREVIOUS row's frame. NSTableView does not
        // reliably re-frame a cell whose height changed (the width follows via
        // autoresizing, the height does not — "width applied, height not"), so
        // a cell recycled from a SHORTER row into a taller one lays out its
        // text view at the stale short height: the text overflows upward and
        // the row's top is clipped ("cut off as if scrolled down"). Size the
        // cell to THIS row's measured height right away — the same value
        // `heightOfRow` returns — so the first layout pass is correct even if
        // the table never re-frames the cell. For a streaming row the cell is
        // configured with the store's CURRENT content, so its height must be
        // measured for that content (the content-tagged cache re-measures when
        // the store has outgrown the last rendered refresh) — a plain (id,
        // width) hit could serve the shorter height of older, already-rendered
        // text and re-introduce the top-cut.
        let width = rowWidth(in: tableView)
        let height: CGFloat
        if entry.kind.isStreaming {
            // Streaming rows are measured from the cell's incremental layout
            // (never a full CoreText measure — see updateVisibleCell). If the
            // cache already holds a height for this exact content, reuse it;
            // otherwise lay the cell out (cheap: only the new characters are
            // typeset) and read the layout-manager height.
            if heights.cached(for: entry.id, width: width)?.tag == Self.contentTag(for: entry),
               let cached = heights.heightIfPresent(for: entry.id, width: width) {
                height = cached
            } else if let textRow = view as? TextRowView {
                // Already configured above; lay out (incremental) and read the
                // layout-manager height.
                textRow.layoutSubtreeIfNeeded()
                height = textRow.contentHeight + 2
                heights.store(entry.id, width: width, height: height, tag: Self.contentTag(for: entry))
            } else {
                height = entry.measuredHeight(forWidth: width)
            }
        } else {
            height = rowHeight(for: entry, width: width)
        }
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return view
    }

    private func configure(_ cell: NSView, with entry: TranscriptEntry, in tableView: NSTableView) {
        let query = searchMatchRowIDs.contains(entry.id) ? viewModel?.searchQuery : nil
        let isCurrent = currentSearchRowID == entry.id
        let caseSensitive = viewModel?.isCaseSensitive ?? false
        switch entry.kind {
        case .userMessage(let text):
            (cell as? TextRowView)?.configure(text: text, thinking: nil, role: .user, isStreaming: false, searchQuery: query, searchCaseSensitive: caseSensitive, isCurrentSearchMatch: isCurrent)
        case .assistantMessage(let text, let thinking, let isStreaming):
            (cell as? TextRowView)?.configure(text: text, thinking: thinking, role: .assistant, isStreaming: isStreaming, cacheHitRate: entry.cacheHitRate, cacheMiss: entry.cacheMiss, searchQuery: query, searchCaseSensitive: caseSensitive, isCurrentSearchMatch: isCurrent)
        case .errorMessage(let text):
            (cell as? TextRowView)?.configure(text: text, thinking: nil, role: .error, isStreaming: false, searchQuery: query, searchCaseSensitive: caseSensitive, isCurrentSearchMatch: isCurrent)
        case .abortedMessage(let text):
            (cell as? TextRowView)?.configure(text: text, thinking: nil, role: .aborted, isStreaming: false, searchQuery: query, searchCaseSensitive: caseSensitive, isCurrentSearchMatch: isCurrent)
        case .toolCall(let card):
            (cell as? ToolCallHostView)?.configure(card: card, searchQuery: query, searchCaseSensitive: caseSensitive, isCurrentSearchMatch: isCurrent) { [weak self] in
                self?.toggleToolCard(card.id)
            }
        }
    }

    // MARK: - Streaming fade, arrow scrolling, jump-to-tail, tool-card expansion

    /// Plain Arrow-Up/Down scroll the transcript like the wheel: each press
    /// moves the view by `arrowScrollStep` (a few rows) toward the head or the
    /// tail, clamped to the document. This is incremental "scrolling", not a
    /// jump — Cmd+Down past the last user message (`jumpToNextUserMessage`)
    /// is the one-key jump to the tail. The
    /// scroll feeds the normal direction-aware follow logic in
    /// `reconcileOnScroll` (scrolling up disengages following; reaching the
    /// bottom re-engages it).
    private func scrollByArrow(_ direction: CGFloat) {
        // A keyboard scroll is the user taking over navigation: the
        // user-message cycle restarts from the viewport position, and any
        // in-flight scroll is cancelled.
        cycleAnchor = nil
        cancelOngoingScroll()
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let viewport = scrollView.contentView.bounds.height
        let step = max(arrowScrollStep, viewport / 8)
        let maxY = max(0, documentView.frame.height - viewport)
        let target = min(maxY, max(0, scrollView.contentView.bounds.origin.y + direction * step))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Fn+Up/Fn+Down and the Page Up/Down keys: scroll one full viewport
    /// toward the head or the tail (Apple's "Page Up: scroll up one page").
    private func scrollByPage(_ direction: CGFloat) {
        cycleAnchor = nil
        cancelOngoingScroll()
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let viewport = scrollView.contentView.bounds.height
        let maxY = max(0, documentView.frame.height - viewport)
        let target = min(maxY, max(0, scrollView.contentView.bounds.origin.y + direction * viewport))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Home / Fn+Left: jump to the very beginning of the conversation (store
    /// index 0), materializing older history as needed, and stop following
    /// (the user returning to the bottom re-engages it). This is also the
    /// terminal step of the Cmd+Up cycle — past the first user message, Up
    /// goes all the way to the top.
    func jumpToTop() {
        cycleAnchor = nil
        cancelOngoingScroll()
        scrollToStoreIndex(0)
        takeTranscriptFocus()
    }

    /// End / Fn+Right / Cmd+Down past the last user message: jump to the tail
    /// in one step and re-engage following. The tail row is refreshed first so
    /// content that grew while scrolled up renders at its true height before
    /// the jump.
    func jumpToBottom() {
        cycleAnchor = nil
        cancelOngoingScroll()
        isFollowing = true
        let lastRow = windowEnd - windowStart - 1
        if lastRow >= 0, let lastEntry = viewModel?.store.entry(at: windowEnd - 1) {
            if !updateVisibleCell(at: lastRow, with: lastEntry) {
                heights.invalidate(lastEntry.id)
            }
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: lastRow))
        }
        scheduleScrollToBottom()
        takeTranscriptFocus()
    }

    /// Takes key focus on the transcript table after a keyboard navigation
    /// jump (Cmd+Up/Cmd+Down, Home/End, Fn+Left/Right). Without this, a jump
    /// performed while the prompt input (or any editable field) had focus
    /// leaves the insertion point THERE, and the very next plain Arrow-Up/Down
    /// is deferred to that field (moving its caret) instead of scrolling the
    /// transcript — the reported "Arrow-Down does nothing after the jump"
    /// until a wheel scroll moves focus to the table. Mirrors the wheel
    /// behavior in `onUserScroll` (scrolling the transcript takes key focus);
    /// like it, does NOT steal focus while the find bar is up, so typing a
    /// new query keeps working.
    func takeTranscriptFocus() {
        guard let window = tableView.window else { return }
        guard viewModel?.isSearchVisible != true else { return }
        window.makeFirstResponder(tableView)
    }

    /// Cancels an in-flight scroll (trackpad momentum after a flick, or a
    /// live gesture) so keyboard navigation takes over: the rest of the
    /// gesture is swallowed and can't fight the jump or clear the cycle
    /// anchor. Called at the start of every transcript navigation.
    private func cancelOngoingScroll() {
        (scrollView as? TranscriptScrollView)?.cancelScroll()
    }

    /// The store index the Cmd+Up/Down cycle last landed on, plus the viewport
    /// The store index the Cmd+Up/Down cycle last landed on. The cycle
    /// continues from the LANDED message rather than the viewport's top row: a
    /// landing anchors the message 8pt below the top (leaving the previous
    /// row's bottom sliver visible) and, near the tail, clamps with earlier
    /// rows above it — so the viewport's top row is often NOT the message just
    /// landed on. The landing stays authoritative until the user takes over
    /// navigation (a real wheel / arrow / page scroll clears it) or the
    /// message scrolls out of the viewport (the viewport's top message wins).
    /// Programmatic shifts — the follow-scroll that runs while streaming,
    /// eviction re-anchors — keep it: a "has the viewport moved" check (any
    /// tolerance) made the cycle re-target the message it had just landed on
    /// when a shift fell outside it — the "two presses per message" report.
    var cycleAnchor: Int?

    /// The anchor for the next user-message cycle step: the last landed
    /// message while it is still visible (or at least in the viewport's
    /// visible range), else the viewport's top message.
    func cycleAnchorStoreIndex() -> Int {
        if let last = cycleAnchor,
           last >= windowStart, last < windowEnd,
           visibleStoreRange().contains(last) {
            return last
        }
        return currentAnchorStoreIndex()
    }

    /// The store indices of the rows currently intersecting the viewport.
    private func visibleStoreRange() -> Range<Int> {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return windowStart..<(windowStart + 1) }
        return (windowStart + visible.location)..<(windowStart + visible.location + visible.length)
    }

    /// The store index the viewport is anchored at — the first row that is
    /// SUBSTANTIALLY visible (more than a thin sliver). A landing leaves the
    /// previous row's bottom 8pt visible, so without the sliver skip the
    /// anchor would be that row, and the next Down would re-target the message
    /// just landed on (a wasted press per message).
    func currentAnchorStoreIndex() -> Int {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return windowStart }
        let minY = tableView.visibleRect.minY
        let sliver: CGFloat = 12
        for r in visible.location..<(visible.location + visible.length) {
            let rect = tableView.rect(ofRow: r)
            if rect.maxY - minY > sliver {
                return windowStart + r
            }
        }
        return windowStart + visible.location
    }

    /// Cmd+Up: cycle to the previous user message (the one strictly above the
    /// viewport's top row), anchoring it at the top of the viewport so the
    /// exchange below it is visible. With no user message above, jumps to the
    /// very beginning of the conversation (store index 0). The decision lives
    /// in `TranscriptCycler` (Core) so it is unit-testable.
    func jumpToPreviousUserMessage() {
        guard let store = viewModel?.store else { return }
        let anchor = cycleAnchorStoreIndex()
        if let target = TranscriptCycler.previousUserMessage(anchor: anchor, entryAt: store.entry(at:)) {
            jumpToUserMessage(target)
        } else {
            jumpToTop()
        }
    }

    /// Cmd+Down: cycle to the next user message (the one strictly below the
    /// viewport's top row). With no user message below — already at the last
    /// one — jumps all the way to the tail, re-engaging following so the
    /// incoming streaming content stays in view. The decision lives in
    /// `TranscriptCycler` (Core) so it is unit-testable.
    func jumpToNextUserMessage() {
        guard let store = viewModel?.store else { return }
        let anchor = cycleAnchorStoreIndex()
        if let target = TranscriptCycler.nextUserMessage(anchor: anchor, count: store.count, entryAt: store.entry(at:)) {
            jumpToUserMessage(target)
        } else {
            jumpToBottom()
        }
    }

    /// Anchors a user message at the top of the viewport (with a small
    /// margin), materializing older history as needed, and stops following —
    /// the user returning to the bottom re-engages it. The landing is clamped
    /// to the document: a message near the tail can't reach the top, so it
    /// lands as low as the content allows instead of overscrolling into blank
    /// space below the last row.
    func jumpToUserMessage(_ storeIndex: Int) {
        cancelOngoingScroll()
        guard let row = materialize(storeIndex: storeIndex, completion: .userMessage) else { return }
        isFollowing = false
        tableView.tile()
        let rowRect = tableView.rect(ofRow: row)
        let docMaxY = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
        let targetY = min(max(0, rowRect.origin.y - 8), docMaxY)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        lastVisibleMaxY = scrollView.documentVisibleRect.maxY
        // Remember the landed message as the cycle's anchor: right after a
        // jump the viewport's top row is the row ABOVE the message (its bottom
        // sliver stays visible under the 8pt margin), so reading the anchor
        // from the viewport there would re-target the same message on the next
        // Down — the cycle would stick. The next step continues from HERE
        // unless the user scrolls the viewport away.
        cycleAnchor = storeIndex
        takeTranscriptFocus()
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

/// The transcript table. Accepts key focus so a scroll (which makes the table
/// first responder) enables keyboard navigation. Plain Arrow-Up/Down and the
/// Cmd+Up/Down user-message cycle are handled window-level by the coordinator's
/// key monitors —
/// the table itself has no arrow handling (rows aren't selectable, so the
/// default key navigation would do nothing).
final class TranscriptTableView: NSTableView {
    override var acceptsFirstResponder: Bool { true }
}

/// The transcript scroll view. `onUserScroll` fires only for real wheel
/// events (never for programmatic follow-scrolls), so scrolling the transcript
/// can take key focus without fighting the prompt bar.
///
/// Keyboard navigation (the Cmd+Up/Down cycle, arrow/page keys, Home/End)
/// calls `cancelScroll` to TAKE OVER an in-flight scroll: the tail of the
/// current gesture — trackpad momentum after a flick, or the remaining
/// `changed` events while the fingers are still down — is swallowed so it
/// can't keep moving the viewport (and re-firing `onUserScroll`, which clears
/// the cycle anchor) after the jump lands. The suppression self-ends on the
/// gesture/momentum end or on a brand-new gesture (or a plain mouse-wheel
/// tick), so scrolling resumes normally.
final class TranscriptScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    /// True from a keyboard navigation until the in-flight gesture/momentum
    /// ends: remaining scroll events are swallowed.
    private var suppressesScroll = false

    /// Cancels any in-flight scroll so a keyboard navigation jump can take
    /// over: the rest of the current gesture/momentum is swallowed until the
    /// gesture ends or a new one begins (a plain mouse-wheel tick also counts
    /// as new input).
    func cancelScroll() {
        suppressesScroll = true
    }

    /// Whether `event` is the TAIL of an in-flight gesture or its momentum —
    /// a scroll event that carries a phase (so it is part of a gesture or
    /// momentum) but is not a boundary (.began/.ended/.cancelled). A plain
    /// mouse-wheel tick has no phase at all and is never a tail.
    static func isScrollTail(_ event: NSEvent) -> Bool {
        let phase = event.phase
        let momentum = event.momentumPhase
        let hasPhase = !phase.isEmpty || !momentum.isEmpty
        let isBoundary = phase == .began || phase == .ended || phase == .cancelled
            || momentum == .began || momentum == .ended || momentum == .cancelled
        return hasPhase && !isBoundary
    }

    override func scrollWheel(with event: NSEvent) {
        if suppressesScroll {
            // The keyboard took over mid-scroll: the tail of the interrupted
            // gesture/momentum is swallowed so it can't fight the jump; a
            // boundary (.began/.ended/.cancelled) or a plain wheel tick ends
            // the suppression — the user is scrolling again.
            if Self.isScrollTail(event) {
                return
            }
            suppressesScroll = false
        }
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

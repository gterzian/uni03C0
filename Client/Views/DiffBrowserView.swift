import AppKit
import Core
import SwiftUI

/// The `pi-diff://` scheme the viewer's expand controls link with.
nonisolated enum DiffLink {
    static let scheme = "pi-diff"
}

/// One built diff document: the attributed text for the one big scrollable
/// area, the per-display-line real-line map (for the gutter), the file
/// sections (scroll spy + reveal + reference-tagged copies), the full-array
/// index of each display line (rebuild anchoring), and the edit-cycle stops.
///
/// The text is built PLAIN (font + line background only, no syntax colors):
/// syntax highlighting is applied lazily to the visible range (see
/// `DiffHighlighter`), so opening a large changeset never pays for coloring
/// files the reader is not looking at.
///
/// `@unchecked Sendable`: the builder produces this on a worker thread and the
/// coordinator applies it on the main actor. `text` is immutable once built,
/// and every other member is a plain `Sendable` value, so reads across the hop
/// are safe (the audited assertion the box makes).
nonisolated struct DiffDocument: @unchecked Sendable {
    let text: NSAttributedString
    let lineNumbers: [Int?]
    /// The number the gutter shows for each display line: the real
    /// current-file line for same/added lines, the old-file line for a removed
    /// (red) line. `lineNumbers` stays the real-line map the copy/reference
    /// machinery needs (nil on a removed line); this one is display-only.
    let gutterLineNumbers: [Int?]
    let sections: [CodeSection]
    let fullIndices: [Int?]
    /// The edit-map ticks: the rendered added/removed display lines across
    /// every file. The vertical scroller paints them, so the bar shows where
    /// the whole changeset's edits sit.
    let markers: PaneMarkers
    /// Each display line's vertical center as a fraction of the document
    /// height, for the edit-map ticks (the document mixes font sizes, so line
    /// count is not a safe fraction).
    let markerFractions: [CGFloat]
    /// The start DISPLAY line of each changed-line run, ascending — the
    /// Cmd+Up / Cmd+Down edit cycle. Computed off-main by the builder.
    let editStops: [Int]
    /// DISPLAY lines carrying a file header band. The code view paints a
    /// full-width band behind each, so a scroll clearly distinguishes one
    /// file's diff from the next.
    let headerLines: [Int]
    /// The document's exact laid-out text height (sum of each line's font
    /// height, insets excluded), computed off-main by the builder. The view
    /// pins its frame to this: TextKit's lazily-estimated used rect would
    /// otherwise move the scroller mid-scroll.
    let contentHeight: CGFloat
    /// `[0, offset-after-each-newline]`, computed off-main as the lines are
    /// appended, so applying the document does not rescan the whole buffer for
    /// line starts on the main thread.
    let lineStartOffsets: [Int]
}

/// Everything the document builder needs, snapshotted on the main actor: each
/// changed file, its loaded diff (nil while still loading), and its render
/// plan. All `Sendable`, so the snapshot crosses to the builder untouched.
nonisolated struct DiffBuildFile: Sendable {
    let path: String
    let diff: LoadedFileDiff?
    /// The file's render plan: the changed runs to render and the expand
    /// controls standing in for the unchanged gaps. Empty while loading or for
    /// a message-only diff (the builder still emits the header/placeholder).
    let items: [DiffRenderItem]
}

nonisolated struct DiffBuildInput: Sendable {
    /// The session folder, needed to turn each file's cwd-relative path into
    /// the canonical absolute path a reference-tagged copy records.
    let cwd: URL
    let files: [DiffBuildFile]
}

/// One run of display lines to syntax-highlight: the document character range
/// it covers, its plain text, and the language to highlight it as. Built on
/// the main actor from the VISIBLE range only.
nonisolated struct HighlightChunk: Sendable {
    let range: NSRange
    let text: String
    let language: String?
}

/// The Changes page's diff viewer: ONE scroll view holding every changed
/// file's diff, in path order, with top/bottom expand controls. It replaces
/// the old per-file pane — the whole sidebar of changed files is one
/// continuous read, and the sidebar highlights whichever file's section owns
/// the top of the viewport. The document carries no per-file title row: the
/// viewer header above the pane names the file (and opens it) for the whole
/// changeset.
///
/// Cheap work only, scaled to what is on screen:
///  - `DiffDocumentBuilder` assembles the plain document off the main actor
///    (no highlight.js).
///  - `DiffHighlighter` colors only the VISIBLE lines, coalesced on a scroll
///    gate, off the main actor — across files (only sections in view) and
///    within a file (only the lines in view, not its whole window).
struct DiffBrowserView: NSViewRepresentable {
    let store: ChangesStore
    /// Bumped by the store whenever the document's inputs change (diffs
    /// loaded, a file expanded, content reloaded).
    let documentVersion: Int
    /// One-shot: scroll to this path's section.
    let revealPath: String?
    /// One-shot: the 1-based real file line to land on within `revealPath`
    /// (an agent link's `#L…`), or nil for a whole-file reveal.
    var revealLine: Int? = nil
    var onRevealConsumed: () -> Void = {}
    /// The store's scroll spy: the path whose section owns the viewport top.
    var onTopSectionChanged: (String?) -> Void = { _ in }
    /// Whether the Changes page is the visible page. Hidden pages defer their
    /// rebuilds (no highlighting for a page nothing shows) and catch up on
    /// activation.
    var pageActive = true
    /// The page's find-in-buffer model.
    var search: (any CodeSearching)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CodePaneContainer {
        let container = CodePaneContainer()
        context.coordinator.container = container
        container.onAppearanceChange = { [weak coordinator = context.coordinator] in
            coordinator?.appearanceChanged()
        }
        container.onScroll = { [weak coordinator = context.coordinator] in
            coordinator?.scrollSpy()
        }
        container.onLinkClick = { [weak coordinator = context.coordinator] url in
            coordinator?.handleLink(url)
        }
        container.linkTextAttributes()
        context.coordinator.installKeyMonitor()
        context.coordinator.installEditJumpMonitor()
        return container
    }

    func updateNSView(_ nsView: CodePaneContainer, context: Context) {
        context.coordinator.setActive(pageActive)
        context.coordinator.setSearch(search)
        context.coordinator.update(
            store: store,
            documentVersion: documentVersion,
            revealPath: revealPath,
            revealLine: revealLine,
            onRevealConsumed: onRevealConsumed,
            onTopSectionChanged: onTopSectionChanged
        )
    }

    static func dismantleNSView(_ nsView: CodePaneContainer, coordinator: Coordinator) {
        coordinator.teardown()
    }

    /// Same contract as the old pane: fill the slot, never the content (an
    /// unbounded document text view's fitting height would inflate the page).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CodePaneContainer, context: Context) -> CGSize? {
        func finite(_ value: CGFloat?) -> CGFloat {
            guard let value, value.isFinite else { return 0 }
            return value
        }
        return CGSize(width: finite(proposal.width), height: finite(proposal.height))
    }

    @MainActor
    final class Coordinator {
        weak var container: CodePaneContainer?
        private weak var search: (any CodeSearching)?
        private weak var store: ChangesStore?
        private var onRevealConsumed: (() -> Void)?
        private var onTopSectionChanged: ((String?) -> Void)?
        private var appliedDocumentVersion = -1
        /// The reveal request already applied, as (path, line), so a second
        /// link to the same file at a different line still jumps.
        private struct RevealKey: Equatable {
            let path: String
            let line: Int?
        }
        private var appliedReveal: RevealKey?
        /// A reveal whose target is not in the current document yet (the
        /// first build is still pending). Applied once the rebuild lands, so
        /// a link clicked before the Changes page was ever shown still lands
        /// on its file.
        private var pendingReveal: RevealKey?
        private var isActive = true
        private var needsRebuild = false
        private var buildTask: Task<Void, Never>?
        private var highlightTask: Task<Void, Never>?
        private var document: DiffDocument?
        /// The display lines whose syntax colors have been applied (Core
        /// `DiffHighlightPlan.State`). Highlighting is PREFETCH-ONLY, exactly
        /// like the transcript's materialized row window: the viewport always
        /// sits inside this window with a buffer to spare, so a scroll never
        /// reveals plain text — the visible content is already rendered when
        /// it arrives.
        private var highlight = DiffHighlightPlan.State()
        /// A highlight pass is off-main. A scroll that needs another pass while
        /// one is in flight QUEUES it instead of cancelling (cancelling would
        /// mean a fast scroll never sends a pass at all).
        private var highlightInFlight = false
        private var highlightQueued = false
        /// The visible-range syntax highlighter (off-main, cache inside).
        private let highlighter = DiffHighlighter()
        private var keyMonitor: Any?
        /// Cmd+Up / Cmd+Down jumps between changed-line runs. Installed from
        /// `makeNSView`, removed in `teardown`.
        private var cmdJumpMonitor: Any?
        /// The display line the edit cycle last landed on. Used as the cycle
        /// anchor while it is still visible (so a landing near the document's
        /// bottom, where scrolling cannot put it at the very top, is never
        /// re-targeted by the next press). `nil` after a rebuild/scroll-away,
        /// when the viewport's own top line becomes the anchor.
        private var cycleAnchorDisplayLine: Int?

        // MARK: Lifecycle

        func setActive(_ active: Bool) {
            guard isActive != active else { return }
            isActive = active
            if active {
                if needsRebuild {
                    needsRebuild = false
                    // A pending rebuild may only be a remount's catch-up: if
                    // this store already built the current document, re-apply
                    // it rather than rebuilding the whole changeset.
                    if let cached = store?.builtDocument(for: appliedDocumentVersion) {
                        let version = appliedDocumentVersion
                        // Re-applying a cached document is deferred a main turn
                        // (it swaps the whole text storage, which must not run
                        // inside an update); show the spinner for that gap so
                        // an active page never flashes blank.
                        container?.setBusy(true)
                        Task { @MainActor [weak self] in
                            self?.apply(cached, version: version)
                        }
                    } else {
                        rebuild()
                    }
                } else {
                    scheduleHighlight()
                }
            } else {
                // Abandon in-flight work: a hidden page highlights nothing and
                // never applies a document nothing shows. The version was
                // already recorded as applied, so flag a catch-up rebuild.
                if buildTask != nil { needsRebuild = true }
                buildTask?.cancel()
                buildTask = nil
                highlightTask?.cancel()
                highlightTask = nil
                container?.setBusy(false)
            }
        }

        func setSearch(_ model: (any CodeSearching)?) {
            if let existing = search, let model, existing === model { return }
            if search == nil, model == nil { return }
            search = model
            if let model, let container {
                model.attach(container)
            }
        }

        func update(
            store: ChangesStore,
            documentVersion: Int,
            revealPath: String?,
            revealLine: Int?,
            onRevealConsumed: @escaping () -> Void,
            onTopSectionChanged: @escaping (String?) -> Void
        ) {
            self.store = store
            self.onRevealConsumed = onRevealConsumed
            self.onTopSectionChanged = onTopSectionChanged

            if documentVersion != appliedDocumentVersion {
                appliedDocumentVersion = documentVersion
                if isActive {
                    // A remount (the Changes page is `.id`-keyed per tab) must
                    // not rebuild the whole changeset off-main: re-apply the
                    // document this store already built, if it matches. Deferred
                    // one main turn — `displayDocument` swaps the whole text
                    // storage, which must not run inside `updateNSView`.
                    if let cached = store.builtDocument(for: documentVersion) {
                        // Deferred one main turn (see the setActive path): show
                        // the spinner for the gap too.
                        container?.setBusy(true)
                        Task { @MainActor [weak self] in
                            self?.apply(cached, version: documentVersion)
                        }
                    } else {
                        rebuild()
                    }
                } else {
                    needsRebuild = true
                }
            }
            if let revealPath {
                let request = RevealKey(path: revealPath, line: revealLine)
                if request != appliedReveal {
                    appliedReveal = request
                    // Land immediately when the target's section is already in
                    // the built document; otherwise remember the request and
                    // land once the rebuild applies (see `apply`).
                    if container?.sections.contains(where: { $0.path == revealPath }) == true {
                        pendingReveal = nil
                        reveal(revealPath, line: revealLine)
                    } else {
                        pendingReveal = request
                    }
                }
                onRevealConsumed()
            } else {
                appliedReveal = nil
            }
        }

        func appearanceChanged() {
            guard isActive else {
                needsRebuild = true
                return
            }
            // The document is plain text, so an appearance change only needs the
            // visible range re-highlighted with the other theme.
            highlighter.clearCache()
            rebuild()
        }

        func teardown() {
            buildTask?.cancel()
            buildTask = nil
            highlightTask?.cancel()
            highlightTask = nil
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            if let cmdJumpMonitor {
                NSEvent.removeMonitor(cmdJumpMonitor)
                self.cmdJumpMonitor = nil
            }
        }

        // MARK: Keyboard find

        func installKeyMonitor() {
            guard keyMonitor == nil else { return }
            let handler: @Sendable (NSEvent) -> NSEvent? = { [weak self] event in
                let key = event.keyCode
                guard key == 3 || key == 5, // F / G
                      event.modifierFlags.contains(.command),
                      !event.modifierFlags.contains(.option),
                      !event.modifierFlags.contains(.control) else { return event }
                guard let self else { return event }
                let isShift = event.modifierFlags.contains(.shift)
                let consume = MainActor.assumeIsolated {
                    self.handleSearchShortcut(key: key, isShift: isShift)
                }
                return consume ? nil : event
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        }

        private func handleSearchShortcut(key: UInt16, isShift: Bool) -> Bool {
            guard isActive, let search, let container else { return false }
            guard container.window?.isKeyWindow == true, container.window?.attachedSheet == nil else { return false }
            guard !NSApp.windows.contains(where: { $0.level == .popUpMenu && $0.isVisible }) else { return false }
            switch key {
            case 3:
                search.toggle()
                return true
            case 5:
                guard search.isVisible else { return false }
                if isShift { search.previous() } else { search.next() }
                return true
            default:
                return false
            }
        }

        // MARK: Edit navigation (Cmd+Up / Cmd+Down)

        /// Installs the window-level Cmd+Up / Cmd+Down monitor for the edit
        /// cycle. Deferred to EDITABLE text views (the prompt input, the find
        /// field), which use Cmd+Up/Down for their own caret movement, and to
        /// sheets/popups — the same guards the transcript's monitor uses. The
        /// closure is `@Sendable` and hands off via `MainActor.assumeIsolated`
        /// (the established AppKit-boundary pattern; an inferred `@MainActor`
        /// closure here crashes in `swift_getObjectType`).
        func installEditJumpMonitor() {
            guard cmdJumpMonitor == nil else { return }
            let handler: @Sendable (NSEvent) -> NSEvent? = { [weak self] event in
                guard event.keyCode == 125 || event.keyCode == 126, // Down / Up
                      event.modifierFlags.contains(.command),
                      !event.modifierFlags.contains(.option),
                      !event.modifierFlags.contains(.control),
                      !event.modifierFlags.contains(.shift) else { return event }
                guard let self else { return event }
                let isUp = event.keyCode == 126
                let consume = MainActor.assumeIsolated {
                    self.handleEditJump(isUp: isUp)
                }
                return consume ? nil : event
            }
            cmdJumpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        }

        @MainActor
        private func handleEditJump(isUp: Bool) -> Bool {
            guard isActive, let container, let document, !document.editStops.isEmpty else { return false }
            guard let window = container.window else { return false }
            guard window.isKeyWindow, window.attachedSheet == nil else { return false }
            guard !NSApp.windows.contains(where: { $0.level == .popUpMenu && $0.isVisible }) else { return false }
            if let editor = window.firstResponder as? NSTextView, editor.isEditable { return false }
            let anchor = currentEditAnchor()
            if isUp {
                if let target = DiffEditCycler.previous(before: anchor, stops: document.editStops) {
                    jumpToEdit(target)
                } else {
                    container.scrollToTop()
                    cycleAnchorDisplayLine = nil
                }
            } else {
                if let target = DiffEditCycler.next(after: anchor, stops: document.editStops) {
                    jumpToEdit(target)
                } else {
                    container.scrollToBottom()
                    cycleAnchorDisplayLine = nil
                }
            }
            return true
        }

        /// The anchor for the next edit-cycle step: the last landed edit while
        /// it is still on screen, else the viewport's top display line. Reading
        /// the top line right after a landing would re-target the edit when the
        /// jump was clamped near the document's bottom (the target cannot reach
        /// the very top), so the landing stays authoritative while visible.
        private func currentEditAnchor() -> Int {
            guard let container else { return 1 }
            if let anchor = cycleAnchorDisplayLine,
               let visible = container.visibleDisplayLineRange,
               visible.contains(anchor) {
                return anchor
            }
            return container.topVisibleDisplayLine
        }

        private func jumpToEdit(_ line: Int) {
            guard let container else { return }
            container.scrollDisplayLineToTop(line)
            cycleAnchorDisplayLine = line
            onTopSectionChanged?(container.topSectionPath)
        }

        // MARK: Scroll spy + links

        func scrollSpy() {
            guard isActive, let container else { return }
            onTopSectionChanged?(container.topSectionPath)
            // Prefetch the next block the moment the viewport nears the edge of
            // the colored window — NOT after a settle delay, or a fast scroll
            // would reach plain text first. When the viewport is comfortably
            // inside the window this is a no-op.
            if needsHighlightPrefetch() { scheduleHighlight() }
        }

        func handleLink(_ url: URL) {
            guard url.scheme == DiffLink.scheme, let store else { return }
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let path = comps?.queryItems?.first(where: { $0.name == "path" })?.value
            switch url.host {
            case "expand":
                guard let path,
                      let gapString = comps?.queryItems?.first(where: { $0.name == "gap" })?.value,
                      let gap = Int(gapString) else { return }
                store.expand(path: path, gap: gap)
            default:
                break
            }
        }

        func reveal(_ path: String, line: Int?) {
            guard let container, let index = container.characterIndex(forPath: path, line: line) else { return }
            container.scrollCharacterToTop(index)
            onTopSectionChanged?(path)
        }

        // MARK: Rebuild

        /// Snapshots the store's inputs on the main actor and assembles the
        /// plain document off-main. The finished document is applied in one
        /// main-actor hop — if the document version has not moved on, and the
        /// page is still visible.
        private func rebuild() {
            guard let container, let store else { return }
            let version = appliedDocumentVersion
            let input = DiffBuildInput(cwd: store.cwd, files: snapshot(store))
            buildTask?.cancel()
            highlightTask?.cancel()
            container.setBusy(true)
            buildTask = Task.detached(priority: .userInitiated) { [weak self] in
                let doc = DiffDocumentBuilder.build(input)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.apply(doc, version: version) }
            }
        }

        private func apply(_ doc: DiffDocument, version: Int) {
            guard version == appliedDocumentVersion else { return }
            guard isActive, let container else {
                needsRebuild = true
                self.container?.setBusy(false)
                return
            }
            // Capture the anchor NOW (the container still shows the old
            // document): a scroll during the off-main build must not be lost.
            let anchor = captureAnchor()
            document = doc
            // A new buffer has no colored lines: the next pass establishes a
            // fresh prefetch window around the viewport.
            highlight = DiffHighlightPlan.State()
            // Expansion/reload can shift every display line after the change;
            // the old landing line no longer names the same run.
            cycleAnchorDisplayLine = nil
            store?.cacheBuiltDocument(doc, version: version)
            let restore = anchor.flatMap { restoreAnchor($0, in: doc) }
            container.displayDocument(
                path: "",
                text: doc.text,
                lineNumbers: doc.lineNumbers,
                gutterLineNumbers: doc.gutterLineNumbers,
                sections: doc.sections,
                markers: doc.markers,
                markerFractions: doc.markerFractions,
                headerLines: doc.headerLines,
                contentHeight: doc.contentHeight,
                restoreCharacterIndex: restore?.index,
                restoreCharacterOffset: restore?.offset ?? 0,
                lineStartOffsets: doc.lineStartOffsets
            )
            container.setBusy(false)
            // A reveal that arrived before this document existed lands now.
            if let pending = pendingReveal {
                pendingReveal = nil
                reveal(pending.path, line: pending.line)
            }
            // The buffer was replaced: re-run an active find against it, then
            // prefetch the colors around the viewport.
            search?.bufferDidChange()
            scheduleHighlight()
        }

        /// The main-actor snapshot of the store's changed files and their loaded
        /// diffs/windows, for the off-main builder.
        private func snapshot(_ store: ChangesStore) -> [DiffBuildFile] {
            store.entries.map { entry in
                let diff = store.diffs[entry.path]
                return DiffBuildFile(
                    path: entry.path,
                    diff: diff,
                    items: diff.map { store.renderItems(for: $0) } ?? []
                )
            }
        }

        private func currentDark() -> Bool {
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        // MARK: Prefetch highlighting

        /// Coalesces highlight passes: a pass already off-main queues the next
        /// one instead of being cancelled (a cancelled pass would never apply).
        private func scheduleHighlight() {
            guard isActive, document != nil else { return }
            if highlightInFlight {
                highlightQueued = true
                return
            }
            highlightTask?.cancel()
            let version = appliedDocumentVersion
            highlightTask = Task { [weak self] in
                await self?.highlightVisible(documentVersion: version)
            }
        }

        /// Whether the viewport is close enough to an edge of the colored
        /// window that the next block should be prefetched now.
        private func needsHighlightPrefetch() -> Bool {
            guard let container,
                  let visible = container.visibleDisplayLineRange,
                  let total = document?.lineNumbers.count, total > 0 else { return true }
            return DiffHighlightPlan.needsPrefetch(state: highlight, visible: visible, total: total)
        }

        /// Extends the colored window so the viewport is always inside it with
        /// a buffer to spare, and colors only the newly added block. The visible
        /// lines are never colored on demand: they were already colored when the
        /// viewport was still a buffer away.
        private func highlightVisible(documentVersion: Int) async {
            highlightInFlight = true
            defer {
                highlightInFlight = false
                if highlightQueued {
                    highlightQueued = false
                    scheduleHighlight()
                }
            }
            guard isActive, documentVersion == appliedDocumentVersion,
                  let container, let document, let store,
                  let visible = container.visibleDisplayLineRange else { return }
            let total = document.lineNumbers.count
            guard total > 0 else { return }

            let firstPass = highlight.end == 0
            let (ranges, newState) = DiffHighlightPlan.step(state: highlight, visible: visible, total: total)
            guard !ranges.isEmpty else { return }

            // The first screen must not land plain: on the initial pass, paint
            // the visible lines before the larger surrounding prefetch. The
            // second pass re-covers them from the highlighter cache.
            if firstPass {
                let visibleChunks = highlightChunks(in: visible, document: document, store: store, container: container)
                guard await paint(visibleChunks, documentVersion: documentVersion, container: container) else { return }
            }

            var chunks: [HighlightChunk] = []
            for range in ranges {
                chunks.append(contentsOf: highlightChunks(in: range, document: document, store: store, container: container))
            }
            if chunks.isEmpty {
                // The new block holds nothing to color (expand controls only):
                // advance the window anyway so the fetch is not retried forever.
                highlight = newState
                return
            }
            guard await paint(chunks, documentVersion: documentVersion, container: container) else { return }
            // Commit the window only after the colors land, so a cancelled pass
            // never marks lines colored that were never painted.
            highlight = newState
        }

        /// Runs `chunks` through the off-main highlighter and applies the
        /// result. Returns false when the pass was superseded (a newer document
        /// or a cancelled pass), so the caller does not commit its window.
        private func paint(_ chunks: [HighlightChunk], documentVersion: Int, container: CodePaneContainer) async -> Bool {
            guard !chunks.isEmpty else { return true }
            let dark = currentDark()
            let highlighter = self.highlighter
            let highlighted = await Task.detached(priority: .userInitiated) {
                highlighter.highlight(chunks, dark: dark)
            }.value
            guard !Task.isCancelled, isActive, documentVersion == appliedDocumentVersion else { return false }
            container.applyHighlights(highlighted)
            return true
        }

        /// The chunks to color for a display-line range, intersected with each
        /// section's rendered code runs (expand controls and message-only prose
        /// are never recolored as code).
        private func highlightChunks(in range: ClosedRange<Int>, document: DiffDocument, store: ChangesStore, container: CodePaneContainer) -> [HighlightChunk] {
            var chunks: [HighlightChunk] = []
            for section in document.sections where section.lineRange.overlaps(range) {
                // A message-only section is secondary-colored prose, not code.
                guard store.diffs[section.path]?.message == nil else { continue }
                // Highlight each rendered code run separately: an expand control
                // between hunks must keep its secondary color, not be recolored
                // as code by a range that spans it.
                for run in section.codeLineRanges {
                    let start = max(run.lowerBound, range.lowerBound)
                    let end = min(run.upperBound, range.upperBound)
                    guard start <= end,
                          let charRange = container.characterRange(forDisplayLines: start...end) else { continue }
                    let text = (container.codeView.string as NSString).substring(with: charRange)
                    guard !text.isEmpty else { continue }
                    chunks.append(HighlightChunk(
                        range: charRange,
                        text: text,
                        language: SyntaxHighlighter.language(forPath: section.path)
                    ))
                }
            }
            return chunks
        }

        /// The (path, full-array line, pixel offset) at the top of the
        /// viewport, so a rebuild keeps the reader's place EXACTLY — not just
        /// the same line, but the same number of pixels of it showing above the
        /// fold. The top line may be a header or an expand control (no full
        /// index); walk forward to the section's first code line so an
        /// expansion never bounces the reader back to the document top, falling
        /// back to the section start for a message-only diff (no code line, so
        /// nothing to key on but the file itself). The offset is that line's top
        /// relative to the viewport top (negative when it is scrolled partly off
        /// screen).
        private func captureAnchor() -> (path: String, fullIndex: Int?, offset: CGFloat)? {
            guard let container, let document else { return nil }
            let index = container.topVisibleCharacterIndex
            let length = (container.codeView.string as NSString).length
            guard length > 0 else { return nil }
            let displayLine = container.codeView.lineNumber(forIndex: min(index, length - 1))
            guard let section = document.sections.first(where: { $0.lineRange.contains(displayLine) })
            else { return nil }
            let clip = container.scrollView.contentView
            let clipTop = clip.convert(NSPoint(x: 0, y: clip.bounds.minY), to: container.codeView).y
            for line in displayLine...section.lineRange.upperBound {
                guard line - 1 < document.fullIndices.count else { break }
                guard let fullIndex = document.fullIndices[line - 1] else { continue }
                return (section.path, fullIndex, lineTop(of: line, in: container) - clipTop)
            }
            // No code line in the section (a message-only or unreadable diff):
            // pin the section start so the rebuild still keeps the file in view.
            return (section.path, nil, lineTop(of: section.lineRange.lowerBound, in: container) - clipTop)
        }

        /// The line's top edge in the code view's coordinates, or 0 when the
        /// line is unmeasurable.
        private func lineTop(of displayLine: Int, in container: CodePaneContainer) -> CGFloat {
            guard displayLine >= 1,
                  displayLine - 1 < container.codeView.lineStartOffsets.count,
                  let layoutManager = container.codeView.layoutManager else { return 0 }
            let charIndex = container.codeView.lineStartOffsets[displayLine - 1]
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
            let fragment = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            return fragment.minY + container.codeView.textContainerInset.height
        }

        private func restoreAnchor(_ anchor: (path: String, fullIndex: Int?, offset: CGFloat), in doc: DiffDocument) -> (index: Int, offset: CGFloat)? {
            // Map the anchor's full-array line to a display line in the NEW
            // document, then use the NEW document's own offset table. Reading
            // the container's `lineStartOffsets` here would still be the OLD
            // document's (the container has not loaded `doc` yet), so a rebuild
            // that changes any earlier line length would scroll to the wrong
            // character — the viewport jump this restore exists to prevent.
            for section in doc.sections where section.path == anchor.path {
                var line = section.lineRange.lowerBound
                if let fullIndex = anchor.fullIndex {
                    for candidate in section.lineRange {
                        guard candidate - 1 < doc.fullIndices.count, doc.fullIndices[candidate - 1] == fullIndex else { continue }
                        line = candidate
                        break
                    }
                }
                guard line >= 1, line - 1 < doc.lineStartOffsets.count else { return nil }
                return (doc.lineStartOffsets[line - 1], anchor.offset)
            }
            return nil
        }
    }
}

/// Assembles one diff document off the main thread — plain text only (font +
/// added/removed line background). Syntax colors are NOT applied here; the
/// visible-range highlighter does that later, so this stays cheap no matter how
/// large the changeset is.
nonisolated enum DiffDocumentBuilder {
    static func build(_ input: DiffBuildInput) -> DiffDocument {
        let addedColor = NSColor.systemGreen.withAlphaComponent(0.18)
        let deletedColor = NSColor.systemRed.withAlphaComponent(0.16)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Exact per-line heights: the document loads PLAIN (background only),
        // so a paragraph's height is its font's line height. Expand/placeholder
        // rows are 11pt, code lines 12pt — a fixed "lines × pitch" would drift.
        let codeLineHeight = ReadOnlyCodeTextView.lineHeight(for: font)
        let smallLineHeight = ReadOnlyCodeTextView.lineHeight(
            for: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        )
        let headerFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let headerLineHeight = ReadOnlyCodeTextView.lineHeight(for: headerFont)
        let spacerFont = NSFont.monospacedSystemFont(ofSize: 5, weight: .regular)
        let spacerLineHeight = ReadOnlyCodeTextView.lineHeight(for: spacerFont)
        let text = NSMutableAttributedString()
        var lineNumbers: [Int?] = []
        var gutterLineNumbers: [Int?] = []
        var fullIndices: [Int?] = []
        var sections: [CodeSection] = []
        var addedLines: [Int] = []
        var removedLines: [Int] = []
        var headerLines: [Int] = []
        var contentHeight: CGFloat = 0
        // Each display line's vertical center as a fraction of the final
        // document height. The document mixes 12pt code, a 12pt header, 11pt
        // expand rows and a 5pt spacer, so a line-count fraction would drift
        // from the glyph it marks; the built y is what the knob actually
        // travels over.
        var lineCenters: [CGFloat] = []

        func appendLine(_ attributed: NSAttributedString, lineNumber: Int?, gutterNumber: Int?, fullIndex: Int?, lineHeight: CGFloat) -> (line: Int, start: Int) {
            if !lineNumbers.isEmpty { text.append(NSAttributedString(string: "\n")) }
            let start = text.length
            text.append(attributed)
            lineNumbers.append(lineNumber)
            gutterLineNumbers.append(gutterNumber)
            fullIndices.append(fullIndex)
            lineCenters.append(contentHeight + lineHeight / 2)
            contentHeight += lineHeight
            return (lineNumbers.count, start)
        }

        for (fileIndex, file) in input.files.enumerated() {
            guard let diff = file.diff else {
                _ = appendLine(placeholderLine("Loading \(file.path)…"), lineNumber: nil, gutterNumber: nil, fullIndex: nil, lineHeight: smallLineHeight)
                continue
            }
            // Each file opens with a header band naming it — the path, its
            // change kind, and its line counts. This is what makes scrolling
            // read as "this file, then the next" rather than one
            // undifferentiated run of diff lines. The spacer above every
            // header but the first (both belong to THIS section, so the scroll
            // spy credits the file that follows) gives the band breathing room.
            let sectionStart = lineNumbers.count + 1
            if fileIndex > 0 {
                _ = appendLine(spacerLine(font: spacerFont), lineNumber: nil, gutterNumber: nil, fullIndex: nil, lineHeight: spacerLineHeight)
            }
            let header = appendLine(
                headerLine(path: file.path, kind: diff.kind, added: diff.added.count, removed: diff.removed.count, font: headerFont),
                lineNumber: nil, gutterNumber: nil, fullIndex: nil, lineHeight: headerLineHeight
            )
            headerLines.append(header.line)

            var diffStart = -1
            var diffEnd = -1
            var diffFirstLine = -1
            var diffLastLine = -1
            var codeRuns: [ClosedRange<Int>] = []
            if diff.message == nil, !diff.lines.isEmpty {
                // Only the changed runs (+ context) are rendered; the unchanged
                // gaps between them are one expand control each, so the file
                // never opens as its whole contents.
                for item in file.items {
                    switch item {
                    case .expand(let gap, let hidden):
                        _ = appendLine(
                            expandLine(hidden: hidden, path: file.path, gap: gap),
                            lineNumber: nil, gutterNumber: nil, fullIndex: nil, lineHeight: smallLineHeight
                        )
                    case .lines(let range):
                        let runStart = lineNumbers.count + 1
                        for index in range {
                            let line = diff.lines[index]
                            let attributed = NSMutableAttributedString(string: line.text, attributes: [
                                .font: font,
                                .foregroundColor: NSColor.labelColor,
                            ])
                            switch line.kind {
                            case .added:
                                attributed.addAttribute(.backgroundColor, value: addedColor, range: NSRange(location: 0, length: attributed.length))
                            case .removed:
                                attributed.addAttribute(.backgroundColor, value: deletedColor, range: NSRange(location: 0, length: attributed.length))
                            case .same:
                                break
                            }
                            let appended = appendLine(
                                attributed,
                                lineNumber: diff.lineNumbers[index],
                                gutterNumber: diff.lineNumbers[index] ?? diff.oldLineNumbers[index],
                                fullIndex: index,
                                lineHeight: codeLineHeight
                            )
                            if diffStart < 0 { diffStart = appended.start }
                            diffEnd = appended.start + attributed.length
                            if diffFirstLine < 0 { diffFirstLine = appended.line }
                            diffLastLine = appended.line
                            if line.kind == .added { addedLines.append(appended.line) }
                            if line.kind == .removed { removedLines.append(appended.line) }
                        }
                        if lineNumbers.count >= runStart {
                            codeRuns.append(runStart...lineNumbers.count)
                        }
                    }
                }
            } else if let message = diff.message {
                let placeholder = placeholderLine(message)
                let appended = appendLine(placeholder, lineNumber: nil, gutterNumber: nil, fullIndex: nil, lineHeight: smallLineHeight)
                diffStart = appended.start
                diffEnd = appended.start + placeholder.length
                diffFirstLine = appended.line
                diffLastLine = appended.line
            } else if diff.lines.isEmpty {
                // An empty added/deleted file still gets a header; give it a
                // body line so the section has a position to anchor on.
                let placeholder = placeholderLine("(empty file)")
                let appended = appendLine(placeholder, lineNumber: nil, gutterNumber: nil, fullIndex: nil, lineHeight: smallLineHeight)
                diffStart = appended.start
                diffEnd = appended.start + placeholder.length
                diffFirstLine = appended.line
                diffLastLine = appended.line
            }

            let sectionEnd = lineNumbers.count
            // The header (and the empty-file placeholder above) guarantee a
            // position to anchor the scroll spy and a reveal on, so every
            // loaded file contributes a section.
            guard sectionEnd >= sectionStart, diffStart >= 0, diffFirstLine > 0 else { continue }
            let diffRange = NSRange(location: diffStart, length: max(diffEnd - diffStart, 0))
            // The section's file, canonical (filesystem stat, off-main): a copy
            // tags a reference with this, so the reference names the FILE.
            let absolutePath = SandboxPolicy.canonicalize(
                URL(fileURLWithPath: file.path, relativeTo: input.cwd).path
            )
            sections.append(CodeSection(
                path: file.path,
                absolutePath: absolutePath,
                lineRange: sectionStart...sectionEnd,
                diffLineRange: diffFirstLine...diffLastLine,
                codeLineRanges: codeRuns.isEmpty ? nil : codeRuns,
                diffCharRange: diffRange
            ))
        }

        return DiffDocument(
            text: text,
            lineNumbers: lineNumbers,
            gutterLineNumbers: gutterLineNumbers,
            sections: sections,
            fullIndices: fullIndices,
            markers: .lines(added: addedLines, removed: removedLines),
            markerFractions: contentHeight > 0 ? lineCenters.map { $0 / contentHeight } : [],
            editStops: DiffEditCycler.editStops(added: addedLines, removed: removedLines),
            headerLines: headerLines,
            contentHeight: contentHeight,
            // Same algorithm as the text view's own scan, run here off-main
            // (the view is the single source of truth for the invariant).
            lineStartOffsets: ReadOnlyCodeTextView.lineStartOffsets(in: text.string)
        )
    }

    private static func selfURL(host: String, path: String, gap: Int? = nil) -> URL? {
        var comps = URLComponents()
        comps.scheme = DiffLink.scheme
        comps.host = host
        var items = [URLQueryItem(name: "path", value: path)]
        if let gap {
            items.append(URLQueryItem(name: "gap", value: String(gap)))
        }
        comps.queryItems = items
        return comps.url
    }

    private static func expandLine(hidden: Int, path: String, gap: Int) -> NSAttributedString {
        let text = "  ⌄  \(hidden) hidden line\(hidden == 1 ? "" : "s") — click to expand"
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        if let url = selfURL(host: "expand", path: path, gap: gap) {
            result.addAttribute(.link, value: url, range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    private static func placeholderLine(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// A near-empty line that only exists to give the next file's header band
    /// breathing room. It must still be a real paragraph (a space, not "") so
    /// the layout manager gives it a fragment of the small font's height.
    private static func spacerLine(font: NSFont) -> NSAttributedString {
        NSAttributedString(string: " ", attributes: [
            .font: font,
            .foregroundColor: NSColor.clear,
        ])
    }

    /// One file's header line: kind letter + path, then its added/removed
    /// counts. The code view paints the full-width band behind it.
    private static func headerLine(path: String, kind: GitStatus.Kind, added: Int, removed: Int, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "  \(kindLetter(kind))  \(path)", attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
        var suffix = ""
        if added > 0 { suffix += "  +\(added)" }
        if removed > 0 { suffix += "  −\(removed)" }
        if !suffix.isEmpty {
            result.append(NSAttributedString(string: suffix, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return result
    }

    private static func kindLetter(_ kind: GitStatus.Kind) -> String {
        switch kind {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .untracked: return "U"
        case .normal: return " "
        }
    }
}

/// Syntax-highlights only the chunks it is handed (the visible display lines),
/// off the main actor, with a small content-keyed cache so scrolling back over
/// already-colored lines is free. The highlighter is confined here: its lock
/// serializes the non-Sendable `Highlightr`/`JSContext`, and every chunk that
/// crosses back is an immutable `NSAttributedString` (`@unchecked Sendable`).
nonisolated final class DiffHighlighter: @unchecked Sendable {
    private let lock = NSLock()
    private var highlighter: SyntaxHighlighter?
    private var cache: [String: (key: String, attributed: NSAttributedString)] = [:]
    private var order: [String] = []
    private let cacheLimit = 96

    func highlight(_ chunks: [HighlightChunk], dark: Bool) -> [HighlightedChunk] {
        lock.lock()
        defer { lock.unlock() }
        return chunks.map { chunk in
            let key = "\(dark)|\(chunk.language ?? "")"
            if let cached = cache[chunk.text], cached.key == key {
                touch(chunk.text)
                return HighlightedChunk(range: chunk.range, attributed: cached.attributed)
            }
            let base = resolvedHighlighter().highlight(chunk.text, as: chunk.language, dark: dark)
                ?? NSAttributedString(string: chunk.text, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ])
            let normalized = NSMutableAttributedString(attributedString: base)
            normalized.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: normalized.length))
            cache[chunk.text] = (key, normalized)
            touch(chunk.text)
            return HighlightedChunk(range: chunk.range, attributed: normalized)
        }
    }

    func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        order.removeAll()
    }

    private func touch(_ text: String) {
        if let index = order.firstIndex(of: text) {
            order.remove(at: index)
        }
        order.append(text)
        while order.count > cacheLimit, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func resolvedHighlighter() -> SyntaxHighlighter {
        if let highlighter { return highlighter }
        let created = SyntaxHighlighter()
        highlighter = created
        return created
    }
}

extension CodePaneContainer {
    /// Sets the link styling the diff viewer's expand controls render with.
    func linkTextAttributes() {
        codeView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
    }
}

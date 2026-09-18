import AppKit
import Core
import SwiftUI

/// The find-in-buffer surface a code pane exposes to the page that owns it.
/// The concrete implementation (`CodeSearchModel`) is `@Observable`; the pane
/// depends on this protocol rather than that class so the renderer test bundle
/// can compile the pane without the Observation macro plugin (blocked in the
/// test sandbox). The pane only forwards the keyboard find commands and buffer
/// reloads to the model — the model drives the highlighting and scrolling
/// through `FilePaneContainer`'s own methods.
@MainActor
protocol CodeSearching: AnyObject {
    var isVisible: Bool { get }
    func attach(_ container: FilePaneContainer)
    func toggle()
    func next()
    func previous()
    func close()
    /// The pane replaced the buffer (a load, a live refresh, a file switch):
    /// re-run the current query against the new text.
    func bufferDidChange()
}

/// The file browser's content pane: a real, current (or, for a deletion,
/// last-committed) file buffer in a `ReadOnlyCodeTextView`, with edit-coloring
/// applied as attributes on top of syntax highlighting. For a modification the
/// buffer is the GITHUB-STYLE INTERLEAVED diff of the current file: every real
/// line in order with the removed lines re-inserted in red at their original
/// position (added lines green). The text is therefore the real file plus the
/// removed lines; `ReadOnlyCodeTextView.lineNumberMap` records the REAL
/// current-file line of each display line, so the gutter numbers, the
/// reference jump, and copy-tagging still mean "line N of the real file" and a
/// selection that spans a removal still produces a valid in-file reference
/// (§2.6).
struct ReadOnlyFilePane: NSViewRepresentable {
    /// How much of the file the pane shows. `.wholeFile` is the Files page's
    /// full buffer (with removed lines interleaved); `.hunks` is the Changes
    /// page's read-through view — only the changed regions plus a few lines of
    /// context, with a `@@ … @@` header per hunk.
    enum LoadMode: Hashable, Sendable {
        case wholeFile
        case hunks
    }

    let cwd: URL
    /// Path of the file to show, relative to `cwd`.
    let path: String
    /// The file's git classification (drives which overlay applies).
    let kind: GitStatus.Kind
    /// Bumped whenever the open file should reload: a selection change, or a
    /// file-change event naming the open file (or a turn end, path unknown).
    /// The coordinator dedupes on (path, token), so identical re-renders are
    /// no-ops while a same-path reload with a new token re-reads the file.
    let reloadToken: Int
    /// One-shot reference-driven open (agent-emitted `pi-file` link): when the
    /// NEXT load for `path` lands, the pane scrolls the reference's start line
    /// to the top of the viewport, flashes its line range, and keeps an anchor
    /// marker on the start line. nil = the normal behavior (preserve the
    /// current scroll on a same-file refresh, top on a new file). The value
    /// travels WITH the reload it belongs to (never lives in shared mutable
    /// coordinator state), and is consumed via `onReferenceConsumed` the
    /// moment that reload captures it (the load itself is async).
    var pendingReference: FileReferenceLink? = nil
    var onReferenceConsumed: (() -> Void)? = nil
    /// Whether the Files page is the visible page (vs. hidden behind the
    /// conversation). While false the coordinator does NOT load the file: the
    /// pane is off-screen, so the whole pipeline — file IO, `git show`, the
    /// diff, and the MAIN-THREAD syntax-highlight pass + whole-file
    /// attributed replace — would be wasted work that blocks whatever page is
    /// on screen. This is the mirror of the transcript coordinator's
    /// page-active gating: the pane stays mounted (its content survives page
    /// flips) but defers its loads; the latest request is recorded and ONE
    /// catch-up load runs when the page activates. A session switch mounts
    /// this pane for the incoming tab even when that tab shows the
    /// conversation, which used to re-read + re-highlight the open file on
    /// the main thread at every switch.
    var pageActive = true
    /// `.wholeFile` (default) or `.hunks` (see `LoadMode`). Part of the load
    /// identity, so a mode change (never happens for one representable
    /// instance) would reload.
    var mode: LoadMode = .wholeFile
    /// The owning page's find-in-buffer model (nil for a pane with no search
    /// bar). The pane forwards Cmd+F/Cmd+G to it and re-runs its query after
    /// every load; the model paints/scrolls through the container.
    var search: (any CodeSearching)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FilePaneContainer {
        let container = FilePaneContainer()
        context.coordinator.container = container
        // Cmd+F / Cmd+G while this pane's page is the visible one. A local key
        // monitor (the transcript coordinator's technique) so it always acts
        // on the pane actually on screen; the coordinator bails unless its
        // page is active and its window is key.
        context.coordinator.installKeyMonitor()
        // A light/dark change (app toggle or system) must re-highlight the
        // open file: Highlightr caches the resolved theme once, so the pane
        // asks its coordinator to rebuild the attributed buffer.
        container.onAppearanceChange = { [weak coordinator = context.coordinator] in
            coordinator?.appearanceChanged()
        }
        return container
    }

    func updateNSView(_ nsView: FilePaneContainer, context: Context) {
        // Activation first, so a return to the Files page triggers the
        // catch-up load and the reload below then dedupes against it;
        // deactivation cancels any in-flight load before the reload records
        // the request for the next activation.
        context.coordinator.setPageActive(pageActive)
        context.coordinator.reload(
            cwd: cwd,
            path: path,
            kind: kind,
            token: reloadToken,
            mode: mode,
            reference: pendingReference?.path == path ? pendingReference : nil,
            onReferenceConsumed: onReferenceConsumed
        )
        context.coordinator.setSearch(search)
    }

    static func dismantleNSView(_ nsView: FilePaneContainer, coordinator: Coordinator) {
        coordinator.teardown()
    }

    /// The pane fills whatever slot SwiftUI gives it; it must NEVER size itself
    /// to its CONTENT. `FilePaneContainer`'s fitting size is the whole file's
    /// text height — the code text view is deliberately unbounded
    /// (`isVerticallyResizable`, `maxSize` = `.greatestFiniteMagnitude`) so it
    /// can scroll — and that fitting height leaks into SwiftUI's layout as the
    /// representable's ideal size, inflating the pane (and everything laid out
    /// around it: `columnDivider`, the ruler) past the real visible slot. This
    /// is the actual root cause the earlier `.frame(maxHeight: .infinity)`
    /// wrapper could not fix: a frame with an infinite max still ADOPTS the
    /// child's oversized ideal height. Adopt the proposed size instead — that
    /// is what "fill the slot" means at the representable boundary.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FilePaneContainer, context: Context) -> CGSize? {
        func finite(_ value: CGFloat?) -> CGFloat {
            guard let value, value.isFinite else { return 0 }
            return value
        }
        return CGSize(width: finite(proposal.width), height: finite(proposal.height))
    }

    @MainActor
    final class Coordinator {
        weak var container: FilePaneContainer?
        private var loadTask: Task<Void, Never>?
        /// The latest request the pane accepted — a same (path, token) request
        /// is a no-op (already loading or already shown), and a load only
        /// applies when it still matches the accepted request (a newer one
        /// supersedes it).
        private var accepted: Pending?
        /// The accepted request while the Files page was NOT the visible page
        /// (or was hidden mid-load): the pane is off-screen, so its load is
        /// deferred and this is re-launched as ONE catch-up load on
        /// activation. Only the latest request is kept.
        private var deferred: Pending?
        /// Whether the Files page is the visible page. Defaults true (standalone
        /// use / tests construct the pane without the conversation page).
        private var isActive = true
        /// The request whose content (a load result or a placeholder/status
        /// message) currently sits in the pane.
        private var displayedPath: String?
        private var displayedToken: Int?
        /// The git kind the displayed content was loaded with. Part of the
        /// display identity alongside path/token: a refresh can change a
        /// file's kind (clean → modified) WITHOUT bumping the token — the
        /// token bump fires on the file-change notification, which precedes
        /// the store's own debounced refresh, so it carries the OLD kind. If
        /// the kind weren't part of the identity, that stale-kind load would
        /// be considered "already displayed" and the pane would keep the
        /// uncolored buffer (the missing added-line overlay).
        private var displayedKind: GitStatus.Kind?
        /// The load mode the displayed content was built with (`.hunks` buffers
        /// have a different text than the full file). Part of the display
        /// identity, so a mode flip can never be deduped away.
        private var displayedMode: ReadOnlyFilePane.LoadMode?
        /// The absolute path + edit overlay of the content currently displayed
        /// (nil while a placeholder is up). Kept so an appearance change can
        /// re-highlight the SAME buffer WITHOUT re-reading the file: the plain
        /// text is read from the code view's own storage in
        /// `appearanceChanged`.
        private var displayedAbsolutePath: String?
        private var displayedOverlay: PaneOverlay = .none
        /// The real-line map of the displayed interleaved diff (nil for a
        /// non-diff buffer). Kept alongside the overlay so a theme re-render
        /// rebuilds the SAME buffer with its real-line numbering intact.
        private var displayedLineNumbers: [Int?]?
        /// A light/dark change arrived while the Files page was hidden: run the
        /// re-highlight once on activation instead of for an off-screen pane.
        private var pendingAppearanceRefresh = false
        /// The owning page's find-in-buffer model (see `ReadOnlyFilePane.search`).
        private weak var search: (any CodeSearching)?
        /// The local key monitor forwarding Cmd+F/Cmd+G to `search`.
        private var keyMonitor: Any?
        private let highlighter = SyntaxHighlighter()
        private let addedColor = NSColor.systemGreen.withAlphaComponent(0.18)
        private let deletedColor = NSColor.systemRed.withAlphaComponent(0.16)
        private let hunkHeaderColor = NSColor.systemBlue.withAlphaComponent(0.10)

        /// One full reload request — everything `launch` needs, captured at
        /// accept time so a deferred (hidden-page) request can be re-launched
        /// verbatim on activation, reference included.
        private struct Pending {
            let cwd: URL
            let path: String
            let kind: GitStatus.Kind
            let token: Int
            let mode: ReadOnlyFilePane.LoadMode
            let reference: FileReferenceLink?
            let onReferenceConsumed: (() -> Void)?
        }

        /// The Files page became the visible page (true) or hid behind the
        /// conversation (false). Hidden: cancel any in-flight load so its
        /// main-thread highlight/apply can never run for an off-screen pane,
        /// and remember the accepted request if it never landed. Visible: one
        /// catch-up load for the latest un-displayed request (the mirror of
        /// the transcript coordinator's catch-up on page activation).
        func setPageActive(_ active: Bool) {
            guard isActive != active else { return }
            isActive = active
            if active {
                let launched: Bool
                if let target = deferred ?? accepted, !isDisplayed(target) {
                    deferred = nil
                    launch(target)
                    launched = true
                } else {
                    deferred = nil
                    launched = false
                }
                // A theme change that landed while hidden: the displayed buffer
                // still carries the old theme. Re-highlight it — unless a
                // catch-up load just started, which already highlights with the
                // current appearance.
                if pendingAppearanceRefresh {
                    pendingAppearanceRefresh = false
                    if !launched { appearanceChanged() }
                }
            } else {
                loadTask?.cancel()
                loadTask = nil
                if let accepted, !isDisplayed(accepted) {
                    deferred = accepted
                }
                // The page is hidden while its find field held focus: hand
                // focus back to the pane, so keystrokes don't land in an
                // invisible field (the query is kept for when the page
                // returns).
                if let container, let window = container.window,
                   let editor = window.firstResponder as? NSTextView,
                   editor.delegate is NSSearchField {
                    window.makeFirstResponder(container.codeView)
                }
            }
        }

        private func isDisplayed(_ request: Pending) -> Bool {
            request.path == displayedPath
                && request.token == displayedToken
                && request.kind == displayedKind
                && request.mode == displayedMode
        }

        // MARK: - Find in buffer

        /// Binds the owning page's search model: the model attaches to this
        /// pane's container so it can search/highlight/scroll the live buffer.
        /// A no-op when the same model is already bound.
        func setSearch(_ model: (any CodeSearching)?) {
            if let existing = search, let model, existing === model { return }
            if search == nil, model == nil { return }
            search = model
            if let model, let container {
                model.attach(container)
            }
        }

        /// Installs the Cmd+F / Cmd+G local key monitor. See
        /// `handleSearchShortcut` for the gating.
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

        /// Cmd+F toggles this pane's find bar, Cmd+G / ⇧Cmd+G cycle its
        /// matches. Only the pane whose page is actually visible handles the
        /// key (the other page's pane is mounted but hidden, exactly like the
        /// transcript's page gating), and only while this window is key — so
        /// the key never reaches a background tab's pane. The transcript's own
        /// Cmd+F monitor consumes first when the conversation is showing.
        @MainActor
        private func handleSearchShortcut(key: UInt16, isShift: Bool) -> Bool {
            guard isActive, let search, let container else { return false }
            guard container.window?.isKeyWindow == true, container.window?.attachedSheet == nil else { return false }
            guard !NSApp.windows.contains(where: { $0.level == .popUpMenu && $0.isVisible }) else { return false }
            switch key {
            case 3: // Cmd+F
                search.toggle()
                return true
            case 5: // Cmd+G / ⇧Cmd+G
                guard search.isVisible else { return false }
                if isShift { search.previous() } else { search.next() }
                return true
            default:
                return false
            }
        }

        /// Removes the key monitor (view dismantled).
        func teardown() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        func reload(cwd: URL, path: String, kind: GitStatus.Kind, token: Int, mode: ReadOnlyFilePane.LoadMode = .wholeFile, reference: FileReferenceLink?, onReferenceConsumed: (() -> Void)?) {
            guard container != nil else { return }
            // The KIND is part of the identity: a refresh that reclassifies
            // the open file (clean → modified) arrives with an unchanged
            // token and must still reload, or the pane never gains the edit
            // overlay (see `displayedKind`). The MODE is likewise part of it.
            if let accepted, accepted.path == path, accepted.token == token, accepted.kind == kind, accepted.mode == mode { return }
            let request = Pending(
                cwd: cwd, path: path, kind: kind, token: token, mode: mode,
                reference: reference, onReferenceConsumed: onReferenceConsumed
            )
            accepted = request
            guard isActive else {
                // Off-screen page: no load now (its main-thread highlight and
                // whole-file apply would block the page the user IS looking
                // at — the session-switch hitch). Keep the latest request;
                // activation runs it as one catch-up load.
                deferred = request
                return
            }
            launch(request)
        }

        private func launch(_ request: Pending) {
            loadTask?.cancel()
            loadTask = nil
            // Hand the reference to THIS load only: it travels as a parameter
            // of the task it belongs to, so a later, unrelated reload (which
            // passes nil) can never overwrite or inherit it. The store's
            // one-shot copy is consumed here — this load captured it (a load
            // deferred until activation consumes it then, never twice).
            if request.reference != nil {
                request.onReferenceConsumed?()
            }
            // A genuinely different file clears the pane while it loads; a
            // same-path refresh (the file changed) keeps showing the old
            // content until the new one is ready.
            if displayedPath != request.path {
                container?.showPlaceholder("Loading…")
                // No buffer is on screen for this path: an appearance change
                // must not re-highlight the previous file over the placeholder.
                displayedAbsolutePath = nil
            }
            loadTask = Task { [weak self] in
                await self?.performLoad(request)
            }
        }

        private func performLoad(_ request: Pending) async {
            guard let container else { return }
            let loaded = await PaneContentLoader.load(cwd: request.cwd, path: request.path, kind: request.kind, mode: request.mode)
            // The page hid while the file was being read (the load was
            // cancelled): nothing may be applied to an off-screen pane — the
            // apply is main-thread work for a page the user cannot see.
            guard !Task.isCancelled else { return }
            // A newer request supersedes this one — same path+token but a
            // reclassified kind is a NEWER request (the store refresh landed
            // after the token bump), so it must win over this stale-kind load.
            guard let current = accepted,
                  current.path == request.path,
                  current.token == request.token,
                  current.kind == request.kind,
                  current.mode == request.mode else { return }
            // The target lines ride on the request that captured them (see
            // `reload`) — a whole-file reference has no target lines.
            let targetLines: (start: Int, end: Int)? = request.reference.flatMap { ref in
                guard let start = ref.startLine else { return nil }
                return (start, max(start, ref.endLine ?? start))
            }
            // The scrollbar edit map mirrors the edit overlay exactly (same
            // added-line diff / whole-file classification).
            let markers = paneMarkers(for: loaded.overlay)
            // The code view is stamped with the file's RESOLVED ABSOLUTE path
            // (canonicalized once, here) — never the git-relative path: a
            // relative path would later be resolved against the app process's
            // own working directory ("Client/ClientApp.swift" → "/Client/…")
            // when the reference is rendered, producing the bogus `..` walk
            // the pasted anchor showed (§1.1).
            let absolutePath = SandboxPolicy.canonicalize(URL(fileURLWithPath: request.path, relativeTo: request.cwd).path)
            if let text = loaded.displayText {
                let attributed = makeAttributed(text: text, path: request.path, overlay: loaded.overlay)
                // A live refresh of the file the user is already reading must
                // not yank the view back to the top — keep their place when
                // the same file is being re-shown. A reference-driven open
                // (targetLines != nil) is never "keep my place": even when it
                // IS the same file, the click means "show me THIS line", so
                // the ratio logic is skipped and the jump lands after load.
                container.displayContent(
                    path: absolutePath,
                    text: attributed,
                    preserveScroll: targetLines == nil && displayedPath == request.path,
                    targetLines: targetLines,
                    markers: markers,
                    lineNumbers: loaded.lineNumbers
                )
                displayedAbsolutePath = absolutePath
                displayedOverlay = loaded.overlay
                displayedLineNumbers = loaded.lineNumbers
            } else {
                container.showPlaceholder(loaded.message ?? "Couldn't read \((request.path as NSString).lastPathComponent).")
                displayedAbsolutePath = nil
            }
            displayedPath = request.path
            displayedToken = request.token
            displayedKind = request.kind
            displayedMode = request.mode
            // The buffer changed under an active find: re-run the query on the
            // new text (a file switch or a live refresh keeps the search).
            search?.bufferDidChange()
        }

        /// Re-runs syntax highlighting for the displayed buffer with the
        /// current appearance's theme. Called from the container when its
        /// effective appearance changes (an app light/dark toggle OR a system
        /// appearance change). The file is NOT re-read and no git subprocess
        /// runs: the plain text comes from the code view's storage and the edit
        /// overlay is the one captured at load, so this is one main-thread
        /// highlight pass with the scroll position preserved. A hidden Files
        /// page defers it to activation; a placeholder does nothing.
        func appearanceChanged() {
            guard isActive, let container, let absolutePath = displayedAbsolutePath, let relativePath = displayedPath else {
                pendingAppearanceRefresh = displayedAbsolutePath != nil
                return
            }
            pendingAppearanceRefresh = false
            let text = container.codeView.string
            let attributed = makeAttributed(text: text, path: relativePath, overlay: displayedOverlay)
            container.displayContent(
                path: absolutePath,
                text: attributed,
                preserveScroll: true,
                markers: paneMarkers(for: displayedOverlay),
                lineNumbers: displayedLineNumbers
            )
            // The re-render replaced the buffer, dropping the search paint:
            // restore it with the current appearance's shades.
            search?.bufferDidChange()
        }

        /// The scrollbar edit map for an overlay — the same mapping the load
        /// path uses, shared so a theme-only re-render keeps the markers.
        private func paneMarkers(for overlay: PaneOverlay) -> PaneMarkers {
            switch overlay {
            case .none: .none
            case .diff(let added, let removed): .lines(added: added, removed: removed)
            case .hunks(let added, let removed, _): .lines(added: added, removed: removed)
            case .wholeGreen: .wholeAdded
            case .wholeRed: .wholeDeleted
            }
        }

        /// Builds the final buffer: syntax highlighting (when the file is
        /// small enough and the language known — else plain monospaced),
        /// normalized to the pane's monospaced font, then the edit overlay
        /// as translucent background attributes on top.
        private func makeAttributed(text: String, path: String, overlay: PaneOverlay) -> NSAttributedString {
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let language = SyntaxHighlighter.language(forPath: path)
            let base: NSAttributedString = highlighter.highlight(text, as: language)
                ?? NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ])
            let styled = NSMutableAttributedString(attributedString: base)
            let whole = NSRange(location: 0, length: (text as NSString).length)
            // Syntax themes can pick their own font family — the pane is
            // uniform monospaced, and the ruler's uniform line-height math
            // depends on it.
            styled.addAttribute(.font, value: font, range: whole)
            // Drop the highlight.js theme's OWN background (the `.hljs` rule),
            // so the pane keeps the app's semantic `textBackgroundColor`
            // instead of a theme-specific wash that would clash with the file
            // browser and the transcript. Token foreground colors stay.
            styled.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: styled.length))
            switch overlay {
            case .none:
                break
            case .diff(let added, let removed):
                // Additions green, removals red — the GitHub unified view. The
                // ranges are display-line ranges (a removed line is a real
                // line of the buffer now).
                for range in PaneContentLoader.charRanges(ofLines: added, in: text) {
                    styled.addAttribute(.backgroundColor, value: addedColor, range: range)
                }
                for range in PaneContentLoader.charRanges(ofLines: removed, in: text) {
                    styled.addAttribute(.backgroundColor, value: deletedColor, range: range)
                }
            case .hunks(let added, let removed, let headers):
                for range in PaneContentLoader.charRanges(ofLines: added, in: text) {
                    styled.addAttribute(.backgroundColor, value: addedColor, range: range)
                }
                for range in PaneContentLoader.charRanges(ofLines: removed, in: text) {
                    styled.addAttribute(.backgroundColor, value: deletedColor, range: range)
                }
                // The `@@ -a,b +c,d @@` lines are chrome, not source: a quiet
                // wash + secondary color so they separate hunks without
                // competing with the edit colors.
                for range in PaneContentLoader.charRanges(ofLines: headers, in: text) {
                    styled.addAttribute(.backgroundColor, value: hunkHeaderColor, range: range)
                    styled.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                }
            case .wholeGreen:
                styled.addAttribute(.backgroundColor, value: addedColor, range: whole)
            case .wholeRed:
                styled.addAttribute(.backgroundColor, value: deletedColor, range: whole)
            }
            return styled
        }
    }
}

// MARK: - Content loading (off the main actor)

/// The per-open-file load outcome: the text to display (nil → show
/// `message`), plus the edit overlay to paint over it.
private struct LoadedContent: Sendable {
    var displayText: String?
    var message: String?
    var overlay: PaneOverlay = .none
    /// For an interleaved diff, the REAL current-file line number of each
    /// DISPLAY line (`nil` for a removed line, which belongs to the old side).
    /// nil overall → the display is the real file and lines number 1,2,3…
    var lineNumbers: [Int?]? = nil
}

private enum PaneOverlay: Sendable {
    case none
    /// An interleaved diff of the open file: 1-based DISPLAY line indices that
    /// are additions (green) and removals (red). The display text is the real
    /// current file with the removed lines re-inserted in their original
    /// position (GitHub's unified view), so a deletion is finally visible —
    /// the marker is the red line itself.
    case diff(added: [Int], removed: [Int])
    /// The Changes page's hunks-only view: same added/removed display lines as
    /// `.diff`, plus the `@@ … @@` header lines to wash as chrome. The buffer
    /// carries only the changed regions plus context, not the whole file.
    case hunks(added: [Int], removed: [Int], headers: [Int])
    /// Every line is new (an untracked-but-added file).
    case wholeGreen
    /// Every line came from HEAD (a deletion).
    case wholeRed
}

/// Edit positions for the SCROLLBAR edit map — derived from the same diff the
/// edit overlay is built from (`PaneOverlay`), so the scrollbar and the text
/// always agree. Resolved to colors/positions by the container (the overlay is
/// carried off-main, so it stays color-free).
///
/// Files are loaded WHOLE into the code view (the entire attributed string
/// lives in the text view; TextKit only LAYS OUT lazily) — there is no
/// windowed/virtualized loading like the transcript's — so every marker has an
/// exact document position. If incremental loading is ever introduced, lines
/// beyond the loaded extent would pile at the top/bottom of the bar instead
/// (see `CodePaneEditMarkerScroller`).
enum PaneMarkers: Sendable {
    case none
    /// 1-based DISPLAY line numbers of an interleaved diff's added (green) and
    /// removed (red) lines.
    case lines(added: [Int], removed: [Int])
    /// The whole buffer is new content.
    case wholeAdded
    /// The whole buffer is the removed side of a deletion.
    case wholeDeleted
}

private enum PaneContentLoader {
    /// Reads + diffs entirely off the main thread: file IO, a `git show` when
    /// the old side is needed, and `TextDiff` all run on the global executor
    /// here; only the final attributed string is built on main.
    nonisolated static func load(cwd: URL, path: String, kind: GitStatus.Kind, mode: ReadOnlyFilePane.LoadMode) async -> LoadedContent {
        switch mode {
        case .wholeFile:
            return await loadWholeFile(cwd: cwd, path: path, kind: kind)
        case .hunks:
            return await loadHunks(cwd: cwd, path: path, kind: kind)
        }
    }

    /// The Changes page's hunks-only buffer: only the changed regions of the
    /// file plus a few context lines, framed by `@@ … @@` headers. The
    /// `lineNumbers` map still records each display line's REAL current-file
    /// line (nil for a removed line or a header), so copy-tagging from a hunk
    /// produces a reference into the actual file — never into the diff view.
    nonisolated private static func loadHunks(cwd: URL, path: String, kind: GitStatus.Kind) async -> LoadedContent {
        switch kind {
        case .deleted:
            // No on-disk content: the whole committed buffer is the old side.
            guard let head = await GitStatus.headContent(of: path, cwd: cwd) else {
                return LoadedContent(message: "No committed content for \((path as NSString).lastPathComponent).")
            }
            return LoadedContent(displayText: head, overlay: .wholeRed)
        case .added, .untracked:
            // Untracked files have no HEAD baseline but are entirely new
            // content, so the Changes page shows them as all-additions.
            guard let text = GitStatus.currentContent(of: path, cwd: cwd) else {
                return LoadedContent(message: "Couldn't read \((path as NSString).lastPathComponent).")
            }
            return LoadedContent(displayText: text, overlay: .wholeGreen)
        case .modified:
            guard let text = GitStatus.currentContent(of: path, cwd: cwd) else {
                return LoadedContent(message: "Couldn't read \((path as NSString).lastPathComponent).")
            }
            guard let old = await GitStatus.headContent(of: path, cwd: cwd) else {
                return LoadedContent(displayText: text)
            }
            let hunks = TextDiff.hunks(old: old, new: text)
            guard !hunks.isEmpty else {
                return LoadedContent(message: "No textual changes in \((path as NSString).lastPathComponent).")
            }
            return hunkContent(hunks, trailingNewline: text.hasSuffix("\n"))
        case .normal:
            return LoadedContent(message: "\((path as NSString).lastPathComponent) has no changes.")
        }
    }

    /// Renders `[TextDiff.Hunk]` into the display buffer: each hunk is one
    /// header line followed by its lines. The returned line-number map keeps
    /// every content line pointing at its REAL current-file line, a removed
    /// line / header pointing at nil — the copy machinery drops nil-mapped
    /// lines from the snippet, so a selection through a hunk never quotes the
    /// `@@` chrome or the old side.
    nonisolated static func hunkContent(_ hunks: [TextDiff.Hunk], trailingNewline: Bool = true) -> LoadedContent {
        var lines: [String] = []
        var lineNumbers: [Int?] = []
        var added: [Int] = []
        var removed: [Int] = []
        var headers: [Int] = []
        for hunk in hunks {
            lines.append("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
            lineNumbers.append(nil)
            headers.append(lines.count)
            for line in hunk.lines {
                lines.append(line.text)
                lineNumbers.append(line.newLine)
                switch line.kind {
                case .added: added.append(lines.count)
                case .removed: removed.append(lines.count)
                case .same: break
                }
            }
        }
        var text = lines.joined(separator: "\n")
        if trailingNewline, !text.isEmpty { text += "\n" }
        return LoadedContent(
            displayText: text,
            overlay: .hunks(added: added, removed: removed, headers: headers),
            lineNumbers: lineNumbers
        )
    }

    /// The Files page's full buffer: the whole current file (or its last
    /// committed content) with removed lines interleaved for a modification.
    nonisolated private static func loadWholeFile(cwd: URL, path: String, kind: GitStatus.Kind) async -> LoadedContent {
        switch kind {
        case .deleted:
            // No on-disk content: the buffer is the last-committed text, and
            // the whole buffer is the "old" side (red).
            guard let head = await GitStatus.headContent(of: path, cwd: cwd) else {
                return LoadedContent(message: "No committed content for \((path as NSString).lastPathComponent).")
            }
            return LoadedContent(displayText: head, overlay: .wholeRed)
        case .added:
            guard let text = GitStatus.currentContent(of: path, cwd: cwd) else {
                return LoadedContent(message: "Couldn't read \((path as NSString).lastPathComponent).")
            }
            return LoadedContent(displayText: text, overlay: .wholeGreen)
        case .modified:
            guard let text = GitStatus.currentContent(of: path, cwd: cwd) else {
                return LoadedContent(message: "Couldn't read \((path as NSString).lastPathComponent).")
            }
            guard let old = await GitStatus.headContent(of: path, cwd: cwd) else {
                // No HEAD baseline (edge): show the file uncolored rather than
                // fail.
                return LoadedContent(displayText: text)
            }
            let diff = interleaved(old: old, new: text)
            return LoadedContent(
                displayText: diff.text,
                overlay: .diff(added: diff.added, removed: diff.removed),
                lineNumbers: diff.lineNumbers
            )
        case .normal, .untracked:
            guard let text = GitStatus.currentContent(of: path, cwd: cwd) else {
                return LoadedContent(message: "Couldn't read \((path as NSString).lastPathComponent).")
            }
            return LoadedContent(displayText: text)
        }
    }

    /// Builds the GitHub-style interleaved view of a modification: every real
    /// current-file line in order, with each run of removed lines re-inserted
    /// where it was (removed-then-added, `TextDiff`'s order). Returns the
    /// display text, the REAL current-file line number of each display line
    /// (`nil` for a removed line), and the 1-based display lines that are
    /// added / removed so the overlay and the scrollbar can color them.
    ///
    /// A modification whose whole change is a deletion therefore displays the
    /// removed lines in red — the gap the old added-lines-only pane left
    /// (title showed a diff, content showed nothing).
    nonisolated static func interleaved(old: String, new: String) -> (text: String, lineNumbers: [Int?], added: [Int], removed: [Int]) {
        let diff = TextDiff.diff(old: old, new: new)
        var lines: [String] = []
        var lineNumbers: [Int?] = []
        var added: [Int] = []
        var removed: [Int] = []
        var currentLine = 0
        for line in diff {
            switch line.kind {
            case .same:
                currentLine += 1
                lines.append(line.text)
                lineNumbers.append(currentLine)
            case .added:
                currentLine += 1
                lines.append(line.text)
                lineNumbers.append(currentLine)
                added.append(lines.count)
            case .removed:
                lines.append(line.text)
                lineNumbers.append(nil)
                removed.append(lines.count)
            }
        }
        var text = lines.joined(separator: "\n")
        if new.hasSuffix("\n") { text += "\n" }
        return (text, lineNumbers, added, removed)
    }

    /// Character ranges (including each line's trailing newline — harmless
    /// for a background attribute) for 1-based line numbers.
    nonisolated static func charRanges(ofLines lines: [Int], in text: String) -> [NSRange] {
        guard !lines.isEmpty, !text.isEmpty else { return [] }
        let ns = text as NSString
        let length = ns.length
        // Start of each line plus a final sentinel at the text length.
        var starts: [Int] = [0]
        var search = 0
        while search < length {
            let found = ns.range(of: "\n", options: [], range: NSRange(location: search, length: length - search))
            guard found.location != NSNotFound else { break }
            starts.append(found.location + 1)
            search = found.location + 1
        }
        if starts.last != length {
            starts.append(length)
        }
        var ranges: [NSRange] = []
        for line in lines {
            let index = line - 1
            guard index >= 0, index + 1 < starts.count else { continue }
            ranges.append(NSRange(location: starts[index], length: starts[index + 1] - starts[index]))
        }
        return ranges
    }
}

// MARK: - Container view

/// The pane's view hierarchy: scroll view + line-number ruler + the real
/// buffer text view, plus a centered status label for loading/error states.
final class FilePaneContainer: NSView {
    let scrollView = NSScrollView()
    let codeView = ReadOnlyCodeTextView(frame: .zero, textContainer: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    /// Called when the view's effective appearance changes (an app light/dark
    /// toggle or a system appearance change), so the coordinator can re-run
    /// syntax highlighting with the matching theme. AppKit invokes
    /// `viewDidChangeEffectiveAppearance` for inherited appearance changes on
    /// every view in the window, so this covers a mid-session toggle without
    /// any global observer.
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        // Hard-clip everything inside the pane to the pane's own bounds. SwiftUI
        // makes this view layer-backed, and a layer-backed NSView does NOT clip
        // its subviews by default (AppKit only clips non-layer-backed drawing).
        // AppKit's ruler machinery sizes its internal content view to the
        // DOCUMENT — which can exceed the pane — and draws the gutter's
        // separator from the scroll view's geometry; with no clip that chrome
        // paints outside the pane, over the tab panel above and the prompt bar
        // below (the full-height gutter-line symptom). Clipping makes the pane's
        // own bounds the hard edge for its subviews regardless of what AppKit
        // lays out inside it.
        clipsToBounds = true

        // The edit-map scroller must be installed BEFORE the scroll view
        // creates its own (hasVerticalScroller = true below would lazily make
        // a plain NSScroller otherwise). Assigning a subclass forces the
        // legacy (always-visible) scroller style — intended: the edit map is
        // only useful while the bar is shown.
        scrollView.verticalScroller = CodePaneEditMarkerScroller()
        // The ruler and AppKit's ruler helper views are subviews of the scroll
        // view; keep them inside it too.
        scrollView.clipsToBounds = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        codeView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        codeView.textColor = .labelColor
        codeView.textContainerInset = NSSize(width: 8, height: 6)
        // No wrapping: the pane shows real file lines, which keeps the ruler's
        // uniform line-height math exact (a wrapped view would misalign the
        // per-line numbers).
        codeView.textContainer?.widthTracksTextView = false
        codeView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        codeView.isVerticallyResizable = true
        codeView.isHorizontallyResizable = true
        codeView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        codeView.autoresizingMask = []
        scrollView.documentView = codeView

        let ruler = CodeLineRulerView(scrollView: scrollView)
        ruler.codeView = codeView
        scrollView.hasVerticalRuler = true
        scrollView.verticalRulerView = ruler
        scrollView.rulersVisible = true

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    /// Shows the file's content in the real-buffer view. With
    /// `preserveScroll`, the viewport's proportional place in the file is kept
    /// across the swap (a live refresh of the file being read shouldn't jump
    /// back to the top); without it the view resets to the top (a new file).
    /// With `targetLines` (a reference-driven open), BOTH are overridden: the
    /// top-scroll inside `codeView.load` fires first, then the jump anchors
    /// the START line to the top of the viewport and flashes the range (see
    /// `revealReference`) — ordering is load-bearing, a jump issued before the
    /// load's own reset would be undone by it.
    func displayContent(path: String, text: NSAttributedString, preserveScroll: Bool = false, targetLines: (start: Int, end: Int)? = nil, markers: PaneMarkers = .none, lineNumbers: [Int?]? = nil) {
        statusLabel.isHidden = true
        codeView.isHidden = false
        codeView.clearReveal()
        // A load without a reference target clears the previous jump's ruler
        // anchor too (a reference-driven load re-sets it in revealReference).
        (scrollView.verticalRulerView as? CodeLineRulerView)?.anchorLine = nil

        let clip = scrollView.contentView
        var anchorRatio: CGFloat?
        if preserveScroll, targetLines == nil, codeView.frame.height > 0 {
            let visible = clip.bounds.height
            if visible > 0 {
                let scrollable = codeView.frame.height - visible
                if scrollable > 0 {
                    anchorRatio = min(max(clip.bounds.minY / scrollable, 0), 1)
                }
            }
        }

        codeView.load(path: path, text: text, lineNumbers: lineNumbers)
        applyMarkers(markers, in: text.string)

        if let targetLines {
            revealReference(lines: targetLines, in: text.string)
        } else if let anchorRatio {
            let visible = clip.bounds.height
            let scrollable = codeView.frame.height - visible
            if scrollable > 0 {
                let y = min(max(anchorRatio * scrollable, 0), scrollable)
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                scrollView.reflectScrolledClipView(clip)
            }
        }
    }

    /// A reference-driven open: scroll so the reference's START line anchors
    /// the top of the viewport, flash the whole referenced range with a
    /// fading highlight, and keep an anchor — a capsule over the start line in
    /// the ruler gutter plus a thin accent bar down the range's left edge — so
    /// the location stays visible after the flash fades. Runs AFTER
    /// `codeView.load`'s scroll-to-top. Lines past the end of the file simply
    /// leave the view at the top (the geometry lookup fails cleanly).
    private func revealReference(lines: (start: Int, end: Int), in text: String) {
        // `lines` are REAL current-file line numbers (what an agent-emitted
        // `pi-file://` link carries). The buffer may be an interleaved diff, so
        // map each real line to its DISPLAY line first (a removed line has no
        // own display line; the nearest context line anchors instead).
        guard let displayStart = codeView.displayLine(forRealLine: lines.start),
              let displayEnd = codeView.displayLine(forRealLine: lines.end),
              let layoutManager = codeView.layoutManager,
              let textContainer = codeView.textContainer,
              let startRange = PaneContentLoader.charRanges(ofLines: [displayStart], in: text).first,
              let endRange = PaneContentLoader.charRanges(ofLines: [displayEnd], in: text).first
        else { return }
        let charRange = NSRange(location: startRange.location, length: (endRange.location + endRange.length) - startRange.location)
        // Force the geometry now: the jump and the flash both need glyph rects
        // (line 858 of a large file is only laid out on demand).
        layoutManager.ensureLayout(for: textContainer)
        let rangeBox = layoutManager.boundingRect(
            forGlyphRange: layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil),
            in: textContainer
        )
        let startBox = layoutManager.boundingRect(
            forGlyphRange: layoutManager.glyphRange(forCharacterRange: startRange, actualCharacterRange: nil),
            in: textContainer
        )
        // Layout-manager rects are in the (flipped, top-down) container space;
        // the container sits inside the text view at the inset.
        let insetY = codeView.textContainerInset.height
        // The anchor: the start line's top at the top of the viewport. The
        // scroll position must be the start line's top expressed in the CLIP
        // VIEW's (bounds) coordinate system — the space `clip.bounds.origin`
        // lives in — not raw container+inset arithmetic: the text view's
        // frame sits at a tiling offset from the clip (its frame origin is not
        // the clip's origin), so a raw scroll lands the line that offset above
        // the viewport — the referenced line ends up out of view and the ruler
        // anchor never appears. Converting through the view chain is exact
        // whatever that offset is.
        let startTopInCodeView = startBox.minY + insetY
        let clip = scrollView.contentView
        let startClipY = clip.convert(NSPoint(x: 0, y: startTopInCodeView), from: codeView).y
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, startClipY)))
        scrollView.reflectScrolledClipView(clip)
        // The range's vertical band in text-view coordinates (full width — the
        // container rect's own width is meaningless with wrapping disabled).
        let band = NSRect(
            x: 0,
            y: rangeBox.minY + insetY,
            width: codeView.bounds.width,
            height: max(rangeBox.height, startBox.height)
        )
        codeView.startReveal(flashRect: band, anchorRect: band)
        (scrollView.verticalRulerView as? CodeLineRulerView)?.anchorLine = displayStart
    }

    /// Refreshes the scrollbar edit map for the freshly-loaded text. Marker
    /// positions are exact: the whole file is in the text view, so every edited
    /// line maps to `(line - 0.5) / lineCount` along the document. Added lines
    /// are green ticks, removed lines (of an interleaved diff) red — the same
    /// red/green the text overlay paints, so the bar and the buffer agree.
    private func applyMarkers(_ markers: PaneMarkers, in text: String) {
        guard let scroller = scrollView.verticalScroller as? CodePaneEditMarkerScroller else { return }
        switch markers {
        case .none:
            scroller.clearMarkers()
        case .wholeAdded:
            scroller.markers = []
            scroller.wholeTrackColor = .systemGreen
        case .wholeDeleted:
            scroller.markers = []
            scroller.wholeTrackColor = .systemRed
        case .lines(let added, let removed):
            scroller.wholeTrackColor = nil
            // Displayed lines: `\n` separators + a final partial line.
            var lineCount = 0
            for character in text where character == "\n" { lineCount += 1 }
            if !text.isEmpty, !text.hasSuffix("\n") { lineCount += 1 }
            guard lineCount > 0 else {
                scroller.markers = []
                return
            }
            func marker(_ line: Int, _ color: NSColor) -> CodePaneEditMarkerScroller.Marker? {
                guard line >= 1, line <= lineCount else { return nil }
                return CodePaneEditMarkerScroller.Marker(
                    fraction: (CGFloat(line) - 0.5) / CGFloat(lineCount),
                    color: color
                )
            }
            scroller.markers = (added.compactMap { marker($0, .systemGreen) }
                + removed.compactMap { marker($0, .systemRed) })
                .sorted { $0.fraction < $1.fraction }
        }
    }

    /// Centered status text (loading / unreadable / no committed content)
    /// over a blank pane.
    func showPlaceholder(_ message: String) {
        codeView.clearReveal()
        (scrollView.verticalRulerView as? CodeLineRulerView)?.anchorLine = nil
        (scrollView.verticalScroller as? CodePaneEditMarkerScroller)?.clearMarkers()
        codeView.load(path: "", text: NSAttributedString(string: ""))
        statusLabel.stringValue = message
        statusLabel.isHidden = false
    }

    // MARK: - Find in buffer

    /// Paints find-in-buffer highlights in the code view (see
    /// `ReadOnlyCodeTextView.applySearchHighlight`).
    func applySearchHighlight(ranges: [NSRange], currentIndex: Int) {
        codeView.applySearchHighlight(ranges: ranges, currentIndex: currentIndex)
    }

    /// Removes the find-in-buffer highlights, restoring the edit overlay.
    func clearSearchHighlight() {
        codeView.clearSearchHighlight()
    }

    /// Scrolls a match (a display-offset range into the current buffer) to the
    /// vertical center of the viewport. Uses the layout manager's own rects
    /// and AppKit's view conversion, exactly like the reference reveal, so the
    /// match lands centered whatever the tiling offset.
    func revealSearchMatch(_ range: NSRange) {
        guard let layoutManager = codeView.layoutManager,
              let textContainer = codeView.textContainer,
              range.location >= 0, range.length > 0,
              NSMaxRange(range) <= (codeView.string as NSString).length else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager.ensureLayout(forGlyphRange: glyphRange)
        let box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let matchCenterInClip = scrollView.contentView.convert(
            NSPoint(x: 0, y: box.midY + codeView.textContainerInset.height),
            from: codeView
        ).y
        let clip = scrollView.contentView
        let target = max(0, matchCenterInClip - clip.bounds.height / 2)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The character index at the top of the viewport — where a fresh find
    /// starts, so Cmd+F deep in a file lands on the next match below rather
    /// than yanking to line 1.
    var topVisibleCharacterIndex: Int {
        guard let layoutManager = codeView.layoutManager,
              let textContainer = codeView.textContainer,
              layoutManager.numberOfGlyphs > 0 else { return 0 }
        let clip = scrollView.contentView
        let topInCodeView = clip.convert(NSPoint(x: 0, y: clip.bounds.minY), to: codeView)
        let point = NSPoint(
            x: codeView.textContainerInset.width,
            y: max(0, topInCodeView.y - codeView.textContainerInset.height)
        )
        // A point past the last line resolves to the one-past-the-end glyph
        // index, which `characterIndexForGlyph(at:)` rejects: clamp into the
        // glyph range (the search only needs a lower bound anyway).
        let glyphIndex = min(max(layoutManager.glyphIndex(for: point, in: textContainer), 0), layoutManager.numberOfGlyphs - 1)
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }
}

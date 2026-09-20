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
/// index of each display line (rebuild anchoring), and the scrollbar edit map.
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
    let sections: [CodeSection]
    let fullIndices: [Int?]
    let markers: PaneMarkers
    /// `[0, offset-after-each-newline]`, computed off-main as the lines are
    /// appended, so applying the document does not rescan the whole buffer for
    /// line starts on the main thread.
    let lineStartOffsets: [Int]
}

/// Everything the document builder needs, snapshotted on the main actor: each
/// changed file, its loaded diff (nil while still loading), and its visible
/// window (nil when there is no diff yet). All `Sendable`, so the snapshot
/// crosses to the builder untouched.
nonisolated struct DiffBuildFile: Sendable {
    let path: String
    let diff: LoadedFileDiff?
    let window: ChangesStore.Window?
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
        /// The visible-range syntax highlighter (off-main, cache inside).
        private let highlighter = DiffHighlighter()
        private var keyMonitor: Any?

        private static let highlightScrollSettle: Duration = .milliseconds(120)
        /// Extra lines above/below the viewport to color, so a small scroll
        /// does not immediately need a new pass.
        private static let highlightMargin = 60

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
                        Task { @MainActor [weak self] in
                            self?.apply(cached, version: version)
                        }
                    } else {
                        rebuild()
                    }
                } else {
                    scheduleHighlight(immediate: true)
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

        // MARK: Scroll spy + links

        func scrollSpy() {
            guard isActive, let container else { return }
            onTopSectionChanged?(container.topSectionPath)
            // Color the newly visible lines once scrolling settles.
            scheduleHighlight(immediate: false)
        }

        func handleLink(_ url: URL) {
            guard url.scheme == DiffLink.scheme, let store else { return }
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let path = comps?.queryItems?.first(where: { $0.name == "path" })?.value
            switch url.host {
            case "expand":
                guard let path,
                      let dir = comps?.queryItems?.first(where: { $0.name == "dir" })?.value else { return }
                store.expand(path: path, direction: dir == "up" ? .up : .down)
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
            store?.cacheBuiltDocument(doc, version: version)
            let restore = anchor.flatMap { restoreCharacterIndex(for: $0, in: doc) }
            container.displayDocument(
                path: "",
                text: doc.text,
                lineNumbers: doc.lineNumbers,
                sections: doc.sections,
                markers: doc.markers,
                restoreCharacterIndex: restore,
                lineStartOffsets: doc.lineStartOffsets
            )
            container.setBusy(false)
            // A reveal that arrived before this document existed lands now.
            if let pending = pendingReveal {
                pendingReveal = nil
                reveal(pending.path, line: pending.line)
            }
            // The buffer was replaced: re-run an active find against it, then
            // color whatever is on screen.
            search?.bufferDidChange()
            scheduleHighlight(immediate: true)
        }

        /// The main-actor snapshot of the store's changed files and their loaded
        /// diffs/windows, for the off-main builder.
        private func snapshot(_ store: ChangesStore) -> [DiffBuildFile] {
            store.entries.map { entry in
                let diff = store.diffs[entry.path]
                return DiffBuildFile(
                    path: entry.path,
                    diff: diff,
                    window: diff.map { store.window(for: $0) }
                )
            }
        }

        private func currentDark() -> Bool {
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        // MARK: Visible-range highlighting

        /// Coalesces highlight passes: a burst of scroll events runs at most one
        /// pass, after the viewport settles.
        private func scheduleHighlight(immediate: Bool) {
            guard isActive else { return }
            highlightTask?.cancel()
            let version = appliedDocumentVersion
            highlightTask = Task { [weak self] in
                if !immediate {
                    try? await Task.sleep(for: Self.highlightScrollSettle)
                }
                guard !Task.isCancelled else { return }
                await self?.highlightVisible(documentVersion: version)
            }
        }

        /// Highlights ONLY the display lines currently on screen (plus a small
        /// margin), for the sections that intersect them. Highlighting runs off
        /// the main actor; the finished colors are applied in one hop.
        private func highlightVisible(documentVersion: Int) async {
            guard isActive, documentVersion == appliedDocumentVersion,
                  let container, let document, let store,
                  let visible = container.visibleDisplayLineRange else { return }

            let lower = max(1, visible.lowerBound - Self.highlightMargin)
            let upper = visible.upperBound + Self.highlightMargin
            var chunks: [HighlightChunk] = []
            for section in document.sections where section.lineRange.overlaps(lower...upper) {
                // A message-only section is secondary-colored prose, not code.
                guard store.diffs[section.path]?.message == nil else { continue }
                let start = max(section.diffLineRange.lowerBound, lower)
                let end = min(section.diffLineRange.upperBound, upper)
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
            guard !chunks.isEmpty else { return }

            let dark = currentDark()
            let highlighter = self.highlighter
            let highlighted = await Task.detached(priority: .userInitiated) {
                highlighter.highlight(chunks, dark: dark)
            }.value
            guard !Task.isCancelled, isActive, documentVersion == appliedDocumentVersion else { return }
            container.applyHighlights(highlighted)
        }

        /// The (path, full-array line) at the top of the viewport, so a rebuild
        /// can keep the reader's place (expansion inserts lines above).
        private func captureAnchor() -> (path: String, fullIndex: Int)? {
            guard let container, let document else { return nil }
            let index = container.topVisibleCharacterIndex
            let length = (container.codeView.string as NSString).length
            guard length > 0 else { return nil }
            let displayLine = container.codeView.lineNumber(forIndex: min(index, length - 1))
            guard displayLine >= 1, displayLine - 1 < document.fullIndices.count,
                  let fullIndex = document.fullIndices[displayLine - 1],
                  let path = document.sections.first(where: { $0.lineRange.contains(displayLine) })?.path
            else { return nil }
            return (path, fullIndex)
        }

        private func restoreCharacterIndex(for anchor: (path: String, fullIndex: Int), in doc: DiffDocument) -> Int? {
            guard let container else { return nil }
            for section in doc.sections where section.path == anchor.path {
                for line in section.lineRange {
                    guard line - 1 < doc.fullIndices.count, doc.fullIndices[line - 1] == anchor.fullIndex else { continue }
                    guard line - 1 < container.codeView.lineStartOffsets.count else { return nil }
                    return container.codeView.lineStartOffsets[line - 1]
                }
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
        let text = NSMutableAttributedString()
        var lineNumbers: [Int?] = []
        var fullIndices: [Int?] = []
        var sections: [CodeSection] = []
        var addedLines: [Int] = []
        var removedLines: [Int] = []

        func appendLine(_ attributed: NSAttributedString, lineNumber: Int?, fullIndex: Int?) -> (line: Int, start: Int) {
            if !lineNumbers.isEmpty { text.append(NSAttributedString(string: "\n")) }
            let start = text.length
            text.append(attributed)
            lineNumbers.append(lineNumber)
            fullIndices.append(fullIndex)
            return (lineNumbers.count, start)
        }

        for file in input.files {
            guard let diff = file.diff, let window = file.window else {
                _ = appendLine(placeholderLine("Loading \(file.path)…"), lineNumber: nil, fullIndex: nil)
                continue
            }
            // The file's identity lives in the viewer header above the pane, so
            // the document opens straight onto the diff — no repeated
            // path/stats/extras row under it.
            let sectionStart = lineNumbers.count + 1

            if diff.message == nil, window.start > 0 {
                _ = appendLine(expandLine(hidden: window.start, path: file.path, direction: "up", label: "above"), lineNumber: nil, fullIndex: nil)
            }

            var diffStart = -1
            var diffEnd = -1
            var diffFirstLine = -1
            var diffLastLine = -1
            if diff.message == nil, !diff.lines.isEmpty {
                for index in window.start...window.end {
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
                    let appended = appendLine(attributed, lineNumber: diff.lineNumbers[index], fullIndex: index)
                    if diffStart < 0 { diffStart = appended.start }
                    diffEnd = appended.start + attributed.length
                    if diffFirstLine < 0 { diffFirstLine = appended.line }
                    diffLastLine = appended.line
                    if line.kind == .added { addedLines.append(appended.line) }
                    if line.kind == .removed { removedLines.append(appended.line) }
                }
            } else if let message = diff.message {
                let placeholder = placeholderLine(message)
                let appended = appendLine(placeholder, lineNumber: nil, fullIndex: nil)
                diffStart = appended.start
                diffEnd = appended.start + placeholder.length
                diffFirstLine = appended.line
                diffLastLine = appended.line
            }

            if diff.message == nil, window.end < diff.lines.count - 1 {
                let hidden = diff.lines.count - 1 - window.end
                _ = appendLine(expandLine(hidden: hidden, path: file.path, direction: "down", label: "below"), lineNumber: nil, fullIndex: nil)
            }

            let sectionEnd = lineNumbers.count
            // A section with no lines (an empty new file) has no position to
            // anchor the scroll spy or a reveal on; skip it.
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
                diffCharRange: diffRange
            ))
        }

        return DiffDocument(
            text: text,
            lineNumbers: lineNumbers,
            sections: sections,
            fullIndices: fullIndices,
            markers: .lines(added: addedLines, removed: removedLines),
            // Same algorithm as the text view's own scan, run here off-main
            // (the view is the single source of truth for the invariant).
            lineStartOffsets: ReadOnlyCodeTextView.lineStartOffsets(in: text.string)
        )
    }

    private static func selfURL(host: String, path: String, direction: String? = nil) -> URL? {
        var comps = URLComponents()
        comps.scheme = DiffLink.scheme
        comps.host = host
        var items = [URLQueryItem(name: "path", value: path)]
        if let direction {
            items.append(URLQueryItem(name: "dir", value: direction))
        }
        comps.queryItems = items
        return comps.url
    }

    private static func expandLine(hidden: Int, path: String, direction: String, label: String) -> NSAttributedString {
        let text = "  ⌃  \(hidden) more line\(hidden == 1 ? "" : "s") \(label) — click to expand"
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        if let url = selfURL(host: "expand", path: path, direction: direction) {
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

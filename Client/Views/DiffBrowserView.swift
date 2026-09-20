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
    let files: [DiffBuildFile]
    let dark: Bool
}

/// The Changes page's diff viewer: ONE scroll view holding every changed
/// file's diff, in path order, with top/bottom expand controls. It replaces
/// the old per-file pane — the whole sidebar of changed files is one
/// continuous read, and the sidebar highlights whichever file's section owns
/// the top of the viewport. The document carries no per-file title row: the
/// viewer header above the pane names the file (and opens it) for the whole
/// changeset.
///
/// The document is built by `DiffDocumentBuilder` OFF the main actor —
/// highlight.js is by far the expensive part (one synchronous JS pass per
/// file, ~200ms/1000 lines), so opening Changes on a large project must never
/// run it on the main thread. `updateNSView` kicks off a build only when the
/// store's `documentVersion` changes and applies the finished document in one
/// main-actor hop; expansion edits the store's per-file window and bumps that
/// version.
struct DiffBrowserView: NSViewRepresentable {
    let store: ChangesStore
    /// Bumped by the store whenever the document's inputs change (diffs
    /// loaded, a file expanded, content reloaded).
    let documentVersion: Int
    /// One-shot: scroll to this path's section.
    let revealPath: String?
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
        private var appliedRevealPath: String?
        private var isActive = true
        private var needsRebuild = false
        /// The off-main document builder (owns the syntax highlighter and its
        /// per-file cache). One build at a time; a superseded build's result is
        /// discarded by the version check in `apply`.
        private let builder = DiffDocumentBuilder()
        private var buildTask: Task<Void, Never>?
        private var document: DiffDocument?
        private var keyMonitor: Any?

        // MARK: Lifecycle

        func setActive(_ active: Bool) {
            guard isActive != active else { return }
            isActive = active
            if active {
                if needsRebuild {
                    needsRebuild = false
                    rebuild()
                }
            } else {
                // Abandon an in-flight build: a hidden page does no highlighting
                // work and never applies a document nothing shows. The version
                // was already recorded as applied, so flag a catch-up rebuild.
                if buildTask != nil { needsRebuild = true }
                buildTask?.cancel()
                buildTask = nil
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
            onRevealConsumed: @escaping () -> Void,
            onTopSectionChanged: @escaping (String?) -> Void
        ) {
            self.store = store
            self.onRevealConsumed = onRevealConsumed
            self.onTopSectionChanged = onTopSectionChanged

            if documentVersion != appliedDocumentVersion {
                appliedDocumentVersion = documentVersion
                if isActive {
                    rebuild()
                } else {
                    needsRebuild = true
                }
            }
            if let revealPath, revealPath != appliedRevealPath {
                appliedRevealPath = revealPath
                reveal(revealPath)
                onRevealConsumed()
            }
            if revealPath == nil {
                appliedRevealPath = nil
            }
        }

        func appearanceChanged() {
            guard isActive else {
                needsRebuild = true
                return
            }
            // The highlight cache keys on the appearance, so a light/dark change
            // simply re-highlights; no cache reset is needed.
            rebuild()
        }

        func teardown() {
            buildTask?.cancel()
            buildTask = nil
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

        func reveal(_ path: String) {
            guard let container, let index = container.characterIndex(forPath: path) else { return }
            container.scrollCharacterToTop(index)
            onTopSectionChanged?(path)
        }

        // MARK: Rebuild

        /// Snapshots the store's inputs on the main actor and starts an off-main
        /// build. The finished document is applied in one main-actor hop — if the
        /// document version has not moved on, and the page is still visible.
        private func rebuild() {
            guard let container, let store else { return }
            let version = appliedDocumentVersion
            let input = DiffBuildInput(files: snapshot(store), dark: currentDark())
            buildTask?.cancel()
            container.setBusy(true)
            let builder = self.builder
            buildTask = Task.detached(priority: .userInitiated) { [weak self] in
                let doc = builder.build(input)
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
            let restore = anchor.flatMap { restoreCharacterIndex(for: $0, in: doc) }
            container.displayDocument(
                path: "",
                text: doc.text,
                lineNumbers: doc.lineNumbers,
                sections: doc.sections,
                markers: doc.markers,
                restoreCharacterIndex: restore
            )
            container.setBusy(false)
            // The buffer was replaced: re-run an active find against it.
            search?.bufferDidChange()
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

/// Builds one diff document off the main thread.
///
/// This is the diff viewer's counterpart to the transcript's off-main height
/// pre-measurement: the expensive work (highlight.js, one synchronous JS pass
/// per file) runs here on a worker thread, and the finished document crosses
/// back to the main actor in a single hop. `@unchecked Sendable` is justified
/// by `lock`: every mutation (the highlighter's JS context and the per-file
/// cache) happens under it, so the non-Sendable `Highlightr` is never touched
/// concurrently, and `build` returns an immutable `DiffDocument`.
///
/// The cache is keyed by the window's CONTENT and appearance, not a content
/// epoch: re-listing the working tree and finding a file unchanged reuses its
/// highlighted segment, so a page open or a no-op refresh never re-highlights
/// the whole changeset.
nonisolated final class DiffDocumentBuilder: @unchecked Sendable {
    private let lock = NSLock()
    /// Created on the first (off-main) build, never on the main actor — a
    /// `var` rather than `lazy` (a nonisolated `lazy var` is rejected) but
    /// always touched under `lock`.
    private var highlighter: SyntaxHighlighter?
    private var cache: [String: (key: String, attributed: NSAttributedString)] = [:]

    func build(_ input: DiffBuildInput) -> DiffDocument {
        lock.lock()
        defer { lock.unlock() }

        let addedColor = NSColor.systemGreen.withAlphaComponent(0.18)
        let deletedColor = NSColor.systemRed.withAlphaComponent(0.16)
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
            if diff.message == nil, !diff.lines.isEmpty {
                let lines = highlightedLines(diff: diff, window: window, dark: input.dark)
                for index in window.start...window.end {
                    let line = diff.lines[index]
                    let attributed = NSMutableAttributedString(attributedString: lines[index - window.start])
                    normalizeFont(attributed)
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
                    if line.kind == .added { addedLines.append(appended.line) }
                    if line.kind == .removed { removedLines.append(appended.line) }
                }
            } else if let message = diff.message {
                let placeholder = placeholderLine(message)
                let appended = appendLine(placeholder, lineNumber: nil, fullIndex: nil)
                diffStart = appended.start
                diffEnd = appended.start + placeholder.length
            }

            if diff.message == nil, window.end < diff.lines.count - 1 {
                let hidden = diff.lines.count - 1 - window.end
                _ = appendLine(expandLine(hidden: hidden, path: file.path, direction: "down", label: "below"), lineNumber: nil, fullIndex: nil)
            }

            let sectionEnd = lineNumbers.count
            // A section with no lines (an empty new file) has no position to
            // anchor the scroll spy or a reveal on; skip it.
            guard sectionEnd >= sectionStart, diffStart >= 0 else { continue }
            let diffRange = NSRange(location: diffStart, length: max(diffEnd - diffStart, 0))
            sections.append(CodeSection(path: file.path, lineRange: sectionStart...sectionEnd, diffCharRange: diffRange))
        }

        return DiffDocument(
            text: text,
            lineNumbers: lineNumbers,
            sections: sections,
            fullIndices: fullIndices,
            markers: .lines(added: addedLines, removed: removedLines)
        )
    }

    /// The syntax-highlighted lines of a file's current window, cached so an
    /// expansion (or an unchanged reload) only re-highlights the file whose
    /// content changed.
    private func highlightedLines(diff: LoadedFileDiff, window: ChangesStore.Window, dark: Bool) -> [NSAttributedString] {
        let plain = (window.start...window.end).map { diff.lines[$0].text }.joined(separator: "\n")
        let key = "\(dark)|\(plain)"
        if let cached = cache[diff.path], cached.key == key {
            return splitLines(cached.attributed)
        }
        let language = SyntaxHighlighter.language(forPath: diff.path)
        let base = resolvedHighlighter().highlight(plain, as: language, dark: dark)
            ?? NSAttributedString(string: plain, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
        let normalized = NSMutableAttributedString(attributedString: base)
        normalized.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: normalized.length))
        cache[diff.path] = (key, normalized)
        return splitLines(normalized)
    }

    /// Splits a highlighted window back into its lines (the newline separators
    /// used to build it are dropped).
    private func splitLines(_ attributed: NSAttributedString) -> [NSAttributedString] {
        let string = attributed.string as NSString
        var result: [NSAttributedString] = []
        var location = 0
        while location <= string.length {
            let search = NSRange(location: location, length: string.length - location)
            let found = string.range(of: "\n", options: [], range: search)
            let end = found.location == NSNotFound ? string.length : found.location
            result.append(attributed.attributedSubstring(from: NSRange(location: location, length: end - location)))
            if found.location == NSNotFound { break }
            location = found.location + 1
        }
        return result
    }

    /// The highlighting engine, created on first use (off-main, under the
    /// builder's lock). Highlightr loads and evaluates highlight.min.js —
    /// doing that at `DiffDocumentBuilder` construction would run it on the
    /// main actor when the coordinator is created.
    private func resolvedHighlighter() -> SyntaxHighlighter {
        if let highlighter { return highlighter }
        let created = SyntaxHighlighter()
        highlighter = created
        return created
    }

    private func normalizeFont(_ attributed: NSMutableAttributedString) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        attributed.addAttribute(.font, value: font, range: NSRange(location: 0, length: attributed.length))
    }

    /// Builds a `pi-diff://` link for a path.
    private func selfURL(host: String, path: String, direction: String? = nil) -> URL? {
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

    private func expandLine(hidden: Int, path: String, direction: String, label: String) -> NSAttributedString {
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

    private func placeholderLine(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
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

import AppKit
import Core
import SwiftUI

/// One built diff document: the attributed text for the one big scrollable
/// area, the per-display-line real-line map (for the gutter), the file
/// sections (scroll spy + reveal + reference-tagged copies), the full-array
/// index of each display line (rebuild anchoring), and the scrollbar edit map.
struct DiffDocument {
    var text: NSAttributedString
    var lineNumbers: [Int?]
    var sections: [CodeSection]
    var fullIndices: [Int?]
    var markers: PaneMarkers
}

/// The Changes page's diff viewer: ONE scroll view holding every changed
/// file's diff, in path order, with a per-file header and top/bottom expand
/// controls. It replaces the old per-file pane — the whole sidebar of changed
/// files is one continuous read, and the sidebar highlights whichever file's
/// section owns the top of the viewport.
///
/// All document building happens here (main actor, because syntax highlighting
/// is), on demand: `updateNSView` rebuilds only when the store's
/// `documentVersion` changes. Expansion edits the store's per-file window and
/// bumps that version; unchanged files are served from the highlight cache.
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
        private let highlighter = SyntaxHighlighter()
        private var document: DiffDocument?
        /// Per-file highlighted diff-lines cache: keyed by path, valid for one
        /// (content epoch, window, appearance) triple. Expansion re-highlights
        /// only the file whose window changed.
        private var highlightCache: [String: (key: String, attributed: NSAttributedString)] = [:]
        private var keyMonitor: Any?

        private static let addedColor = NSColor.systemGreen.withAlphaComponent(0.18)
        private static let deletedColor = NSColor.systemRed.withAlphaComponent(0.16)
        private static let headerBackground = NSColor.labelColor.withAlphaComponent(0.07)
        private static let linkScheme = "pi-diff"

        // MARK: Lifecycle

        func setActive(_ active: Bool) {
            guard isActive != active else { return }
            isActive = active
            if active, needsRebuild {
                needsRebuild = false
                rebuild()
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
            // Theme change: drop the cache so every file re-highlights.
            highlightCache.removeAll()
            rebuild()
        }

        func teardown() {
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
            guard url.scheme == Self.linkScheme, let store else { return }
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let path = comps?.queryItems?.first(where: { $0.name == "path" })?.value
            switch url.host {
            case "expand":
                guard let path,
                      let dir = comps?.queryItems?.first(where: { $0.name == "dir" })?.value else { return }
                store.expand(path: path, direction: dir == "up" ? .up : .down)
            case "open":
                guard let path else { return }
                store.openInDefaultApp(path)
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

        private func rebuild() {
            guard let container, let store else { return }
            let anchor = captureAnchor()
            let doc = build(store: store)
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
            // The buffer was replaced: re-run an active find against it.
            search?.bufferDidChange()
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

        // MARK: Document building

        private func build(store: ChangesStore) -> DiffDocument {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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

            for entry in store.entries {
                guard let diff = store.diffs[entry.path] else {
                    _ = appendLine(placeholderLine("Loading \(entry.path)…"), lineNumber: nil, fullIndex: nil)
                    continue
                }
                let headerRow = appendLine(headerLine(entry), lineNumber: nil, fullIndex: nil)
                let sectionStart = headerRow.line

                if diff.message == nil, store.canExpand(diff, .up) {
                    let hidden = store.window(for: diff).start
                    _ = appendLine(expandLine(hidden: hidden, path: entry.path, direction: "up", label: "above"), lineNumber: nil, fullIndex: nil)
                }

                var diffStart = -1
                var diffEnd = -1
                if diff.message == nil, diff.displayLineCount > 0 {
                    let window = store.window(for: diff)
                    let lines = highlightedLines(diff: diff, window: window, dark: dark, contentEpoch: store.contentEpoch)
                    for index in window.start...window.end {
                        let line = diff.lines[index]
                        let attributed = NSMutableAttributedString(attributedString: lines[index - window.start])
                        normalizeFont(attributed)
                        switch line.kind {
                        case .added:
                            attributed.addAttribute(.backgroundColor, value: Self.addedColor, range: NSRange(location: 0, length: attributed.length))
                        case .removed:
                            attributed.addAttribute(.backgroundColor, value: Self.deletedColor, range: NSRange(location: 0, length: attributed.length))
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
                    _ = appendLine(placeholderLine(message), lineNumber: nil, fullIndex: nil)
                }

                if diff.message == nil, store.canExpand(diff, .down) {
                    let window = store.window(for: diff)
                    let hidden = diff.displayLineCount - 1 - window.end
                    _ = appendLine(expandLine(hidden: hidden, path: entry.path, direction: "down", label: "below"), lineNumber: nil, fullIndex: nil)
                }

                let sectionEnd = lineNumbers.count
                let diffRange: NSRange
                if diffStart >= 0 {
                    diffRange = NSRange(location: diffStart, length: max(diffEnd - diffStart, 0))
                } else {
                    diffRange = NSRange(location: headerRow.start, length: 0)
                }
                sections.append(CodeSection(path: entry.path, lineRange: sectionStart...sectionEnd, diffCharRange: diffRange))
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
        /// expansion only re-highlights the file whose window changed.
        private func highlightedLines(diff: LoadedFileDiff, window: ChangesStore.Window, dark: Bool, contentEpoch: Int) -> [NSAttributedString] {
            let key = "\(contentEpoch)|\(diff.path)|\(diff.lines.count)|\(window.start)|\(window.end)|\(dark)"
            if let cached = highlightCache[diff.path], cached.key == key {
                return splitLines(cached.attributed)
            }
            let slice = window.start...window.end
            let plain = slice.map { diff.lines[$0].text }.joined(separator: "\n")
            let language = SyntaxHighlighter.language(forPath: diff.path)
            let base = highlighter.highlight(plain, as: language)
                ?? NSAttributedString(string: plain, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ])
            let normalized = NSMutableAttributedString(attributedString: base)
            normalized.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: normalized.length))
            highlightCache[diff.path] = (key, normalized)
            return splitLines(normalized)
        }

        /// Splits a highlighted window back into its lines (the newline
        /// separators used to build it are dropped).
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

        private func normalizeFont(_ attributed: NSMutableAttributedString) {
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            attributed.addAttribute(.font, value: font, range: NSRange(location: 0, length: attributed.length))
        }

        private func headerLine(_ entry: GitStatus.FileEntry) -> NSAttributedString {
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            let result = NSMutableAttributedString(string: entry.path, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ])
            if let stats = entry.stats, stats.added + stats.deleted > 0 {
                if stats.added > 0 {
                    result.append(NSAttributedString(string: "  +\(stats.added)", attributes: [
                        .font: font, .foregroundColor: NSColor.systemGreen,
                    ]))
                }
                if stats.deleted > 0 {
                    result.append(NSAttributedString(string: "  −\(stats.deleted)", attributes: [
                        .font: font, .foregroundColor: NSColor.systemRed,
                    ]))
                }
            } else if entry.kind == .untracked {
                result.append(NSAttributedString(string: "  new", attributes: [
                    .font: font, .foregroundColor: NSColor.systemBlue,
                ]))
            }
            // A trailing link hands the WHOLE file to another app — the viewer
            // only ever shows the diff. Omitted for a deleted file (nothing on
            // disk to open).
            if entry.kind != .deleted, let url = selfURL(host: "open", path: entry.path) {
                let linkStart = result.length
                result.append(NSAttributedString(string: "   ↗ Open in app", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.controlAccentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]))
                result.addAttribute(.link, value: url, range: NSRange(location: linkStart, length: result.length - linkStart))
            }
            result.addAttribute(.backgroundColor, value: Self.headerBackground, range: NSRange(location: 0, length: result.length))
            return result
        }

        /// Builds a `pi-diff://` link for a path.
        private func selfURL(host: String, path: String, direction: String? = nil) -> URL? {
            var comps = URLComponents()
            comps.scheme = Self.linkScheme
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

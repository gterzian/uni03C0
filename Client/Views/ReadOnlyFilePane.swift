import AppKit
import Core
import SwiftUI

/// The file browser's content pane: a real, current (or, for a deletion,
/// last-committed) file buffer in a `ReadOnlyCodeTextView`, with edit-coloring
/// applied as attributes on top of syntax highlighting. Always the actual text
/// — never an interleaved diff — so `startLine`/`endLine` mean "line N of the
/// real file" and copy-tagging stays exact (§2.6).
struct ReadOnlyFilePane: NSViewRepresentable {
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FilePaneContainer {
        let container = FilePaneContainer()
        context.coordinator.container = container
        return container
    }

    func updateNSView(_ nsView: FilePaneContainer, context: Context) {
        context.coordinator.reload(
            cwd: cwd,
            path: path,
            kind: kind,
            token: reloadToken,
            reference: pendingReference?.path == path ? pendingReference : nil,
            onReferenceConsumed: onReferenceConsumed
        )
    }

    @MainActor
    final class Coordinator {
        weak var container: FilePaneContainer?
        private var loadTask: Task<Void, Never>?
        private var lastRequest: (path: String, token: Int)?
        private var displayedPath: String?
        private let highlighter = SyntaxHighlighter()
        private let addedColor = NSColor.systemGreen.withAlphaComponent(0.18)
        private let deletedColor = NSColor.systemRed.withAlphaComponent(0.16)

        func reload(cwd: URL, path: String, kind: GitStatus.Kind, token: Int, reference: FileReferenceLink?, onReferenceConsumed: (() -> Void)?) {
            guard container != nil else { return }
            if let last = lastRequest, last.path == path, last.token == token { return }
            lastRequest = (path, token)
            // Hand the reference to THIS load only: it travels as a parameter
            // of the task it belongs to, so a later, unrelated reload (which
            // passes nil) can never overwrite or inherit it. The store's
            // one-shot copy is consumed here — this reload captured it.
            if reference != nil {
                onReferenceConsumed?()
            }
            loadTask?.cancel()
            // A genuinely different file clears the pane while it loads; a
            // same-path refresh (the file changed) keeps showing the old
            // content until the new one is ready.
            if displayedPath != path {
                container?.showPlaceholder("Loading…")
            }
            loadTask = Task { [weak self] in
                await self?.performLoad(cwd: cwd, path: path, kind: kind, token: token, reference: reference)
            }
        }

        private func performLoad(cwd: URL, path: String, kind: GitStatus.Kind, token: Int, reference: FileReferenceLink?) async {
            guard let container else { return }
            let loaded = await PaneContentLoader.load(cwd: cwd, path: path, kind: kind)
            // A newer request supersedes this one.
            guard let last = lastRequest, last.path == path, last.token == token else { return }
            // The target lines ride on the request that captured them (see
            // `reload`) — a whole-file reference has no target lines.
            let targetLines: (start: Int, end: Int)? = reference.flatMap { ref in
                guard let start = ref.startLine else { return nil }
                return (start, max(start, ref.endLine ?? start))
            }
            // The scrollbar edit map mirrors the edit overlay exactly (same
            // added-line diff / whole-file classification).
            let markers: PaneMarkers = switch loaded.overlay {
            case .none: .none
            case .greenLines(let lines): .lines(lines)
            case .wholeGreen: .wholeAdded
            case .wholeRed: .wholeDeleted
            }
            // The code view is stamped with the file's RESOLVED ABSOLUTE path
            // (canonicalized once, here) — never the git-relative path: a
            // relative path would later be resolved against the app process's
            // own working directory ("Client/ClientApp.swift" → "/Client/…")
            // when the reference is rendered, producing the bogus `..` walk
            // the pasted anchor showed (§1.1).
            let absolutePath = SandboxPolicy.canonicalize(URL(fileURLWithPath: path, relativeTo: cwd).path)
            if let text = loaded.displayText {
                let attributed = makeAttributed(text: text, path: path, overlay: loaded.overlay)
                // A live refresh of the file the user is already reading must
                // not yank the view back to the top — keep their place when
                // the same file is being re-shown. A reference-driven open
                // (targetLines != nil) is never "keep my place": even when it
                // IS the same file, the click means "show me THIS line", so
                // the ratio logic is skipped and the jump lands after load.
                container.displayContent(
                    path: absolutePath,
                    text: attributed,
                    preserveScroll: targetLines == nil && displayedPath == path,
                    targetLines: targetLines,
                    markers: markers
                )
            } else {
                container.showPlaceholder(loaded.message ?? "Couldn't read \((path as NSString).lastPathComponent).")
            }
            displayedPath = path
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
            switch overlay {
            case .none:
                break
            case .greenLines(let lines):
                for range in PaneContentLoader.charRanges(ofLines: lines, in: text) {
                    styled.addAttribute(.backgroundColor, value: addedColor, range: range)
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
}

private enum PaneOverlay: Sendable {
    case none
    /// 1-based lines of the CURRENT text that were added.
    case greenLines([Int])
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
    /// 1-based added lines of the current text (a partial modification).
    case lines([Int])
    /// The whole buffer is new content.
    case wholeAdded
    /// The whole buffer is the removed side of a deletion.
    case wholeDeleted
}

private enum PaneContentLoader {
    /// Reads + diffs entirely off the main thread: file IO, a `git show` when
    /// the old side is needed, and `TextDiff` all run on the global executor
    /// here; only the final attributed string is built on main.
    nonisolated static func load(cwd: URL, path: String, kind: GitStatus.Kind) async -> LoadedContent {
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
            return LoadedContent(displayText: text, overlay: .greenLines(addedLineNumbers(old: old, new: text)))
        case .normal, .untracked:
            guard let text = GitStatus.currentContent(of: path, cwd: cwd) else {
                return LoadedContent(message: "Couldn't read \((path as NSString).lastPathComponent).")
            }
            return LoadedContent(displayText: text)
        }
    }

    /// 1-based line numbers (in the NEW text) of added lines, from the same
    /// `TextDiff` output used everywhere else. `.same` and `.added` lines each
    /// occupy one current-text line, in order; `.removed` lines have no
    /// position in the current text at all and are deliberately not shown
    /// inline (the red side of a modification is what the tree's
    /// deletion-vs-addition fill behind the file name shows — see
    /// `rowTintColor` in FileBrowserView).
    nonisolated static func addedLineNumbers(old: String, new: String) -> [Int] {
        let diff = TextDiff.diff(old: old, new: new)
        var added: [Int] = []
        var newLine = 0
        for line in diff {
            switch line.kind {
            case .same, .added:
                newLine += 1
            case .removed:
                continue
            }
            if line.kind == .added {
                added.append(newLine)
            }
        }
        return added
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        // The edit-map scroller must be installed BEFORE the scroll view
        // creates its own (hasVerticalScroller = true below would lazily make
        // a plain NSScroller otherwise). Assigning a subclass forces the
        // legacy (always-visible) scroller style — intended: the edit map is
        // only useful while the bar is shown.
        scrollView.verticalScroller = CodePaneEditMarkerScroller()
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
    func displayContent(path: String, text: NSAttributedString, preserveScroll: Bool = false, targetLines: (start: Int, end: Int)? = nil, markers: PaneMarkers = .none) {
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

        codeView.load(path: path, text: text)
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
        guard let layoutManager = codeView.layoutManager,
              let textContainer = codeView.textContainer,
              let startRange = PaneContentLoader.charRanges(ofLines: [lines.start], in: text).first,
              let endRange = PaneContentLoader.charRanges(ofLines: [lines.end], in: text).first
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
        // The anchor: the start line's top at the top of the viewport.
        let startDocY = startBox.minY + insetY
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, startDocY)))
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
        (scrollView.verticalRulerView as? CodeLineRulerView)?.anchorLine = lines.start
    }

    /// Refreshes the scrollbar edit map for the freshly-loaded text. Marker
    /// positions are exact: the whole file is in the text view, so every added
    /// line maps to `(line - 0.5) / lineCount` along the document.
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
        case .lines(let lines):
            scroller.wholeTrackColor = nil
            // Real displayed lines: `\n` separators + a final partial line.
            var lineCount = 0
            for character in text where character == "\n" { lineCount += 1 }
            if !text.isEmpty, !text.hasSuffix("\n") { lineCount += 1 }
            guard lineCount > 0 else {
                scroller.markers = []
                return
            }
            scroller.markers = lines.compactMap { line in
                guard line >= 1, line <= lineCount else { return nil }
                return CodePaneEditMarkerScroller.Marker(
                    fraction: (CGFloat(line) - 0.5) / CGFloat(lineCount),
                    color: .systemGreen
                )
            }
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
}

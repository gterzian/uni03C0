import AppKit
import Core

/// The find-in-buffer surface a code viewer exposes to the page that owns it.
/// The concrete implementation (`CodeSearchModel`) is `@Observable`; the viewer
/// depends on this protocol rather than that class so the renderer test bundle
/// can compile the viewer without the Observation macro plugin (blocked in the
/// test sandbox).
@MainActor
protocol CodeSearching: AnyObject {
    var isVisible: Bool { get }
    func attach(_ container: CodePaneContainer)
    func toggle()
    func next()
    func previous()
    func close()
    /// The viewer replaced the buffer (a rebuild, an expansion): re-run the
    /// current query against the new text.
    func bufferDidChange()
}

/// Edit positions for the diff viewer's scrollbar edit map: the display lines
/// that are additions (green ticks) and removals (red ticks) across every file
/// shown. Resolved to positions by the container, since the builder that
/// produces them stays color-free.
enum PaneMarkers: Sendable {
    case none
    /// 1-based DISPLAY line numbers of additions and removals, in the whole
    /// document.
    case lines(added: [Int], removed: [Int])
}

/// A highlighted chunk, with its position in the document. Consumed by
/// `CodePaneContainer.applyHighlights`; declared here (with its consumer)
/// rather than in `DiffBrowserView` so the container compiles into the
/// renderer test bundle, which does not build the whole Changes page.
nonisolated struct HighlightedChunk: @unchecked Sendable {
    let range: NSRange
    let attributed: NSAttributedString
}

/// One file's slice of the diff viewer's document: where its lines live in the
/// document, which of those lines are actual diff lines (the visible-range
/// highlighter colors only these, never the expand/placeholder rows), and which
/// characters belong to its diff (for reference-tagged copies). `lineRange`
/// spans the section's diff and expand lines too, so the scroll spy attributes
/// a viewport parked anywhere in the section to the right file.
nonisolated struct CodeSection: Sendable {
    /// Session-relative path (the form the sidebar and the agent use).
    let path: String
    /// Canonical absolute path of the same file. The diff document is a
    /// multi-file buffer, so this is what a reference-tagged copy writes into
    /// the `CodeReference` (the reference must name the FILE, never the diff).
    let absolutePath: String
    let lineRange: ClosedRange<Int>
    /// Display lines holding real diff lines (excludes expand/placeholder rows).
    let diffLineRange: ClosedRange<Int>
    /// The rendered code-line runs, ascending. A file with far-apart changes is
    /// several runs separated by expand controls, so the visible highlighter
    /// and the reference-tagged copy ranges walk these, never the whole
    /// `diffLineRange` (which would swallow the control rows between hunks).
    let codeLineRanges: [ClosedRange<Int>]
    let diffCharRange: NSRange

    init(
        path: String,
        absolutePath: String,
        lineRange: ClosedRange<Int>,
        diffLineRange: ClosedRange<Int>,
        codeLineRanges: [ClosedRange<Int>]? = nil,
        diffCharRange: NSRange
    ) {
        self.path = path
        self.absolutePath = absolutePath
        self.lineRange = lineRange
        self.diffLineRange = diffLineRange
        self.codeLineRanges = codeLineRanges ?? [diffLineRange]
        self.diffCharRange = diffCharRange
    }
}

/// The diff viewer's view hierarchy: one scroll view over one buffered
/// `ReadOnlyCodeTextView` holding every shown file's diff, plus the line-number
/// ruler. The container only ever swaps the whole
/// document (and repaints the chrome); all document building lives in
/// `DiffBrowserView.Coordinator`.
final class CodePaneContainer: NSView {
    let scrollView = NSScrollView()
    let codeView = ReadOnlyCodeTextView(frame: .zero, textContainer: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    /// Small in-app spinner shown while the document builder highlights
    /// off-main. An AppKit `NSProgressIndicator` (never a SwiftUI spinner) so
    /// nothing invalidates the shell graph per frame — the same rule the
    /// transcript's reload overlay follows. `PassthroughIndicator` never eats a
    /// scroll/click over its small frame.
    private let busyIndicator = PassthroughIndicator()

    /// Called when the view's effective appearance changes (an app light/dark
    /// toggle or a system appearance change), so the owner can rebuild the
    /// document with the matching syntax theme.
    var onAppearanceChange: (() -> Void)?
    /// Called on every scroll, so the owner can update the sidebar's
    /// current-file highlight (the scroll spy).
    var onScroll: (() -> Void)?
    /// Called when a link in the buffer is clicked (an expand control).
    var onLinkClick: ((URL) -> Void)?
    /// The sections of the current document, in document order.
    private(set) var sections: [CodeSection] = []

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
        // Hard-clip everything inside the pane to its own bounds (a layer-backed
        // NSView does not clip subviews): AppKit's ruler helper is sized to the
        // document and would otherwise paint its separator over the chrome.
        clipsToBounds = true

        // Install the edit-map scroller BEFORE the scroll view creates its own
        // (assigning a subclass forces the legacy always-visible style).
        scrollView.verticalScroller = CodePaneEditMarkerScroller()
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
        // No wrapping: the viewer shows real diff lines, which keeps the
        // ruler's uniform line-height math exact.
        codeView.textContainer?.widthTracksTextView = false
        codeView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        codeView.isVerticallyResizable = true
        codeView.isHorizontallyResizable = true
        codeView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        codeView.autoresizingMask = []
        // A large changeset's document must stay lazily laid out: with
        // non-contiguous layout `sizeToFit` no longer forces a full-document
        // pass (which cost seconds at 100k+ lines) and TextKit lays out the
        // visible band on demand, the same lazy model the ruler already uses.
        codeView.layoutManager?.allowsNonContiguousLayout = true
        codeView.onLinkClick = { [weak self] url in self?.onLinkClick?(url) }
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

        busyIndicator.style = .spinning
        busyIndicator.controlSize = .small
        busyIndicator.isDisplayedWhenStopped = false
        busyIndicator.isHidden = true
        busyIndicator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(statusLabel)
        addSubview(busyIndicator)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            busyIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            busyIndicator.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])

        // The scroll spy rides the clip view's bounds changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
    }

    @objc private func clipViewDidScroll(_ note: Notification) {
        onScroll?()
    }

    /// Swaps in a freshly built document. `restoreClientY` re-anchors the
    /// viewport after a rebuild (expansion inserted lines), keeping the same
    /// document position under the top of the view.
    func displayDocument(
        path: String,
        text: NSAttributedString,
        lineNumbers: [Int?]? = nil,
        sections: [CodeSection] = [],
        markers: PaneMarkers = .none,
        markerFractions: [CGFloat]? = nil,
        headerLines: [Int] = [],
        contentHeight: CGFloat? = nil,
        restoreCharacterIndex: Int? = nil,
        lineStartOffsets: [Int]? = nil
    ) {
        statusLabel.isHidden = true
        codeView.isHidden = false
        codeView.clearReveal()
        (scrollView.verticalRulerView as? CodeLineRulerView)?.anchorLine = nil
        self.sections = sections

        codeView.load(path: path, text: text, lineNumbers: lineNumbers, lineStartOffsets: lineStartOffsets, contentHeight: contentHeight)
        // The document is every file's diff in one buffer: each file's diff
        // lines map to that file's canonical absolute path, so a copy inside
        // the diff tags a reference to the FILE (never to "the diff").
        codeView.setSectionPaths(sectionPaths(sections))
        applyMarkers(markers, fractions: markerFractions, in: text.string)
        codeView.setHeaderLines(headerLines)

        if let restoreCharacterIndex, restoreCharacterIndex < (codeView.string as NSString).length {
            scrollCharacterToTop(restoreCharacterIndex)
        } else {
            scrollToTop()
        }
    }

    /// Shows/hides the in-app spinner for an off-main document build. Unlike
    /// `showPlaceholder` this never clears the displayed document, so a rebuild
    /// (expansion, appearance, refresh) keeps the reader's content on screen
    /// until the new document is ready.
    func setBusy(_ busy: Bool) {
        if busy {
            busyIndicator.startAnimation(nil)
        } else {
            busyIndicator.stopAnimation(nil)
        }
        busyIndicator.isHidden = !busy
    }

    /// Centered status text (loading / no changed files / unreadable) over a
    /// blank viewer.
    func showPlaceholder(_ message: String) {
        codeView.clearReveal()
        (scrollView.verticalRulerView as? CodeLineRulerView)?.anchorLine = nil
        (scrollView.verticalScroller as? CodePaneEditMarkerScroller)?.clearMarkers()
        codeView.setHeaderLines([])
        codeView.setSectionPaths([])
        sections = []
        codeView.load(path: "", text: NSAttributedString(string: ""))
        statusLabel.stringValue = message
        statusLabel.isHidden = false
    }

    // MARK: - Scrolling

    private var clipView: NSClipView { scrollView.contentView }

    /// Scrolls a character index's line to the top of the viewport.
    func scrollCharacterToTop(_ index: Int) {
        guard let layoutManager = codeView.layoutManager,
              layoutManager.numberOfGlyphs > 0 else { return }
        let clamped = min(max(index, 0), max((codeView.string as NSString).length - 1, 0))
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: clamped)
        let fragment = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let topInCodeView = fragment.minY + codeView.textContainerInset.height
        let clipY = clipView.convert(NSPoint(x: 0, y: topInCodeView), from: codeView).y
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: max(0, clipY)))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Scrolls a match (a display-offset range) to the vertical center of the
    /// viewport.
    func revealSearchMatch(_ range: NSRange) {
        guard let layoutManager = codeView.layoutManager,
              let textContainer = codeView.textContainer,
              range.location >= 0, range.length > 0,
              NSMaxRange(range) <= (codeView.string as NSString).length else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager.ensureLayout(forGlyphRange: glyphRange)
        let box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let matchCenterInClip = clipView.convert(
            NSPoint(x: 0, y: box.midY + codeView.textContainerInset.height),
            from: codeView
        ).y
        let target = max(0, matchCenterInClip - clipView.bounds.height / 2)
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: target))
        scrollView.reflectScrolledClipView(clipView)
    }

    func scrollToTop() {
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: 0))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Scrolls to the end of the document (the last edit-cycle fallback).
    func scrollToBottom() {
        let maxY = max(0, codeView.frame.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: maxY))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// The 1-based display line at the top of the viewport — the anchor the
    /// Cmd+Up / Cmd+Down edit cycle moves strictly away from.
    var topVisibleDisplayLine: Int {
        let length = (codeView.string as NSString).length
        guard length > 0 else { return 1 }
        return codeView.lineNumber(forIndex: min(topVisibleCharacterIndex, length - 1))
    }

    /// Scrolls a display line's top edge to the top of the viewport (the
    /// landing of an edit-cycle jump).
    func scrollDisplayLineToTop(_ line: Int) {
        guard line >= 1, line - 1 < codeView.lineStartOffsets.count else { return }
        scrollCharacterToTop(codeView.lineStartOffsets[line - 1])
    }

    /// The character index at the top of the viewport.
    var topVisibleCharacterIndex: Int {
        guard let layoutManager = codeView.layoutManager,
              let textContainer = codeView.textContainer,
              layoutManager.numberOfGlyphs > 0 else { return 0 }
        let topInCodeView = clipView.convert(NSPoint(x: 0, y: clipView.bounds.minY), to: codeView)
        let point = NSPoint(
            x: codeView.textContainerInset.width,
            y: max(0, topInCodeView.y - codeView.textContainerInset.height)
        )
        let glyphIndex = min(max(layoutManager.glyphIndex(for: point, in: textContainer), 0), layoutManager.numberOfGlyphs - 1)
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }

    // MARK: - Visible range (lazy highlighting)

    /// The 1-based display lines currently inside the viewport, or nil when
    /// there is no text. Used to highlight ONLY what is on screen; the bounds
    /// force layout of the visible band alone (never the whole document).
    var visibleDisplayLineRange: ClosedRange<Int>? {
        guard let layoutManager = codeView.layoutManager,
              let textContainer = codeView.textContainer,
              layoutManager.numberOfGlyphs > 0 else { return nil }
        let length = (codeView.string as NSString).length
        guard length > 0 else { return nil }
        let visibleInCodeView = clipView.convert(clipView.bounds, to: codeView)
        let inset = codeView.textContainerInset
        let band = NSRect(
            x: 0,
            y: visibleInCodeView.minY - inset.height,
            width: max(codeView.bounds.width, 1),
            height: max(visibleInCodeView.height, 1)
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: band, in: textContainer)
        guard glyphRange.length > 0 else { return nil }
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let first = codeView.lineNumber(forIndex: min(charRange.location, length - 1))
        let last = codeView.lineNumber(forIndex: min(NSMaxRange(charRange), length - 1))
        return first...max(first, last)
    }

    /// The character range of a run of display lines, excluding the trailing
    /// newline. nil when the range is out of bounds.
    func characterRange(forDisplayLines range: ClosedRange<Int>) -> NSRange? {
        let offsets = codeView.lineStartOffsets
        let length = (codeView.string as NSString).length
        guard range.lowerBound >= 1, range.lowerBound <= offsets.count else { return nil }
        let start = offsets[range.lowerBound - 1]
        let end: Int
        if range.upperBound < offsets.count {
            end = offsets[range.upperBound] - 1
        } else {
            end = length
        }
        guard end >= start, end <= length else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Applies syntax foreground colors to the visible range. Only
    /// `foregroundColor` is copied, so the uniform monospaced font (and the
    /// added/removed line backgrounds) stay exactly as built.
    func applyHighlights(_ chunks: [HighlightedChunk]) {
        guard let storage = codeView.textStorage else { return }
        storage.beginEditing()
        defer { storage.endEditing() }
        for chunk in chunks {
            let length = chunk.attributed.length
            chunk.attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: length), options: []) { value, runRange, _ in
                guard let color = value as? NSColor else { return }
                let docRange = NSRange(location: chunk.range.location + runRange.location, length: runRange.length)
                guard NSMaxRange(docRange) <= storage.length else { return }
                storage.addAttribute(.foregroundColor, value: color, range: docRange)
            }
        }
    }

    // MARK: - Sections

    /// One range per code-line run, so a reference-tagged copy is clamped to
    /// the run under the selection and the expand controls between hunks fall
    /// back to a plain copy.
    private func sectionPaths(_ sections: [CodeSection]) -> [(range: NSRange, absolutePath: String)] {
        var result: [(range: NSRange, absolutePath: String)] = []
        for section in sections {
            for lines in section.codeLineRanges {
                guard let range = characterRange(forDisplayLines: lines) else { continue }
                result.append((range, section.absolutePath))
            }
        }
        return result
    }

    /// The path owning the top of the viewport (the scroll spy).
    var topSectionPath: String? {
        guard !sections.isEmpty else { return nil }
        let index = topVisibleCharacterIndex
        let displayLine = codeView.lineNumber(forIndex: min(index, max((codeView.string as NSString).length - 1, 0)))
        return sections.first { $0.lineRange.contains(displayLine) }?.path
            ?? sections.last?.path
    }

    /// The character index of a path's section start (for a reveal jump), or
    /// nil when the path is not in the document. When `line` is given (the
    /// 1-based real file line an agent's `pi-file` link named), the nearest
    /// display line showing that real line wins — falling back to the section
    /// start when the target is outside the currently shown diff window.
    func characterIndex(forPath path: String, line: Int? = nil) -> Int? {
        guard let section = sections.first(where: { $0.path == path }) else { return nil }
        var target = section.lineRange.lowerBound
        if let line {
            // The section's display lines carry real file line numbers (nil for
            // a removed line), monotonically non-decreasing, so walk to the
            // last display line at or before the target and stop at the first
            // that overshoots. Never consults `displayLine(forRealLine:)`: that
            // searches the WHOLE multi-file map, where every file's real line
            // numbers restart — it would land on an earlier file with the same
            // line number.
            for display in section.lineRange {
                guard let real = codeView.realLineNumber(forDisplayLine: display) else { continue }
                if real <= line { target = display } else { break }
            }
        }
        guard target >= 1, target - 1 < codeView.lineStartOffsets.count else { return nil }
        return codeView.lineStartOffsets[target - 1]
    }

    // MARK: - Search

    func applySearchHighlight(ranges: [NSRange], currentIndex: Int) {
        codeView.applySearchHighlight(ranges: ranges, currentIndex: currentIndex)
    }

    func clearSearchHighlight() {
        codeView.clearSearchHighlight()
    }

    // MARK: - Scrollbar edit map

    /// Maps the document's added/removed display lines to colored ticks on the
    /// vertical scroller, so the bar shows where the whole changeset's edits
    /// sit. `fractions` (from the builder) gives each line's real vertical
    /// center as a document fraction — the document mixes font sizes, so a
    /// line-count fraction would drift from the glyph it marks. Without it
    /// (tests), a uniform line-count fraction is the fallback.
    private func applyMarkers(_ markers: PaneMarkers, fractions: [CGFloat]?, in text: String) {
        guard let scroller = scrollView.verticalScroller as? CodePaneEditMarkerScroller else { return }
        switch markers {
        case .none:
            scroller.clearMarkers()
        case .lines(let added, let removed):
            scroller.wholeTrackColor = nil
            let offsets = codeView.lineStartOffsets
            let lineCount = text.isEmpty ? 0 : (text.hasSuffix("\n") ? offsets.count - 1 : offsets.count)
            guard lineCount > 0 else {
                scroller.markers = []
                return
            }
            func marker(_ line: Int, _ color: NSColor) -> CodePaneEditMarkerScroller.Marker? {
                guard line >= 1, line <= lineCount else { return nil }
                let fraction: CGFloat
                if let fractions, line - 1 < fractions.count {
                    fraction = fractions[line - 1]
                } else {
                    fraction = (CGFloat(line) - 0.5) / CGFloat(lineCount)
                }
                return CodePaneEditMarkerScroller.Marker(fraction: fraction, color: color)
            }
            // `added`/`removed` are in ascending line order, so this is a merge
            // of two sorted runs (no O(n log n) sort of a huge changeset).
            var result: [CodePaneEditMarkerScroller.Marker] = []
            result.reserveCapacity(added.count + removed.count)
            var i = 0, j = 0
            while i < added.count || j < removed.count {
                let takeAdded: Bool
                if j >= removed.count { takeAdded = true }
                else if i >= added.count { takeAdded = false }
                else { takeAdded = added[i] <= removed[j] }
                let line = takeAdded ? added[i] : removed[j]
                if takeAdded { i += 1 } else { j += 1 }
                if let m = marker(line, takeAdded ? .systemGreen : .systemRed) { result.append(m) }
            }
            scroller.markers = result
        }
    }
}

/// A spinner that never consumes a mouse event: it floats over the code view,
/// and a scroll or click landing on its small frame must reach the text view
/// underneath.
private final class PassthroughIndicator: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

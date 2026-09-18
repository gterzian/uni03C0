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

/// Edit positions for the diff viewer's SCROLLBAR edit map: the display lines
/// that are additions (green ticks) and removals (red ticks) across every file
/// shown. Resolved to positions by the container, since the builder that
/// produces them stays color-free.
enum PaneMarkers: Sendable {
    case none
    /// 1-based DISPLAY line numbers of additions and removals, in the whole
    /// document.
    case lines(added: [Int], removed: [Int])
}

/// One file's slice of the diff viewer's document: where its lines live in the
/// document, and which characters belong to its diff (for reference-tagged
/// copies). `lineRange` spans the section's header and expand rows too, so the
/// scroll spy attributes a viewport parked on a header to the right file.
struct CodeSection: Sendable {
    let path: String
    let lineRange: ClosedRange<Int>
    let diffCharRange: NSRange
}

/// The diff viewer's view hierarchy: one scroll view over one buffered
/// `ReadOnlyCodeTextView` holding every shown file's diff, plus the line-number
/// ruler and the edit-map scroller. The container only ever swaps the whole
/// document (and repaints the chrome); all document building lives in
/// `DiffBrowserView.Coordinator`.
final class CodePaneContainer: NSView {
    let scrollView = NSScrollView()
    let codeView = ReadOnlyCodeTextView(frame: .zero, textContainer: nil)
    private let statusLabel = NSTextField(labelWithString: "")

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
        restoreCharacterIndex: Int? = nil
    ) {
        statusLabel.isHidden = true
        codeView.isHidden = false
        codeView.clearReveal()
        (scrollView.verticalRulerView as? CodeLineRulerView)?.anchorLine = nil
        self.sections = sections

        codeView.load(path: path, text: text, lineNumbers: lineNumbers)
        codeView.setSectionPaths(sections.map { ($0.diffCharRange, $0.path) })
        applyMarkers(markers, in: text.string)

        if let restoreCharacterIndex, restoreCharacterIndex < (codeView.string as NSString).length {
            scrollCharacterToTop(restoreCharacterIndex)
        } else {
            scrollToTop()
        }
    }

    /// Centered status text (loading / no changed files / unreadable) over a
    /// blank viewer.
    func showPlaceholder(_ message: String) {
        codeView.clearReveal()
        (scrollView.verticalRulerView as? CodeLineRulerView)?.anchorLine = nil
        (scrollView.verticalScroller as? CodePaneEditMarkerScroller)?.clearMarkers()
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

    // MARK: - Sections

    /// The path owning the top of the viewport (the scroll spy).
    var topSectionPath: String? {
        guard !sections.isEmpty else { return nil }
        let index = topVisibleCharacterIndex
        let displayLine = codeView.lineNumber(forIndex: min(index, max((codeView.string as NSString).length - 1, 0)))
        return sections.first { $0.lineRange.contains(displayLine) }?.path
            ?? sections.last?.path
    }

    /// The character index of a path's section header (for a reveal jump), or
    /// nil when the path is not in the document.
    func characterIndex(forPath path: String) -> Int? {
        guard let section = sections.first(where: { $0.path == path }) else { return nil }
        let line = section.lineRange.lowerBound
        guard line >= 1, line - 1 < codeView.lineStartOffsets.count else { return nil }
        return codeView.lineStartOffsets[line - 1]
    }

    // MARK: - Search

    func applySearchHighlight(ranges: [NSRange], currentIndex: Int) {
        codeView.applySearchHighlight(ranges: ranges, currentIndex: currentIndex)
    }

    func clearSearchHighlight() {
        codeView.clearSearchHighlight()
    }

    // MARK: - Scrollbar edit map

    private func applyMarkers(_ markers: PaneMarkers, in text: String) {
        guard let scroller = scrollView.verticalScroller as? CodePaneEditMarkerScroller else { return }
        switch markers {
        case .none:
            scroller.clearMarkers()
        case .lines(let added, let removed):
            scroller.wholeTrackColor = nil
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
}

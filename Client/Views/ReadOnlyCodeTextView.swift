import AppKit
import Core

extension NSPasteboard.PasteboardType {
    /// The custom type for frozen code references (§1.2). A copy writes TWO
    /// representations on ONE `NSPasteboardItem`: the plain snippet under
    /// `.string` (so every other app pastes just the code) and the full
    /// `CodeReference` (absolute path + lines + snippet) under this type —
    /// which the prompt composer's `paste` recognizes and renders as an exact
    /// `path:line-line` anchor plus the fenced snippet.
    static let codeReference = NSPasteboard.PasteboardType("com.gterzian.uni03c0.code-reference")
}

/// A read-only, selectable code text view — the diff viewer's real-buffer view
/// (§1.3/§2.6). The buffer is always actual file text (one file's lines, or an
/// interleaved multi-file diff), so line numbers and selections mean exactly
/// what they say, and the syntax + edit overlays are attributes layered on top
/// by the owner.
///
/// Copy is the mechanism behind the frozen reference: `copy(_:)` maps the
/// selection to 1-based lines via a per-load offset table, and writes the
/// snippet + full `CodeReference` to the pasteboard. Highlighting lives
/// OUTSIDE this view (the pane layer), so the class stays free of Highlightr
/// and can be compiled directly into the renderer test bundles.
final class ReadOnlyCodeTextView: NSTextView {
    /// The absolute path of the file whose content the buffer holds (the
    /// reference's `absolutePath`). Empty until a file is loaded. For a
    /// multi-file buffer (the diff viewer) this is the fallback when a
    /// selection falls outside every `sectionPaths` entry.
    private(set) var absolutePath = ""
    /// For a multi-file buffer (the diff viewer): the character range each
    /// file's diff lines occupy, so a copy tags the reference with the file the
    /// selection is actually in. Headers/expand rows are deliberately absent —
    /// copying them writes a plain string, not a reference.
    private var sectionPaths: [(range: NSRange, absolutePath: String)] = []
    /// Clicks on links in the buffer (the diff viewer's expand controls).
    var onLinkClick: ((URL) -> Void)?
    /// Start offset (UTF-16) of every line, ascending, built once per load.
    /// `lineStartOffsets[k]` is where line k+1 begins; the line's end is the
    /// next entry (or the text length for the last line). The final entry is
    /// the text length exactly when the text ends with a newline, which makes
    /// the trailing "phantom" line non-empty in the table but unreachable via
    /// `lineNumber(forIndex:)` (guarded by `index < length`).
    private(set) var lineStartOffsets: [Int] = [0]
    /// For an interleaved diff buffer, the REAL current-file line number of
    /// each 1-based DISPLAY line (`nil` for a removed line, which is old-side
    /// content). nil → the buffer is the real file and display line == real
    /// line. The gutter, the reference jump, and copy all consult this so
    /// "line N" keeps meaning line N of the real file even though the buffer
    /// carries the removed lines.
    private(set) var lineNumberMap: [Int?]?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        if let container {
            super.init(frame: frameRect, textContainer: container)
        } else {
            // Created without a container (standalone use: tests, or the pane
            // before it reconfigures): build the default text system chain
            // (storage → layout manager → container) so the view is fully
            // functional off the bat — an NSTextView with a nil container has
            // no text storage at all.
            let storage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            storage.addLayoutManager(layoutManager)
            let container = NSTextContainer(size: NSSize(width: max(frameRect.width, 320), height: frameRect.height))
            layoutManager.addTextContainer(container)
            super.init(frame: frameRect, textContainer: container)
        }
        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        // Belt-and-suspenders on top of `isEditable = false`: the delegate
        // (this view) refuses every text change. Explicit, in the same spirit
        // as the sandbox policy's `with message` deny rules — this path is
        // deliberately closed off, not guarded by a single flag.
        delegate = self
    }

    // MARK: - Reference reveal (flash + anchor)

    /// Persistent accent bar along a reference jump's line range (drawn under
    /// the glyphs in `drawBackground`, so it scrolls with the text and stays
    /// after the flash fades). Cleared by the next `displayContent`/placeholder.
    private(set) var revealAnchorRect: NSRect? {
        didSet { needsDisplay = true }
    }
    /// The fading flash rectangle of a reference jump; nil once faded out.
    private(set) var revealFlashRect: NSRect? {
        didSet { needsDisplay = true }
    }
    /// Current flash opacity (driven by `revealFlashTimer`).
    private(set) var revealFlashAlpha: CGFloat = 0
    private var revealFlashTimer: Timer?
    private var revealFlashStart: Date?
    /// The highlight color of a reference jump (amber, so it reads on both
    /// light and dark syntax themes).
    private static let revealColor = NSColor.systemYellow

    /// Starts the flash animation over `rect` (text-view coordinates) and
    /// keeps the anchor bar at the range's left edge.
    func startReveal(flashRect: NSRect, anchorRect: NSRect) {
        stopRevealFlash()
        revealFlashRect = flashRect
        revealAnchorRect = anchorRect
        revealFlashAlpha = 0.55
        revealFlashStart = Date()
        needsDisplay = true
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickRevealFlash()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealFlashTimer = timer
    }

    /// Clears both the flash and the anchor (a new load, a placeholder).
    func clearReveal() {
        stopRevealFlash()
        if revealFlashRect != nil {
            revealFlashRect = nil
        }
        if revealAnchorRect != nil {
            revealAnchorRect = nil
        }
    }

    private func stopRevealFlash() {
        revealFlashTimer?.invalidate()
        revealFlashTimer = nil
        if revealFlashRect != nil {
            revealFlashRect = nil
        }
        revealFlashAlpha = 0
        revealFlashStart = nil
    }

    private func tickRevealFlash() {
        // ~0.85 s linear fade from 0.55 → 0, then the flash is gone for good
        // (the anchor bar stays).
        let duration: TimeInterval = 0.85
        let elapsed = revealFlashStart.map { Date().timeIntervalSince($0) } ?? duration
        if elapsed >= duration {
            stopRevealFlash()
            return
        }
        revealFlashAlpha = max(0, 0.55 * (1 - elapsed / duration))
        needsDisplay = true
    }

    /// Draws the reveal chrome UNDER the glyphs: NSTextView paints the
    /// background first and the text after, so a background fill reads as a
    /// text highlight rather than a translucent wash over the characters. The
    /// anchor is a thin accent bar along the range's left edge; the flash is
    /// the fading fill (see `startReveal`).
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let anchorRect = revealAnchorRect {
            Self.revealColor.withAlphaComponent(0.6).setFill()
            NSRect(x: 0, y: anchorRect.minY, width: 3, height: max(anchorRect.height, 1)).fill()
        }
        if let flashRect = revealFlashRect, revealFlashAlpha > 0.005 {
            Self.revealColor.withAlphaComponent(revealFlashAlpha).setFill()
            flashRect.fill()
        }
    }

    // MARK: - Find-in-buffer highlight

    /// The ranges currently carrying a search-match backdrop, in document
    /// order (a test hook and the overlay ledger).
    private(set) var searchHighlightRanges: [NSRange] = []
    /// Index into `searchHighlightRanges` painted with the stronger "current"
    /// shade, -1 when none.
    private(set) var currentSearchHighlightIndex = -1
    /// The backgrounds that sat under each painted match, captured before the
    /// search shade replaced them so `clearSearchHighlight` can restore them.
    /// Without this ledger, clearing would strip the edit overlay's red/green
    /// line fills wherever a match overlapped one.
    private var searchOverlay: [(range: NSRange, background: NSColor?)] = []

    /// Paints find-in-buffer highlights over `ranges`: every match in the pale
    /// shade, `currentIndex` in the stronger one. Any previous search paint is
    /// restored first, so this is idempotent. Ranges are display-offset ranges
    /// into the current buffer (an interleaved diff's removed lines included).
    func applySearchHighlight(ranges: [NSRange], currentIndex: Int) {
        clearSearchHighlight()
        guard let storage = textStorage else { return }
        let length = storage.length
        for (index, range) in ranges.enumerated() {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            guard clamped.length > 0 else { continue }
            captureSearchOverlay(in: storage, range: clamped)
            let color = index == currentIndex ? SearchMatchHighlight.current : SearchMatchHighlight.match
            storage.addAttribute(.backgroundColor, value: color, range: clamped)
        }
        searchHighlightRanges = ranges
        currentSearchHighlightIndex = currentIndex
    }

    /// Removes the search highlight and restores whatever background the edit
    /// overlay had underneath it.
    func clearSearchHighlight() {
        guard let storage = textStorage else { return }
        let length = storage.length
        for entry in searchOverlay where NSMaxRange(entry.range) <= length {
            if let background = entry.background {
                storage.addAttribute(.backgroundColor, value: background, range: entry.range)
            } else {
                storage.removeAttribute(.backgroundColor, range: entry.range)
            }
        }
        searchOverlay = []
        searchHighlightRanges = []
        currentSearchHighlightIndex = -1
    }

    /// Records the background value under `range` (disjoint per match, so the
    /// entries never overlap).
    private func captureSearchOverlay(in storage: NSTextStorage, range: NSRange) {
        storage.enumerateAttribute(.backgroundColor, in: range) { value, subrange, _ in
            searchOverlay.append((subrange, value as? NSColor))
        }
    }

    /// All non-overlapping occurrences of `query` in `text`, case-insensitive
    /// by default. The pure half of find-in-buffer — the pane paints and
    /// scrolls the ranges this returns.
    nonisolated static func searchRanges(of query: String, in text: String, caseSensitive: Bool) -> [NSRange] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return [] }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let ns = text as NSString
        var ranges: [NSRange] = []
        var location = 0
        while location < ns.length {
            let search = NSRange(location: location, length: ns.length - location)
            let found = ns.range(of: needle, options: options, range: search)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            location = found.location + max(found.length, 1)
        }
        return ranges
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Loads a file's content (syntax + edit attributes already applied by the
    /// pane) and rebuilds the line-offset table. `lineNumbers` is the real-line
    /// map for an interleaved diff (nil for a plain, non-diff buffer).
    func load(path: String, text: NSAttributedString, lineNumbers: [Int?]? = nil) {
        absolutePath = path
        lineNumberMap = lineNumbers
        sectionPaths = []
        // The whole buffer is being replaced: the previous search paint's
        // ledger points into the OLD storage and must not be replayed onto the
        // new one (the caller re-applies the search after a load).
        searchOverlay = []
        searchHighlightRanges = []
        currentSearchHighlightIndex = -1
        textStorage?.setAttributedString(text)
        rebuildLineOffsets()
        sizeToFit()
        // New file: show the top.
        scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func rebuildLineOffsets() {
        let ns = string as NSString
        let length = ns.length
        var offsets: [Int] = [0]
        var search = 0
        while search < length {
            let found = ns.range(of: "\n", options: [], range: NSRange(location: search, length: length - search))
            guard found.location != NSNotFound else { break }
            offsets.append(found.location + 1)
            search = found.location + 1
        }
        lineStartOffsets = offsets
    }

    /// Registers the file each character range belongs to (a multi-file diff
    /// buffer). Ranges are the files' DIFF LINES only, so copying a header or
    /// an expand row falls back to a plain copy rather than a bogus reference.
    func setSectionPaths(_ paths: [(range: NSRange, absolutePath: String)]) {
        sectionPaths = paths
    }

    /// The absolute path owning a character index, falling back to
    /// `absolutePath` for a single-file buffer.
    private func path(at index: Int) -> String {
        for entry in sectionPaths where NSLocationInRange(index, entry.range) {
            return entry.absolutePath
        }
        return absolutePath
    }

    /// The 1-based line containing character `index` (0 ≤ index < length).
    /// Internal so the diff viewer's container can resolve the scroll spy's
    /// top-of-viewport line to the section that owns it — one source of truth
    /// for "which line is this" across the code views.
    func lineNumber(forIndex index: Int) -> Int {
        let offsets = lineStartOffsets
        var low = 0
        var high = offsets.count - 1
        var answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if offsets[mid] <= index {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer + 1
    }

    /// The REAL current-file line number of a 1-based DISPLAY line. nil = a
    /// removed line (old-side content with no current-file position). Without
    /// an interleaved-diff map, the display line IS the real line.
    func realLineNumber(forDisplayLine displayLine: Int) -> Int? {
        guard let lineNumberMap else { return displayLine >= 1 ? displayLine : nil }
        guard displayLine >= 1, displayLine <= lineNumberMap.count else { return nil }
        return lineNumberMap[displayLine - 1]
    }

    /// The 1-based DISPLAY line showing real current-file line `real`, or the
    /// nearest preceding real line when `real` itself was removed (a reference
    /// to a removed line anchors at the context around it).
    func displayLine(forRealLine real: Int) -> Int? {
        guard real >= 1 else { return nil }
        guard let lineNumberMap else { return real }
        var lastReal: Int?
        for (index, value) in lineNumberMap.enumerated() {
            guard let value else { continue }
            if value == real { return index + 1 }
            if value > real { return lastReal ?? (index + 1) }
            lastReal = index + 1
        }
        return lastReal
    }

    /// The REAL current-file line number of a character index (the copy
    /// reference's line). A character on a removed line maps to the nearest
    /// real line before it, so a selection spanning a removal still produces a
    /// valid in-file reference.
    func realLineNumber(forIndex index: Int) -> Int {
        let display = lineNumber(forIndex: index)
        var candidate = display
        while candidate >= 1 {
            if let real = realLineNumber(forDisplayLine: candidate) { return real }
            candidate -= 1
        }
        return 1
    }

    /// The selected text with any interleaved removed lines dropped, so a
    /// copy-tagged reference quotes text that is actually in the current file.
    /// Real lines keep their own newlines, so the surviving lines join
    /// naturally.
    private func realSnippet(for selection: NSRange) -> String {
        let ns = string as NSString
        let end = selection.location + selection.length
        var location = selection.location
        var snippet = ""
        while location < end {
            let display = lineNumber(forIndex: location)
            let lineStart = lineStartOffsets[display - 1]
            let nextStart = display < lineStartOffsets.count ? lineStartOffsets[display] : ns.length
            let segmentEnd = min(nextStart, end)
            let segmentStart = max(lineStart, selection.location)
            if realLineNumber(forDisplayLine: display) != nil, segmentEnd > segmentStart {
                snippet += ns.substring(with: NSRange(location: segmentStart, length: segmentEnd - segmentStart))
            }
            location = segmentEnd
        }
        return snippet
    }

    // MARK: - Copy → frozen reference

    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        // Nothing selected (just a caret), or no file loaded: fall back to
        // normal copy behavior instead of writing a zero-width nonsense
        // reference.
        guard selection.length > 0,
              Range(selection, in: string) != nil,
              !absolutePath.isEmpty else {
            super.copy(sender)
            return
        }
        // endLine is derived from the LAST selected character, so a selection
        // that extends through a trailing newline does not count the following
        // (empty) line as included. The lines are REAL current-file lines even
        // when the buffer is an interleaved diff (removed lines map to the
        // nearest real line around them), and the snippet drops the removed
        // lines so the frozen reference always quotes text that is in the file.
        let startLine = realLineNumber(forIndex: selection.location)
        let endLine = realLineNumber(forIndex: selection.location + selection.length - 1)
        let snippet = realSnippet(for: selection)
        let reference = CodeReference(
            absolutePath: path(at: selection.location),
            startLine: startLine,
            endLine: endLine,
            snippet: snippet
        )
        writeReference(reference)
    }

    /// Writes the reference in two representations: other apps see the plain
    /// snippet (written first, so a first-item-only reader finds it), our
    /// composer reads the full `.codeReference` payload via `data(forType:)`
    /// (which searches every item). Typed setters, exactly the pattern
    /// `CodeCopyButton` already proves — `writeObjects([item])` produced no
    /// pasteboard change in the renderer test harness, so the item API is
    /// avoided here.
    private func writeReference(_ reference: CodeReference) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(reference.snippet, forType: .string)
        guard let data = try? JSONEncoder().encode(reference) else {
            // Encoding cannot realistically fail for this struct, but never
            // drop the snippet over it.
            return
        }
        pasteboard.setData(data, forType: .codeReference)
    }
}

// MARK: - Editing closed off

extension ReadOnlyCodeTextView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        false
    }

    /// Forwards a link click (the diff viewer's expand controls) to
    /// `onLinkClick`. Other schemes fall through to AppKit.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let onLinkClick else { return false }
        if let url = link as? URL {
            onLinkClick(url)
            return true
        }
        if let string = link as? String, let url = URL(string: string) {
            onLinkClick(url)
            return true
        }
        return false
    }
}

// MARK: - Line-number ruler

/// The content pane's line-number gutter: a custom `NSRulerView` (the
/// mechanism source editors use) drawing numbers read from the code view's
/// per-load offset table. Purely cosmetic — the copy/selection machinery in
/// `ReadOnlyCodeTextView` needs no visible gutter at all.
///
/// Two load-bearing properties keep the numbers glued to the right lines:
///
/// - **It redraws when the text scrolls or the buffer changes.** A ruler is a
///   separate view sitting next to the clip view; scrolling the clip does NOT
///   invalidate it (a view only redraws when AppKit asks, and nothing asks the
///   ruler), so without observers the numbers go stale the moment the document
///   moves — they stay attached to the OLD viewport's lines, half off-screen or
///   missing entirely, until some unrelated event (a resize, an expose, a
///   reload) happens to repaint the ruler, which reads as numbers that appear
///   or disappear on scroll. The ruler therefore observes the clip view's
///   bounds changes (`NSView.boundsDidChangeNotification` — the same signal the
///   transcript's coordinator uses to detect scrolling) and the text storage's
///   edits (a file load swaps the whole buffer), and marks itself dirty on
///   either.
///
/// - **Every number's position comes from the layout manager, never from
///   document-line arithmetic.** The visible band is derived by converting the
///   ruler's own bounds into the text view (through AppKit's view conversion,
///   so it is exact whatever the scroll origin or the code view's frame
///   offset), and each label is centered on its line fragment's rect — the
///   actual glyph rectangle the text view renders, queried via
///   `enumerateLineFragments`. Uniform "line index × pitch" math breaks the
///   moment anything shifts the document (a text-container inset, a scroll-
///   view tiling offset, a font change); fragment rects cannot.
final class CodeLineRulerView: NSRulerView {
    weak var codeView: ReadOnlyCodeTextView?

    /// The first line of the current reference jump — drawn as a persistent
    /// marker in the gutter (the anchor that stays after the flash fades), so
    /// the user can still find where the referenced range started. Cleared
    /// when a different file loads without a reference.
    var anchorLine: Int? {
        didSet {
            guard anchorLine != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Flipped so drawing coordinates run top-down like the text view's
    /// layout (line N sits below line N−1).
    override var isFlipped: Bool { true }

    /// How many times the gutter has drawn. Test hook for the RenderingTests
    /// scroll-redraw regression: `needsDisplay` cannot be READ back in the
    /// offscreen harness (the window consumes dirty flags on run-loop turns),
    /// so the tests pin "the ruler redraws when the document scrolls" by
    /// asserting this advances after a scroll — which it only does if the
    /// observers in `init` marked the ruler dirty and the display pass ran.
    /// Main-thread only, like drawing itself.
    private(set) var renderedFrameCount = 0

    /// Registers the two redraw sources (`init`-only, removed by name in
    /// `deinit`): the clip view's bounds changes (every scroll) and the code
    /// view's text storage edits (every buffer swap).
    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 52
        clientView = scrollView.contentView
        // Clip the ruler's own subviews (AppKit's `_NSRulerContentView` is
        // sized to the DOCUMENT and can be taller than the ruler) to the
        // ruler's bounds, so nothing the ruler machinery draws can escape the
        // gutter.
        clipsToBounds = true

        // Redraw on scroll: see the class doc — the ruler is a sibling of the
        // clip view, and AppKit does not invalidate it when the clip scrolls.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gutterSourceChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        // Redraw when a load replaces the buffer (numbers + anchor must track
        // the new text). `setAttributedString` on the storage posts this; the
        // clip-bounds path cannot cover it (a new load does not scroll).
        if let storage = (scrollView.documentView as? ReadOnlyCodeTextView)?.textStorage {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(gutterSourceChanged(_:)),
                name: NSTextStorage.didProcessEditingNotification,
                object: storage
            )
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: nil)
    }

    @objc private func gutterSourceChanged(_ notification: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        renderedFrameCount += 1
        guard let codeView,
              let layoutManager = codeView.layoutManager,
              let textContainer = codeView.textContainer else { return }
        let ns = codeView.string as NSString
        guard ns.length > 0 else { return }
        let inset = codeView.textContainerInset

        // The band of text currently under the ruler: the ruler's own vertical
        // extent mapped into the code view's coordinates (through AppKit's
        // conversion — never doc-coordinate arithmetic — so it is exact
        // whatever the scroll origin or the code view's frame offset relative
        // to the clip), then shifted into the text container's coordinate
        // system (glyph/fragment rects are container coords; the container
        // sits inside the text view at the inset). Only the VERTICAL extent is
        // meaningful here: the ruler is a vertical gutter, and the clip view's
        // horizontal origin can sit anywhere relative to the text, so the
        // band's x is widened to cover the whole document width.
        let rulerVisibleInCodeView = codeView.convert(bounds, from: self)
        let bandInContainer = NSRect(
            x: -inset.width,
            y: rulerVisibleInCodeView.minY - inset.height,
            width: codeView.bounds.width + inset.width * 2,
            height: rulerVisibleInCodeView.height
        ).standardized
        guard bandInContainer.height > 0 else { return }

        // Lay out only what this band needs (plus slack so lines straddling
        // the viewport edges are ready), then ask for the glyphs that fall —
        // even partially — inside the band. Bounding layout, not
        // `ensureLayout(for:)`: a large file must stay lazily laid out (files
        // load whole; TextKit lays out on demand as the user scrolls), and a
        // full-document layout on every redraw would defeat that.
        layoutManager.ensureLayout(forBoundingRect: bandInContainer.insetBy(dx: 0, dy: -40), in: textContainer)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: bandInContainer, in: textContainer)
        guard glyphRange.length > 0 else { return }

        let offsets = codeView.lineStartOffsets
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let numberPadding: CGFloat = 6

        // The persistent reference-jump anchor: a soft capsule over the start
        // line's vertical span, drawn BEFORE the numbers so they stay legible
        // on top of it. Its span comes from the anchor line's own fragment
        // rect (located via the same offset table the copy machinery uses), so
        // it stays glued to the line it marks.
        if let anchorLine, anchorLine >= 1, anchorLine - 1 < offsets.count {
            let charIndex = offsets[anchorLine - 1]
            if charIndex < ns.length {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
                let anchorFragment = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                if anchorFragment.height > 0 {
                    let centerY = convert(NSPoint(x: 0, y: anchorFragment.midY + inset.height), from: codeView).y
                    // The anchor line is scrolled out of view: nothing to mark.
                    if centerY >= bounds.minY, centerY <= bounds.maxY {
                        NSColor.systemYellow.withAlphaComponent(0.4).setFill()
                        NSBezierPath(
                            roundedRect: NSRect(
                                x: 4,
                                y: centerY - anchorFragment.height * 0.55,
                                width: ruleThickness - 8,
                                height: anchorFragment.height * 1.1
                            ),
                            xRadius: 4,
                            yRadius: 4
                        ).fill()
                    }
                }
            }
        }

        // One label per visible line, centered on the line fragment's rect.
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { [weak self] fragmentRect, _, _, fragmentGlyphRange, _ in
            guard let self, fragmentGlyphRange.length > 0 else { return }
            let charIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            // The phantom empty line after a trailing newline has no characters.
            guard charIndex < ns.length else { return }
            let displayLine = codeView.lineNumber(forIndex: charIndex)
            // A wrapped line's continuation fragments are not line starts —
            // only the fragment that begins the logical line carries the
            // number (the pane disables wrapping, so this is defensive).
            guard displayLine >= 1, displayLine - 1 < offsets.count, offsets[displayLine - 1] == charIndex else { return }
            // The number is the REAL current-file line, and an interleaved
            // diff's removed lines have no current-file number — their gutter
            // stays blank (the red line background is their marker).
            guard let realLine = codeView.realLineNumber(forDisplayLine: displayLine) else { return }

            let label = "\(realLine)" as NSString
            let size = label.size(withAttributes: attributes)
            // The fragment's vertical center in the text view's coordinates,
            // converted into the ruler's (flipped) coordinates.
            let centerInCodeView = NSPoint(x: 0, y: fragmentRect.midY + inset.height)
            let centerY = convert(centerInCodeView, from: codeView).y
            // Skip fragments whose center is outside the ruler's own band: the
            // glyph range includes lines that merely graze the viewport edge,
            // whose labels would otherwise be drawn almost entirely off-view.
            guard centerY >= bounds.minY, centerY <= bounds.maxY else { return }
            let drawRect = NSRect(
                x: ruleThickness - numberPadding - size.width,
                y: centerY - size.height / 2,
                width: size.width,
                height: size.height
            )
            label.draw(in: drawRect, withAttributes: attributes)
        }
    }
}

// MARK: - Edit-marker vertical scroller

/// A vertical scroller annotated with colored ticks showing where content
/// with edits sits along the document — the content pane's edited lines and
/// the file tree's edited-file rows alike.
///
/// Each edited position gets a colored tick at the scrollbar position it
/// would occupy when scrolled to — the knob-top mapping, so a tick tells you
/// exactly how far you have to scroll to bring that edit into view at the
/// top, and as you scroll the ticks stay put while the knob travels over them
/// (the markers are doc-anchored; they update only when the content reloads
/// or the row list changes, never on scroll).
///
/// Drawn via `drawKnobSlot` per the NSScroller.h guidance — the supported
/// customization seam, with the system applying its own track/knob fade alpha
/// to whatever these parts-drawing methods paint (a plain `draw(_:)` override
/// is explicitly not supported). Assigning a scroller SUBCLASS to a scroll
/// view forces the legacy scroller style (always-visible), which is the point:
/// the edit map is only useful while the bar is shown. The knob is drawn by
/// the default `drawKnob`, on top of whatever this draws.
class EditMarkerScroller: NSScroller {
    /// One edit tick: `fraction` is the edited position's center as a fraction
    /// of the document (0 = top, 1 = bottom); `color` its marker color.
    struct Marker {
        let fraction: CGFloat
        let color: NSColor
    }

    /// Whole-buffer edit tint (a file that is entirely new/deleted): fills the
    /// whole track behind the knob. nil = per-line ticks only.
    var wholeTrackColor: NSColor? {
        didSet { needsDisplay = true }
    }

    /// The edit ticks, in ascending document order.
    var markers: [Marker] = [] {
        didSet {
            markersRevision &+= 1
            needsDisplay = true
        }
    }

    /// Bumped on every `markers` change, so the built tick paths can be cached
    /// across scroller repaints (the knob moves on every scroll, but the ticks
    /// do not).
    private var markersRevision = 0
    private struct FillsKey: Equatable {
        let revision: Int
        let minY, midX, height, knobHeight: CGFloat
    }
    private var fillsKey: FillsKey?
    private var cachedFills: [(color: NSColor, path: NSBezierPath)] = []

    /// Clears both the ticks and the whole-track tint.
    func clearMarkers() {
        if !markers.isEmpty { markers = [] }
        if wholeTrackColor != nil { wholeTrackColor = nil }
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        super.drawKnobSlot(in: slotRect, highlight: flag)
        drawEditMarkers(in: slotRect)
    }

    /// Device-RGB key for batching same-colored ticks. `NSColor` hash/equality
    /// across dynamically-constructed colors (the hue-blended row tints) is not
    /// a contract to rely on for dictionary keys, but equal components are
    /// exactly "paint these together".
    private struct ColorKey: Hashable {
        let r, g, b, a: CGFloat
        init(_ color: NSColor) {
            let rgb = color.usingColorSpace(.deviceRGB) ?? color
            r = rgb.redComponent
            g = rgb.greenComponent
            b = rgb.blueComponent
            a = rgb.alphaComponent
        }
    }

    /// Paints the edit map into the slot, UNDER the knob (the knob is drawn
    /// afterwards by the default `drawKnob`, so it covers any tick it overlaps
    /// — a tick whose edit is currently on screen disappears under the knob,
    /// exactly the \"you are here\" read). The scroller is flipped (top-down):
    /// slot y grows downward, matching the document.
    private func drawEditMarkers(in slotRect: NSRect) {
        if let wholeTrackColor {
            wholeTrackColor.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: slotRect, xRadius: slotRect.width / 2, yRadius: slotRect.width / 2).fill()
        }

        guard !markers.isEmpty else { return }
        // Map a document fraction to the slot position whose knob-top would
        // land there: the knob travels over (slotHeight - knobHeight) as the
        // viewport travels over the scrollable document. `rect(for:)` is the
        // authoritative source when available; `knobProportion` is the fallback.
        let knobHeight = rect(for: .knob).height > 0 ? rect(for: .knob).height : knobProportion * slotRect.height

        // Only the TICKS depend on `markers`; the knob moves on every scroll,
        // so the built paths are cached and re-filled until the tick set or the
        // slot geometry changes. See `buildFills` for the one-rect-per-pixel
        // coalescing that keeps a huge changeset from drawing tens of thousands
        // of subpaths on every repaint.
        let key = FillsKey(revision: markersRevision, minY: slotRect.minY, midX: slotRect.midX, height: slotRect.height, knobHeight: knobHeight)
        if fillsKey != key {
            cachedFills = buildFills(in: slotRect, knobHeight: knobHeight)
            fillsKey = key
        }
        for entry in cachedFills {
            entry.color.setFill()
            entry.path.fill()
        }
    }

    /// Builds one batched path per tick color, coalescing ticks that land on
    /// the same point row. A changed file alone can contribute one tick per
    /// edited line — tens of thousands for a large changeset — and they land
    /// on at most one per point of track, so the coalesced map is visually
    /// identical while being ~100× cheaper to rasterize.
    private func buildFills(in slotRect: NSRect, knobHeight: CGFloat) -> [(color: NSColor, path: NSBezierPath)] {
        let tickWidth: CGFloat = 4
        let tickHeight: CGFloat = 5
        let x = slotRect.midX - tickWidth / 2
        let travel = max(slotRect.height - knobHeight, 1)

        var order: [ColorKey] = []
        var colorByKey: [ColorKey: NSColor] = [:]
        var rowsByKey: [ColorKey: Set<Int>] = [:]
        var pathByKey: [ColorKey: NSBezierPath] = [:]
        for marker in markers {
            let f = min(max(marker.fraction, 0), 1)
            let y = slotRect.minY + f * travel - tickHeight / 2
            let row = Int(y.rounded())
            let key = ColorKey(marker.color)
            if colorByKey[key] == nil {
                colorByKey[key] = marker.color
                rowsByKey[key] = []
                pathByKey[key] = NSBezierPath()
                order.append(key)
            }
            if rowsByKey[key]!.insert(row).inserted {
                pathByKey[key]!.appendRoundedRect(
                    NSRect(x: x, y: CGFloat(row), width: tickWidth, height: tickHeight),
                    xRadius: tickWidth / 2,
                    yRadius: tickWidth / 2
                )
            }
        }
        return order.map { (colorByKey[$0]!, pathByKey[$0]!) }
    }
}

/// The content pane's edit map: an `EditMarkerScroller` whose ticks are one
/// per edited LINE of the open file — the added lines of a modification are
/// green ticks, and a whole-buffer new/deleted file tints the whole track via
/// `wholeTrackColor` instead. Kept as its own named subclass (not a bare
/// `EditMarkerScroller`) so the pane's install/cast sites read as the pane's
/// own type and it stays free to grow pane-specific behavior; the generic
/// marker drawing lives in the base, which the file tree's scroller uses for
/// its per-edited-file ticks.
final class CodePaneEditMarkerScroller: EditMarkerScroller {}

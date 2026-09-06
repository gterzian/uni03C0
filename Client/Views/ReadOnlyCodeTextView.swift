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

/// A read-only, selectable code text view — the file browser content pane's
/// real-buffer view (§1.3/§2.6). The buffer is always the actual text of the
/// file on disk (or, for a deletion, its last-committed content), so line
/// numbers and selections mean exactly what they say, and the syntax + edit
/// overlays are attributes layered on top by the pane.
///
/// Copy is the mechanism behind the frozen reference: `copy(_:)` maps the
/// selection to 1-based lines via a per-load offset table, and writes the
/// snippet + full `CodeReference` to the pasteboard. Highlighting lives
/// OUTSIDE this view (the pane layer), so the class stays free of Highlightr
/// and can be compiled directly into the renderer test bundles.
final class ReadOnlyCodeTextView: NSTextView {
    /// The absolute path of the file whose content the buffer holds (the
    /// reference's `absolutePath`). Empty until a file is loaded.
    private(set) var absolutePath = ""
    /// Start offset (UTF-16) of every line, ascending, built once per load.
    /// `lineStartOffsets[k]` is where line k+1 begins; the line's end is the
    /// next entry (or the text length for the last line). The final entry is
    /// the text length exactly when the text ends with a newline, which makes
    /// the trailing "phantom" line non-empty in the table but unreachable via
    /// `lineNumber(forIndex:)` (guarded by `index < length`).
    private(set) var lineStartOffsets: [Int] = [0]

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
        drawsBackground = false
        // Belt-and-suspenders on top of `isEditable = false`: the delegate
        // (this view) refuses every text change. Explicit, in the same spirit
        // as the sandbox policy's `with message` deny rules — this path is
        // deliberately closed off, not guarded by a single flag.
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Loads a file's content (syntax + edit attributes already applied by the
    /// pane) and rebuilds the line-offset table.
    func load(path: String, text: NSAttributedString) {
        absolutePath = path
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

    /// The 1-based line containing character `index` (0 ≤ index < length).
    private func lineNumber(forIndex index: Int) -> Int {
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

    // MARK: - Copy → frozen reference

    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        // Nothing selected (just a caret), or no file loaded: fall back to
        // normal copy behavior instead of writing a zero-width nonsense
        // reference.
        guard selection.length > 0,
              let range = Range(selection, in: string),
              !absolutePath.isEmpty else {
            super.copy(sender)
            return
        }
        // endLine is derived from the LAST selected character, so a selection
        // that extends through a trailing newline does not count the following
        // (empty) line as included.
        let startLine = lineNumber(forIndex: selection.location)
        let endLine = lineNumber(forIndex: selection.location + selection.length - 1)
        let snippet = String(string[range])
        let reference = CodeReference(
            absolutePath: absolutePath,
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
}

// MARK: - Line-number ruler

/// The content pane's line-number gutter: a custom `NSRulerView` (the
/// mechanism source editors use) drawing numbers read from the code view's
/// per-load offset table, scrolled in sync with the text automatically by the
/// scroll view. Purely cosmetic — the copy/selection machinery in
/// `ReadOnlyCodeTextView` needs no visible gutter at all.
final class CodeLineRulerView: NSRulerView {
    weak var codeView: ReadOnlyCodeTextView?

    /// Flipped so drawing coordinates run top-down like the text view's
    /// layout (line N sits below line N−1).
    override var isFlipped: Bool { true }

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 52
        clientView = scrollView.contentView
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let codeView,
              let scrollView = codeView.enclosingScrollView,
              let layoutManager = codeView.layoutManager,
              let textContainer = codeView.textContainer else { return }
        let ns = codeView.string as NSString
        guard ns.length > 0 else { return }

        // Every rendered line has the same height: the pane uses a single
        // monospaced font with wrapping disabled, so line fragments are
        // uniform. Measure once from the first fragment.
        layoutManager.ensureLayout(for: textContainer)
        let firstGlyph = layoutManager.glyphIndexForCharacter(at: 0)
        let lineHeight = layoutManager.lineFragmentUsedRect(forGlyphAt: firstGlyph, effectiveRange: nil).height
        guard lineHeight > 0 else { return }

        let topInset = codeView.textContainerInset.height
        let offsets = codeView.lineStartOffsets
        let lineCount = offsets.count - (offsets.last == ns.length && ns.length > 0 ? 1 : 0)
        guard lineCount > 0 else { return }

        // Visible band in the text view's (flipped, top-down) coordinates.
        let clip = scrollView.contentView
        let visible = clip.bounds
        let docHeight = codeView.bounds.height
        let startY = max(0, visible.minY - topInset)
        let endY = min(docHeight - topInset, visible.maxY - topInset)
        let firstLine = max(1, Int(floor(startY / lineHeight)) + 1)
        let lastLine = min(lineCount, max(firstLine, Int(ceil(endY / lineHeight))))

        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let numberPadding: CGFloat = 6

        for line in firstLine...lastLine {
            guard line >= 1, line <= offsets.count else { continue }
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            // The line's vertical center in the text view's coordinates,
            // converted into the ruler's (flipped) coordinates.
            let centerInCodeView = NSPoint(x: 0, y: topInset + (CGFloat(line) - 0.5) * lineHeight)
            let centerInRuler = convert(centerInCodeView, from: codeView)
            let drawRect = NSRect(
                x: ruleThickness - numberPadding - size.width,
                y: centerInRuler.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            label.draw(in: drawRect, withAttributes: attributes)
        }
    }
}

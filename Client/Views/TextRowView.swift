import AppKit
import Core

/// Single source of truth for how transcript text is styled and measured.
/// The renderer (`TextRowView`) and the height measurer both go through this,
/// so the measured row height exactly matches the rendered content — no blank
/// space at the bottom of a streaming row, no clipping.
enum TranscriptText {
    /// lineFragmentPadding 8 each side.
    static let horizontalPadding: CGFloat = 16
    /// textContainerInset 6 top + 6 bottom.
    static let verticalInset: CGFloat = 12

    /// A fenced code block within the row's full attributed string.
    struct CodeBlockInfo {
        var range: NSRange
        var code: String
    }

    /// The row's attributed string plus its fenced code blocks (for the row's
    /// card backgrounds and corner copy buttons).
    struct AttributedResult {
        var string: NSAttributedString
        var codeBlocks: [CodeBlockInfo]
    }

    static func attributedString(
        text: String,
        thinking: String?,
        role: TextRowView.Role,
        isStreaming: Bool,
        cacheHitRate: Double? = nil,
        cacheMiss: Bool = false
    ) -> NSAttributedString {
        attributedResult(text: text, thinking: thinking, role: role, isStreaming: isStreaming, cacheHitRate: cacheHitRate, cacheMiss: cacheMiss).string
    }

    static func attributedResult(
        text: String,
        thinking: String?,
        role: TextRowView.Role,
        isStreaming: Bool,
        cacheHitRate: Double? = nil,
        cacheMiss: Bool = false
    ) -> AttributedResult {
        let body = NSMutableParagraphStyle()
        body.lineSpacing = 2
        body.lineBreakMode = .byWordWrapping
        let bodyFont = NSFont.systemFont(ofSize: FontSettings.shared.bodySize)
        // Notice/error rows (stream failures, aborts): hard failures render
        // red; user-initiated aborts render secondary (weaker).
        let bodyColor: NSColor = switch role {
        case .error: .systemRed
        case .aborted: .secondaryLabelColor
        case .user, .assistant: .labelColor
        }

        let result = NSMutableAttributedString()

        if let thinking, !thinking.isEmpty {
            let thinkStyle = NSMutableParagraphStyle()
            thinkStyle.lineSpacing = 1
            thinkStyle.lineBreakMode = .byWordWrapping
            result.append(NSAttributedString(string: "💭 " + thinking, attributes: [
                .font: NSFont.systemFont(ofSize: FontSettings.shared.bodySize - 1),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: thinkStyle,
            ]))
            // Only separate thinking from text when there is actual text; while
            // thinking (empty text) the cursor sits directly after the thinking
            // so pin-to-bottom shows the reasoning stream, not blank space.
            if !text.isEmpty {
                result.append(NSAttributedString(string: "\n\n", attributes: [.paragraphStyle: body]))
            }
        }

        var markdownBody: MarkdownText.MarkdownBody?
        var bodyStart = 0
        if !text.isEmpty {
            // User messages and assistant responses render as markdown —
            // including while streaming: the parser styles whatever has arrived
            // so far (an unclosed code fence renders the tail as code until
            // the closing fence lands). Errors and aborts stay plain.
            let rendersMarkdown = (role == .user) || (role == .assistant)
            if rendersMarkdown {
                let parsed = MarkdownText.body(text: text, bodySize: FontSettings.shared.bodySize)
                markdownBody = parsed
                bodyStart = result.length
                result.append(parsed.string)
            } else {
                result.append(NSAttributedString(string: text, attributes: [
                    .font: bodyFont,
                    .foregroundColor: bodyColor,
                    .paragraphStyle: body,
                ]))
            }
        }
        if isStreaming {
            result.append(NSAttributedString(string: "▌", attributes: [
                .font: bodyFont,
                // Light base; TextRowView pulses it between light and lighter.
                .foregroundColor: NSColor.systemBlue.withAlphaComponent(0.6),
            ]))
        }
        // Cache read rate for the finished turn, below the final response.
        // Very light by default; a hit under 99% draws attention (orange), and
        // a full cache eviction anywhere in the turn is flagged "large miss".
        // Precision adapts so a 99.97% hit never rounds up to a false "100%".
        if let cacheHitRate, !isStreaming, role == .assistant {
            let percent = cacheHitRate * 100
            let color: NSColor = (cacheMiss || percent < 99)
                ? .systemOrange
                : (DisplayOptions.increaseContrast ? .secondaryLabelColor : .tertiaryLabelColor)
            var formatted = String(format: "%.2f", percent)
            var digits = 2
            while percent < 100 && formatted.hasPrefix("100") && digits < 4 {
                digits += 1
                formatted = String(format: "%.\(digits)f", percent)
            }
            // Trim trailing zeros: 99.70 → 99.7, 100.00 → 100.
            if formatted.contains(".") {
                while formatted.hasSuffix("0") { formatted.removeLast() }
                if formatted.hasSuffix(".") { formatted.removeLast() }
            }
            let suffix = cacheMiss ? " · large miss" : ""
            result.append(NSAttributedString(string: "\n⚡ cache \(formatted)%\(suffix)", attributes: [
                .font: NSFont.systemFont(ofSize: FontSettings.shared.bodySize - 2),
                .foregroundColor: color,
                .paragraphStyle: body,
            ]))
        }
        // Fenced code blocks, offset from the markdown body into the full
        // string (thinking runs precede the body).
        var codeBlocks: [CodeBlockInfo] = []
        if let markdownBody {
            codeBlocks = markdownBody.codeBlocks.map { block in
                CodeBlockInfo(
                    range: NSRange(location: bodyStart + block.range.location, length: block.range.length),
                    code: block.code
                )
            }
        }
        return AttributedResult(string: result, codeBlocks: codeBlocks)
    }

    static func measuredHeight(
        text: String,
        thinking: String?,
        role: TextRowView.Role,
        isStreaming: Bool,
        width: CGFloat,
        cacheHitRate: Double? = nil,
        cacheMiss: Bool = false
    ) -> CGFloat {
        let attributed = attributedString(text: text, thinking: thinking, role: role, isStreaming: isStreaming, cacheHitRate: cacheHitRate, cacheMiss: cacheMiss)
        guard attributed.length > 0 else { return 30 }
        let usableWidth = max(width - horizontalPadding, 60)
        let bounds = attributed.boundingRect(
            with: NSSize(width: usableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // +2px slack so the text view's layout-manager height never exceeds the
        // measured height (which would clip the last line).
        return ceil(bounds.height) + verticalInset + 2
    }
}

/// The row label VoiceOver reads before the message text — distinguishes the
/// speaker/kind without relying on color or layout.
extension TextRowView.Role {
    var accessibilityLabel: String {
        switch self {
        case .user: "User message"
        case .assistant: "Assistant message"
        case .error: "Error"
        case .aborted: "Aborted message"
        }
    }
}

/// A read-only, selectable multi-line text cell for user/assistant messages.
/// Backed by an `NSTextView` (selectable text, correct wrapping); the table
/// supplies the row height via `TranscriptText.measuredHeight`, and `layout()`
/// sizes the text view to match so content is never clipped.
final class TextRowView: NSView, NSTextViewDelegate {
    enum Role {
        case user
        case assistant
        /// A stream-failure row (network errors, aborts, truncation) — styled
        /// red via `TranscriptText`.
        case error
        /// An abort notice ("Operation aborted") — user-initiated, styled
        /// weaker than an error (secondary color, not red).
        case aborted
    }

    /// Light-blue highlight behind user messages (the user's own words stand
    /// out from the agent's replies). Dynamic: a deep blue in dark mode so
    /// white label text stays readable, pale blue in light mode. With Increase
    /// Contrast enabled the blue is strengthened in both modes. Resolved per
    /// draw, so a mid-session toggle applies without reconfiguring rows.
    fileprivate static let userHighlight = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if DisplayOptions.increaseContrast {
            return dark
                ? NSColor(calibratedRed: 0.21, green: 0.30, blue: 0.50, alpha: 1.0)
                : NSColor(calibratedRed: 0.66, green: 0.79, blue: 1.0, alpha: 1.0)
        }
        return dark
            ? NSColor(calibratedRed: 0.16, green: 0.21, blue: 0.35, alpha: 1.0)
            : NSColor(calibratedRed: 0.87, green: 0.93, blue: 1.0, alpha: 1.0)
    }

    private let textView = NSTextView()
    /// Full-bleed light-blue backdrop for user rows. Drawn as a separate
    /// view (not `textView.backgroundColor`) so code cards can layer above it
    /// and below the text — and to avoid toggling `drawsBackground` per
    /// configure, which forced an eager text re-layout.
    private let highlightView = UserHighlightView()
    /// The fenced code blocks in the current string (full-string ranges).
    private var codeBlocks: [TranscriptText.CodeBlockInfo] = []
    /// One full-width card per code block, behind the text.
    private var codeCardViews: [CodeBlockCardView] = []
    /// One corner copy button per code block, above the text (final assistant
    /// rows only).
    private var copyButtons: [CodeCopyButton] = []
    private var role: Role = .assistant
    /// Whether this row currently renders a streaming assistant message — the
    /// caret pulse and text fade only apply then.
    private var isStreamingRow = false
    /// Observer for the Reduce Motion toggle, so the caret pulse stops/starts
    /// without waiting for the next configure.
    private var reduceMotionObserver: NSObjectProtocol?
    /// Bumped on every fade so stale animation steps (superseded by a newer
    /// batch) are skipped.
    private var fadeGeneration = 0
    /// Streaming caret: pulses light↔dark blue while a turn generates —
    /// including before any content has streamed back (the turn-start
    /// placeholder row shows just the caret).
    private var caretTimer: Timer?
    private var caretBright = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = self
        textView.drawsBackground = false
        textView.isRichText = false
        // No spell/grammar checking on transcript content: it can be very
        // large, and CoreNLP's language-ID asserts on big inputs (crashes the
        // app on NSTextCheckingOperationQueue). Code also reads better without
        // underline squiggles.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 8
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.autoresizingMask = [.width]
        addSubview(textView)
        // The user-message backdrop sits behind the text (code cards layer
        // between it and the text view).
        addSubview(highlightView, positioned: .below, relativeTo: textView)
        // VoiceOver: the row is a labelled text area; the label distinguishes
        // the speaker/kind, the value is the message text.
        textView.setAccessibilityElement(true)
        textView.setAccessibilityRole(.textArea)
        // If the user toggles Reduce Motion / Increase Contrast mid-session,
        // stop the caret pulse (or restart it) without waiting for the next
        // streaming delta.
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: DisplayOptions.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if DisplayOptions.reduceMotion {
                self.stopCaretPulse()
            } else if self.isStreamingRow {
                if DisplayOptions.increaseContrast {
                    self.stopCaretPulse()
                    self.applyHighContrastCaret()
                } else {
                    self.startCaretPulse()
                }
            }
        }
    }

    func configure(text: String, thinking: String?, role: Role, isStreaming: Bool, cacheHitRate: Double? = nil, cacheMiss: Bool = false) {
        self.role = role
        isStreamingRow = isStreaming
        textView.setAccessibilityLabel(role.accessibilityLabel)
        let oldString = textView.string
        let result = TranscriptText.attributedResult(text: text, thinking: thinking, role: role, isStreaming: isStreaming, cacheHitRate: cacheHitRate, cacheMiss: cacheMiss)
        codeBlocks = result.codeBlocks
        textView.textStorage?.setAttributedString(result.string)
        // Only the incoming text animates — the old text stays rock-solid.
        // (The whole-row CATransition used to crossfade everything, which read
        // as a constant flicker while streaming.)
        if isStreaming, role == .assistant, !oldString.isEmpty, !DisplayOptions.reduceMotion {
            fadeInNewlyAppendedText(over: oldString)
        }
        // User rows get the light-blue backdrop (resolved per draw, so a
        // mid-session appearance/contrast change applies without reconfigure).
        highlightView.isHidden = role != .user
        rebuildCodeBlockChrome()
        if isStreaming, role == .assistant, !DisplayOptions.reduceMotion {
            if DisplayOptions.increaseContrast {
                // Increase Contrast: a solid, static caret — no pulsing.
                stopCaretPulse()
                applyHighContrastCaret()
            } else {
                startCaretPulse()
            }
        } else {
            stopCaretPulse()
        }
        needsLayout = true
    }

    /// Rebuilds the code-block card backgrounds and corner copy buttons for
    /// the current string. Cards appear for every fenced block (any markdown
    /// row, streaming included); buttons only on final assistant responses —
    /// a partially-streamed block is not copy-worthy.
    private func rebuildCodeBlockChrome() {
        for view in codeCardViews { view.removeFromSuperview() }
        for button in copyButtons { button.removeFromSuperview() }
        codeCardViews.removeAll()
        copyButtons.removeAll()
        guard !codeBlocks.isEmpty else { return }
        let wantsButtons = role == .assistant && !isStreamingRow
        for block in codeBlocks {
            let card = CodeBlockCardView()
            addSubview(card, positioned: .below, relativeTo: textView)
            codeCardViews.append(card)
            if wantsButtons {
                let button = CodeCopyButton(code: block.code)
                addSubview(button)
                copyButtons.append(button)
            }
        }
    }

    /// Fades in only the characters appended since the last render. The common
    /// prefix (already-visible text) is left untouched; the streaming caret is
    /// excluded — it pulses on its own.
    private func fadeInNewlyAppendedText(over oldString: String) {
        guard let storage = textView.textStorage else { return }
        let old = oldString as NSString
        let new = storage.string as NSString
        var prefix = 0
        let maxLen = min(old.length, new.length)
        while prefix < maxLen, old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        var length = new.length - prefix
        if length > 1, new.character(at: prefix + length - 1) == 0x258C { // ▌ caret
            length -= 1
        }
        guard length > 0 else { return }
        fadeIn(range: NSRange(location: prefix, length: length))
    }

    /// Dims `range` to near-invisible, then steps it back to its final color
    /// over ~0.3s. The final color is captured per attribute run before the
    /// dimming (thinking/body/caret can differ).
    private func fadeIn(range: NSRange) {
        guard let storage = textView.textStorage, range.length > 0 else { return }
        fadeGeneration += 1
        let generation = fadeGeneration
        var runs: [(NSRange, NSColor)] = []
        var idx = range.location
        let end = range.location + range.length
        while idx < end {
            var eff = NSRange(location: 0, length: 0)
            let color = (storage.attribute(.foregroundColor, at: idx, effectiveRange: &eff) as? NSColor) ?? .labelColor
            if let clipped = eff.intersection(range), clipped.length > 0 {
                runs.append((clipped, color))
            }
            idx = eff.upperBound
        }
        for (r, c) in runs {
            storage.addAttribute(.foregroundColor, value: c.withAlphaComponent(0.12), range: r)
        }
        let steps = 6
        for step in 1...steps {
            let alpha = 0.12 + 0.88 * CGFloat(step) / CGFloat(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.05) { [weak self] in
                guard let self, self.fadeGeneration == generation, let storage = self.textView.textStorage else { return }
                for (r, c) in runs {
                    // The text may have been replaced/truncated since this fade
                    // was scheduled; clip the range to the current length so a
                    // stale range can't exceed the string (which raises an
                    // NSRangeException on addAttribute).
                    let current = NSRange(location: 0, length: storage.length)
                    let clipped = NSIntersectionRange(r, current)
                    guard clipped.length > 0 else { continue }
                    storage.addAttribute(.foregroundColor, value: c.withAlphaComponent(alpha), range: clipped)
                }
            }
        }
    }

    private func startCaretPulse() {
        guard caretTimer == nil else { return }
        caretTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pulseCaret()
            }
        }
    }

    private func stopCaretPulse() {
        caretTimer?.invalidate()
        caretTimer = nil
        caretBright = true
    }

    /// Alternates the caret's color between light and lighter blue. The
    /// streaming caret is always the last character of the attributed string.
    private func pulseCaret() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let range = NSRange(location: storage.length - 1, length: 1)
        caretBright.toggle()
        let color: NSColor = caretBright
            ? NSColor.systemBlue.withAlphaComponent(0.6)
            : NSColor.systemBlue.withAlphaComponent(0.2)
        storage.addAttribute(.foregroundColor, value: color, range: range)
    }

    /// The streaming caret rendered for Increase Contrast: solid, strong, and
    /// static — visibility never depends on pulsing.
    private func applyHighContrastCaret() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let range = NSRange(location: storage.length - 1, length: 1)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
    }

    deinit {
        MainActor.assumeIsolated {
            if let reduceMotionObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
            }
            // AppKit views deallocate on the main thread; the timer was created
            // and must be invalidated there.
            caretTimer?.invalidate()
            caretTimer = nil
        }
    }

    /// The row height implied by this cell's own text layout (usedRect +
    /// insets). The coordinator seeds the height cache from this so the table
    /// never needs a separate CoreText measurement for visible streaming rows.
    var contentHeight: CGFloat {
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else {
            return bounds.height
        }
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
    }

    /// The row height for a specific width, independent of the cell's current
    /// frame. The coordinator seeds the cache with this: a reused cell can
    /// still hold a stale (wider) frame after a window resize, and measuring
    /// at that stale width under-reports the height — the row then renders
    /// short and the (taller) text overflows upward, clipping the message's
    /// top.
    func contentHeight(atWidth width: CGFloat) -> CGFloat {
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else {
            return bounds.height
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
    }

    // MARK: - Test hooks (internal read-only access for RenderingTests)

    /// Number of code-card backgrounds currently placed (one per fenced block).
    var renderedCodeBlockCount: Int { codeCardViews.count }
    /// Number of corner copy buttons currently placed (final assistant rows only).
    var renderedCopyButtonCount: Int { copyButtons.count }
    /// The frame (in row coordinates) of the nth code card, for layout tests.
    func renderedCodeCardFrame(at index: Int) -> NSRect {
        guard index >= 0, index < codeCardViews.count else { return .zero }
        return codeCardViews[index].frame
    }
    /// The current string's fenced code blocks (full-string ranges).
    var codeBlocksForTesting: [TranscriptText.CodeBlockInfo] { codeBlocks }
    /// The placed corner buttons (for click/copy tests).
    var copyButtonsForTesting: [CodeCopyButton] { copyButtons }

    override func layout() {
        super.layout()
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else { return }
        let width = max(bounds.width, 320)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let height = used + textView.textContainerInset.height * 2
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(height, bounds.height))

        // User rows: the light-blue backdrop fills the whole row.
        highlightView.frame = bounds

        // Position each code card behind the text and its corner button above
        // it. The layout manager reports block rects in the text view's
        // (flipped) container coordinates; the cards are subviews of the
        // (non-flipped) row, so the rect must be converted — a raw y lands the
        // card ~a row-height off, covering the wrong text.
        guard !codeBlocks.isEmpty else { return }
        let containerY = textView.textContainerInset.height
        for (index, block) in codeBlocks.enumerated() {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            let bbox = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let cardRect = textView.convert(
                NSRect(x: 0, y: bbox.minY + containerY, width: textView.bounds.width, height: bbox.height),
                to: self
            )
            codeCardViews[index].frame = cardRect
            if index < copyButtons.count {
                copyButtons[index].frame = NSRect(
                    x: cardRect.maxX - CodeCopyButton.size.width - 8,
                    y: cardRect.maxY - CodeCopyButton.size.height - 6,
                    width: CodeCopyButton.size.width,
                    height: CodeCopyButton.size.height
                )
            }
        }

        // Diagnostic for the top-cut investigation (only when enabled):
        // log any state where the first line would be clipped at the row's
        // top ("cut off as if scrolled down").
        let topCutDebug = ProcessInfo.processInfo.environment["PI_DEBUG_TOP_CUT"] == "1"
        if topCutDebug, bounds.height > 0, layoutManager.numberOfGlyphs > 0 {
            let firstFrag = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let firstTopInCell = textView.frame.height - firstFrag.minY - firstFrag.height
            if firstTopInCell > bounds.height + 1 {
                let entry = String(
                    format: "TOP-CUT bounds=%@ tv=%@ firstTop=%.1f content=%.1f",
                    NSStringFromRect(bounds), NSStringFromRect(textView.frame), firstTopInCell, contentHeight
                )
                if let handle = FileHandle(forWritingAtPath: "/tmp/topcut.log") {
                    handle.seekToEndOfFile()
                    handle.write((entry + "\n").data(using: .utf8)!)
                    try? handle.close()
                } else {
                    try? (entry + "\n").write(toFile: "/tmp/topcut.log", atomically: true, encoding: .utf8)
                }
            }
        }
    }

    // MARK: - NSTextViewDelegate

    /// Markdown links are clickable: open them in the default browser. The
    /// row is read-only, so this is the only interaction links need.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}

/// The full-bleed light-blue backdrop behind user messages. Fills with the
/// dynamic `TextRowView.userHighlight` color, so dark/light mode and Increase
/// Contrast resolve at draw time.
private final class UserHighlightView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        TextRowView.userHighlight.setFill()
        dirtyRect.fill()
    }
}

/// One full-width card behind a fenced code block. Rounded, filled with the
/// dynamic `MarkdownText.codeBackground` color; the row positions it over the
/// block's line rects (below the text, so glyphs stay crisp on top).
private final class CodeBlockCardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        MarkdownText.codeBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}

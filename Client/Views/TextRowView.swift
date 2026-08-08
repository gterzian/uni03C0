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

    static func attributedString(
        text: String,
        thinking: String?,
        role: TextRowView.Role,
        isStreaming: Bool
    ) -> NSAttributedString {
        let body = NSMutableParagraphStyle()
        body.lineSpacing = 2
        body.lineBreakMode = .byWordWrapping
        let bodyFont = NSFont.systemFont(ofSize: FontSettings.shared.bodySize)
        let bodyColor: NSColor = role == .user ? .labelColor : .labelColor

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
        if !text.isEmpty {
            result.append(NSAttributedString(string: text, attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: body,
            ]))
        }
        if isStreaming {
            result.append(NSAttributedString(string: "▌", attributes: [
                .font: bodyFont,
                // Light base; TextRowView pulses it between light and lighter.
                .foregroundColor: NSColor.systemBlue.withAlphaComponent(0.6),
            ]))
        }
        return result
    }

    static func measuredHeight(
        text: String,
        thinking: String?,
        role: TextRowView.Role,
        isStreaming: Bool,
        width: CGFloat
    ) -> CGFloat {
        let attributed = attributedString(text: text, thinking: thinking, role: role, isStreaming: isStreaming)
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

/// A read-only, selectable multi-line text cell for user/assistant messages.
/// Backed by an `NSTextView` (selectable text, correct wrapping); the table
/// supplies the row height via `TranscriptText.measuredHeight`, and `layout()`
/// sizes the text view to match so content is never clipped.
final class TextRowView: NSView {
    enum Role {
        case user
        case assistant
    }

    /// Light-blue highlight behind user messages (the user's own words stand
    /// out from the agent's replies).
    private static let userHighlight = NSColor(calibratedRed: 0.87, green: 0.93, blue: 1.0, alpha: 1.0)

    private let textView = NSTextView()
    private var role: Role = .assistant
    /// Whether the light-blue user highlight is currently applied. Setting
    /// `drawsBackground` on every configure — even to the same value — forces
    /// AppKit to eagerly re-layout the whole text container synchronously
    /// (the 100%-CPU path in samples during streaming).
    private var drawsUserHighlight = false
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
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 8
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.autoresizingMask = [.width]
        addSubview(textView)
    }

    func configure(text: String, thinking: String?, role: Role, isStreaming: Bool) {
        self.role = role
        let oldString = textView.string
        textView.textStorage?.setAttributedString(
            TranscriptText.attributedString(text: text, thinking: thinking, role: role, isStreaming: isStreaming)
        )
        // Only the incoming text animates — the old text stays rock-solid.
        // (The whole-row CATransition used to crossfade everything, which read
        // as a constant flicker while streaming.)
        if isStreaming, role == .assistant, !oldString.isEmpty {
            fadeInNewlyAppendedText(over: oldString)
        }
        let shouldHighlight = role == .user
        if shouldHighlight != drawsUserHighlight {
            drawsUserHighlight = shouldHighlight
            textView.drawsBackground = shouldHighlight
            if shouldHighlight {
                textView.backgroundColor = Self.userHighlight
            }
        }
        if isStreaming, role == .assistant {
            startCaretPulse()
        } else {
            stopCaretPulse()
        }
        needsLayout = true
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

    deinit {
        // AppKit views deallocate on the main thread; the timer was created
        // and must be invalidated there.
        MainActor.assumeIsolated {
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

    override func layout() {
        super.layout()
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else { return }
        let width = max(bounds.width, 320)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let height = used + textView.textContainerInset.height * 2
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(height, bounds.height))
    }
}

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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FilePaneContainer {
        let container = FilePaneContainer()
        context.coordinator.container = container
        return container
    }

    func updateNSView(_ nsView: FilePaneContainer, context: Context) {
        context.coordinator.reload(cwd: cwd, path: path, kind: kind, token: reloadToken)
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

        func reload(cwd: URL, path: String, kind: GitStatus.Kind, token: Int) {
            guard container != nil else { return }
            if let last = lastRequest, last.path == path, last.token == token { return }
            lastRequest = (path, token)
            loadTask?.cancel()
            // A genuinely different file clears the pane while it loads; a
            // same-path refresh (the file changed) keeps showing the old
            // content until the new one is ready.
            if displayedPath != path {
                container?.showPlaceholder("Loading…")
            }
            loadTask = Task { [weak self] in
                await self?.performLoad(cwd: cwd, path: path, kind: kind, token: token)
            }
        }

        private func performLoad(cwd: URL, path: String, kind: GitStatus.Kind, token: Int) async {
            guard let container else { return }
            let loaded = await PaneContentLoader.load(cwd: cwd, path: path, kind: kind)
            // A newer request supersedes this one.
            guard let last = lastRequest, last.path == path, last.token == token else { return }
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
                // the same file is being re-shown.
                container.displayContent(path: absolutePath, text: attributed, preserveScroll: displayedPath == path)
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
    /// inline (the red side of a modification lives only in the tree badge).
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
    func displayContent(path: String, text: NSAttributedString, preserveScroll: Bool = false) {
        statusLabel.isHidden = true
        codeView.isHidden = false

        let clip = scrollView.contentView
        var anchorRatio: CGFloat?
        if preserveScroll, codeView.frame.height > 0 {
            let visible = clip.bounds.height
            if visible > 0 {
                let scrollable = codeView.frame.height - visible
                if scrollable > 0 {
                    anchorRatio = min(max(clip.bounds.minY / scrollable, 0), 1)
                }
            }
        }

        codeView.load(path: path, text: text)

        if let anchorRatio {
            let visible = clip.bounds.height
            let scrollable = codeView.frame.height - visible
            if scrollable > 0 {
                let y = min(max(anchorRatio * scrollable, 0), scrollable)
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                scrollView.reflectScrolledClipView(clip)
            }
        }
    }

    /// Centered status text (loading / unreadable / no committed content)
    /// over a blank pane.
    func showPlaceholder(_ message: String) {
        codeView.load(path: "", text: NSAttributedString(string: ""))
        statusLabel.stringValue = message
        statusLabel.isHidden = false
    }
}

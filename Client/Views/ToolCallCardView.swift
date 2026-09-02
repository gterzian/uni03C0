import AppKit
import Core
import SwiftUI

/// A table cell that hosts a SwiftUI tool-call card. Structured cards for
/// edit/write/bash/read events — typed before/after data from tool events,
/// not scraped terminal output.
final class ToolCallHostView: NSView {
    private var host: NSHostingView<AnyView>?
    /// The card this cell currently renders. The transcript coordinator reads
    /// these to spot VISIBLE cells still showing a stale state after a
    /// turn-end settle (a running card the store just flipped to `.failed`
    /// on abort — see `settleInterruptedToolCalls`): such cells must be
    /// reconfigured even when their row isn't the tail.
    private(set) var renderedCardID: String?
    private(set) var renderedCardState: ToolCallState?
    /// The last configured card content + search state, so a scroll re-entry
    /// that re-configures the cell with IDENTICAL inputs can skip the SwiftUI
    /// rootView swap (which would otherwise run a full card layout pass for
    /// nothing). `ToolCallCard` is Equatable, so the comparison is exact.
    private var lastConfiguredCard: ToolCallCard?
    private var lastConfiguredQuery: String?
    private var lastConfiguredCaseSensitive = false
    private var lastConfiguredIsCurrent = false
    private var lastConfiguredExpanded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // One layer per cell: the card's raster is cached in its own backing
        // store, so updating one card never re-rasterizes the others (the
        // `CABackingStoreUpdate_` churn in samples).
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func configure(card: ToolCallCard, searchQuery: String? = nil, searchCaseSensitive: Bool = false, isCurrentSearchMatch: Bool = false, onToggleExpand: @escaping () -> Void) {
        renderedCardID = card.id
        renderedCardState = card.state
        // Identical inputs (a scroll re-entry rendering the same card): the
        // hosting view already shows it — swapping rootView would re-run the
        // whole SwiftUI layout for no visible change. The card's own @State
        // (expansion) lives inside `ToolCallCardView` and `.id(card.id)` keeps
        // it across swaps, so skipping the swap preserves it exactly like a
        // swap would. The expansion registry is read below, so a state change
        // there (a user tap) always differs from `lastConfiguredCard`'s
        // initial-expansion input.
        let expanded = ToolCardExpansion.shared.isExpanded(card.id)
        if card == lastConfiguredCard,
           searchQuery == lastConfiguredQuery,
           searchCaseSensitive == lastConfiguredCaseSensitive,
           isCurrentSearchMatch == lastConfiguredIsCurrent,
           expanded == lastConfiguredExpanded {
            return
        }
        lastConfiguredCard = card
        lastConfiguredQuery = searchQuery
        lastConfiguredCaseSensitive = searchCaseSensitive
        lastConfiguredIsCurrent = isCurrentSearchMatch
        lastConfiguredExpanded = expanded
        // `.id(card.id)` keeps the card's own expansion state alive across
        // output updates for the same call, but resets it when a recycled cell
        // is reused for a different call.
        let root = AnyView(
            ToolCallCardView(
                card: card,
                onToggleExpand: onToggleExpand,
                isInitiallyExpanded: expanded,
                searchQuery: searchQuery,
                searchCaseSensitive: searchCaseSensitive,
                isCurrentSearchMatch: isCurrentSearchMatch
            )
            .id(card.id)
        )
        if let host {
            host.rootView = root
        } else {
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            hosting.translatesAutoresizingMaskIntoConstraints = false
            // A cell must never paint outside its row: the SwiftUI card's
            // rendered height can transiently exceed the measured row height
            // (streaming output grows between batched height updates, and
            // sizeThatFits can differ by a fraction), and an unclipped hosting
            // view then draws over the NEXT row — covering the top of the
            // following user/assistant message ("cut off at the top, as if
            // scrolled down").
            hosting.wantsLayer = true
            hosting.layer?.masksToBounds = true
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
                hosting.topAnchor.constraint(equalTo: topAnchor),
                hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            host = hosting
        }
    }
}

/// Structured card for a tool execution: name + state, arguments, output.
/// Output is collapsed to a generous preview (30 lines) with an expand button
/// to reveal the full content. The row height is measured from the REAL
/// SwiftUI layout (`NSHostingController.sizeThatFits`), so expand/collapse
/// never leaves whitespace.
struct ToolCallCardView: View {
    let card: ToolCallCard
    var onToggleExpand: () -> Void = {}
    /// The live find query (nil when the find bar is closed or this row has
    /// no match) — the matched term is highlighted in yellow, not the row.
    var searchQuery: String?
    var searchCaseSensitive = false
    var isCurrentSearchMatch = false

    @State private var isExpanded: Bool

    init(card: ToolCallCard, onToggleExpand: @escaping () -> Void = {}, isInitiallyExpanded: Bool = false, searchQuery: String? = nil, searchCaseSensitive: Bool = false, isCurrentSearchMatch: Bool = false) {
        self.card = card
        self.onToggleExpand = onToggleExpand
        self.searchQuery = searchQuery
        self.searchCaseSensitive = searchCaseSensitive
        self.isCurrentSearchMatch = isCurrentSearchMatch
        _isExpanded = State(initialValue: isInitiallyExpanded)
    }

    /// Returns `text` with every occurrence of the live query highlighted in
    /// yellow (find-in-page style; the current match uses a stronger shade).
    /// Plain text unchanged when the find bar is closed or there is no query.
    private func highlighted(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        guard let query = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return attr }
        let options: String.CompareOptions = searchCaseSensitive ? [] : [.caseInsensitive]
        let color = Color(nsColor: isCurrentSearchMatch ? SearchMatchHighlight.current : SearchMatchHighlight.match)
        let ns = text as NSString
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.length > 0 {
            let found = ns.range(of: query, options: options, range: searchRange)
            guard found.location != NSNotFound else { break }
            if let r = Range(found, in: attr) {
                attr[r].backgroundColor = color
            }
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        return attr
    }

    /// The parsed edit operations when this is an edit tool call with
    /// well-formed args; nil otherwise (fall back to the plain rendering).
    private var editOperations: [EditOperation]? {
        guard card.toolName == "edit" else { return nil }
        // Prefer the raw structured args (untruncated); fall back to parsing
        // the display string (history that predates argumentsValue).
        let ops = EditToolArgs.parse(card.argumentsValue)
        if !ops.isEmpty { return ops }
        let fromString = EditToolArgs.parse(json: card.arguments)
        return fromString.isEmpty ? nil : fromString
    }

    private var hasExpandableContent: Bool {
        editOperations != nil || !card.arguments.isEmpty || !card.output.isEmpty
    }

    var body: some View {
        let ops = editOperations
        VStack(alignment: .leading, spacing: 6) {
            header
            if let ops, !ops.isEmpty {
                // GitHub-style red/green diff instead of the raw arguments.
                EditDiffView(
                    operations: ops,
                    isExpanded: isExpanded,
                    searchQuery: searchQuery,
                    searchCaseSensitive: searchCaseSensitive,
                    isCurrentSearchMatch: isCurrentSearchMatch
                )
            } else if !card.arguments.isEmpty {
                Text(highlighted(card.arguments))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 2)
                    .textSelection(.enabled)
            }
            // The raw output: errors always show (never hidden behind the
            // diff), other tools show as before; a successful edit's output is
            // the diff/patch text, redundant next to the pretty diff, so it is
            // omitted for cards that render one.
            if !card.output.isEmpty, card.state == .failed || ops == nil {
                Text(highlighted(card.output))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(card.state == .failed ? Color.red : .primary)
                    .lineLimit(isExpanded ? nil : 30)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Running spinner: visible for the whole call, even while output
            // streams in. An NSProgressIndicator (AppKit-driven animation),
            // deliberately not SwiftUI's ProgressView — an animated SwiftUI
            // spinner inside an NSHostingView keeps its (child) graph
            // invalidating every frame for the whole tool run.
            if card.state == .running {
                HStack(spacing: 6) {
                    SpinnerView()
                        .frame(width: 12, height: 12)
                    if card.toolName == "bash", let start = card.startedAt {
                        // The run timer lives here — the prompt-bar readout
                        // no longer shows one. Ticks once per second via
                        // TimelineView while the tool runs (the only SwiftUI
                        // invalidation is this caption; the row height is
                        // unchanged, so the table never churns).
                        TimelineView(.periodic(from: start, by: 1)) { _ in
                            Text("⏱ \(Self.formatElapsed(Date().timeIntervalSince(start)))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("running…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1)
        )
        // The whole card is the click target (the chevron in the header just
        // tracks the state); a drag still selects text. No animation — the row
        // height snaps with the table, so animating the content would leave
        // transient whitespace.
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasExpandableContent else { return }
            isExpanded.toggle()
            onToggleExpand()
        }
        // VoiceOver: the card is one labelled element with a "toggle full
        // content" action; the args/output texts inside stay separate elements.
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityAction(named: Text("Toggle full content")) {
            guard hasExpandableContent else { return }
            isExpanded.toggle()
            onToggleExpand()
        }
        .accessibilityAddTraits(hasExpandableContent ? .isButton : [])
        .padding(.vertical, 4)
    }

    /// The path shown in the card title for file-path tools (`read`/`write`),
    /// so a card says "read /path/to/file" instead of just "read". Nil for
    /// tools that don't act on a single path (bash, glob, …).
    private var titlePath: String? {
        guard card.toolName == "read" || card.toolName == "write" else { return nil }
        return card.pathArgument
    }

    /// Accessibility label: "Tool bash, done" — the state word matches the
    /// visual state readout. File-path tools include the path.
    private var cardAccessibilityLabel: String {
        if let path = titlePath {
            return "Tool \(card.toolName) \(path), \(card.state.label)"
        }
        return "Tool \(card.toolName), \(card.state.label)"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 14)
            Text(highlighted(card.toolName))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            if let titlePath {
                Text(highlighted(titlePath))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The path is the flexible element: it takes the space the
                    // Spacer used to occupy so the title reads "read <path>",
                    // compressing (truncating in the middle) before the trailing
                    // state ever moves.
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }
            if hasExpandableContent {
                // Passive state indicator — the whole card is the click target.
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(isExpanded ? "Collapse" : "Show full content")
            }
            HStack(spacing: 4) {
                Image(systemName: stateIcon)
                    .font(.system(size: 10))
                Text(card.state.label)
                    .font(.caption)
            }
            .foregroundStyle(stateColor)
        }
    }

    private var iconName: String {
        switch card.toolName {
        case "bash": "terminal"
        case "edit", "write": "square.and.pencil"
        case "read": "doc.text"
        case "glob": "magnifyingglass"
        default: "wrench.and.screwdriver"
        }
    }

    private var iconColor: Color {
        switch card.toolName {
        case "bash": .purple
        case "edit", "write": .blue
        case "read": .teal
        default: .secondary
        }
    }

    private var stateIcon: String {
        switch card.state {
        case .running: "circle.dotted"
        case .done: "checkmark.circle"
        case .failed: "xmark.circle"
        }
    }

    private var stateColor: Color {
        switch card.state {
        case .running: .secondary
        case .done: .green
        case .failed: .red
        }
    }

    private var borderColor: Color {
        switch card.state {
        case .running: Color(nsColor: .separatorColor)
        case .done: Color(nsColor: .separatorColor)
        // Solid red under Increase Contrast — the failure isn't carried by
        // alpha alone.
        case .failed: DisplayOptions.increaseContrast ? .red : .red.opacity(0.5)
        }
    }

    /// "23s" under a minute, "1:23" (m:ss) above — the running bash tool's
    /// per-second elapsed readout.
    private static func formatElapsed(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded(.down)))
        if total >= 60 {
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return "\(total)s"
    }
}

/// GitHub-style red/green diff for edit tool calls: one block per edit
/// operation — a path header, then removed lines (red), added lines (green),
/// and context lines (plain). Collapsed shows a short preview; expanded shows
/// every line. Rendered as ONE selectable attributed string (per-line colors
/// via attributes), so a drag can select across lines — many sibling `Text`
/// views could only ever select a single line. Pure SwiftUI over `TextDiff`,
/// so the row measures exactly like any other card content
/// (`NSHostingController.sizeThatFits`).
struct EditDiffView: View {
    let operations: [EditOperation]
    let isExpanded: Bool
    /// The live find query — matched terms get the yellow highlight on top of
    /// the diff's own red/green, so the search term is findable in edits too.
    let searchQuery: String?
    let searchCaseSensitive: Bool
    let isCurrentSearchMatch: Bool

    /// Line budget (headers + diff lines) for the collapsed preview.
    private static let collapsedLineBudget = 14

    init(operations: [EditOperation], isExpanded: Bool, searchQuery: String? = nil, searchCaseSensitive: Bool = false, isCurrentSearchMatch: Bool = false) {
        self.operations = operations
        self.isExpanded = isExpanded
        self.searchQuery = searchQuery
        self.searchCaseSensitive = searchCaseSensitive
        self.isCurrentSearchMatch = isCurrentSearchMatch
    }

    /// The full diff as plain text — what the corner copy button delivers. One
    /// block per operation, path header then unified-diff lines, so the whole
    /// edit can be pasted back (e.g. into the prompt as steering).
    static func diffText(_ operations: [EditOperation]) -> String {
        operations.map { op in
            var lines = ["--- \(op.path)"]
            for line in TextDiff.diff(old: op.oldText, new: op.newText) {
                switch line.kind {
                case .removed: lines.append("-" + line.text)
                case .added: lines.append("+" + line.text)
                case .same: lines.append(" " + line.text)
                }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    @State private var copied = false
    /// Bumped on every copy so a stale reset (superseded by a newer copy)
    /// never flips the icon back early.
    @State private var copyGeneration = 0

    private enum SegmentKind { case path, removed, added, same }
    /// One rendered line: its text (sign included) and its kind.
    private typealias Segment = (text: String, kind: SegmentKind)

    var body: some View {
        let all = buildSegments()
        let shown = isExpanded ? all : Array(all.prefix(Self.collapsedLineBudget))
        VStack(alignment: .leading, spacing: 0) {
            // Header row: the corner copy button (copies the FULL diff — the
            // whole block, not just the visible preview). High-priority so it
            // never toggles the card's expand/collapse.
            HStack {
                Spacer()
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .help(copied ? "Copied" : "Copy diff")
                    .highPriorityGesture(TapGesture().onEnded { copyDiff() })
            }
            // ONE attributed text, not one per line — selection can span the
            // whole diff. Per-line red/green and the search highlight are
            // attributes on runs.
            Text(attributedString(for: shown))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isExpanded, all.count > Self.collapsedLineBudget {
                Text("…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }
        }
    }

    private func copyDiff() {
        let text = Self.diffText(operations)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
        let generation = copyGeneration + 1
        copyGeneration = generation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard copyGeneration == generation else { return }
            copied = false
        }
    }

    private func buildSegments() -> [Segment] {
        var segments: [Segment] = []
        for op in operations {
            segments.append((op.path, .path))
            for line in TextDiff.diff(old: op.oldText, new: op.newText) {
                switch line.kind {
                case .removed: segments.append(("-" + (line.text.isEmpty ? " " : line.text), .removed))
                case .added: segments.append(("+" + (line.text.isEmpty ? " " : line.text), .added))
                case .same: segments.append((" " + (line.text.isEmpty ? " " : line.text), .same))
                }
            }
        }
        return segments
    }

    /// Joins the segments into one attributed string: newline-separated, each
    /// line styled by kind, then the search term highlighted in yellow on top.
    private func attributedString(for segments: [Segment]) -> AttributedString {
        let bodyFont = Font.system(size: 11, design: .monospaced)
        var result = AttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 { result += "\n" }
            var line = AttributedString(segment.text)
            switch segment.kind {
            case .path:
                line.font = .system(size: 11, weight: .medium, design: .monospaced)
                line.foregroundColor = .secondary
            case .removed:
                line.font = bodyFont
                line.foregroundColor = .red
                line.backgroundColor = Color.red.opacity(0.10)
            case .added:
                line.font = bodyFont
                line.foregroundColor = .green
                line.backgroundColor = Color.green.opacity(0.10)
            case .same:
                line.font = bodyFont
                line.foregroundColor = .primary
            }
            result += line
        }
        applySearchHighlight(to: &result)
        return result
    }

    /// Paints the live query in yellow over the diff's own red/green — the
    /// same find-in-page behavior as the transcript rows.
    private func applySearchHighlight(to result: inout AttributedString) {
        guard let query = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return }
        let options: String.CompareOptions = searchCaseSensitive ? [] : [.caseInsensitive]
        let color = Color(nsColor: isCurrentSearchMatch ? SearchMatchHighlight.current : SearchMatchHighlight.match)
        let full = String(result.characters) as NSString
        var searchRange = NSRange(location: 0, length: full.length)
        while searchRange.length > 0 {
            let found = full.range(of: query, options: options, range: searchRange)
            guard found.location != NSNotFound else { break }
            if let r = Range(found, in: result) {
                result[r].backgroundColor = color
            }
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: full.length - next)
        }
    }
}

/// An animated spinner for the running-tool indicator and any always-animated
/// chrome (toolbar Stop button, tab status, in-progress overlays).
/// Deliberately NOT SwiftUI's `ProgressView`: an animated SwiftUI spinner
/// inside an `NSHostingView` keeps its (child) SwiftUI graph invalidating
/// every frame for the whole time it is visible — during a long stream that
/// is the entire turn, sweeping the hosting views' layout into every display
/// cycle (the shell-relayout cost seen in main-thread samples: hosting
/// `layout()` cascades + `sizeThatFits` re-measures per streaming commit).
/// `NSProgressIndicator` animates on its own AppKit timer and never touches
/// the SwiftUI graph — the row/card height and the surrounding layout stay
/// static, so nothing re-lays out while it spins.
struct SpinnerView: NSViewRepresentable {
    /// Size to match the replaced `ProgressView().controlSize(...)`.
    var controlSize: NSControl.ControlSize = .small

    func makeNSView(context: Context) -> ClickTransparentIndicator {
        let indicator = ClickTransparentIndicator()
        indicator.style = .spinning
        indicator.controlSize = controlSize
        indicator.startAnimation(nil)
        return indicator
    }

    func updateNSView(_ nsView: ClickTransparentIndicator, context: Context) {}

    /// The indicator is decoration inside a SwiftUI `Button` (toolbar Stop,
    /// tab pill) and must never consume the click that should reach the
    /// button; it never needs mouse events itself.
    final class ClickTransparentIndicator: NSProgressIndicator {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

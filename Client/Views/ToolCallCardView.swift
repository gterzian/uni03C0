import AppKit
import Core
import SwiftUI

/// A table cell that hosts a SwiftUI tool-call card. Structured cards for
/// edit/write/bash/read events — typed before/after data from tool events,
/// not scraped terminal output.
final class ToolCallHostView: NSView {
    private var host: NSHostingView<AnyView>?

    func configure(card: ToolCallCard, onToggleExpand: @escaping () -> Void) {
        // `.id(card.id)` keeps the card's own expansion state alive across
        // output updates for the same call, but resets it when a recycled cell
        // is reused for a different call.
        let root = AnyView(
            ToolCallCardView(
                card: card,
                onToggleExpand: onToggleExpand,
                isInitiallyExpanded: ToolCardExpansion.shared.isExpanded(card.id)
            )
            .id(card.id)
        )
        if let host {
            host.rootView = root
        } else {
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            hosting.translatesAutoresizingMaskIntoConstraints = false
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

    @State private var isExpanded: Bool

    init(card: ToolCallCard, onToggleExpand: @escaping () -> Void = {}, isInitiallyExpanded: Bool = false) {
        self.card = card
        self.onToggleExpand = onToggleExpand
        _isExpanded = State(initialValue: isInitiallyExpanded)
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
                EditDiffView(operations: ops, isExpanded: isExpanded)
            } else if !card.arguments.isEmpty {
                Text(card.arguments)
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
                Text(card.output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(card.state == .failed ? Color.red : .primary)
                    .lineLimit(isExpanded ? nil : 30)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if card.state == .running {
                // Static indicator — deliberately no ProgressView: an animated
                // spinner inside an NSHostingView keeps its (child) SwiftUI
                // graph invalidating every frame for the whole tool run.
                HStack(spacing: 6) {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 10))
                    Text("running…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 14)
            Text(card.toolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
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
        case .failed: .red.opacity(0.5)
        }
    }
}

/// GitHub-style red/green diff for edit tool calls: one block per edit
/// operation — a path header, then removed lines (red), added lines (green),
/// and context lines (plain). Collapsed shows a short preview; expanded shows
/// every line. Pure SwiftUI over `TextDiff`, so the row measures exactly like
/// any other card content (`NSHostingController.sizeThatFits`).
struct EditDiffView: View {
    let operations: [EditOperation]
    let isExpanded: Bool

    /// Line budget (headers + diff lines) for the collapsed preview.
    private static let collapsedLineBudget = 14

    private enum DiffRow: Hashable {
        case path(String)
        case line(DiffLine)
    }

    var body: some View {
        let rows = buildRows()
        let shown = isExpanded ? rows : Array(rows.prefix(Self.collapsedLineBudget))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
            if !isExpanded, rows.count > Self.collapsedLineBudget {
                Text("…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }
        }
    }

    private func buildRows() -> [DiffRow] {
        var rows: [DiffRow] = []
        for op in operations {
            rows.append(.path(op.path))
            for line in TextDiff.diff(old: op.oldText, new: op.newText) {
                rows.append(.line(line))
            }
        }
        return rows
    }

    @ViewBuilder
    private func rowView(_ row: DiffRow) -> some View {
        switch row {
        case .path(let path):
            Text(path)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .padding(.horizontal, 6)
        case .line(let line):
            diffLineView(line)
        }
    }

    private func diffLineView(_ line: DiffLine) -> some View {
        let (sign, foreground, background): (String, Color, Color) = switch line.kind {
        case .removed: ("-", .red, Color.red.opacity(0.10))
        case .added: ("+", .green, Color.green.opacity(0.10))
        case .same: (" ", .primary, .clear)
        }
        return HStack(spacing: 6) {
            Text(sign)
                .foregroundStyle(foreground)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 10, alignment: .trailing)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(line.kind == .same ? Color.primary : foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 0.5)
        .background(background)
    }
}

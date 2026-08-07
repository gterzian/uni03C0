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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !card.arguments.isEmpty {
                Text(card.arguments)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 2)
                    .textSelection(.enabled)
            }
            if !card.output.isEmpty {
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
            guard !card.output.isEmpty || !card.arguments.isEmpty else { return }
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
            if !card.output.isEmpty || !card.arguments.isEmpty {
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

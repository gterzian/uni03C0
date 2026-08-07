import AppKit
import PiCore
import SwiftUI

/// A table cell that hosts a SwiftUI tool-call card. Structured cards for
/// edit/write/bash/read events — typed before/after data from tool events,
/// not scraped terminal output.
final class ToolCallHostView: NSView {
    private var host: NSHostingView<ToolCallCardView>?

    func configure(card: ToolCallCard) {
        if let host {
            host.rootView = ToolCallCardView(card: card)
        } else {
            let hosting = NSHostingView(rootView: ToolCallCardView(card: card))
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
/// Height matches `TranscriptEntryKind.toolCallHeight` (both must agree).
struct ToolCallCardView: View {
    let card: ToolCallCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !card.arguments.isEmpty {
                Text(card.arguments)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if !card.output.isEmpty {
                Text(card.output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(card.state == .failed ? Color.red : .primary)
                    .lineLimit(12)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if card.state == .running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("running…").font(.caption).foregroundStyle(.secondary)
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

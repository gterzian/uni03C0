import Core
import SwiftUI

/// The thin status bar below the prompt input: context-window usage on the
/// left, and the model + thinking-level pickers on the right. These selectors
/// live at the bottom (next to the input) rather than the toolbar so the
/// session's runtime settings are visible next to where you type.
struct SessionStatusBar: View {
    let viewModel: SessionViewModel

    var body: some View {
        HStack(spacing: 12) {
            contextLabel

            Spacer()

            modelMenu
            thinkingMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .font(.caption)
        .foregroundStyle(.secondary)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: Context usage

    private var contextLabel: some View {
        let percent = viewModel.contextUsage?.percent
        let text = percent.map { "\(Int(round($0)))%" } ?? "–"
        return Label("Context \(text)", systemImage: "rectangle.compress.vertical")
            .help("Context window usage")
    }

    // MARK: Model

    private var modelMenu: some View {
        Menu {
            ForEach(viewModel.availableModels) { model in
                Button {
                    Task { try? await viewModel.setModel(model.provider ?? "", model.id) }
                } label: {
                    if viewModel.model?.id == model.id {
                        Label(model.name ?? model.id, systemImage: "checkmark")
                    } else {
                        Text(model.name ?? model.id)
                    }
                }
            }
        } label: {
            Label(viewModel.model?.name ?? viewModel.model?.id ?? "Model", systemImage: "cpu")
        }
        .help("Switch model")
    }

    // MARK: Thinking level

    private var thinkingMenu: some View {
        Menu {
            ForEach(viewModel.availableThinkingLevels, id: \.self) { level in
                Button {
                    Task { try? await viewModel.setThinkingLevel(level) }
                } label: {
                    if viewModel.thinkingLevel == level {
                        Label(level, systemImage: "checkmark")
                    } else {
                        Text(level)
                    }
                }
            }
        } label: {
            Label(viewModel.thinkingLevel ?? "Thinking", systemImage: "brain")
        }
        .help("Set thinking level")
    }
}

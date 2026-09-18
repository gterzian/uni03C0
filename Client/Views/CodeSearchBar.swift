import SwiftUI

/// The find bar for a code pane (the Files page's open file or the Changes
/// page's diff). The counterpart of the session's `SessionSearchBar`, but for
/// one in-memory buffer instead of the whole conversation: the match count is
/// known immediately, so there is no "searching…" state to show. Cmd+F opens
/// it, Enter / ⇧Enter cycle, Esc closes.
struct CodeSearchBar: View {
    @Bindable var model: CodeSearchModel
    let placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            SearchField(
                text: $model.query,
                placeholder: placeholder,
                onEnter: { model.next() },
                onEscape: { model.close() }
            )
            .frame(width: 160)
            .onChange(of: model.query) { _, query in model.updateQuery(query) }
            let trimmed = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if model.matchCount == 0 {
                    Text("no matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(model.currentIndex + 1)/\(model.matchCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Button { model.previous() } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.matchCount == 0)
            .help("Previous match (⇧↩)")
            Button { model.next() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.matchCount == 0)
            .help("Next match (↩)")
            Toggle(isOn: Binding(
                get: { model.isCaseSensitive },
                set: { model.setCaseSensitive($0) }
            )) {
                Text("Aa")
                    .font(.system(size: 10, weight: .semibold))
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .fixedSize()
            .help("Case-sensitive")
            Button { model.close() } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close (esc)")
        }
    }
}

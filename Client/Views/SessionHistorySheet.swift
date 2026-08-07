import Core
import SwiftUI

/// Full, unbounded list of a project's sessions (§7 "View Full History…").
/// Reads only the first few lines of each session file, so listing stays cheap
/// regardless of session length. Selecting a row resumes it via
/// `switch_session` on the live process. Plain list, no search — Close button
/// in the title bar, Esc also dismisses.
struct SessionHistorySheet: View {
    let cwd: URL
    let viewModel: SessionViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SessionListing.Summary] = []

    var body: some View {
        List(sessions) { session in
            Button {
                Task {
                    await viewModel.switchSession(session.path)
                    dismiss()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? session.path.lastPathComponent : session.title)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text("\(relativeTime(session.timestamp)) · \(session.path.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 580, height: 500)
        .navigationTitle("Session History")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .task {
            sessions = SessionListing.recentSessions(for: cwd, limit: nil)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        guard date != .distantPast else { return "unknown date" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

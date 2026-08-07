import SwiftUI

/// Menu-bar quick prompt. The content is a *launcher*, not a session: it
/// spawns nothing at app launch (MenuBarExtra content is instantiated eagerly
/// even before the window is shown — a SessionView here would start a pi
/// process on startup). The session only starts once the user picks a project.
struct QuickPromptView: View {
    @State private var session: URL?

    var body: some View {
        Group {
            if let session {
                SessionView(cwd: session)
                    .frame(width: 720, height: 560)
            } else {
                QuickPromptLauncher { url in
                    AppState.shared.lastProject = url
                    session = url
                }
                .frame(width: 720, height: 560)
            }
        }
    }
}

/// Compact launcher: last project + project list. No session until a click.
struct QuickPromptLauncher: View {
    let onSelect: (URL) -> Void
    @State private var appState = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Quick Prompt", systemImage: "terminal.fill")
                .font(.headline)
                .padding(.bottom, 6)

            if let last = appState.lastProject {
                Button {
                    onSelect(last)
                } label: {
                    Label("Last project: \(last.lastPathComponent)", systemImage: "clock")
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
                Divider()
            }

            Text("Projects")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.projectsRoot == nil {
                Text("No projects folder set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose Projects Folder…") {
                    appState.chooseProjectsRoot()
                }
                .padding(.top, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(appState.projects, id: \.self) { project in
                            Button {
                                onSelect(project)
                            } label: {
                                Label(project.lastPathComponent, systemImage: "folder")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

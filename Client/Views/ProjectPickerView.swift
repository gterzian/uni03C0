import SwiftUI

/// Shown when a window has no project chosen. Spawns nothing — no `pi`
/// process, no session — until the user picks an explicit project directory.
struct ProjectPickerView: View {
    let onSelect: (URL) -> Void
    @State private var appState = AppState.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Choose a project")
                .font(.title2.weight(.semibold))

            if let root = appState.projectsRoot {
                Text(root.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appState.projects.isEmpty {
                    Text("No project folders found in this directory.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(appState.projects, id: \.self) { project in
                                Button {
                                    onSelect(project)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder.fill")
                                            .foregroundStyle(.blue)
                                            .frame(width: 16)
                                        Text(project.lastPathComponent)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 340)
                }
                Divider()
                Button("Change Projects Folder…") {
                    appState.chooseProjectsRoot()
                }
            } else {
                Text("No projects folder set. Choose one to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Choose Projects Folder…") {
                    appState.chooseProjectsRoot()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

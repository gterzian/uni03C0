import SwiftUI

/// Shown when a window has no project chosen. Spawns nothing — no `pi`
/// process, no session — until the user picks an explicit project directory.
///
/// The "projects folder" is the *top-level* folder for all the projects the
/// agent may work on: every project folder inside it is accessible. It can be
/// as small as a single project — the root folder itself can be used directly
/// as the project.
struct ProjectPickerView: View {
    let onSelect: (URL) -> Void
    @State private var appState = AppState.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Choose a projects folder")
                .font(.title2.weight(.semibold))

            Text("This is the top-level folder for all the projects the agent can work on. Every project folder inside it is accessible — and it can be just one project if that's all you have.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            if let root = appState.projectsRoot {
                Text(root.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.projects.isEmpty {
                    Text("No project folders found inside this folder yet. Add a project folder to it, choose another folder, or use this folder itself as the project.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    Button("Use This Folder as the Project") {
                        onSelect(root)
                    }
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

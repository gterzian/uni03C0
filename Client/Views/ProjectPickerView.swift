import SwiftUI

/// Shown when the window has no project chosen. Two clearly separated steps:
///
/// 1. **Setup** (no projects folder chosen yet): choose the top-level projects
///    folder and review the sandbox fields (development directories, allowed
///    internet domains). Choosing the folder saves the sandbox settings and
///    advances to step 2.
/// 2. **Project selection**: pick the project folder to start working on.
///    This is about starting work, not setup — the sandbox fields are gone.
///    Selecting a project spawns the sandboxed agent for that folder.
struct ProjectPickerView: View {
    let onSelect: (URL) -> Void
    @State private var appState = AppState.shared
    @State private var sandbox = SandboxSettingsModel.shared

    var body: some View {
        if appState.projectsRoot == nil {
            setupView
        } else {
            projectSelectionView
        }
    }

    // MARK: Step 1 — setup: the sandbox definition

    private var setupView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text("Set up the agent's sandbox")
                    .font(.title2.weight(.semibold))

                Text("The agent runs in a sandbox: it can touch only what you define here. Everything else — files, network — is blocked.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)

                // 1. Working folder — everything inside is read + write.
                VStack(alignment: .leading, spacing: 4) {
                    Label("1. Working folder — everything inside is read + write", systemImage: "folder")
                        .font(.headline)
                    Text("The top-level folder for all your projects. The agent can read and write every project in it — this is the workspace it works on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Choose Working Folder…") {
                        appState.chooseProjectsRoot()
                        // Advancing to the project step counts as finishing
                        // setup: persist the whitelists as they are right now.
                        sandbox.save()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // 2. Additional read/write paths outside the working folder.
                VStack(alignment: .leading, spacing: 4) {
                    Label("2. Additional read/write paths (outside the working folder)", systemImage: "wrench.and.screwdriver")
                        .font(.headline)
                    TextEditor(text: $sandbox.readOnlyPathsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 120)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary, lineWidth: 1))
                    Text("One path per line — toolchain homes, caches, frameworks, Xcode. The agent can read and write these too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // 3. Internet access — only these domains.
                VStack(alignment: .leading, spacing: 4) {
                    Label("3. Internet access — only these domains", systemImage: "globe")
                        .font(.headline)
                    TextEditor(text: $sandbox.allowedHostsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary, lineWidth: 1))
                    Text("One domain per line; subdomains included. The agent can reach no other internet host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Saved when you choose a working folder. Edit anytime in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Step 2 — pick the project to work on

    private var projectSelectionView: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "hammer")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text("Start working on a project")
                    .font(.title2.weight(.semibold))

                Text("Pick the project folder the agent starts working in. It can be any project inside your projects folder, or the folder itself — the agent can read and write every project in it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                if let root = appState.projectsRoot {
                    Text(root.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if appState.projects.isEmpty {
                        Text("No project folders found inside this folder yet. Add a project folder to it, choose another folder, or use this folder itself as the project.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                        Button("Use This Folder as the Project") {
                            select(root)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(appState.projects, id: \.self) { project in
                                    Button {
                                        select(project)
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
                        .frame(maxHeight: 300)
                    }

                    Divider()
                    Button("Change Projects Folder…") {
                        appState.chooseProjectsRoot()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Starting work on a project also re-saves the sandbox settings (in case
    /// the user went back and forth), then opens the session.
    private func select(_ url: URL) {
        sandbox.save()
        AppState.shared.lastProject = url
        onSelect(url)
    }
}

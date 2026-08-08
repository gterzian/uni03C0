import SwiftUI

/// The sandbox settings page (app menu → Settings…, ⌘,): the definition of
/// the sandbox — the top-level projects folder (read+write for everything in
/// it), the development directories, and the allowed internet domains. Same
/// fields as the first-run setup; applied at app startup.
struct SandboxSettingsView: View {
    @State private var model = SandboxSettingsModel.shared
    @State private var appState = AppState.shared
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sandbox")
                .font(.title2.weight(.semibold))
            Text("The agent runs in a Seatbelt sandbox: everything it can touch is defined here, and everything else is off-limits. These settings are applied at app startup — a running agent keeps the sandbox it started with until the app is restarted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The workspace: the top-level working folder, fully read+write.
            VStack(alignment: .leading, spacing: 4) {
                Label("Working folder (read + write)", systemImage: "folder")
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(appState.projectsRoot?.path ?? "No working folder chosen")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change…") {
                        appState.chooseProjectsRoot()
                    }
                }
                Text("The top-level folder the agent works on — everything inside it is read + write. The agent also gets ~/.pi. Changing it takes effect on the next app start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            settingsSection(
                icon: "wrench.and.screwdriver",
                title: "Additional read/write paths (outside the working folder)",
                text: $model.readOnlyPathsText,
                height: 170,
                footnote: "One path per line — toolchain homes, package caches, frameworks, Xcode. The agent can read and write these in addition to the working folder. ~/.pi is always allowed."
            )

            settingsSection(
                icon: "globe",
                title: "Allowed internet domains",
                text: $model.allowedHostsText,
                height: 110,
                footnote: "One domain per line; subdomains are included. The agent can reach no other internet host. The model provider's domain (e.g. api.deepseek.com) must be listed for the agent to reach its model."
            )

            HStack(spacing: 10) {
                if saved {
                    Label("Saved — applies at next app startup", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
                Spacer()
                Button("Save") {
                    model.save()
                    saved = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func settingsSection(
        icon: String,
        title: String,
        text: Binding<String>,
        height: CGFloat,
        footnote: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.headline)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .frame(height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.quaternary, lineWidth: 1)
                )
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

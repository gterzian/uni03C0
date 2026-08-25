import Core
import SwiftUI

/// The settings page (app menu → Settings…, ⌘,): the definition of the
/// sandbox — the top-level projects folder (read+write for everything in
/// it), the development directories, and the allowed internet domains — plus
/// the agent RPC endpoint (the pi executable spawned as `pi --mode rpc`).
/// Same fields as the first-run setup; snapshotted per session at spawn.
struct SandboxSettingsView: View {
    @State private var model = SandboxSettingsModel.shared
    @State private var appState = AppState.shared
    @State private var saved = false
    /// The agent RPC endpoint: the local pi executable spawned as
    /// `pi --mode rpc`. Prefilled with the default (pi resolved from PATH).
    @State private var rpcEndpointText = RPCEndpointSettings.load().executablePath
    /// Whether the tool-call timeout is enforced (Load from Settings).
    @State private var toolTimeoutEnabled: Bool
    /// The tool-call timeout in minutes (Load from Settings).
    @State private var toolTimeoutMinutes: Int

    init() {
        let timeout = ToolTimeoutSettings.load()
        _toolTimeoutEnabled = State(initialValue: timeout.isEnabled)
        _toolTimeoutMinutes = State(initialValue: max(1, timeout.seconds / 60))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable content; the Save bar stays pinned below so it is
            // always reachable however the window is sized.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Settings")
                        .font(.title2.weight(.semibold))
                    Text("The agent runs in a Seatbelt sandbox: everything it can touch is defined below, and everything else is off-limits. Settings are snapshotted when a session starts — a running agent keeps what it started with until the session ends; new sessions (including new tabs) pick up the current values.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Explainer: what's configurable here vs. the fixed policy scaffold.
                    VStack(alignment: .leading, spacing: 6) {
                        Label("What's configurable, what's not", systemImage: "info.circle")
                            .font(.headline)
                        Text("The fields below are the agent's world — anything not listed is denied (files, network, syscalls). Always allowed with no configuration needed: ~/.pi (read + write), system directories (read-only), temp folders, your git configuration (read-only, so git and SwiftPM package resolution work), and loopback networking. Internet egress happens only through the whitelisted domains below — a domain that isn't listed cannot be reached, no matter what the agent tries.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

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
                        Text("The top-level folder the agent works on — everything inside it is read + write. The agent also gets ~/.pi. Changing it takes effect on the next session.")
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
                        footnote: "One domain per line; subdomains are included. URLs are fine — a pasted link is saved as its bare host (https://example.com/path → example.com). The agent can reach no other internet host. The model provider's domain (e.g. api.deepseek.com) must be listed for the agent to reach its model."
                    )

                    // Tool-call timeout: a runtime behavior, read LIVE at the
                    // start of each tool call (not snapshotted at spawn, unlike
                    // the sandbox settings and the RPC endpoint). The assistant
                    // is free to run as long as it wants — only a single tool
                    // call is bounded.
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Tool call timeout", systemImage: "timer")
                            .font(.headline)
                        Toggle("Stop a tool call that runs too long", isOn: $toolTimeoutEnabled)
                            .font(.callout)
                        if toolTimeoutEnabled {
                            Stepper("\(toolTimeoutMinutes) minutes", value: $toolTimeoutMinutes, in: 1...240)
                                .font(.callout)
                        }
                        Text("If a single tool call (a command, a file edit, …) runs longer than this, the client aborts it and shows a notice. The assistant itself is not limited — a turn may run indefinitely as long as no one tool exceeds the limit. Default 10 minutes. Off = no limit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // The agent RPC endpoint: where the client finds `pi --mode rpc`.
                    // Local process only — the client speaks the RPC protocol over the
                    // executable's stdin/stdout.
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Agent RPC endpoint", systemImage: "terminal")
                            .font(.headline)
                        HStack(spacing: 8) {
                            TextField("pi executable path", text: $rpcEndpointText)
                                .font(.system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                            Button("Reset to Default") {
                                rpcEndpointText = RPCEndpointSettings.defaults.executablePath
                            }
                        }
                        Text("The path to the pi executable the client drives in RPC mode (`pi --mode rpc`), spawned as a local process. Default: the pi binary found on PATH. New sessions start from this path.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 560)

            Divider()

            HStack(spacing: 10) {
                if saved {
                    Label("Saved — new sessions use these settings", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
                Spacer()
                Button("Save") {
                    model.save()
                    RPCEndpointSettings(
                        executablePath: rpcEndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
                    ).save()
                    ToolTimeoutSettings(
                        seconds: toolTimeoutMinutes * 60,
                        isEnabled: toolTimeoutEnabled
                    ).save()
                    saved = true
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
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

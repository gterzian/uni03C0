import Foundation
import Observation

/// One session's observable state. This is now a *thin shim* over
/// `TranscriptStore`: it owns the connection, the RPC commands (prompt/abort/
/// setModel/...), and the few bits of UI state SwiftUI reads (`isStreaming`,
/// `model`, `thinkingLevel`, `isReloading`). It does NOT own the transcript —
/// that lives in `TranscriptStore`, folded off the main thread. The AppKit
/// coordinator reads the store directly.
///
/// The event stream is the single source of truth — nothing is
/// hand-maintained in parallel.
@MainActor
@Observable
public final class SessionViewModel {
    public enum ConnectionState: Equatable {
        case starting
        case connected
        case disconnected(String)
    }

    public private(set) var connectionState: ConnectionState = .starting
    public private(set) var isStreaming = false
    public private(set) var model: ModelInfo?
    public private(set) var availableModels: [ModelInfo] = []
    public private(set) var thinkingLevel: String?
    public private(set) var availableThinkingLevels: [String] = []
    /// Context-window usage (percentage of the model's context window in use),
    /// refreshed from `get_session_stats` when a turn settles. Read by the
    /// status bar.
    public private(set) var contextUsage: ContextUsage?
    public private(set) var sessionFile: URL?
    public private(set) var sessionName: String?
    /// True while a session switch / reload is rebuilding the transcript off
    /// the main thread. SwiftUI shows an in-app spinner from this; the main
    /// thread is never blocked.
    public private(set) var isReloading = false
    /// True while the coordinator is fetching a block of older history at the
    /// top of the transcript (scrolling up). Drives the in-app spinner above
    /// the conversation. Set by the AppKit coordinator on the main actor.
    public var isFetchingOlder = false

    /// The full history, owned off-main. Both the RPC-folding here and the
    /// coordinator (main thread) read/write it through lock-guarded APIs.
    public let store = TranscriptStore()

    public let cwd: URL
    public let controller: ProcessController
    /// Loopback whitelist proxy — the agent's only internet egress. Started
    /// with the session, stopped with it.
    public let proxy: WhitelistProxy

    /// AppKit-side hook: the transcript coordinator sets this and is called on
    /// the main actor whenever the store has mutated. The SwiftUI body
    /// deliberately never reads the transcript entries, so a streamed delta
    /// does not touch the SwiftUI graph at all — updates flow store → AppKit
    /// directly.
    public var onTranscriptChange: (() -> Void)?

    private var eventTask: Task<Void, Never>?

    public init(cwd: URL, executable: String = PiExecutable.resolve(), projectsRoot: URL? = nil) {
        self.cwd = cwd
        // Debug escape hatch: PI_NOSANDBOX=1 runs the agent without a Seatbelt
        // profile (used to isolate sandbox-caused failures).
        let settings = ProcessInfo.processInfo.environment["PI_NOSANDBOX"] == nil
            ? SandboxSettings.load()
            : nil
        // Snapshot the sandbox settings at spawn: the seatbelt profile is
        // one-way and the proxy whitelist is fixed for the session's life, so
        // edits take effect on the next session (the settings page says so).
        self.proxy = WhitelistProxy(whitelist: .init(hosts: settings?.allowedHosts ?? []))
        self.controller = ProcessController(
            executablePath: executable,
            arguments: ["--mode", "rpc"],
            workingDirectory: cwd.path,
            sandbox: settings,
            proxy: self.proxy,
            projectsRoot: projectsRoot?.path
        )
    }

    // MARK: - Lifecycle

    public func start() async {
        guard eventTask == nil else { return }
        // Bring up the loopback egress first so the spawn picks up the port.
        try? await proxy.start()
        await controller.start()
        eventTask = Task { [weak self] in
            await self?.consumeEvents()
        }
        await refreshState()
        // A fresh session starts on the client's preferred model and thinking
        // level. Applied once at spawn, so a resume/reload never overrides what
        // the user chose for a running session.
        await applyDefaults()
        // Switching the model can change which thinking levels it supports, so
        // re-fetch the runtime options (models + levels) for the status bar.
        await refreshRuntimeOptions()
        await refreshContextStats()
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await controller.terminate()
        await proxy.stop()
    }

    private func consumeEvents() async {
        do {
            for try await frame in controller.events {
                await handleFrame(frame)
            }
            if connectionState != .disconnected("") {
                connectionState = .disconnected("agent process exited")
            }
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    /// Handles one frame: applies UI-visible state on the main actor, then
    /// folds the transcript off the main thread and notifies the renderer if
    /// anything changed. The main actor yields while the store folds, so a
    /// streamed delta never blocks the UI.
    private func handleFrame(_ frame: RPCFrame) async {
        switch frame.type {
        case "agent_start", "turn_start":
            isStreaming = true
        case "agent_end", "turn_end":
            // turn_end also fires BETWEEN tool rounds inside one agent run —
            // that is not the end of the work, so nothing is flushed here
            // (flushing here raced pi and collapsed the queue).
            isStreaming = false

        case "agent_settled":
            // The whole agent run settled. Flush any queued steering as ONE
            // combined prompt (never one turn per message like the TUI) — or,
            // after an abort, return it to the input for editing instead.
            isStreaming = false
            if abortReturnsQueuedSteering {
                // The user aborted: don't flush queued steering as a new
                // prompt — return it to the input for editing instead.
                abortReturnsQueuedSteering = false
                if !queuedSteering.isEmpty {
                    let restored = queuedSteeringText
                    queuedSteering = []
                    onRestoreSteeringToInput?(restored)
                }
            } else {
                await flushQueuedSteering()
            }
            // The new assistant messages carry the context reading, so the
            // usage is now accurate.
            await refreshContextStats()

        case "thinking_level_changed":
            if let level = frame.levelText() { thinkingLevel = level }
        case "model_changed":
            if let model = frame.decodeModelChange() { self.model = model }

        default:
            break // transcript frames are folded by the store below
        }

        let changed = await Task.detached(priority: .userInitiated) { [store] in
            store.apply(frame)
        }.value
        if changed {
            onTranscriptChange?()
        }
    }

    // MARK: - Commands

    /// Set when an abort ends the turn: queued steering is returned to the
    /// prompt input instead of being flushed as a new prompt.
    private var abortReturnsQueuedSteering = false

    /// Hook for the prompt bar: called with the joined queued steering when an
    /// abort returns it to the input.
    public var onRestoreSteeringToInput: ((String) -> Void)?

    public func sendPrompt(_ text: String) async throws {
        abortReturnsQueuedSteering = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let response = try await controller.send(.prompt(message: trimmed))
        if response.success == false {
            throw ProcessError.commandFailed(response.error ?? "prompt rejected")
        }
    }

    // MARK: - Steering (queued while a turn is in flight)

    /// Steering messages queued while a turn is in flight. They are never sent
    /// individually: when the turn settles, the whole queue is flushed as one
    /// combined prompt (`flushQueuedSteering`), so the agent never starts one
    /// turn per queued message.
    public private(set) var queuedSteering: [String] = []

    /// True while at least one steering message is queued — drives the banner
    /// above the prompt bar.
    public var hasQueuedSteering: Bool { !queuedSteering.isEmpty }

    /// The queued steering, joined for display and for the single flush.
    public var queuedSteeringText: String { queuedSteering.joined(separator: "\n\n") }

    /// Queue a steering message (Return while a turn is in flight). It is held
    /// until the turn settles, then sent as part of one combined prompt.
    public func queueSteering(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queuedSteering.append(trimmed)
    }

    /// Remove one queued steering message (the per-row edit/delete buttons on
    /// the queued-steering banner).
    public func removeQueuedSteering(at index: Int) {
        guard queuedSteering.indices.contains(index) else { return }
        queuedSteering.remove(at: index)
    }

    /// Sends all queued steering messages as one combined prompt. On failure
    /// the combined text is kept so the next settle retries instead of losing
    /// the user's steering.
    private func flushQueuedSteering() async {
        guard !queuedSteering.isEmpty else { return }
        let combined = queuedSteeringText
        queuedSteering = []
        do {
            try await sendPrompt(combined)
        } catch {
            queuedSteering = [combined]
        }
    }

    public func setModel(_ provider: String, _ modelId: String) async throws {
        let response = try await controller.send(.setModel(provider: provider, modelId: modelId))
        if let model = response.dataPayload(ModelInfo.self) {
            self.model = model
        } else if let model = response.decodeModelChange() {
            self.model = model
        }
    }

    public func setThinkingLevel(_ level: String) async throws {
        _ = try await controller.send(.setThinkingLevel(level: level))
        thinkingLevel = level
    }

    /// Aborts the current agent operation — the in-flight LLM turn (including
    /// thinking) and any running tool execution.
    public func abort() async throws {
        abortReturnsQueuedSteering = true
        _ = try await controller.send(.abort())
    }

    /// Reload = ask the running process what its own session file is, then
    /// `switch_session` to that same path (re-reads state from disk without
    /// restarting the process), then repopulate messages.
    public func reload() async {
        guard let payload = try? await controller.send(.getState()).dataPayload(SessionStatePayload.self),
              let path = payload.sessionFile else { return }
        _ = try? await controller.send(.switchSession(path: path))
        await refreshState()
        await loadMessages()
    }

    /// Resume = switch to another session file, then repopulate.
    public func switchSession(_ path: URL) async {
        _ = try? await controller.send(.switchSession(path: path.path))
        await refreshState()
        await loadMessages()
    }

    /// Applies the client defaults to a freshly spawned session: the DeepSeek
    /// Flash model and the maximum thinking level. Best-effort (ignores
    /// failures) so an environment without those defaults falls back to the
    /// agent's own.
    private func applyDefaults() async {
        if model?.id != Defaults.modelID || model?.provider != Defaults.modelProvider {
            try? await setModel(Defaults.modelProvider, Defaults.modelID)
        }
        if thinkingLevel != Defaults.thinkingLevel {
            try? await setThinkingLevel(Defaults.thinkingLevel)
        }
    }

    /// Refreshes the context-window usage percentage from `get_session_stats`.
    public func refreshContextStats() async {
        guard connectionState == .connected else { return }
        guard let payload = try? await controller.send(.getSessionStats()).dataPayload(SessionStatsPayload.self) else {
            return
        }
        contextUsage = payload.contextUsage
    }

    private func refreshState() async {
        guard let payload = try? await controller.send(.getState()).dataPayload(SessionStatePayload.self) else {
            connectionState = .disconnected("no response from the agent")
            return
        }
        model = payload.model
        thinkingLevel = payload.thinkingLevel
        if let file = payload.sessionFile { sessionFile = URL(fileURLWithPath: file) }
        sessionName = payload.sessionName
        isStreaming = payload.isStreaming ?? false
        connectionState = .connected
        await refreshRuntimeOptions()
    }

    /// Refreshes the available models and thinking levels (used by the status
    /// bar pickers). The set of supported levels depends on the current model,
    /// so this runs again after the model is switched.
    private func refreshRuntimeOptions() async {
        let models = try? await controller.send(.getAvailableModels()).dataPayload(ModelsPayload.self)
        availableModels = models?.models ?? []
        let levels = try? await controller.send(.getAvailableThinkingLevels()).dataPayload(LevelsPayload.self)
        availableThinkingLevels = levels?.levels ?? []
    }

    /// Rebuilds the transcript from `get_messages` off the main thread,
    /// driving the in-app `isReloading` spinner (not the system beachball)
    /// while the store folds the whole history.
    public func loadMessages() async {
        guard let payload = try? await controller.send(.getMessages()).dataPayload(MessagesPayload.self) else {
            return
        }
        let messages = payload.messages
        isReloading = true
        let changed = await Task.detached(priority: .userInitiated) { [store] in
            store.rebuild(from: messages)
        }.value
        isReloading = false
        if changed {
            onTranscriptChange?()
        }
        await refreshContextStats()
    }
}

// MARK: - Small decode helpers

private struct LevelBox: Decodable { let level: String? }

private extension RPCFrame {
    func levelText() -> String? {
        (try? decode(LevelBox.self))?.level
    }
}

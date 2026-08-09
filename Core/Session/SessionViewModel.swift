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
    /// The last send/prompt failure (preflight errors, auth failures, …), shown
    /// as a dismissible error banner above the prompt bar. Cleared on the next
    /// successful send. Set by the view layer (SessionContent's dismiss button).
    public var lastError: String?
    public private(set) var isStreaming = false
    public private(set) var model: ModelInfo?
    public private(set) var availableModels: [ModelInfo] = []
    public private(set) var thinkingLevel: String?
    public private(set) var availableThinkingLevels: [String] = []
    /// Context-window usage (percentage of the model's context window in use),
    /// refreshed from `get_session_stats`. Polled continuously while a turn is
    /// streaming so the readout tracks the live context; refreshed once more
    /// when the turn settles. Read by the status readout in the prompt bar.
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
    /// Periodic `get_session_stats` poller while the agent is streaming. pi has
    /// no event that pushes context usage, so the client polls: `get_session_stats`
    /// is a synchronous estimate on the agent side and the RPC loop interleaves
    /// it with event streaming, so a 2s cadence costs ~nothing while keeping the
    /// readout live. Started on the first turn-start and stopped on settle (the
    /// true end of work — not `agent_end`/`turn_end`, which also fire between
    /// tool rounds).
    private static let contextPollInterval: Duration = .seconds(2)
    private var contextPollTask: Task<Void, Never>?

    public init(cwd: URL, executable: String? = nil, projectsRoot: URL? = nil) {
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
        // The RPC endpoint: the local pi executable spawned as `pi --mode rpc`.
        // Read from the settings (default: pi resolved from PATH), overridable
        // programmatically for tests.
        let exec = executable ?? RPCEndpointSettings.load().executablePath
        self.controller = ProcessController(
            executablePath: exec,
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
        // No defaults are forced at spawn: the session starts exactly as it
        // would in the terminal TUI — pi applies its own settings
        // (defaultProvider / defaultModel / defaultThinkingLevel) at spawn
        // and the app reads the live model + thinking level from get_state
        // and events. Never switching the model or thinking level behind the
        // user's back keeps the requests the session produces — and thus the
        // provider-side prompt cache — identical whether the session is
        // driven from the app or the TUI.
        // Switching the model can change which thinking levels it supports, so
        // re-fetch the runtime options (models + levels) for the status bar.
        await refreshRuntimeOptions()
        await refreshContextStats()
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        stopContextPolling()
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
            startContextPolling()
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
            stopContextPolling()
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
        do {
            let response = try await controller.send(.prompt(message: trimmed))
            if response.success == false {
                throw ProcessError.commandFailed(response.error ?? "prompt rejected")
            }
            lastError = nil
        } catch {
            // Surface send failures (auth/preflight/network) to the UI instead
            // of silently swallowing them.
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
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

    /// Refreshes the context-window usage percentage from `get_session_stats`.
    public func refreshContextStats() async {
        guard connectionState == .connected else { return }
        guard let payload = try? await controller.send(.getSessionStats()).dataPayload(SessionStatsPayload.self) else {
            return
        }
        contextUsage = payload.contextUsage
    }

    /// Starts the continuous context-usage poller (idempotent). Runs until
    /// `stopContextPolling()` — on `agent_settled` or session teardown.
    private func startContextPolling() {
        guard contextPollTask == nil else { return }
        contextPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshContextStats()
                do {
                    try await Task.sleep(for: Self.contextPollInterval)
                } catch {
                    return // cancelled — the loop is done
                }
            }
        }
    }

    private func stopContextPolling() {
        contextPollTask?.cancel()
        contextPollTask = nil
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

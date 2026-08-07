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
    public let controller: PiProcessController

    /// AppKit-side hook: the transcript coordinator sets this and is called on
    /// the main actor whenever the store has mutated. The SwiftUI body
    /// deliberately never reads the transcript entries, so a streamed delta
    /// does not touch the SwiftUI graph at all — updates flow store → AppKit
    /// directly.
    public var onTranscriptChange: (() -> Void)?

    private var eventTask: Task<Void, Never>?

    public init(cwd: URL, executable: String = PiExecutable.resolve()) {
        self.cwd = cwd
        self.controller = PiProcessController(
            executablePath: executable,
            arguments: ["--mode", "rpc"],
            workingDirectory: cwd.path
        )
    }

    // MARK: - Lifecycle

    public func start() async {
        guard eventTask == nil else { return }
        await controller.start()
        eventTask = Task { [weak self] in
            await self?.consumeEvents()
        }
        await refreshState()
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await controller.terminate()
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
        case "agent_end", "turn_end", "agent_settled":
            isStreaming = false

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

    public func sendPrompt(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let response = try await controller.send(.prompt(message: trimmed))
        if response.success == false {
            throw PiError.commandFailed(response.error ?? "prompt rejected")
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

    private func refreshState() async {
        guard let payload = try? await controller.send(.getState()).dataPayload(SessionStatePayload.self) else {
            connectionState = .disconnected("no response from pi")
            return
        }
        model = payload.model
        thinkingLevel = payload.thinkingLevel
        if let file = payload.sessionFile { sessionFile = URL(fileURLWithPath: file) }
        sessionName = payload.sessionName
        isStreaming = payload.isStreaming ?? false
        connectionState = .connected
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
    }
}

// MARK: - Small decode helpers

private struct LevelBox: Decodable { let level: String? }

private extension RPCFrame {
    func levelText() -> String? {
        (try? decode(LevelBox.self))?.level
    }
}

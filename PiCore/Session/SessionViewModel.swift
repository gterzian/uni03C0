import Foundation
import Observation

/// One session's observable state, populated purely by folding incoming RPC
/// frames. The event stream is the single source of truth — nothing is
/// hand-maintained in parallel.
///
/// Owns a `PiProcessController` (one per window) and bridges the actor's
/// frame stream onto the main actor.
@MainActor
@Observable
public final class SessionViewModel {
    public enum ConnectionState: Equatable {
        case starting
        case connected
        case disconnected(String)
    }

    public private(set) var connectionState: ConnectionState = .starting
    public private(set) var entries: [TranscriptEntry] = []
    public private(set) var isStreaming = false
    public private(set) var model: ModelInfo?
    public private(set) var availableModels: [ModelInfo] = []
    public private(set) var thinkingLevel: String?
    public private(set) var availableThinkingLevels: [String] = []
    public private(set) var sessionFile: URL?
    public private(set) var sessionName: String?

    public let cwd: URL
    public let controller: PiProcessController

    /// AppKit-side hook: the transcript coordinator sets this and is called on
    /// the main actor whenever `entries` has been mutated. The SwiftUI body
    /// deliberately never reads `entries`, so a streamed delta does not touch
    /// the SwiftUI graph at all — updates flow model → AppKit directly.
    public var onTranscriptChange: (() -> Void)?

    private var eventTask: Task<Void, Never>?
    private var streamingEntryID: String?

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
                fold(frame)
            }
            if connectionState != .disconnected("") {
                connectionState = .disconnected("agent process exited")
            }
        } catch {
            connectionState = .disconnected(error.localizedDescription)
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

    public func loadMessages() async {
        guard let payload = try? await controller.send(.getMessages()).dataPayload(MessagesPayload.self) else {
            return
        }
        rebuildEntries(from: payload.messages)
        onTranscriptChange?()
    }

    // MARK: - Event folding

    private func fold(_ frame: RPCFrame) {
        switch frame.type {
        case "response":
            break // matched responses consumed by send(); stray responses ignored        case "agent_start", "turn_start":
            isStreaming = true
        case "agent_end", "turn_end", "agent_settled":
            isStreaming = false

        case "message_start":
            if let message = frame.decodeMessage() { beginMessage(message) }
        case "message_end":
            if let message = frame.decodeMessage(), message.role == "assistant" {
                finalizeAssistant(message)
            }
        case "message_update":
            if let event = frame.decodeAssistantEvent() { applyAssistantEvent(event) }

        case "tool_execution_start":
            if let start = frame.decodeToolStart() { beginToolCall(start) }
        case "tool_execution_update":
            if let update = frame.decodeToolUpdate() { updateToolCall(update) }
        case "tool_execution_end":
            if let end = frame.decodeToolEnd() { endToolCall(end) }

        case "bash_execution_update":
            if let delta = frame.deltaText() { appendBashOutput(id: frame.id, delta: delta) }

        case "thinking_level_changed":
            if let level = frame.levelText() { thinkingLevel = level }

        case "model_changed":
            if let model = frame.decodeModelChange() { self.model = model }

        case "stderr":
            // Diagnostics only; could surface in a debug overlay later.
            break

        default:
            break // compaction/queue/extension events: not surfaced in v1
        }
        onTranscriptChange?()
    }

    private func beginMessage(_ message: AgentMessage) {
        let blocks = message.content ?? []
        if message.role == "user" {
            let text = blocks
                .filter { $0.type == "text" }
                .compactMap { $0.text }
                .joined(separator: "\n\n")
            if !text.isEmpty {
                entries.append(TranscriptEntry(id: message.id ?? makeID("user"), kind: .userMessage(text: text)))
            }
        } else if message.role == "toolResult" {
            // openai-completions providers deliver tool results as separate
            // messages; attach to the matching execution card.
            let text = blocks.compactMap { $0.text }.joined(separator: "\n")
            attachToolResult(id: message.toolCallId, name: message.toolName, text: text, failed: message.isError ?? false)
        } else if message.role == "assistant" {
            let text = blocks.filter { $0.type == "text" }.compactMap { $0.text }.joined(separator: "\n\n")
            let thinking = blocks.filter { $0.type == "thinking" }.compactMap { $0.thinking }.joined(separator: "\n")
            let id = message.id ?? makeID("assistant")
            entries.append(TranscriptEntry(id: id, kind: .assistantMessage(text: text, thinking: thinking, isStreaming: true)))
            streamingEntryID = id
        }
    }

    private func applyAssistantEvent(_ event: AssistantMessageEvent) {
        guard let id = streamingEntryID,
              let index = entries.lastIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        guard case .assistantMessage(let text, let thinking, let isStreaming) = entry.kind else { return }

        if event.isText {
            if event.type == "text_start" || event.type == "text_delta" {
                entry.kind = .assistantMessage(text: text + (event.delta ?? ""), thinking: thinking, isStreaming: isStreaming)
            } else if event.type == "text_end", let content = event.content {
                entry.kind = .assistantMessage(text: content, thinking: thinking, isStreaming: isStreaming)
            }
        } else if event.isThinking {
            if event.type == "thinking_start" || event.type == "thinking_delta" {
                entry.kind = .assistantMessage(text: text, thinking: thinking + (event.delta ?? ""), isStreaming: isStreaming)
            } else if event.type == "thinking_end", let content = event.content {
                entry.kind = .assistantMessage(text: text, thinking: content, isStreaming: isStreaming)
            }
        }
        entries[index] = entry
    }

    private func finalizeAssistant(_ message: AgentMessage) {
        guard let id = streamingEntryID,
              let index = entries.lastIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        guard case .assistantMessage(_, _, _) = entry.kind else { return }
        let blocks = message.content ?? []
        let text = blocks.filter { $0.type == "text" }.compactMap { $0.text }.joined(separator: "\n\n")
        let thinking = blocks.filter { $0.type == "thinking" }.compactMap { $0.thinking }.joined(separator: "\n")
        entry.kind = .assistantMessage(text: text, thinking: thinking, isStreaming: false)
        entries[index] = entry
        streamingEntryID = nil
    }

    private func beginToolCall(_ start: ToolExecutionStart) {
        let id = start.toolCallId ?? makeID("tool")
        let card = ToolCallCard(
            id: id,
            toolName: start.toolName ?? "tool",
            arguments: start.args?.prettyPrinted() ?? "",
            state: .running
        )
        entries.append(TranscriptEntry(id: id, kind: .toolCall(card: card)))
    }

    private func updateToolCall(_ update: ToolExecutionUpdate) {
        guard let id = update.toolCallId,
              let index = entries.lastIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        guard case .toolCall(var card) = entry.kind else { return }
        card.output = update.partialResult?.textContent() ?? card.output
        entry.kind = .toolCall(card: card)
        entries[index] = entry
    }

    private func endToolCall(_ end: ToolExecutionEnd) {
        guard let id = end.toolCallId,
              let index = entries.lastIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        guard case .toolCall(var card) = entry.kind else { return }
        card.output = end.result?.textContent() ?? card.output
        card.state = (end.isError ?? false) ? .failed : .done
        entry.kind = .toolCall(card: card)
        entries[index] = entry
    }

    private func attachToolResult(id: String?, name: String?, text: String, failed: Bool) {
        guard let id,
              let index = entries.lastIndex(where: {
                  if case .toolCall(let card) = $0.kind { return card.id == id }
                  return false
              }) else {
            // No execution card yet (e.g. resumed history): create one.
            if let id {
                var card = ToolCallCard(id: id, toolName: name ?? "tool", arguments: "")
                card.output = text
                card.state = failed ? .failed : .done
                entries.append(TranscriptEntry(id: id, kind: .toolCall(card: card)))
            }
            return
        }
        var entry = entries[index]
        entry.attachToolOutput(text, failed: failed)
        entries[index] = entry
    }

    private func appendBashOutput(id: String?, delta: String) {
        if let id, let index = entries.lastIndex(where: { $0.id == id }) {
            var entry = entries[index]
            guard case .toolCall(var card) = entry.kind else { return }
            card.output += delta
            entry.kind = .toolCall(card: card)
            entries[index] = entry
        } else {
            // Lazily create a card for direct bash commands (not used by v1 UI).
            let cardID = id ?? makeID("bash")
            var card = ToolCallCard(id: cardID, toolName: "bash", arguments: "")
            card.output = delta
            entries.append(TranscriptEntry(id: cardID, kind: .toolCall(card: card)))
        }
    }

    // MARK: - History rebuild (get_messages)

    private func rebuildEntries(from messages: [AgentMessage]) {
        var result: [TranscriptEntry] = []
        // tool_use ids in order, for attaching subsequent tool_result blocks.
        var pendingToolCalls: [String] = []

        for message in messages {
            let blocks = message.content ?? []
            if message.role == "user" {
                var texts: [String] = []
                var results: [(id: String?, text: String)] = []
                for block in blocks {
                    if block.isToolResult {
                        results.append((block.toolCallId, block.resultText()))
                    } else if block.type == "text" {
                        texts.append(block.text ?? "")
                    }
                }
                if !texts.isEmpty {
                    result.append(TranscriptEntry(id: message.id ?? makeID("user"), kind: .userMessage(text: texts.joined(separator: "\n\n"))))
                }
                for (id, text) in results {
                    if let id, let index = result.lastIndex(where: {
                        if case .toolCall(let card) = $0.kind { return card.id == id }
                        return false
                    }) {
                        result[index].attachToolOutput(text)
                    } else if let last = pendingToolCalls.last,
                              let index = result.lastIndex(where: {
                                  if case .toolCall(let card) = $0.kind { return card.id == last }
                                  return false
                              }) {
                        result[index].attachToolOutput(text)
                    }
                }
            } else if message.role == "assistant" {
                // Flatten content blocks in order: text/thinking entries and
                // tool-call cards, preserving interleaving.
                for block in blocks {
                    switch block.type {
                    case "text":
                        let text = block.text ?? ""
                        if !text.isEmpty {
                            result.append(TranscriptEntry(id: message.id.map { "\($0)-text" } ?? makeID("assistant"), kind: .assistantMessage(text: text, thinking: "", isStreaming: false)))
                        }
                    case "thinking":
                        let thinking = block.thinking ?? ""
                        if !thinking.isEmpty {
                            result.append(TranscriptEntry(id: message.id.map { "\($0)-think" } ?? makeID("assistant"), kind: .assistantMessage(text: "", thinking: thinking, isStreaming: false)))
                        }
                    case "tool_use", "toolCall", "tool_call":
                        let cardID = block.id ?? makeID("tool")
                        let card = ToolCallCard(
                            id: cardID,
                            toolName: block.name ?? "tool",
                            arguments: block.toolArgumentsPretty(),
                            state: .done
                        )
                        result.append(TranscriptEntry(id: cardID, kind: .toolCall(card: card)))
                        pendingToolCalls.append(cardID)
                    default:
                        break
                    }
                }
            } else if message.role == "toolResult" {
                // Attach the output to the matching tool-call card (by id).
                let text = blocks.compactMap { $0.text }.joined(separator: "\n")
                let failed = message.isError ?? false
                if let id = message.toolCallId,
                   let index = result.lastIndex(where: {
                       if case .toolCall(let card) = $0.kind { return card.id == id }
                       return false
                   }) {
                    result[index].attachToolOutput(text, failed: failed)
                } else if !text.isEmpty {
                    // No matching card (e.g. card ids differ across providers):
                    // attach to the most recent tool call.
                    if let last = pendingToolCalls.last,
                       let index = result.lastIndex(where: {
                           if case .toolCall(let card) = $0.kind { return card.id == last }
                           return false
                       }) {
                        result[index].attachToolOutput(text, failed: failed)
                    }
                }
            }
        }
        entries = result
        streamingEntryID = nil
    }

    private var counter: UInt64 = 0
    private func makeID(_ prefix: String) -> String {
        counter &+= 1
        return "\(prefix)-\(counter)-\(UInt64(Date().timeIntervalSince1970 * 1000))"
    }
}

// MARK: - Small decode helpers

private struct DeltaBox: Decodable { let delta: String? }
private struct LevelBox: Decodable { let level: String? }

private extension RPCFrame {
    func deltaText() -> String? {
        (try? decode(DeltaBox.self))?.delta
    }

    func levelText() -> String? {
        (try? decode(LevelBox.self))?.level
    }
}

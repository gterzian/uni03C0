import Foundation

/// Owns the FULL ordered transcript, independent of any rendering concern.
///
/// pi's event stream is append-only, so every mutation happens at the tail:
/// either a row is appended (a new message / tool card) or the last row grows
/// in place (streaming text, tool output). This store therefore needs no
/// index-based diffing — a change is always "something at the end changed",
/// and the renderer decides whether to bother pulling it.
///
/// The store lives off the main thread (lock-guarded; PiCore is nonisolated).
/// The UI thread only ever *pulls* the windowed slices it needs, and never
/// folds, rebuilds, or holds the whole history. `boundingRect`-style height
/// measurement is deliberately NOT here: it lives in the app layer (PiMacApp)
/// where the `TranscriptText`/`TextRowView` renderers are, so PiCore stays free
/// of AppKit. The store's only measurement role is to own the mutable entry
/// list the render side keys its height cache on.
public final class TranscriptStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [TranscriptEntry] = []
    /// Bumped on every tail mutation (append or in-place change).
    private var _version: UInt64 = 0
    /// Bumped only on a wholesale rebuild (session switch). The renderer uses
    /// this to detect "rows were replaced, do a full reload", as opposed to
    /// "rows were appended, do incremental inserts".
    private var _generation: UInt64 = 0

    // Live-streaming state (meaningless after a rebuild).
    private var streamingEntryID: String?
    private var counter: UInt64 = 0

    public init() {}

    // MARK: - Read API (any thread, cheap, lock-guarded)

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _entries.count
    }

    /// The tail-mutation generation. Changes to `_version` mean "append or
    /// in-place edit at the end"; changes to `_generation` mean "everything
    /// was replaced".
    public var currentVersion: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _version
    }

    public var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _generation
    }

    public func entry(at index: Int) -> TranscriptEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard _entries.indices.contains(index) else { return nil }
        return _entries[index]
    }

    public func entries(in range: Range<Int>) -> [TranscriptEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard range.lowerBound >= 0, range.lowerBound < _entries.count else { return [] }
        let clamped = range.clamped(to: _entries.indices)
        return Array(_entries[clamped])
    }

    // MARK: - Off-main entry points

    /// Folds one RPC frame into the transcript. Returns true if it mutated the
    /// transcript (i.e. the renderer should be notified).
    @discardableResult
    public func apply(_ frame: RPCFrame) -> Bool {
        var changed = false
        switch frame.type {
        case "message_start":
            if let message = frame.decodeMessage() { beginMessage(message); changed = true }
        case "message_end":
            if let message = frame.decodeMessage(), message.role == "assistant" {
                finalizeAssistant(message)
                changed = true
            }
        case "message_update":
            if let event = frame.decodeAssistantEvent() { applyAssistantEvent(event); changed = true }

        case "tool_execution_start":
            if let start = frame.decodeToolStart() { beginToolCall(start); changed = true }
        case "tool_execution_update":
            if let update = frame.decodeToolUpdate() { updateToolCall(update); changed = true }
        case "tool_execution_end":
            if let end = frame.decodeToolEnd() { endToolCall(end); changed = true }

        case "bash_execution_update":
            if let delta = frame.deltaText() { appendBashOutput(id: frame.id, delta: delta); changed = true }

        default:
            break // response/compaction/queue/extension frames: not surfaced in v1
        }
        if changed {
            lock.lock()
            _version &+= 1
            lock.unlock()
        }
        return changed
    }

    /// Rebuilds the whole transcript from a `get_messages` response (session
    /// switch / resume / reload). Called off the main thread.
    @discardableResult
    public func rebuild(from messages: [AgentMessage]) -> Bool {
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

        lock.lock()
        _entries = result
        _version &+= 1
        _generation &+= 1
        streamingEntryID = nil
        lock.unlock()
        return true
    }

    // MARK: - Live folding helpers (lock held by caller)

    private func beginMessage(_ message: AgentMessage) {
        let blocks = message.content ?? []
        if message.role == "user" {
            let text = blocks
                .filter { $0.type == "text" }
                .compactMap { $0.text }
                .joined(separator: "\n\n")
            if !text.isEmpty {
                _entries.append(TranscriptEntry(id: message.id ?? makeID("user"), kind: .userMessage(text: text)))
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
            _entries.append(TranscriptEntry(id: id, kind: .assistantMessage(text: text, thinking: thinking, isStreaming: true)))
            streamingEntryID = id
        }
    }

    private func applyAssistantEvent(_ event: AssistantMessageEvent) {
        guard let id = streamingEntryID,
              let index = _entries.lastIndex(where: { $0.id == id }) else { return }
        var entry = _entries[index]
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
        _entries[index] = entry
    }

    private func finalizeAssistant(_ message: AgentMessage) {
        guard let id = streamingEntryID,
              let index = _entries.lastIndex(where: { $0.id == id }) else { return }
        var entry = _entries[index]
        guard case .assistantMessage(_, _, _) = entry.kind else { return }
        let blocks = message.content ?? []
        let text = blocks.filter { $0.type == "text" }.compactMap { $0.text }.joined(separator: "\n\n")
        let thinking = blocks.filter { $0.type == "thinking" }.compactMap { $0.thinking }.joined(separator: "\n")
        entry.kind = .assistantMessage(text: text, thinking: thinking, isStreaming: false)
        _entries[index] = entry
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
        _entries.append(TranscriptEntry(id: id, kind: .toolCall(card: card)))
    }

    private func updateToolCall(_ update: ToolExecutionUpdate) {
        guard let id = update.toolCallId,
              let index = _entries.lastIndex(where: { $0.id == id }) else { return }
        var entry = _entries[index]
        guard case .toolCall(var card) = entry.kind else { return }
        card.output = update.partialResult?.textContent() ?? card.output
        entry.kind = .toolCall(card: card)
        _entries[index] = entry
    }

    private func endToolCall(_ end: ToolExecutionEnd) {
        guard let id = end.toolCallId,
              let index = _entries.lastIndex(where: { $0.id == id }) else { return }
        var entry = _entries[index]
        guard case .toolCall(var card) = entry.kind else { return }
        card.output = end.result?.textContent() ?? card.output
        card.state = (end.isError ?? false) ? .failed : .done
        entry.kind = .toolCall(card: card)
        _entries[index] = entry
    }

    private func attachToolResult(id: String?, name: String?, text: String, failed: Bool) {
        guard let id,
              let index = _entries.lastIndex(where: {
                  if case .toolCall(let card) = $0.kind { return card.id == id }
                  return false
              }) else {
            // No execution card yet (e.g. resumed history): create one.
            if let id {
                var card = ToolCallCard(id: id, toolName: name ?? "tool", arguments: "")
                card.output = text
                card.state = failed ? .failed : .done
                _entries.append(TranscriptEntry(id: id, kind: .toolCall(card: card)))
            }
            return
        }
        var entry = _entries[index]
        entry.attachToolOutput(text, failed: failed)
        _entries[index] = entry
    }

    private func appendBashOutput(id: String?, delta: String) {
        if let id, let index = _entries.lastIndex(where: { $0.id == id }) {
            var entry = _entries[index]
            guard case .toolCall(var card) = entry.kind else { return }
            card.output += delta
            entry.kind = .toolCall(card: card)
            _entries[index] = entry
        } else {
            // Lazily create a card for direct bash commands (not used by v1 UI).
            let cardID = id ?? makeID("bash")
            var card = ToolCallCard(id: cardID, toolName: "bash", arguments: "")
            card.output = delta
            _entries.append(TranscriptEntry(id: cardID, kind: .toolCall(card: card)))
        }
    }

    private func makeID(_ prefix: String) -> String {
        counter &+= 1
        return "\(prefix)-\(counter)-\(UInt64(Date().timeIntervalSince1970 * 1000))"
    }
}

// MARK: - Small decode helpers

private struct DeltaBox: Decodable { let delta: String? }

private extension RPCFrame {
    func deltaText() -> String? {
        (try? decode(DeltaBox.self))?.delta
    }
}

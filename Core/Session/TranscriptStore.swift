import Foundation

/// Owns the FULL ordered transcript, independent of any rendering concern.
///
/// pi's event stream is append-only, so every mutation happens at the tail:
/// either a row is appended (a new message / tool card) or the last row grows
/// in place (streaming text, tool output). This store therefore needs no
/// index-based diffing — a change is always "something at the end changed",
/// and the renderer decides whether to bother pulling it.
///
/// The store lives off the main thread (lock-guarded; Core is nonisolated).
/// The UI thread only ever *pulls* the windowed slices it needs, and never
/// folds, rebuilds, or holds the whole history. `boundingRect`-style height
/// measurement is deliberately NOT here: it lives in the app layer (Client)
/// where the `TranscriptText`/`TextRowView` renderers are, so Core stays free
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
    /// Id of the placeholder streaming row created on `turn_start` — immediate
    /// feedback (a pulsing caret) during time-to-first-token, before the real
    /// `message_start` has arrived.
    private var turnStartPlaceholderID: String?
    private var counter: UInt64 = 0

    // Per-turn cache accounting. The average is accumulated across every LLM
    // call of a turn (all the toolUse steps + the final answer) and attached to
    // the turn-ending row. The miss detector mirrors pi's `cache-stats.js`:
    // a step re-billed `min(prevPrompt, prompt) - cacheRead` tokens; a turn
    // whose any step re-billed more than `largeMissMinTokens` is flagged.
    private var turnInput = 0
    private var turnCacheRead = 0
    private var turnCacheWrite = 0
    private var turnHasLargeMiss = false
    /// Cross-turn miss detection state: the previous LLM request's prompt
    /// tokens. Deliberately NOT reset at turn boundaries — an idle gap between
    /// turns is exactly when the cache is evicted, and the first request of the
    /// new turn must compare against the previous turn's last request.
    private var lastPromptTokens = 0
    private var hasPreviousRequest = false
    /// A step whose request re-billed at least this many previously-cached
    /// tokens counts as a full (large) cache miss. Matches pi's cache-miss
    /// notice threshold (20k tokens).
    private static let largeMissMinTokens = 20_000

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
    ///
    /// The whole mutation runs under the lock: folding happens off the main
    /// thread (detached tasks) while the renderer reads on the main thread, so
    /// every write must be serialized against `entry(at:)`/`count`/… — not just
    /// the version bump.
    @discardableResult
    public func apply(_ frame: RPCFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
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

        case "agent_end", "turn_end":
            changed = endTurnPlaceholderOrFinalize()

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
            _version &+= 1
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

        // Turn cache accounting, rebuilt from the message history (the live
        // state is meaningless after a session switch). Locals: the rebuild
        // loop runs without the lock; instance state is synced at the end.
        var turnInput = 0
        var turnCacheRead = 0
        var turnCacheWrite = 0
        var turnHasLargeMiss = false
        // Cross-turn miss detection state, carried across user boundaries so
        // an idle gap between turns is detected (cache evicted -> next turn's
        // first request re-bills the whole prompt).
        var lastPromptTokens = 0
        var hasPreviousRequest = false

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
                // A new turn begins: fresh average, keep cross-turn miss state.
                turnInput = 0
                turnCacheRead = 0
                turnCacheWrite = 0
                turnHasLargeMiss = false
            } else if message.role == "assistant" {
                // Flatten content blocks in order: text/thinking entries and
                // tool-call cards, preserving interleaving.
                var lastTextEntryIndex: Int?
                for block in blocks {
                    switch block.type {
                    case "text":
                        let text = block.text ?? ""
                        if !text.isEmpty {
                            result.append(TranscriptEntry(id: message.id.map { "\($0)-text" } ?? makeID("assistant"), kind: .assistantMessage(text: text, thinking: "", isStreaming: false)))
                            lastTextEntryIndex = result.count - 1
                        }
                    case "thinking":
                        let thinking = block.thinking ?? ""
                        if !thinking.isEmpty {
                            result.append(TranscriptEntry(id: message.id.map { "\($0)-think" } ?? makeID("assistant"), kind: .assistantMessage(text: "", thinking: thinking, isStreaming: false)))
                            lastTextEntryIndex = result.count - 1
                        }
                    case "tool_use", "toolCall", "tool_call":
                        let cardID = block.id ?? makeID("tool")
                        let card = ToolCallCard(
                            id: cardID,
                            toolName: block.name ?? "tool",
                            arguments: block.toolArgumentsPretty(),
                            argumentsValue: block.toolArguments,
                            state: .done
                        )
                        result.append(TranscriptEntry(id: cardID, kind: .toolCall(card: card)))
                        pendingToolCalls.append(cardID)
                    default:
                        break
                    }
                }
                // Turn cache accounting: every step contributes; a step that
                // re-billed most of the previous prompt flags a large miss.
                if let usage = message.usage {
                    turnInput += usage.input ?? 0
                    turnCacheRead += usage.cacheRead ?? 0
                    turnCacheWrite += usage.cacheWrite ?? 0
                    let prompt = usage.promptTokens
                    if hasPreviousRequest, prompt > 0 {
                        let missed = min(lastPromptTokens, prompt) - (usage.cacheRead ?? 0)
                        if missed > Self.largeMissMinTokens {
                            turnHasLargeMiss = true
                        }
                    }
                    if prompt > 0 {
                        lastPromptTokens = prompt
                        hasPreviousRequest = true
                    }
                }
                // Cache read rate for the turn: attach the AGGREGATE rate to the
                // final response entry (the last text/thinking row), never a
                // tool-call turn. Requires real usage (aborted EMPTY_USAGE is
                // all zeros and must not attach a rate).
                if !blocks.contains(where: { $0.isToolCall }),
                   (message.usage?.promptTokens ?? 0) > 0,
                   let index = lastTextEntryIndex {
                    let total = turnInput + turnCacheRead + turnCacheWrite
                    if total > 0 {
                        result[index].cacheHitRate = Double(turnCacheRead) / Double(total)
                        result[index].cacheMiss = turnHasLargeMiss
                    }
                }
                // Surface stream failures recorded in the session (network
                // errors etc.) the same way live folding does.
                if let kind = Self.failureKind(for: message),
                   !blocks.contains(where: { $0.isToolCall }),
                   let messageID = message.id {
                    result.append(TranscriptEntry(id: "\(messageID)-error", kind: kind))
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
        turnStartPlaceholderID = nil
        // Carry the rebuilt history's cross-turn miss state into live folding:
        // the next request's miss detection must compare against the last
        // request in the history (an idle gap since then evicts the cache).
        // The turn totals reset — the next user message opens a new turn.
        self.lastPromptTokens = lastPromptTokens
        self.hasPreviousRequest = hasPreviousRequest
        resetTurnAccounting()
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
            // The user's message is echoed at the start of the turn — reserve
            // the response slot right below it so the client can show the
            // pulsing caret during time-to-first-token.
            beginTurnPlaceholder()
            // A new turn begins: fresh average, but keep the cross-turn
            // miss-detection state (idle gaps evict the cache).
            resetTurnAccounting()
        } else if message.role == "toolResult" {
            // openai-completions providers deliver tool results as separate
            // messages; attach to the matching execution card.
            let text = blocks.compactMap { $0.text }.joined(separator: "\n")
            attachToolResult(id: message.toolCallId, name: message.toolName, text: text, failed: message.isError ?? false)
        } else if message.role == "assistant" {
            let text = blocks.filter { $0.type == "text" }.compactMap { $0.text }.joined(separator: "\n\n")
            let thinking = blocks.filter { $0.type == "thinking" }.compactMap { $0.thinking }.joined(separator: "\n")
            let id = message.id ?? makeID("assistant")
            // Promote the turn-start placeholder (wherever it sits — always
            // right below the echoed user message) to the real message, so no
            // orphaned empty row is left blinking forever.
            if let placeholder = turnStartPlaceholderID,
               let index = _entries.lastIndex(where: { $0.id == placeholder }) {
                _entries[index] = TranscriptEntry(id: id, kind: .assistantMessage(text: text, thinking: thinking, isStreaming: true))
            } else {
                _entries.append(TranscriptEntry(id: id, kind: .assistantMessage(text: text, thinking: thinking, isStreaming: true)))
            }
            streamingEntryID = id
            turnStartPlaceholderID = nil
        }
    }

    private func applyAssistantEvent(_ event: AssistantMessageEvent) {
        if event.isToolCall {
            applyToolCallStreamEvent(event)
            return
        }
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
        // Turn cache accounting: every step (tool-use or final) contributes to
        // the turn average; a step that re-billed most of the previous prompt
        // flags a large miss.
        accumulateTurnUsage(message.usage)
        // The turn-ending message (no tool calls) carries the turn average —
        // the per-request rate of the final call alone would ignore the steps
        // that built the context. Requires real usage (promptTokens > 0): an
        // aborted turn's EMPTY_USAGE (all zeros) must not attach a rate.
        if !blocks.contains(where: { $0.isToolCall }), (message.usage?.promptTokens ?? 0) > 0 {
            entry.cacheHitRate = turnCacheHitRate
            entry.cacheMiss = turnHasLargeMiss
        }
        _entries[index] = entry
        streamingEntryID = nil
        turnStartPlaceholderID = nil
        // Surface stream failures (network errors, aborts, truncation) the way
        // the TUI does: an error row after the partial assistant message.
        appendFailureRowIfNeeded(for: message, blocks: blocks)
    }

    /// Accumulates one LLM request's usage into the current turn's totals and
    /// updates the large-miss flag against the previous request's prompt.
    private func accumulateTurnUsage(_ usage: TokenUsage?) {
        guard let usage else { return }
        turnInput += usage.input ?? 0
        turnCacheRead += usage.cacheRead ?? 0
        turnCacheWrite += usage.cacheWrite ?? 0
        let prompt = usage.promptTokens
        if hasPreviousRequest, prompt > 0 {
            let missed = min(lastPromptTokens, prompt) - (usage.cacheRead ?? 0)
            if missed > Self.largeMissMinTokens {
                turnHasLargeMiss = true
            }
        }
        if prompt > 0 {
            lastPromptTokens = prompt
            hasPreviousRequest = true
        }
    }

    /// The turn's aggregate cache hit rate (0–1): cache reads over the sum of
    /// every step's prompt tokens. Nil when the turn had no reported usage.
    private var turnCacheHitRate: Double? {
        let total = turnInput + turnCacheRead + turnCacheWrite
        guard total > 0 else { return nil }
        return Double(turnCacheRead) / Double(total)
    }

    /// Starts a new turn's cache accounting: zero the accumulated totals but
    /// KEEP the cross-turn miss-detection state (an idle gap between turns is
    /// exactly when the cache is evicted; the next turn's first step must
    /// compare against the previous turn's last request).
    private func resetTurnAccounting() {
        turnInput = 0
        turnCacheRead = 0
        turnCacheWrite = 0
        turnHasLargeMiss = false
    }

    /// Appends a notice row when a message ended in error/aborted/truncated
    /// (the stop reasons pi reports for failed LLM streams). Skipped when the
    /// message carries tool calls — their failures show in the cards.
    private func appendFailureRowIfNeeded(for message: AgentMessage, blocks: [ContentBlock]) {
        guard !blocks.contains(where: { $0.isToolCall }) else { return }
        guard let kind = Self.failureKind(for: message) else { return }
        let id = message.id ?? makeID("assistant")
        _entries.append(TranscriptEntry(id: "\(id)-error", kind: kind))
    }

    /// The TUI-equivalent failure/notice kind for a message's stop reason, or
    /// nil when the message ended normally. Wording matches
    /// `assistant-message.js`; severity is split so aborts (user-initiated)
    /// render weaker than hard failures:
    /// - "error" → errorMessage("Error: …") — a hard failure
    /// - "aborted" → abortedMessage(…) — user-initiated, not an error
    /// - "length" → errorMessage("Response was truncated before completion.")
    static func failureKind(for message: AgentMessage) -> TranscriptEntryKind? {
        switch message.stopReason {
        case "error":
            return .errorMessage("Error: \(message.errorMessage ?? "Unknown error")")
        case "aborted":
            let errorMessage = message.errorMessage
            if let errorMessage, errorMessage != "Request was aborted" {
                return .abortedMessage(errorMessage)
            }
            return .abortedMessage("Operation aborted")
        case "length":
            return .errorMessage("Response was truncated before completion.")
        default:
            return nil
        }
    }

    /// Reserves the response slot after the echoed user message: a placeholder
    /// streaming row whose caret gives feedback during time-to-first-token,
    /// promoted to the real message by `message_start` (assistant) or dropped
    /// by the turn end.
    private func beginTurnPlaceholder() {
        // Never while an assistant message is already streaming (steering
        // echoes mid-turn), and never two placeholders.
        if _entries.contains(where: { $0.kind.isStreaming }) { return }
        let id = makeID("turn-start")
        turnStartPlaceholderID = id
        _entries.append(TranscriptEntry(id: id, kind: .assistantMessage(text: "", thinking: "", isStreaming: true)))
    }

    /// The turn ended. If a placeholder never became a message (abort before
    /// `message_start`, extension command), drop it; otherwise finalize any
    /// assistant entry still marked streaming (abort mid-thinking).
    private func endTurnPlaceholderOrFinalize() -> Bool {
        if let placeholder = turnStartPlaceholderID,
           let index = _entries.lastIndex(where: { $0.id == placeholder }) {
            _entries.remove(at: index)
            turnStartPlaceholderID = nil
            return true
        }
        guard let index = _entries.lastIndex(where: { $0.kind.isStreaming }),
              case .assistantMessage(let text, let thinking, _) = _entries[index].kind else { return false }
        _entries[index].kind = .assistantMessage(text: text, thinking: thinking, isStreaming: false)
        turnStartPlaceholderID = nil
        return true
    }

    /// pi streams tool-call generation as `toolcall_start` / `toolcall_delta` /
    /// `toolcall_end` assistant-message events, well BEFORE `tool_execution_start`
    /// (which fires only once the tool actually begins running). In RPC mode the
    /// `message_update` envelope is stripped of the cumulative `message` and of
    /// the event's `partial` snapshot, so `toolcall_start`/`toolcall_delta` carry
    /// only a `contentIndex` — the call's id, name and arguments are unknowable
    /// until `toolcall_end`, which carries the completed call block. The card is
    /// therefore created at `toolcall_end` (real id + name + pretty args from the
    /// block): there is never a placeholder "tool" card, and `tool_execution_start`
    /// matches by the real id, so one card spans the whole call — the call shown
    /// first, the result appended into it as output arrives.
    private func applyToolCallStreamEvent(_ event: AssistantMessageEvent) {
        switch event.type {
        case "toolcall_start", "toolcall_delta":
            break // nothing renderable yet — everything arrives at toolcall_end
        case "toolcall_end":
            // The completed call block is the authoritative id/name/args source
            // (anthropic: input; openai-completions: arguments, maybe a string).
            guard let block = event.toolCall.flatMap(decodeToolCallBlock),
                  let callID = block.id ?? event.id else { return }
            let pretty = block.toolArgumentsPretty()
            if let index = _entries.lastIndex(where: { $0.id == callID }),
               case .toolCall(var card) = _entries[index].kind {
                // Defensive: the card already exists (re-run / late event) —
                // refresh name and args in place.
                card.toolName = block.name ?? card.toolName
                if !pretty.isEmpty { card.arguments = pretty }
                if let raw = block.toolArguments { card.argumentsValue = raw }
                _entries[index].kind = .toolCall(card: card)
            } else {
                _entries.append(TranscriptEntry(
                    id: callID,
                    kind: .toolCall(card: ToolCallCard(id: callID, toolName: block.name ?? "tool", arguments: pretty, argumentsValue: block.toolArguments))
                ))
            }
        default:
            break
        }
    }

    private func beginToolCall(_ start: ToolExecutionStart) {
        let id = start.toolCallId ?? makeID("tool")
        if let index = _entries.lastIndex(where: { $0.id == id }),
           case .toolCall(var card) = _entries[index].kind {
            // The card already exists from the streamed toolcall_* events:
            // swap in the final pretty-printed args, keep it running.
            card.arguments = start.args?.prettyPrinted() ?? card.arguments
            card.argumentsValue = start.args ?? card.argumentsValue
            card.toolName = start.toolName ?? card.toolName
            card.state = .running
            _entries[index].kind = .toolCall(card: card)
            return
        }
        let card = ToolCallCard(
            id: id,
            toolName: start.toolName ?? "tool",
            arguments: start.args?.prettyPrinted() ?? "",
            argumentsValue: start.args,
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

    private func appendBashOutput(id: String?, delta: String) {        if let id, let index = _entries.lastIndex(where: { $0.id == id }) {
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

    /// Decodes the `toolcall_end.toolCall` block (a JSONValue) into the client's
    /// tolerant content-block model, so anthropic `input` and openai
    /// `arguments` (object or JSON-encoded string) both normalize.
    private func decodeToolCallBlock(_ value: JSONValue) -> ContentBlock? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(ContentBlock.self, from: data)
    }
}

// MARK: - Small decode helpers

private struct DeltaBox: Decodable { let delta: String? }

private extension RPCFrame {
    func deltaText() -> String? {
        (try? decode(DeltaBox.self))?.delta
    }
}

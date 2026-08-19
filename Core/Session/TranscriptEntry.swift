import Foundation

/// One row in the transcript. Stable `id`s are the load-bearing property:
/// they let the diffable data source distinguish "this row's content changed
/// in place" (reconfigure) from "this is a new row" (insert), which is the
/// difference between an incremental height update and a full relayout.
public struct TranscriptEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public var kind: TranscriptEntryKind
    /// Cache read share (0–1) of the LLM requests that produced this turn, when
    /// the provider reported usage and the message ended a turn. Surfaced as a
    /// small cache line under the final assistant response.
    public var cacheHitRate: Double?
    /// True when any step of the turn re-billed the whole previous prompt (a
    /// full cache eviction) — highlighted separately in the cache line.
    public var cacheMiss: Bool

    public init(id: String, kind: TranscriptEntryKind, cacheHitRate: Double? = nil, cacheMiss: Bool = false) {
        self.id = id
        self.kind = kind
        self.cacheHitRate = cacheHitRate
        self.cacheMiss = cacheMiss
    }
}

public enum TranscriptEntryKind: Hashable, Sendable {
    case userMessage(text: String)
    case assistantMessage(text: String, thinking: String, isStreaming: Bool)
    case toolCall(card: ToolCallCard)
    /// A stream failure surfaced after the partial assistant message (network
    /// errors, provider failures, truncation) — styled red in the transcript,
    /// matching how the TUI renders `stopReason` failures.
    case errorMessage(String)
    /// A user- or system-initiated abort ("Operation aborted") — not a
    /// failure, so styled weaker than an error.
    case abortedMessage(String)

    public var isStreaming: Bool {
        if case .assistantMessage(_, _, let streaming) = self { return streaming }
        return false
    }
}

public enum ToolCallState: Hashable, Sendable {
    case running
    case done
    case failed

    public var label: String {
        switch self {
        case .running: "running…"
        case .done: "done"
        case .failed: "failed"
        }
    }
}

public struct ToolCallCard: Hashable, Sendable, Identifiable {
    public var id: String
    public var toolName: String
    /// Pretty-printed arguments for display (may be truncated).
    public var arguments: String
    /// The raw structured arguments, untruncated — the diff view (edit tool)
    /// parses this, never the display string.
    public var argumentsValue: JSONValue?
    public var output: String
    public var state: ToolCallState
    /// When the tool call started executing — live-stream cards only. Cards
    /// rebuilt from `get_messages` are already settled and carry no real
    /// start time (nil). The running bash card's per-second elapsed timer
    /// reads this.
    public var startedAt: Date?

    public init(id: String, toolName: String, arguments: String, argumentsValue: JSONValue? = nil, output: String = "", state: ToolCallState = .running, startedAt: Date? = nil) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.argumentsValue = argumentsValue
        self.output = output
        self.state = state
        self.startedAt = startedAt
    }
}

public extension TranscriptEntry {
    /// The searchable text of the row — everything a user could want to find:
    /// message text, thinking, tool name/args/output, error text. Joined with
    /// newlines so a query spanning fields still matches. Purely data (never
    /// rendered); the per-session search scans this, not the view window.
    var searchableText: String {
        switch kind {
        case .userMessage(let text):
            return text
        case .assistantMessage(let text, let thinking, _):
            return [thinking, text].filter { !$0.isEmpty }.joined(separator: "\n")
        case .toolCall(let card):
            return [card.toolName, card.arguments, card.output].filter { !$0.isEmpty }.joined(separator: "\n")
        case .errorMessage(let text), .abortedMessage(let text):
            return text
        }
    }

    /// Attaches tool-result output to a tool-call card (used when rebuilding
    /// history from `get_messages`, where tool results arrive as later
    /// user/toolResult messages).
    mutating func attachToolOutput(_ text: String, failed: Bool = false) {
        guard case .toolCall(var card) = kind else { return }
        if !text.isEmpty {
            card.output = text
        }
        card.state = failed ? .failed : .done
        kind = .toolCall(card: card)
    }
}

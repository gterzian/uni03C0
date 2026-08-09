import Foundation

/// One row in the transcript. Stable `id`s are the load-bearing property:
/// they let the diffable data source distinguish "this row's content changed
/// in place" (reconfigure) from "this is a new row" (insert), which is the
/// difference between an incremental height update and a full relayout.
public struct TranscriptEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public var kind: TranscriptEntryKind

    public init(id: String, kind: TranscriptEntryKind) {
        self.id = id
        self.kind = kind
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

    public init(id: String, toolName: String, arguments: String, argumentsValue: JSONValue? = nil, output: String = "", state: ToolCallState = .running) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.argumentsValue = argumentsValue
        self.output = output
        self.state = state
    }
}

public extension TranscriptEntry {
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

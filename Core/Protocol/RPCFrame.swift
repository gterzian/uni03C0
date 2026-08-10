import Foundation

/// A single decoded JSONL frame from the pi RPC process.
///
/// Only the top-level envelope is decoded eagerly. Command/event payloads are
/// decoded lazily into typed structs via the `decode*` helpers, which decode
/// from the raw `Data` so unknown fields are ignored (JSONDecoder behavior).
public struct RPCFrame: Sendable {
    public let raw: Data
    public let type: String
    public let id: String?
    public let command: String?
    public let success: Bool?
    public let error: String?

    /// The `data` field of a response frame, when present (lazy).
    public let data: JSONValue?

    public init(
        raw: Data,
        type: String,
        id: String?,
        command: String?,
        success: Bool?,
        error: String?,
        data: JSONValue? = nil
    ) {
        self.raw = raw
        self.type = type
        self.id = id
        self.command = command
        self.success = success
        self.error = error
        self.data = data
    }

    // MARK: Typed decoding

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: raw)
    }

    /// Decodes the `data` payload (response frames) into a typed struct.
    public func dataPayload<T: Decodable>(_ type: T.Type) -> T? {
        guard let data else { return nil }
        guard let encoded = try? JSONEncoder().encode(data) else { return nil }
        return try? JSONDecoder().decode(type, from: encoded)
    }

    public func decodeMessage() -> AgentMessage? {
        struct Box: Decodable { let message: AgentMessage }
        return try? decode(Box.self).message
    }

    public func decodeAssistantEvent() -> AssistantMessageEvent? {
        struct Box: Decodable { let assistantMessageEvent: AssistantMessageEvent }
        return try? decode(Box.self).assistantMessageEvent
    }

    public func decodeToolStart() -> ToolExecutionStart? {
        try? decode(ToolExecutionStart.self)
    }

    public func decodeToolUpdate() -> ToolExecutionUpdate? {
        try? decode(ToolExecutionUpdate.self)
    }

    public func decodeToolEnd() -> ToolExecutionEnd? {
        try? decode(ToolExecutionEnd.self)
    }

    public func decodeModelChange() -> ModelInfo? {
        struct Box: Decodable { let model: ModelInfo? }
        return (try? decode(Box.self))?.model
    }
}

// MARK: - Envelope

struct LightFrame: Decodable {
    let type: String
    let id: String?
    let command: String?
    let success: Bool?
    let error: String?
    let data: JSONValue?
}

// MARK: - Response payloads

public struct SessionStatePayload: Codable, Sendable, Equatable {
    public var model: ModelInfo?
    public var thinkingLevel: String?
    public var isStreaming: Bool?
    public var isCompacting: Bool?
    public var steeringMode: String?
    public var followUpMode: String?
    public var sessionFile: String?
    public var sessionId: String?
    public var sessionName: String?
    public var autoCompactionEnabled: Bool?
    public var messageCount: Int?
    public var pendingMessageCount: Int?
}

public struct ModelsPayload: Codable, Sendable, Equatable {
    public var models: [ModelInfo]
}

public struct LevelsPayload: Codable, Sendable, Equatable {
    public var levels: [String]
}

public struct MessagesPayload: Codable, Sendable, Equatable {
    public var messages: [AgentMessage]
}

/// The `contextUsage` slice of `SessionStats`, for the context-length status.
public struct ContextUsage: Codable, Sendable, Equatable {
    public var tokens: Int?
    public var contextWindow: Int?
    /// Percentage of the context window in use (0–100), or nil when unknown.
    public var percent: Double?
}

/// The `get_session_stats` response. Only `contextUsage` is surfaced; the rest
/// of `SessionStats` (token totals, cost, message counts) is ignored for now.
public struct SessionStatsPayload: Codable, Sendable, Equatable {
    public var contextUsage: ContextUsage?
}

public struct SwitchSessionPayload: Codable, Sendable, Equatable {
    public var cancelled: Bool?
}

// MARK: - Model

public struct ModelInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String?
    public var api: String?
    public var provider: String?
    public var baseUrl: String?
    public var reasoning: Bool?
    public var input: [String]?
    public var cost: JSONValue?
    public var contextWindow: Int?
    public var maxTokens: Int?
    public var compat: JSONValue?
}

// MARK: - Messages & content

public struct AgentMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: [ContentBlock]?
    public var id: String?
    /// openai-completions providers deliver tool results as separate messages
    /// with role "toolResult" carrying the originating call's id/name.
    public var toolCallId: String?
    public var toolName: String?
    public var isError: Bool?
    /// Token/cache accounting for the LLM request that produced this message
    /// (assistant messages). Surfaced as the per-turn cache read rate.
    public var usage: TokenUsage?
    public var timestamp: Int64?
    /// How the assistant response ended ("end", "error", "aborted", "length").
    /// Present on `message_end`/`turn_end` for assistant messages; the client
    /// surfaces `error`/`aborted`/`length` as transcript error rows.
    public var stopReason: String?
    /// The failure text carried with `stopReason == "error"` (network failures,
    /// provider errors, …) or "aborted".
    public var errorMessage: String?
}

/// Token/cache usage attached to an assistant message by the provider adapter
/// (`usage` on the finalized message). All fields optional: providers differ
/// in what they report, and the client only reads the cache split.
public struct TokenUsage: Codable, Sendable, Equatable {
    /// Prompt tokens billed at the uncached (input) rate.
    public var input: Int?
    public var output: Int?
    /// Prompt tokens served from the provider's context cache.
    public var cacheRead: Int?
    /// Prompt tokens written to the cache (cache-write premium, when billed).
    public var cacheWrite: Int?

    public init(input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil, cacheWrite: Int? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    /// Total prompt tokens billed for the request (uncached + cache read +
    /// cache write).
    public var promptTokens: Int {
        (input ?? 0) + (cacheRead ?? 0) + (cacheWrite ?? 0)
    }

    /// Cache read share of the full prompt (0–1), or nil when no usage/tokens.
    public var cacheHitRate: Double? {
        let read = cacheRead ?? 0
        let write = cacheWrite ?? 0
        let uncached = input ?? 0
        let total = read + write + uncached
        guard total > 0 else { return nil }
        return Double(read) / Double(total)
    }
}

/// A tolerant content block model. Provider formats differ (anthropic uses
/// `tool_use`/`input`, openai-completions uses `toolCall`/`arguments`), so all
/// variants are captured as optionals and normalized via helpers.
public struct ContentBlock: Codable, Sendable, Equatable {
    public var type: String
    public var text: String?
    public var id: String?
    public var name: String?
    public var input: JSONValue?
    public var arguments: JSONValue?
    public var thinking: String?
    public var toolCallId: String?
    public var content: JSONValue?

    public var isToolCall: Bool {
        type == "tool_use" || type == "toolCall" || type == "tool_call"
    }

    public var isToolResult: Bool { type == "tool_result" }

    public var toolArguments: JSONValue? {
        arguments ?? input
    }

    /// Arguments for display: `arguments`/`input` may be a JSON object or a
    /// JSON-encoded string (openai-completions providers send a string).
    public func toolArgumentsPretty(maxChars: Int = 2000) -> String {
        guard let raw = toolArguments else { return "" }
        if case .string(let s) = raw {
            if let data = s.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
                return parsed.prettyPrinted(maxChars: maxChars)
            }
            return String(s.prefix(maxChars))
        }
        return raw.prettyPrinted(maxChars: maxChars)
    }

    /// Extracts plain text from a tool_result content payload, which may be
    /// either an array of `{type: "text", text: "..."}` blocks or a bare string.
    public func resultText() -> String {
        guard let content else { return "" }
        switch content {
        case .array(let blocks):
            var parts: [String] = []
            for block in blocks {
                if case .object(let obj) = block,
                   case .string(let t)? = obj["text"] {
                    parts.append(t)
                } else if case .string(let s) = block {
                    parts.append(s)
                }
            }
            return parts.joined(separator: "\n")
        case .string(let s):
            return s
        default:
            return ""
        }
    }
}

// MARK: - Streaming deltas

public struct AssistantMessageEvent: Codable, Sendable, Equatable {
    public var type: String
    public var contentIndex: Int?
    public var delta: String?
    public var content: String?
    /// `toolcall_start` carries the call's id and tool name.
    public var id: String?
    public var toolName: String?
    /// `toolcall_end` carries the final tool-call block.
    public var toolCall: JSONValue?

    public var isText: Bool { type.hasPrefix("text_") }
    public var isThinking: Bool { type.hasPrefix("thinking_") }
    public var isToolCall: Bool { type.hasPrefix("toolcall_") }
}

// MARK: - Tool execution

public struct ToolExecutionStart: Codable, Sendable, Equatable {
    public var toolCallId: String?
    public var toolName: String?
    public var args: JSONValue?
}

public struct ToolExecutionUpdate: Codable, Sendable, Equatable {
    public var toolCallId: String?
    public var toolName: String?
    public var args: JSONValue?
    public var partialResult: ToolResultPayload?
}

public struct ToolExecutionEnd: Codable, Sendable, Equatable {
    public var toolCallId: String?
    public var toolName: String?
    public var args: JSONValue?
    public var result: ToolResultPayload?
    public var isError: Bool?
}

public struct ToolResultPayload: Codable, Sendable, Equatable {
    public var content: JSONValue?
    public var details: JSONValue?

    /// Accumulated text output (docs: partialResult contains the accumulated
    /// output so far, so display should replace, not append).
    public func textContent() -> String {
        guard let content else { return "" }
        switch content {
        case .array(let blocks):
            var parts: [String] = []
            for block in blocks {
                if case .object(let obj) = block,
                   case .string(let t)? = obj["text"] {
                    parts.append(t)
                } else if case .string(let s) = block {
                    parts.append(s)
                }
            }
            return parts.joined(separator: "\n")
        case .string(let s):
            return s
        default:
            return ""
        }
    }
}


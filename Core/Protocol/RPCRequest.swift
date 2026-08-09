import Foundation

/// An outgoing RPC command. Requests are JSONL objects with a `type` and an
/// optional client-generated `id` used for response correlation. Fields are
/// `JSONValue` (Sendable) so requests can cross actor boundaries.
public struct RPCRequest: Sendable {
    public var id: String?
    public var type: String
    public var fields: [String: JSONValue]

    public init(id: String? = nil, type: String, fields: [String: JSONValue] = [:]) {
        self.id = id
        self.type = type
        self.fields = fields
    }

    /// Encodes the request as JSON bytes, merging `type` and `id` with fields.
    /// Appends the LF terminator (JSONL framing).
    public func jsonData() throws -> Data {
        var object: [String: JSONValue] = ["type": .string(type)]
        if let id { object["id"] = .string(id) }
        for (key, value) in fields { object[key] = value }
        var data = try JSONEncoder().encode(JSONValue.object(object))
        data.append(0x0A)
        return data
    }
}

/// Convenience constructors for the commands the native client actually uses.
/// Field names verified against pi 0.84.1's RPC implementation.
public extension RPCRequest {
    static func getState() -> RPCRequest {
        RPCRequest(type: "get_state")
    }

    static func getMessages() -> RPCRequest {
        RPCRequest(type: "get_messages")
    }

    /// Cumulative token/cost/context statistics for the current session
    /// (`SessionStats` in pi's RPC). The client uses `contextUsage` to show the
    /// context-length percentage in the status bar.
    static func getSessionStats() -> RPCRequest {
        RPCRequest(type: "get_session_stats")
    }

    static func getAvailableModels() -> RPCRequest {
        RPCRequest(type: "get_available_models")
    }

    static func setModel(provider: String, modelId: String) -> RPCRequest {
        RPCRequest(type: "set_model", fields: ["provider": .string(provider), "modelId": .string(modelId)])
    }

    static func getAvailableThinkingLevels() -> RPCRequest {
        RPCRequest(type: "get_available_thinking_levels")
    }

    static func setThinkingLevel(level: String) -> RPCRequest {
        RPCRequest(type: "set_thinking_level", fields: ["level": .string(level)])
    }

    /// Send a user prompt. `streamingBehavior` ("steer" | "followUp") is
    /// required only when the agent is already streaming.
    static func prompt(message: String, streamingBehavior: String? = nil) -> RPCRequest {
        var fields: [String: JSONValue] = ["message": .string(message)]
        if let streamingBehavior { fields["streamingBehavior"] = .string(streamingBehavior) }
        return RPCRequest(type: "prompt", fields: fields)
    }

    static func abort() -> RPCRequest {
        RPCRequest(type: "abort")
    }

    /// Switch to a different session file. Field is `sessionPath` (verified —
    /// NOT `path`).
    static func switchSession(path: String) -> RPCRequest {
        RPCRequest(type: "switch_session", fields: ["sessionPath": .string(path)])
    }
}

/// Errors thrown by the process/protocol layer.
public enum ProcessError: Error, Sendable, LocalizedError {
    case processNotRunning
    case launchFailed(String)
    case disconnected
    case userTerminated
    case commandFailed(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .processNotRunning: "agent process is not running"
        case .launchFailed(let detail): "failed to launch the agent: \(detail)"
        case .disconnected: "agent process disconnected"
        case .userTerminated: "agent process terminated by user"
        case .commandFailed(let detail): "command failed: \(detail)"
        case .timeout(let detail): "timed out: \(detail)"
        }
    }
}

/// Resolves the `pi` executable the same way the terminal TUI uses it:
/// via PATH (global npm install). No bundling.
///
/// `pi` is the name of the underlying agent binary the app drives; the
/// executable lookup is the one place the app must know pi by name.
public enum PiExecutable {
    public static func resolve() -> String {
        let common = ["/opt/homebrew/bin/pi", "/usr/local/bin/pi"]
        for candidate in common
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") where !dir.isEmpty {
                let full = String(dir) + "/pi"
                if FileManager.default.isExecutableFile(atPath: full) {
                    return full
                }
            }
        }
        return common[0]
    }
}

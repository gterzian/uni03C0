import Foundation

/// Where the client finds its agent RPC endpoint: the executable the client
/// spawns as `pi --mode rpc` and speaks the JSONL RPC protocol to over
/// stdin/stdout. Persisted in UserDefaults so the user can point the client
/// at a different pi binary (e.g. a dev build) from the Settings page.
///
/// The default is the pi executable resolved from PATH (`PiExecutable.resolve`).
/// The setting is read once per session at spawn — a running session keeps the
/// endpoint it started with; new sessions (including new tabs) pick up the
/// current value.
public struct RPCEndpointSettings: Sendable, Equatable {
    public var executablePath: String

    public init(executablePath: String) {
        self.executablePath = executablePath
    }

    /// The pi executable found on PATH, or the first common install location.
    public static let defaults = RPCEndpointSettings(executablePath: PiExecutable.resolve())

    private static let executablePathKey = "rpc.executablePath"

    public static func load() -> RPCEndpointSettings {
        guard let stored = UserDefaults.standard.string(forKey: executablePathKey),
              !stored.isEmpty else {
            return defaults
        }
        return RPCEndpointSettings(executablePath: stored)
    }

    public func save() {
        UserDefaults.standard.set(executablePath, forKey: Self.executablePathKey)
    }
}

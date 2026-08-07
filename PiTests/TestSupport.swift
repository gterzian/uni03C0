import Foundation
import XCTest
@testable import PiCore

// MARK: - Test helpers

/// Builds an `RPCFrame` whose `raw` is the given JSON line and whose `type`
/// matches. Useful for feeding crafted frames into `TranscriptStore`.
func frame(type: String, _ json: String) -> RPCFrame {
    RPCFrame(raw: Data(json.utf8), type: type, id: nil, command: nil, success: nil, error: nil)
}

/// Skips an integration test when `pi` isn't installed, so the suite still runs
/// cleanly on machines without a pi install. pi manages its own auth (env vars
/// or its own config file), so no credential check here.
func requirePi() throws {
    let exe = PiExecutable.resolve()
    guard FileManager.default.isExecutableFile(atPath: exe) else {
        throw XCTSkip("pi executable not found at \(exe)")
    }
}

/// Thread-safe event accumulator for live-process tests (single producer task,
/// read after termination).
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(entry)
    }
    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

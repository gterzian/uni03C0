import Foundation
import XCTest
@testable import Core

// MARK: - Test helpers

/// Builds an `RPCFrame` whose `raw` is the given JSON line and whose `type`
/// matches. Useful for feeding crafted frames into `TranscriptStore` from
/// documented pi RPC behavior (no real process, no live model).
func frame(type: String, _ json: String) -> RPCFrame {
    RPCFrame(raw: Data(json.utf8), type: type, id: nil, command: nil, success: nil, error: nil)
}

/// Builds a `response` frame carrying a `data` payload, the shape pi returns
/// for a successful command. Used to mock command responses.
func response(command: String, dataJSON: String) -> RPCFrame {
    let raw = "{\"type\":\"response\",\"command\":\"\(command)\",\"success\":true,\"data\":\(dataJSON)}\n"
    let data = Data(raw.utf8)
    let light = try! JSONDecoder().decode(LightFrame.self, from: data)
    return RPCFrame(raw: data, type: light.type, id: light.id, command: light.command, success: light.success, error: light.error, data: light.data)
}

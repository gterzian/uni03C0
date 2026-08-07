import XCTest
@testable import PiCore

/// Tests for `RPCRequest` encoding — especially the field names that were
/// corrected empirically against a live pi (e.g. `sessionPath`, not `path`).
final class RequestEncodingTests: XCTestCase {

    private func decodeObject(_ data: Data) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let obj) = value else {
            XCTFail("expected object, got \(value)")
            return [:]
        }
        return obj
    }

    func testRequestsEndWithLF() {
        let data = try! RPCRequest.getState().jsonData()
        XCTAssertEqual(data.last, 0x0A)
    }

    func testGetStateHasTypeOnly() throws {
        let obj = try decodeObject(try RPCRequest.getState().jsonData())
        XCTAssertEqual(obj["type"], .string("get_state"))
        XCTAssertEqual(obj.count, 1)
    }

    func testPromptUsesMessageKey() throws {
        let obj = try decodeObject(try RPCRequest.prompt(message: "hello").jsonData())
        XCTAssertEqual(obj["type"], .string("prompt"))
        XCTAssertEqual(obj["message"], .string("hello"))
    }

    func testSwitchSessionUsesSessionPathKey() throws {
        // Empirically it's `sessionPath`, NOT `path`.
        let obj = try decodeObject(try RPCRequest.switchSession(path: "/tmp/s.json").jsonData())
        XCTAssertEqual(obj["type"], .string("switch_session"))
        XCTAssertEqual(obj["sessionPath"], .string("/tmp/s.json"))
        XCTAssertNil(obj["path"])
    }

    func testSetThinkingLevelUsesLevelKey() throws {
        let obj = try decodeObject(try RPCRequest.setThinkingLevel(level: "low").jsonData())
        XCTAssertEqual(obj["level"], .string("low"))
    }

    func testSetModelCarriesProviderAndId() throws {
        let obj = try decodeObject(try RPCRequest.setModel(provider: "p", modelId: "m").jsonData())
        XCTAssertEqual(obj["provider"], .string("p"))
        XCTAssertEqual(obj["modelId"], .string("m"))
    }
}

import XCTest
@testable import Core

/// Unit tests for `EditToolArgs` — decoding pi's edit-tool arguments
/// (`{path, edits:[{oldText,newText}]}`) into diffable operations.
final class EditToolArgsTests: XCTestCase {

    // MARK: - Structured (JSONValue) parsing

    func testParsesSingleEdit() {
        let value: JSONValue = [
            "path": "Sources/Main.swift",
            "edits": [
                ["oldText": "foo", "newText": "bar"]
            ]
        ]
        let ops = EditToolArgs.parse(value)
        XCTAssertEqual(ops, [EditOperation(path: "Sources/Main.swift", oldText: "foo", newText: "bar")])
    }

    func testParsesMultipleEditsPreservingOrder() {
        let value: JSONValue = [
            "path": "a.txt",
            "edits": [
                ["oldText": "one", "newText": "1"],
                ["oldText": "two", "newText": "2"],
            ]
        ]
        let ops = EditToolArgs.parse(value)
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(ops[0].newText, "1")
        XCTAssertEqual(ops[1].newText, "2")
        XCTAssertEqual(ops[1].path, "a.txt")
    }

    func testParsesMultilineOldAndNewText() {
        let value: JSONValue = [
            "path": "f.swift",
            "edits": [
                ["oldText": "line1\nline2", "newText": "line1\nchanged\nline2"]
            ]
        ]
        let ops = EditToolArgs.parse(value)
        XCTAssertEqual(ops.first?.oldText, "line1\nline2")
        XCTAssertEqual(ops.first?.newText, "line1\nchanged\nline2")
    }

    func testSkipsMalformedEditEntriesButKeepsValidOnes() {
        let value: JSONValue = [
            "path": "f.txt",
            "edits": [
                ["oldText": "a", "newText": "b"],
                ["oldText": "missing-new"],
                "not-an-object",
                ["oldText": 42, "newText": "x"], // wrong types
                ["oldText": "c", "newText": "d"],
            ]
        ]
        let ops = EditToolArgs.parse(value)
        XCTAssertEqual(ops.map(\.oldText), ["a", "c"])
    }

    func testEmptyEditsArrayYieldsEmpty() {
        let value: JSONValue = ["path": "f.txt", "edits": []]
        XCTAssertEqual(EditToolArgs.parse(value), [])
    }

    func testMissingShapeYieldsEmpty() {
        XCTAssertEqual(EditToolArgs.parse(nil), [])
        XCTAssertEqual(EditToolArgs.parse(.string("nope")), [])
        XCTAssertEqual(EditToolArgs.parse(["path": "f.txt"]), [])          // no edits
        XCTAssertEqual(EditToolArgs.parse(["edits": []]), [])              // no path
        XCTAssertEqual(EditToolArgs.parse(["path": 5, "edits": []]), [])   // path wrong type
    }

    func testIgnoresExtraFields() {
        let value: JSONValue = [
            "path": "f.txt",
            "edits": [["oldText": "a", "newText": "b"]],
            "unknown": "whatever",
        ]
        XCTAssertEqual(EditToolArgs.parse(value).count, 1)
    }

    // MARK: - String fallback

    func testParsesJSONStringForm() {
        let json = #"{"path":"f.txt","edits":[{"oldText":"a","newText":"b"}]}"#
        XCTAssertEqual(EditToolArgs.parse(json: json).count, 1)
    }

    func testStringFormWithUnicodeAndEscapes() {
        let json = #"{"path":"f.txt","edits":[{"oldText":"caf\u00e9","newText":"coffee"}]}"#
        let ops = EditToolArgs.parse(json: json)
        XCTAssertEqual(ops.first?.oldText, "café")
    }

    func testUnparseableStringYieldsEmpty() {
        XCTAssertEqual(EditToolArgs.parse(json: ""), [])
        XCTAssertEqual(EditToolArgs.parse(json: "not json"), [])
        // Truncated pretty print (the display path appends "…") — must not
        // crash, must yield [] so the card falls back to plain text.
        XCTAssertEqual(EditToolArgs.parse(json: #"{"path":"f.txt","edits":[{"oldText":"a","newText":"b"}]…"#), [])
    }
}

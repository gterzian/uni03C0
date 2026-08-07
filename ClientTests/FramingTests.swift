import XCTest
@testable import Core

/// Tests for `JSONLFramer` — the manual LF-only framing. The reason it's
/// hand-rolled is that the stdlib treats U+2028/U+2029 as line breaks, which
/// are legal inside JSON string payloads and would corrupt the stream.
final class FramingTests: XCTestCase {

    func testSplitsOnSingleLF() {
        var framer = JSONLFramer()
        let records = framer.feed(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        XCTAssertEqual(records.map { String(data: $0, encoding: .utf8) }, ["{\"a\":1}", "{\"b\":2}"])
    }

    func testMultipleRecordsInOneFeed() {
        var framer = JSONLFramer()
        let records = framer.feed(Data("a\nb\nc\n".utf8))
        XCTAssertEqual(records.map { String(data: $0, encoding: .utf8) }, ["a", "b", "c"])
    }

    func testAccumulatesPartialAcrossFeeds() {
        var framer = JSONLFramer()
        XCTAssertTrue(framer.feed(Data("hel".utf8)).isEmpty)
        let records = framer.feed(Data("lo\n".utf8))
        XCTAssertEqual(records.map { String(data: $0, encoding: .utf8) }, ["hello"])
    }

    func testStripsTrailingCRForCRLFInput() {
        var framer = JSONLFramer()
        let records = framer.feed(Data("one\r\ntwo\r\n".utf8))
        XCTAssertEqual(records.map { String(data: $0, encoding: .utf8) }, ["one", "two"])
    }

    func testDoesNotSplitOnUnicodeLineSeparator() {
        // U+2028/U+2029 are legal inside a JSON string; they must NOT end a record.
        let payload = "{\"x\":\"line\u{2028}separated\"}"
        var framer = JSONLFramer()
        let records = framer.feed(Data((payload + "\n").utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(String(data: records[0], encoding: .utf8), payload)
    }

    func testDrainReturnsTrailingPartialRecord() {
        var framer = JSONLFramer()
        _ = framer.feed(Data("hello\nworld".utf8)) // "world" has no newline
        let tail = framer.drain()
        XCTAssertEqual(tail.map { String(data: $0, encoding: .utf8) }, "world")
        XCTAssertNil(framer.drain()) // second drain is empty
    }
}

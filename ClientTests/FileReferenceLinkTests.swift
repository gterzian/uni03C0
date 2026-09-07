import XCTest
@testable import Core

/// Pure parsing of agent-emitted `pi-file://` reference links (`FileReferenceLink`):
/// scheme/path/fragment decoding and its tolerance rules. No AppKit, no
/// filesystem — everything here is a pure function of a URL.
final class FileReferenceLinkTests: XCTestCase {
    private func link(_ string: String) -> FileReferenceLink? {
        guard let url = URL(string: string) else {
            XCTFail("URL(string:) failed for \(string)")
            return nil
        }
        return FileReferenceLink(url: url)
    }

    // MARK: - Scheme + path

    func testParsesRelativePath() {
        let parsed = link("pi-file:///Core/Renderer.swift")
        XCTAssertEqual(parsed?.path, "Core/Renderer.swift")
        XCTAssertNil(parsed?.startLine)
        XCTAssertNil(parsed?.endLine)
    }

    func testRejectsForeignSchemes() {
        XCTAssertNil(link("https://example.com/Core/Renderer.swift"))
        XCTAssertNil(link("file:///Core/Renderer.swift"))
    }

    func testRejectsEmptyPath() {
        XCTAssertNil(link("pi-file:///"))
        XCTAssertNil(link("pi-file://"))
    }

    func testPercentEncodedPathIsDecoded() {
        // A filename with a space and parens — encoded per the skill's rules —
        // round-trips to the real path (URL.path percent-decodes).
        XCTAssertEqual(link("pi-file:///Sources/My%20File(2).swift")?.path, "Sources/My File(2).swift")
        // A literal # in a filename must be encoded or it starts the fragment.
        XCTAssertEqual(link("pi-file:///weird%23name.txt")?.path, "weird#name.txt")
    }

    // MARK: - Fragment lines

    func testSingleLineFragment() {
        let parsed = link("pi-file:///a.swift#L42")
        XCTAssertEqual(parsed?.path, "a.swift")
        XCTAssertEqual(parsed?.startLine, 42)
        XCTAssertEqual(parsed?.endLine, 42)
    }

    func testRangeFragment() {
        let parsed = link("pi-file:///a.swift#L42-50")
        XCTAssertEqual(parsed?.startLine, 42)
        XCTAssertEqual(parsed?.endLine, 50)
    }

    func testMissingOrMalformedFragmentIsTolerated() {
        // Missing → whole-file open (no scroll target).
        XCTAssertNil(link("pi-file:///a.swift#L")?.startLine)
        XCTAssertNil(link("pi-file:///a.swift#")?.startLine)
        // A range that never parses as numbers → no scroll target.
        XCTAssertNil(link("pi-file:///a.swift#Labc")?.startLine)
        XCTAssertNil(link("pi-file:///a.swift#Lx-42")?.startLine)
        // Lenient parses, so a reference still lands somewhere useful: a
        // backwards range opens at its start line, and a bare number (no L
        // prefix — the way an agent trained on GitHub URLs might write it) is
        // accepted as the line.
        XCTAssertEqual(link("pi-file:///a.swift#L50-42")?.startLine, 50)
        XCTAssertEqual(link("pi-file:///a.swift#42")?.startLine, 42)
    }

    // MARK: - Round-trip with the click pipeline

    func testLinkRenderedByMarkdownParsesBack() {
        // The exact shape the skill tells the agent to emit.
        let markdown = "[Core/Renderer.swift:118-126](pi-file:///Core/Renderer.swift#L118-126)"
        let link = URL(string: markdown.components(separatedBy: "](")[1].dropLast().description)
        let parsed = link.flatMap(FileReferenceLink.init(url:))
        XCTAssertEqual(parsed?.path, "Core/Renderer.swift")
        XCTAssertEqual(parsed?.startLine, 118)
        XCTAssertEqual(parsed?.endLine, 126)
    }

    func testConstructedLinkKeepsExplicitLines() {
        let parsed = FileReferenceLink(path: "Package.swift", startLine: 7, endLine: 7)
        XCTAssertEqual(parsed.path, "Package.swift")
        XCTAssertEqual(parsed.startLine, 7)
        XCTAssertEqual(parsed.endLine, 7)
    }
}

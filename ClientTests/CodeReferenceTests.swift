import XCTest
@testable import Core

/// Pure rendering of a `CodeReference` into prompt text (§1.1/§1.4). Paths
/// are fake (nonexistent) so no filesystem access is involved; both sides are
/// canonical on the test machine, so the relative math is deterministic.
final class CodeReferenceTests: XCTestCase {
    private func reference(path: String, start: Int, end: Int, snippet: String) -> CodeReference {
        CodeReference(absolutePath: path, startLine: start, endLine: end, snippet: snippet)
    }

    func testSameProjectRendersRelativeAnchorAndFence() {
        let reference = reference(
            path: "/Users/tester/proj/Core/Renderer.swift",
            start: 118, end: 126,
            snippet: "let x = 1\n"
        )
        let text = reference.promptText(relativeTo: URL(fileURLWithPath: "/Users/tester/proj"))
        XCTAssertEqual(
            text,
            "[Ref: Core/Renderer.swift:118-126]\n```swift\nlet x = 1\n```"
        )
    }

    func testCrossProjectWalksUp() {
        let reference = reference(
            path: "/Users/tester/OtherProject/Core/Renderer.swift",
            start: 3, end: 8,
            snippet: "func f() {}\n"
        )
        let text = reference.promptText(relativeTo: URL(fileURLWithPath: "/Users/tester/proj"))
        XCTAssertEqual(
            text,
            "[Ref: ../OtherProject/Core/Renderer.swift:3-8]\n```swift\nfunc f() {}\n```"
        )
    }

    func testSingleLineAnchorOmitsEndLine() {
        let reference = reference(
            path: "/Users/tester/proj/main.swift",
            start: 42, end: 42,
            snippet: "print(\"hi\")\n"
        )
        let text = reference.promptText(relativeTo: URL(fileURLWithPath: "/Users/tester/proj"))
        XCTAssertTrue(text.hasPrefix("[Ref: main.swift:42]\n"))
    }

    func testSnippetWithoutTrailingNewlineGetsOne() {
        let reference = reference(
            path: "/Users/tester/proj/f.swift",
            start: 1, end: 1,
            snippet: "no newline"
        )
        XCTAssertTrue(reference.promptText(relativeTo: URL(fileURLWithPath: "/Users/tester/proj")).hasSuffix("\n```"))
    }

    func testUnknownExtensionGetsUnlabeledFence() {
        let reference = reference(
            path: "/Users/tester/proj/notes.xyz",
            start: 1, end: 1,
            snippet: "raw"
        )
        let text = reference.promptText(relativeTo: URL(fileURLWithPath: "/Users/tester/proj"))
        XCTAssertTrue(text.contains("```\nraw"), "expected an unlabeled fence, got:\n\(text)")
    }

    func testFenceLanguageMap() {
        XCTAssertEqual(CodeReference.fenceLanguage(forPath: "/a/b.swift"), "swift")
        XCTAssertEqual(CodeReference.fenceLanguage(forPath: "/a/b.m"), "objectivec")
        XCTAssertEqual(CodeReference.fenceLanguage(forPath: "/a/b.sh"), "bash")
        XCTAssertEqual(CodeReference.fenceLanguage(forPath: "/a/b.py"), "python")
        XCTAssertEqual(CodeReference.fenceLanguage(forPath: "/a/b.tsx"), "typescript")
        XCTAssertNil(CodeReference.fenceLanguage(forPath: "/a/b.xyz"))
        XCTAssertNil(CodeReference.fenceLanguage(forPath: "/a/b"))
    }

    func testDeletedFileReferenceIsSelfContained() {
        // A deleted file's snippet never needs the file to still exist.
        let reference = reference(
            path: "/Users/tester/proj/gone.swift",
            start: 1, end: 5,
            snippet: "let legacy = true\n"
        )
        let text = reference.promptText(relativeTo: URL(fileURLWithPath: "/Users/tester/proj"))
        XCTAssertTrue(text.contains("[Ref: gone.swift:1-5]"))
        XCTAssertTrue(text.contains("let legacy = true"))
    }

    func testCodableRoundTrip() throws {
        let reference = reference(
            path: "/Users/tester/proj/Core/Renderer.swift",
            start: 10, end: 12,
            snippet: "x\n"
        )
        let data = try JSONEncoder().encode(reference)
        let decoded = try JSONDecoder().decode(CodeReference.self, from: data)
        XCTAssertEqual(decoded, reference)
    }
}

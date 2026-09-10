import XCTest
@testable import Core

/// Pure path math for `RelativePath.compute(from:to:)` — the inverse of
/// `PathCompletion`'s fragment + cwd resolution. No filesystem access.
final class RelativePathTests: XCTestCase {
    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    func testDirectChildFile() {
        XCTAssertEqual(
            RelativePath.compute(from: url("/Users/tester/proj"), to: url("/Users/tester/proj/README.md")),
            "README.md"
        )
    }

    func testNestedSameProject() {
        XCTAssertEqual(
            RelativePath.compute(from: url("/Users/tester/proj"), to: url("/Users/tester/proj/Core/Renderer.swift")),
            "Core/Renderer.swift"
        )
    }

    func testOneLevelUp() {
        XCTAssertEqual(
            RelativePath.compute(from: url("/Users/tester/proj/Sub"), to: url("/Users/tester/proj/Core/Renderer.swift")),
            "../Core/Renderer.swift"
        )
    }

    func testDivergingSubtrees() {
        XCTAssertEqual(
            RelativePath.compute(from: url("/Users/tester/projA/src"), to: url("/Users/tester/projB/lib/f.swift")),
            "../../projB/lib/f.swift"
        )
    }

    func testWalkToRootArea() {
        XCTAssertEqual(
            RelativePath.compute(from: url("/Users/tester/proj"), to: url("/tmp/scratch/x.swift")),
            "../../../tmp/scratch/x.swift"
        )
    }

    func testLexicalDotComponentsAreStandardized() {
        XCTAssertEqual(
            RelativePath.compute(from: url("/Users/tester/proj/./Sub/.."), to: url("/Users/tester/proj/Core/x.swift")),
            "Core/x.swift"
        )
    }
}

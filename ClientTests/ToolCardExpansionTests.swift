import XCTest
@testable import Core

/// Tests for `ToolCardExpansion` — the per-card expand/collapse registry that
/// drives tool-card row measurement. Pure state.
final class ToolCardExpansionTests: XCTestCase {

    func testStartsCollapsed() {
        let expansion = ToolCardExpansion()
        XCTAssertFalse(expansion.isExpanded("card-1"))
    }

    func testToggleExpandsAndCollapses() {
        let expansion = ToolCardExpansion()
        expansion.toggle("card-1")
        XCTAssertTrue(expansion.isExpanded("card-1"))
        expansion.toggle("card-1")
        XCTAssertFalse(expansion.isExpanded("card-1"))
    }

    func testCardsAreIndependent() {
        let expansion = ToolCardExpansion()
        expansion.toggle("card-1")
        XCTAssertTrue(expansion.isExpanded("card-1"))
        XCTAssertFalse(expansion.isExpanded("card-2"))
        expansion.toggle("card-2")
        XCTAssertTrue(expansion.isExpanded("card-1"))
        XCTAssertTrue(expansion.isExpanded("card-2"))
    }

    func testResetClearsAll() {
        let expansion = ToolCardExpansion()
        expansion.toggle("a")
        expansion.toggle("b")
        expansion.reset()
        XCTAssertFalse(expansion.isExpanded("a"))
        XCTAssertFalse(expansion.isExpanded("b"))
    }
}

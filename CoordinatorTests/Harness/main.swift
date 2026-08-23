import Foundation
import XCTest

// Runner for the plain-swiftc coordinator test harness. Pure-Swift test
// methods are not ObjC-visible, so XCTest's normal discovery cannot find them
// — each test method is invoked explicitly (the documented RenderingTests
// approach). Failures are counted by the stub XCTest module's global counter;
// the process exits non-zero when any test fails.
let tests: [(name: String, body: () -> Void)] = [
    ("testInitialStateStreamsToTheTailAndFollows", { CoordinatorNavigationTests().testInitialStateStreamsToTheTailAndFollows() }),
    ("testDownCyclesThroughUserMessagesThenJumpsToTheTail", { CoordinatorNavigationTests().testDownCyclesThroughUserMessagesThenJumpsToTheTail() }),
    ("testUpCyclesThroughUserMessagesThenJumpsToTheTop", { CoordinatorNavigationTests().testUpCyclesThroughUserMessagesThenJumpsToTheTop() }),
    ("testJumpAboveTheWindowMaterializesHistory", { CoordinatorNavigationTests().testJumpAboveTheWindowMaterializesHistory() }),
    ("testCycleAdvancesAcrossAProgrammaticViewportShift", { CoordinatorNavigationTests().testCycleAdvancesAcrossAProgrammaticViewportShift() }),
    ("testWheelScrollRestartsTheCycleFromTheViewport", { CoordinatorNavigationTests().testWheelScrollRestartsTheCycleFromTheViewport() }),
    ("testLargeMaterializationDefersWithSpinner", { CoordinatorNavigationTests().testLargeMaterializationDefersWithSpinner() }),
    ("testJumpMovesKeyFocusToTheTranscript", { CoordinatorNavigationTests().testJumpMovesKeyFocusToTheTranscript() }),
    ("testJumpDoesNotStealFocusWhileTheFindBarIsUp", { CoordinatorNavigationTests().testJumpDoesNotStealFocusWhileTheFindBarIsUp() }),
]

var totalFailures = 0
for test in tests {
    let before = __testFailures
    test.body()
    let failures = __testFailures - before
    totalFailures += failures
    print("\(failures == 0 ? "PASS" : "FAIL") \(test.name)")
}
if totalFailures == 0 {
    print("All \(tests.count) coordinator tests passed.")
} else {
    print("\(totalFailures) assertion(s) failed across \(tests.count) tests.")
    exit(1)
}

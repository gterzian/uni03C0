import XCTest
@testable import Core

/// Tests for the batched, tail-first search in `SessionViewModel`: the search
/// walks the conversation from the TAIL upward in slices of `searchBatchSize`,
/// each slice searched in its own task and applied incrementally, so the find
/// bar fills in near the bottom first and shows a spinner until the whole
/// session is covered. These tests shrink the batch size to 1 to make every
/// intermediate state observable (everything runs on the main actor, so the
/// batch sequence is deterministic).
@MainActor
final class SessionViewModelSearchTests: XCTestCase {

    /// Builds a view model whose store holds these rows (store indices):
    ///   0 user      "needle at the top"
    ///   1 assistant "needle in the middle"
    ///   2 user      "nothing here"
    ///   3 assistant "nothing here either"
    ///   4 user      "needle at the bottom"
    ///   5 assistant "no results here"
    private func makeViewModel() -> SessionViewModel {
        let vm = SessionViewModel(cwd: URL(fileURLWithPath: "/tmp"))
        vm.searchBatchSize = 1
        let store = vm.store

        func turn(_ userText: String, _ assistantText: String) {
            _ = store.apply(frame(type: "message_start",
                "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u\(store.count)\",\"content\":[{\"type\":\"text\",\"text\":\"\(userText)\"}]}}"))
            _ = store.apply(frame(type: "message_start",
                "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a\(store.count)\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}"))
            _ = store.apply(frame(type: "message_update",
                "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"\(assistantText)\"}}"))
            _ = store.apply(frame(type: "message_end",
                "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"id\":\"a\(store.count - 1)\",\"content\":[{\"type\":\"text\",\"text\":\"\(assistantText)\"}]}}"))
        }

        turn("needle at the top", "needle in the middle")
        turn("nothing here", "nothing here either")
        turn("needle at the bottom", "no results here")
        XCTAssertEqual(store.count, 6, "expected 6 rows (one user + one assistant per turn)")
        return vm
    }

    /// Yields the main actor until `condition` holds, failing the test on
    /// timeout (the batched search runs on the main actor, so this is how the
    /// test lets batches land).
    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("timed out waiting for the search to settle")
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func testBatchedSearchLandsMatchesInReverseSessionOrder() async {
        let vm = makeViewModel()
        vm.runSearch("needle")
        await waitUntil { !vm.isSearching && vm.searchMatches.count == 3 }
        XCTAssertEqual(vm.searchMatches.map(\.storeIndex), [4, 1, 0],
            "results are presented in REVERSE session order: the bottom-most match first")
        XCTAssertFalse(vm.isSearching, "search must be complete")
        XCTAssertEqual(vm.searchCurrentIndex, 0,
            "the current match is the first-found (bottom) match, so the counter reads 1/3")
    }

    func testResultsArriveIncrementallyTailFirst() async {
        let vm = makeViewModel()
        // Record every publish: search start + each applied batch. Because the
        // loop runs on the main actor, this sequence is fully deterministic.
        var observations: [(matches: Int, searching: Bool)] = []
        vm.onSearchResultsChanged = {
            observations.append((vm.searchMatches.count, vm.isSearching))
        }
        vm.runSearch("needle")
        await waitUntil { !vm.isSearching && vm.searchMatches.count == 3 }

        // Tail-first: the first matches found are the BOTTOM rows (4), then 1,
        // then 0 — so the list must be observed growing 0 → 1 → 2 → 3 with the
        // spinner on until the very last batch.
        XCTAssertTrue(observations.contains { $0.matches == 1 && $0.searching },
            "must observe a partial state (1 match) while still searching")
        XCTAssertTrue(observations.contains { $0.matches == 2 && $0.searching },
            "must observe a partial state (2 matches) while still searching")
        let finalObservation = observations.last
        XCTAssertEqual(finalObservation?.matches, 3)
        XCTAssertEqual(finalObservation?.searching, false)
    }

    func testJumpLandsOnFirstFoundMatchOnce() async {
        let vm = makeViewModel()
        var jumps: [Int] = []
        vm.onSearchJump = { jumps.append($0) }
        vm.runSearch("needle")
        await waitUntil { !vm.isSearching && vm.searchMatches.count == 3 }
        // Only ONE jump, to the first-found match — the tail row (4). Later
        // batches prepend matches without yanking the viewport again.
        XCTAssertEqual(jumps, [4], "jump exactly once, to the bottommost match found first")
    }

    func testCyclingDuringSearchAdvancesWithoutRestarting() async {
        let vm = makeViewModel()
        vm.toggleSearch() // open the find bar (Enter cycling requires it)
        // Record every state publication (run reset, each batch, each cycle).
        var observations: [(matches: Int, searching: Bool)] = []
        vm.onSearchResultsChanged = { observations.append((vm.searchMatches.count, vm.isSearching)) }
        vm.runSearch("needle")
        // Wait until at least one match is visible (mid-flight or complete).
        await waitUntil { observations.contains { !$0.searching && $0.matches > 0 } }
        let preCycle = observations.count
        vm.nextSearchMatch()
        // Give a wrongly-restarted search time to apply new batches.
        try? await Task.sleep(for: .milliseconds(20))
        // The cycle's own highlight notification is fine — a RESTART would
        // reset the list to 0 matches and flip isSearching back on.
        let after = observations.dropFirst(preCycle)
        XCTAssertTrue(after.allSatisfy { !$0.searching },
            "Enter cycling must never restart the search")
        XCTAssertFalse(after.contains { $0.matches == 0 },
            "Enter cycling must never clear the visible match list")
        XCTAssertTrue(vm.searchMatches.indices.contains(vm.searchCurrentIndex),
            "the advanced index must point into the visible match list")
    }

    func testCyclingAfterCompletionWalksAndWraps() async {
        let vm = makeViewModel()
        vm.toggleSearch()
        vm.runSearch("needle")
        await waitUntil { !vm.isSearching && vm.searchMatches.count == 3 }
        // Matches are in reverse session order [4, 1, 0]; the current match is
        // the first-found (bottom) match, at index 0.
        XCTAssertEqual(vm.searchMatches.map(\.storeIndex), [4, 1, 0])
        XCTAssertEqual(vm.searchMatches[vm.searchCurrentIndex].storeIndex, 4, "result 1 is the bottom-most match")
        // ↓/Enter moves DOWN the session (toward newer content), so the
        // result number DECREASES: from result 1 (bottom) it wraps to the
        // last result (top), then walks back down through the history.
        vm.nextSearchMatch()
        XCTAssertEqual(vm.searchMatches[vm.searchCurrentIndex].storeIndex, 0, "↓ from the bottom-most match wraps to the top-most (result 3/3)")
        vm.nextSearchMatch()
        XCTAssertEqual(vm.searchMatches[vm.searchCurrentIndex].storeIndex, 1, "↓ then walks down the history (result 2/3)")
        vm.nextSearchMatch()
        XCTAssertEqual(vm.searchMatches[vm.searchCurrentIndex].storeIndex, 4, "↓ wraps back to result 1/3 (the bottom)")
        // ↑/Shift+Enter moves UP the session (toward older content), so the
        // result number INCREASES.
        vm.previousSearchMatch()
        XCTAssertEqual(vm.searchMatches[vm.searchCurrentIndex].storeIndex, 1, "↑ from the bottom goes to result 2/3")
    }

    func testEmptyQueryClearsResultsImmediately() async {
        let vm = makeViewModel()
        vm.runSearch("needle")
        await waitUntil { !vm.isSearching && vm.searchMatches.count == 3 }
        vm.runSearch("   ")
        await waitUntil { vm.searchMatches.isEmpty && !vm.isSearching }
        XCTAssertEqual(vm.searchCurrentIndex, -1)
    }

    func testCaseSensitiveToggleReRunsTheSearch() async {
        let vm = makeViewModel()
        vm.runSearch("needle")
        await waitUntil { !vm.isSearching && vm.searchMatches.count == 3 }
        vm.setCaseSensitive(true)
        XCTAssertTrue(vm.isCaseSensitive)
        // Uppercase "NEEDLE" matches nothing case-sensitively.
        vm.searchQuery = "NEEDLE"
        vm.runSearch("NEEDLE")
        await waitUntil { !vm.isSearching && vm.searchMatches.isEmpty }
        XCTAssertEqual(vm.searchCurrentIndex, -1)
    }

    func testSessionSwitchClearsInFlightSearch() async {
        let vm = makeViewModel()
        var observations: [(matches: Int, searching: Bool)] = []
        vm.onSearchResultsChanged = { observations.append((vm.searchMatches.count, vm.isSearching)) }
        vm.runSearch("needle")
        // Let the search start, then close it mid-flight (what a session
        // switch does via loadMessages → clearSearchResults).
        await waitUntil { observations.count >= 2 } // search began + first batch landed
        vm.closeSearch()
        await waitUntil { !vm.isSearching && vm.searchMatches.isEmpty }
        XCTAssertEqual(vm.searchCurrentIndex, -1)
        XCTAssertEqual(observations.last?.searching, false)
    }
}

import AppKit
import Core
import XCTest

/// End-to-end tests for the transcript Coordinator's keyboard navigation —
/// the Cmd+Up / Cmd+Down user-message cycle and its scroll / focus / follow
/// effects — driven through the REAL AppKit object graph (an offscreen
/// `NSTableView` + `NSScrollView`) with a REAL `TranscriptStore` folded from
/// RPC frames, exactly like the ClientTests do. The only stand-in is
/// `SessionViewModel` (its real counterpart spawns `pi --mode rpc` at init;
/// tests never spawn pi). Deterministic: no window server, and the single
/// deferred scroll (`jumpToBottom`'s one-run-loop-turn hop) is spun
/// explicitly.
///
/// This target compiles `TranscriptView.swift` directly alongside the tests,
/// so the coordinator's internal members are accessible here — the same
/// arrangement as the renderer's test hooks in RenderingTests.
final class CoordinatorNavigationTests: XCTestCase {

    // MARK: - Building a session

    private func frame(type: String, _ json: String) -> RPCFrame {
        RPCFrame(raw: Data(json.utf8), type: type, id: nil, command: nil, success: nil, error: nil)
    }

    /// Folds one completed turn (a user message + an assistant reply) into the
    /// store, exactly as pi's event stream would (same frames as ClientTests).
    private func foldTurn(_ store: TranscriptStore, user: String, reply: String) {
        _ = store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u\(store.count)\",\"content\":[{\"type\":\"text\",\"text\":\"\(user)\"}]}}"))
        _ = store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a\(store.count)\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}"))
        _ = store.apply(frame(type: "message_update",
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"\(reply)\"}}"))
        _ = store.apply(frame(type: "message_end",
            "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"id\":\"a\(store.count - 1)\",\"content\":[{\"type\":\"text\",\"text\":\"\(reply)\"}]}}"))
    }

    /// A coordinator over `turns` completed turns (two rows each: users at
    /// even store indices, assistants at odd), folded AFTER the scroll view
    /// exists and forwarded through `onTranscriptChange` — the same flow as a
    /// streamed session (rows append, the tail follows in). Returns the
    /// coordinator, the framed-but-never-shown scroll view, and the view model
    /// stand-in.
    private func makeStreamingCoordinator(turns: Int, viewport: CGFloat = 600) -> (Coordinator, NSScrollView, SessionViewModel) {
        let vm = SessionViewModel()
        let coordinator = Coordinator()
        let sv = coordinator.makeScrollView(viewModel: vm)
        sv.frame = NSRect(x: 0, y: 0, width: 640, height: viewport)
        for t in 0..<turns {
            foldTurn(vm.store, user: "question \(t)", reply: "ok")
        }
        vm.onTranscriptChange?()
        sv.layoutSubtreeIfNeeded()
        return (coordinator, sv, vm)
    }

    // MARK: - Geometry helpers

    /// The store index of the row currently at the top of the viewport.
    /// Note this INCLUDES a partially-visible sliver of the row above the
    /// landed message (the 8pt margin) — the coordinator's `cycleAnchor` is
    /// the exact landed message and is what the cycle assertions use.
    private func topStoreIndex(_ coordinator: Coordinator) -> Int {
        coordinator.windowStart + coordinator.tableView.rows(in: coordinator.tableView.visibleRect).location
    }

    /// How far `storeIndex`'s top edge sits below the viewport's top edge.
    /// A user-message jump anchors the row at +8.
    private func rowTopOffset(_ coordinator: Coordinator, _ storeIndex: Int) -> CGFloat {
        let rowRect = coordinator.tableView.rect(ofRow: storeIndex - coordinator.windowStart)
        return rowRect.origin.y - coordinator.scrollView.documentVisibleRect.minY
    }

    /// Spins the main run loop long enough for `jumpToBottom`'s deferred
    /// scroll (one `DispatchQueue.main.async` hop) to land.
    private func spinRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    // MARK: - Initial state

    func testInitialStateStreamsToTheTailAndFollows() {
        let (coordinator, sv, _) = makeStreamingCoordinator(turns: 20)
        XCTAssertTrue(coordinator.isFollowing, "a fresh session pins to the tail")
        // The tail means the LAST row's bottom rests at the viewport's bottom
        // (the table frame has a little padding below the last row).
        let lastRect = coordinator.tableView.rect(ofRow: coordinator.tableView.numberOfRows - 1)
        XCTAssertEqual(lastRect.maxY - sv.documentVisibleRect.maxY, 0, accuracy: 0.5,
            "the viewport rests at the bottom of the conversation")
    }

    // MARK: - The Down cycle

    func testDownCyclesThroughUserMessagesThenJumpsToTheTail() {
        let (coordinator, sv, vm) = makeStreamingCoordinator(turns: 20) // 40 rows, users at evens
        let store = vm.store
        XCTAssertTrue(coordinator.isFollowing)

        // Move off the tail first so the Down walk starts mid-conversation,
        // where messages can be anchored at the top of the viewport.
        coordinator.jumpToPreviousUserMessage()
        guard let start = coordinator.cycleAnchor?.storeIndex else {
            XCTFail("the Up jump should land on a message"); return
        }
        XCTAssertEqual(start, 18, "the first Up from the tail lands on the previous user message")
        XCTAssertEqual(rowTopOffset(coordinator, start), 8, accuracy: 0.5)

        // Down walks every user message below the start, in order — each
        // landing is the NEXT user message (never re-showing the one just
        // left). The expected targets come from the pure TranscriptCycler:
        // this test proves the coordinator does exactly what the decision
        // logic says. Messages that fit are anchored at the viewport top;
        // messages too close to the tail clamp to the bottom of the document.
        var anchor = start
        var expected = TranscriptCycler.nextUserMessage(anchor: anchor, count: store.count, entryAt: store.entry(at:))
        var positionable = 0
        var clamped = 0
        while let target = expected {
            coordinator.jumpToNextUserMessage()
            XCTAssertEqual(coordinator.cycleAnchor?.storeIndex, target,
                "Down lands on the next user message, never the one just left")
            let rect = coordinator.tableView.rect(ofRow: target - coordinator.windowStart)
            let docMaxY = max(0, sv.documentView!.frame.height - sv.contentView.bounds.height)
            if rect.origin.y - 8 <= docMaxY {
                XCTAssertEqual(rowTopOffset(coordinator, target), 8, accuracy: 0.5,
                    "the message is anchored at the top of the viewport")
                XCTAssertFalse(coordinator.isFollowing, "a deliberate jump stops following")
                positionable += 1
            } else {
                XCTAssertEqual(sv.documentVisibleRect.minY, docMaxY, accuracy: 0.5,
                    "a near-tail message clamps to the bottom of the document")
                clamped += 1
            }
            anchor = target
            expected = TranscriptCycler.nextUserMessage(anchor: anchor, count: store.count, entryAt: store.entry(at:))
        }
        XCTAssertGreaterThan(positionable, 0, "the cycle exercised top-anchored landings")
        XCTAssertGreaterThan(clamped, 0, "the cycle exercised near-tail clamped landings")

        // Terminal Down: past the last user message, all the way to the live
        // tail, re-engaging following.
        coordinator.jumpToNextUserMessage()
        spinRunLoop()
        XCTAssertTrue(coordinator.isFollowing, "the tail jump re-engages following")
        // The tail jump uses scrollToBottom, which aims at the document FRAME
        // bottom (the table frame carries a little padding below the rows).
        let doc = sv.documentView!
        XCTAssertLessThanOrEqual(doc.frame.height - sv.documentVisibleRect.maxY, 1,
            "the viewport is at the live tail")
    }

    // MARK: - The Up cycle

    func testUpCyclesThroughUserMessagesThenJumpsToTheTop() {
        let (coordinator, sv, vm) = makeStreamingCoordinator(turns: 20)
        let store = vm.store

        // Every Up jump goes AWAY from the tail, so every landing is
        // top-anchored at +8 and following stays off.
        var anchor = coordinator.currentAnchorStoreIndex()
        var expected = TranscriptCycler.previousUserMessage(anchor: anchor, entryAt: store.entry(at:))
        var landed = 0
        while let target = expected {
            coordinator.jumpToPreviousUserMessage()
            XCTAssertEqual(coordinator.cycleAnchor?.storeIndex, target,
                "Up lands on the previous user message")
            XCTAssertEqual(rowTopOffset(coordinator, target), 8, accuracy: 0.5,
                "the message is anchored at the top of the viewport")
            XCTAssertFalse(coordinator.isFollowing, "a deliberate jump stops following")
            anchor = target
            landed += 1
            expected = TranscriptCycler.previousUserMessage(anchor: anchor, entryAt: store.entry(at:))
        }
        XCTAssertGreaterThan(landed, 5, "the cycle actually walked several messages")

        // Terminal Up: past the first user message, all the way to the very
        // beginning of the conversation (clamped to offset 0).
        coordinator.jumpToPreviousUserMessage()
        XCTAssertEqual(coordinator.scrollView.documentVisibleRect.minY, 0,
            "the top of the conversation is the document's start")
        XCTAssertNil(coordinator.cycleAnchor, "a terminal jump clears the cycle anchor")
        XCTAssertFalse(coordinator.isFollowing)
    }

    // MARK: - Materializing older history

    func testJumpAboveTheWindowMaterializesHistory() {
        // Fold BEFORE makeScrollView, like a reloaded session: the store is
        // already full, so the initial window only materializes the tail
        // chunk. A small viewport keeps the chunk at the 40-row floor.
        let vm = SessionViewModel()
        for t in 0..<30 {
            foldTurn(vm.store, user: "q \(t)", reply: "ok")
        }
        let coordinator = Coordinator()
        let sv = coordinator.makeScrollView(viewModel: vm)
        sv.frame = NSRect(x: 0, y: 0, width: 640, height: 120)
        sv.layoutSubtreeIfNeeded()

        XCTAssertEqual(coordinator.windowStart, 20,
            "only the tail chunk (60 − 40) is materialized initially")

        // Jump to an early user message: history is prepended in one go and
        // the message lands at the top of the viewport — no RPC round trip.
        coordinator.jumpToUserMessage(2)
        XCTAssertEqual(coordinator.windowStart, 0, "older history was materialized")
        XCTAssertEqual(coordinator.cycleAnchor?.storeIndex, 2, "the target message was landed on")
        XCTAssertEqual(rowTopOffset(coordinator, 2), 8, accuracy: 0.5)
    }

    // MARK: - Cycle anchor robustness

    func testCycleAdvancesAcrossAProgrammaticViewportShift() {
        // Regression: the follow-scroll that runs while streaming (following
        // re-engages after a near-tail landing) shifts the viewport between
        // keypresses. A tight "has the viewport moved" check made the next
        // Down re-target the message it had just landed on — the reported
        // "Cmd+Down needs two inputs to advance".
        let (coordinator, sv, vm) = makeStreamingCoordinator(turns: 20)
        // Down from the tail lands on 22, clamped at the document bottom.
        coordinator.jumpToNextUserMessage()
        XCTAssertEqual(coordinator.cycleAnchor?.storeIndex, 22)
        // followTail aims at the LAST ROW's bottom, ~10pt above the frame
        // bottom the clamp uses — a small programmatic shift, no user input.
        let lastRow = coordinator.tableView.numberOfRows - 1
        let lastBottom = coordinator.tableView.rect(ofRow: lastRow).maxY
        sv.contentView.scroll(to: NSPoint(x: 0, y: lastBottom - sv.contentView.bounds.height))
        sv.reflectScrolledClipView(sv.contentView)
        // The next Down must advance to 24 — not re-land on 22.
        coordinator.jumpToNextUserMessage()
        XCTAssertEqual(coordinator.cycleAnchor?.storeIndex, 24,
            "the cycle advances past the landed message despite the programmatic shift")
        _ = vm
    }

    func testWheelScrollRestartsTheCycleFromTheViewport() {
        let (coordinator, sv, vm) = makeStreamingCoordinator(turns: 20)
        let window = NSWindow(contentRect: sv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        sv.frame = window.contentView!.bounds
        window.contentView = sv
        coordinator.jumpToNextUserMessage()
        XCTAssertEqual(coordinator.cycleAnchor?.storeIndex, 22)
        // A real wheel scroll is the user taking over navigation.
        (sv as! TranscriptScrollView).onUserScroll?()
        XCTAssertNil(coordinator.cycleAnchor, "a wheel scroll clears the cycle anchor")
        _ = vm
    }

    // MARK: - Large materialization shows the spinner

    func testLargeMaterializationDefersWithSpinner() {
        // A jump far above the materialized window fetches a large block: the
        // loading spinner goes up and the prepend runs on the next run-loop
        // turn (so it paints before the synchronous measurement), then the
        // landing completes.
        let vm = SessionViewModel()
        for t in 0..<80 {
            foldTurn(vm.store, user: "q \(t)", reply: "ok")
        }
        let coordinator = Coordinator()
        let sv = coordinator.makeScrollView(viewModel: vm)
        sv.frame = NSRect(x: 0, y: 0, width: 640, height: 120)
        sv.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(coordinator.windowStart, 25,
            "precondition: the window is a tail chunk, so the jump needs a large fetch")

        coordinator.jumpToUserMessage(2)
        XCTAssertTrue(vm.isFetchingOlder, "the spinner is raised while the block loads")
        XCTAssertNil(coordinator.cycleAnchor, "the landing is deferred until the prepend runs")

        spinRunLoop()
        XCTAssertFalse(vm.isFetchingOlder, "the load completed")
        XCTAssertEqual(coordinator.windowStart, 0, "the whole conversation is materialized")
        XCTAssertEqual(coordinator.cycleAnchor?.storeIndex, 2, "the deferred landing completed")
    }

    // MARK: - Scroll cancellation

    /// A synthetic scroll event with the given live/momentum phase, built via
    /// `CGEvent` so the phases survive into `NSEvent`. The CG field encoding
    /// differs from `NSEvent.Phase`'s raw values: 1 = began, 2 = changed,
    /// 4 = ended, 8 = cancelled; 0 = no phase (a plain mouse-wheel tick).
    private func scrollEvent(deltaY: CGFloat, phase: Int = 0, momentumPhase: Int = 0) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                         wheel1: Int32(deltaY), wheel2: 0, wheel3: 0)!
        if phase != 0 { cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: Int64(phase)) }
        if momentumPhase != 0 { cg.setIntegerValueField(CGEventField(rawValue: 123)!, value: Int64(momentumPhase)) }
        return NSEvent(cgEvent: cg)!
    }

    func testJumpCancelsAnOngoingScroll() {
        let (coordinator, sv, vm) = makeStreamingCoordinator(turns: 20)
        let transcriptSV = sv as! TranscriptScrollView
        var userScrolls = 0
        transcriptSV.onUserScroll = { userScrolls += 1 }

        // Baseline: a momentum event (the tail of a flick) reaches the
        // transcript as a user scroll.
        transcriptSV.scrollWheel(with: scrollEvent(deltaY: -3, momentumPhase: 2))
        XCTAssertGreaterThan(userScrolls, 0, "precondition: an ongoing momentum scroll counts as a user scroll")

        // A keyboard jump takes over and cancels the scroll.
        coordinator.jumpToNextUserMessage()
        XCTAssertEqual(coordinator.cycleAnchor?.storeIndex, 22)
        let scrollsBefore = userScrolls
        let pos = sv.documentVisibleRect.minY

        // The interrupted scroll's tail arrives: swallowed — the viewport
        // stays put and no user-scroll callback fires (which would clear the
        // cycle anchor and re-fight the landing).
        transcriptSV.scrollWheel(with: scrollEvent(deltaY: -3, momentumPhase: 2))
        XCTAssertEqual(sv.documentVisibleRect.minY, pos, "the momentum tail does not move the viewport")
        XCTAssertEqual(userScrolls, scrollsBefore, "the momentum tail is swallowed")
        XCTAssertEqual(coordinator.cycleAnchor?.storeIndex, 22, "the landed message stays the cycle anchor")

        // The momentum ends, then a brand-new gesture begins: scrolling
        // resumes normally.
        transcriptSV.scrollWheel(with: scrollEvent(deltaY: 0, momentumPhase: 4))
        transcriptSV.scrollWheel(with: scrollEvent(deltaY: 0, phase: 1))
        transcriptSV.scrollWheel(with: scrollEvent(deltaY: -3, phase: 2))
        XCTAssertGreaterThan(userScrolls, scrollsBefore, "a new gesture resumes scrolling")
        _ = vm
    }

    func testScrollTailClassification() {
        // A tail: any event carrying a non-boundary phase.
        XCTAssertTrue(TranscriptScrollView.isScrollTail(scrollEvent(deltaY: -3, phase: 2)))
        XCTAssertTrue(TranscriptScrollView.isScrollTail(scrollEvent(deltaY: -3, momentumPhase: 2)))
        XCTAssertTrue(TranscriptScrollView.isScrollTail(scrollEvent(deltaY: -3, phase: 2, momentumPhase: 2)))
        // Boundaries end the suppression.
        XCTAssertFalse(TranscriptScrollView.isScrollTail(scrollEvent(deltaY: 0, phase: 1)))
        XCTAssertFalse(TranscriptScrollView.isScrollTail(scrollEvent(deltaY: 0, phase: 4)))
        XCTAssertFalse(TranscriptScrollView.isScrollTail(scrollEvent(deltaY: 0, phase: 8)))
        XCTAssertFalse(TranscriptScrollView.isScrollTail(scrollEvent(deltaY: 0, momentumPhase: 1)))
        XCTAssertFalse(TranscriptScrollView.isScrollTail(scrollEvent(deltaY: 0, momentumPhase: 4)))
        XCTAssertFalse(TranscriptScrollView.isScrollTail(scrollEvent(deltaY: 0, momentumPhase: 8)))
        // A plain mouse-wheel tick has no phase: never a tail, never swallowed.
        XCTAssertFalse(TranscriptScrollView.isScrollTail(scrollEvent(deltaY: -3)))
    }

    // MARK: - Key focus after a jump

    /// A borderless, never-shown window hosting the scroll view, with an
    /// editable field holding key focus.
    private func makeWindow(_ sv: NSScrollView) -> (NSWindow, NSTextField) {
        let window = NSWindow(contentRect: sv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        sv.frame = window.contentView!.bounds
        window.contentView = sv
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field), "precondition: the editable field holds focus")
        return (window, field)
    }

    func testJumpMovesKeyFocusToTheTranscript() {
        // The coordinator holds the view model WEAKLY, so the test must retain
        // it (a discarded `_` would deallocate it and the jump would no-op).
        let (coordinator, sv, vm) = makeStreamingCoordinator(turns: 5)
        let (window, _) = makeWindow(sv)
        coordinator.jumpToPreviousUserMessage()
        XCTAssertTrue(window.firstResponder === coordinator.tableView,
            "a keyboard navigation jump takes focus on the transcript, so the next Arrow key scrolls it")
        _ = vm
    }

    func testJumpDoesNotStealFocusWhileTheFindBarIsUp() {
        let (coordinator, sv, vm) = makeStreamingCoordinator(turns: 5)
        vm.isSearchVisible = true
        let (window, field) = makeWindow(sv)
        coordinator.jumpToPreviousUserMessage()
        // The find field is an NSTextField whose field editor is what actually
        // holds first responder; the point is that the transcript did NOT take
        // it, so typing a new query keeps working.
        XCTAssertTrue(window.firstResponder !== coordinator.tableView,
            "while the find bar is up, typing a new query keeps working")
        XCTAssertTrue(window.firstResponder is NSTextView,
            "the find field's editor still holds key focus")
        _ = field
    }
}

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
        guard let start = coordinator.cycleAnchor else {
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
            XCTAssertEqual(coordinator.cycleAnchor, target,
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
            XCTAssertEqual(coordinator.cycleAnchor, target,
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
        XCTAssertEqual(coordinator.cycleAnchor, 2, "the target message was landed on")
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
        XCTAssertEqual(coordinator.cycleAnchor, 22)
        // followTail aims at the LAST ROW's bottom, ~10pt above the frame
        // bottom the clamp uses — a small programmatic shift, no user input.
        let lastRow = coordinator.tableView.numberOfRows - 1
        let lastBottom = coordinator.tableView.rect(ofRow: lastRow).maxY
        sv.contentView.scroll(to: NSPoint(x: 0, y: lastBottom - sv.contentView.bounds.height))
        sv.reflectScrolledClipView(sv.contentView)
        // The next Down must advance to 24 — not re-land on 22.
        coordinator.jumpToNextUserMessage()
        XCTAssertEqual(coordinator.cycleAnchor, 24,
            "the cycle advances past the landed message despite the programmatic shift")
        _ = vm
    }

    func testWheelScrollRestartsTheCycleFromTheViewport() {
        let (coordinator, sv, vm) = makeStreamingCoordinator(turns: 20)
        let window = NSWindow(contentRect: sv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        sv.frame = window.contentView!.bounds
        window.contentView = sv
        // Land on a POSITIONABLE message (top-anchored), so the viewport's top
        // substantial row after the landing IS the landed message.
        coordinator.jumpToPreviousUserMessage()
        XCTAssertEqual(coordinator.cycleAnchor, 18)
        // A real wheel scroll is the user taking over navigation.
        (sv as! TranscriptScrollView).onUserScroll?()
        XCTAssertNil(coordinator.cycleAnchor, "a wheel scroll clears the cycle anchor")
        // The next Down advances from the viewport's top MESSAGE (sliver-
        // skipped) — it must NOT re-target 18 via the 8pt sliver of the row
        // above it (the wasted press that made cycling feel two-per-message).
        coordinator.jumpToNextUserMessage()
        XCTAssertEqual(coordinator.cycleAnchor, 20,
            "after a user scroll the cycle advances, never re-shows the message just landed on")
        _ = vm
    }

    func testCycleAdvancesAfterALargeViewportShift() {
        // Regression: an eviction re-anchor (rows removed above the viewport)
        // or a streaming follow-scroll moves the viewport by far more than any
        // offset tolerance while the landed message stays visible. The cycle
        // must still advance ONE press per message — a "has the viewport
        // moved" check would fall back and re-target the message just landed
        // on (or skip ahead), the "two presses per message" report.
        let (coordinator, sv, vm) = makeStreamingCoordinator(turns: 20)
        coordinator.jumpToPreviousUserMessage()
        XCTAssertEqual(coordinator.cycleAnchor, 18)
        // Move the viewport far up: 18 stays visible (it was at top+8), but
        // the offset moved well beyond any tight tolerance.
        let before = sv.documentVisibleRect.minY
        sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, before - 250)))
        sv.reflectScrolledClipView(sv.contentView)
        coordinator.jumpToNextUserMessage()
        XCTAssertEqual(coordinator.cycleAnchor, 20,
            "the cycle advances despite a large viewport shift")
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
        XCTAssertEqual(coordinator.cycleAnchor, 2, "the deferred landing completed")
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
        XCTAssertEqual(coordinator.cycleAnchor, 22)
        let scrollsBefore = userScrolls
        let pos = sv.documentVisibleRect.minY

        // The interrupted scroll's tail arrives: swallowed — the viewport
        // stays put and no user-scroll callback fires (which would clear the
        // cycle anchor and re-fight the landing).
        transcriptSV.scrollWheel(with: scrollEvent(deltaY: -3, momentumPhase: 2))
        XCTAssertEqual(sv.documentVisibleRect.minY, pos, "the momentum tail does not move the viewport")
        XCTAssertEqual(userScrolls, scrollsBefore, "the momentum tail is swallowed")
        XCTAssertEqual(coordinator.cycleAnchor, 22, "the landed message stays the cycle anchor")

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

    // MARK: - Column-width changes (the content-clipping fix)

    /// The content-clipping regression: a column-width change (window resize,
    /// scroller show/hide) leaves the table's row rects at the OLD width's
    /// heights. Streaming rows self-heal (the batched refresh re-measures at
    /// the current width); a SETTLED row keeps its stale too-short rect and
    /// clips its top. The fix must re-query every materialized row's height
    /// when the render width changes — driven by the clip view's frame-change
    /// hook, NOT by a scroll (a resize with no scroll in between must still
    /// heal). This drives the hook directly: narrow the column, post the clip
    /// view's frame-change notification, and assert the settled row re-measures
    /// taller at the narrower width.
    func testColumnWidthChangeReQueriesSettledRowHeights() {
        // A reply long enough to wrap at the wide width and wrap MORE at the
        // narrow one — the height must grow, or the test asserts nothing.
        let longReply = (0..<160).map { "word\($0)" }.joined(separator: " ")
        let vm = SessionViewModel()
        let coordinator = Coordinator()
        let sv = coordinator.makeScrollView(viewModel: vm)
        sv.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        foldTurn(vm.store, user: "question", reply: longReply)
        vm.onTranscriptChange?()
        sv.layoutSubtreeIfNeeded()

        let tableView = coordinator.tableView!
        let column = tableView.tableColumns.first!
        let wide = column.width
        // Store index 1: the assistant reply (even indices are users).
        let wideHeight = tableView.rect(ofRow: 1).height

        // Narrow the render width, as a window resize would. The table does
        // NOT re-query `heightOfRow` on a column-width change by itself — that
        // is the bug — so the frame-change hook must invalidate the stale
        // rects.
        column.width = max(wide / 2, 340)
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: sv.contentView)
        sv.layoutSubtreeIfNeeded()

        let narrowHeight = tableView.rect(ofRow: 1).height
        XCTAssertGreaterThan(narrowHeight, wideHeight,
            "a narrower column wraps the settled reply more; its height must be re-queried, not kept at the old width's")
    }

    // MARK: - Row height vs. rendered content (the top-clip regressions)

    /// The clipping invariant, on every materialized row that has a live cell:
    /// the table's row rect must be at least as tall as the content the CELL
    /// lays out. A row shorter than its content overflows UPWARD (the cell's
    /// text view is bottom-anchored in the non-flipped cell), so the first
    /// line(s) are painted over — and hidden by — the row above: the
    /// "message top cut off as if scrolled down" symptom.
    private func assertNoClipping(_ coordinator: Coordinator, _ label: String) {
        let tableView = coordinator.tableView!
        for row in 0..<tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TextRowView else { continue }
            let rowHeight = tableView.rect(ofRow: row).height
            let content = cell.contentHeight
            if content > rowHeight + 0.5 {
                XCTFail("\(label): row \(row) (store \(coordinator.windowStart + row)) renders \(content)pt of text in a \(rowHeight)pt row — the top is clipped")
            }
        }
    }

    /// A row MATERIALIZED MID-STREAM must have its height re-queried.
    ///
    /// The regression: while the user is scrolled up, the batched refresh is
    /// skipped, so the streaming row's cached height stays at the last rendered
    /// content. When the row is then materialized (the user peeks at the tail,
    /// or any recycled cell comes back), `makeCell` renders the store's CURRENT
    /// content — taller than the height `heightOfRow` just served — and seeded
    /// the cache with it, but the TABLE was never told: the row stayed short
    /// and the cell's text overflowed it upward, clipping the top of the
    /// message until a reload (switching tabs and back) re-queried the height.
    func testRowMaterializedMidStreamHasItsHeightRequeried() {
        let vm = SessionViewModel()
        let coordinator = Coordinator()
        let sv = coordinator.makeScrollView(viewModel: vm)
        sv.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        sv.layoutSubtreeIfNeeded()
        spinRunLoop()

        // Settled history to scroll up into.
        for t in 0..<8 {
            foldTurn(vm.store, user: "question \(t)", reply: "a short reply \(t)")
        }
        vm.onTranscriptChange?()
        sv.layoutSubtreeIfNeeded()
        spinRunLoop()

        // ONE turn with TWO assistant messages (pi's normal shape: thinking,
        // a tool call, then more thinking — no user echo in between). The
        // first streams while following, so the refresh gate tracks its id.
        foldUserEcho(vm, id: "u-turn")
        streamAssistantThinking(vm, coordinator, id: "a-first",
                                text: "First message thinking, streamed while pinned to the bottom of the transcript.")

        // The user scrolls up to read history: following disengages, so from
        // here on nothing renders per delta.
        let up = max(0, sv.documentVisibleRect.minY - 120)
        sv.contentView.scroll(to: NSPoint(x: 0, y: up))
        sv.reflectScrolledClipView(sv.contentView)
        spinRunLoop() // the clip view's bounds-change notification is coalesced
        coordinator.isFollowing = false

        // The turn's SECOND message streams and is peeked at halfway (the row
        // materializes with content newer than the height the table serves).
        // The gate never sees this message — it is still tracking the first.
        let thinking = "Now I need to verify the edit to `timers.rs` didn't break anything, since `event_loop.rs` was refactored without me touching it. The builds passed with both V8 and Boa, so all good. Now I'll run `cargo fmt` one more time to ensure formatting is clean, then show the final diff summary and generate a commit message."
        streamAssistantThinking(vm, coordinator, id: "a-second", text: thinking,
                                peekAtTail: true, sv: sv, scrolledUp: true,
                                checkEachDelta: { [self] in
            // Mid-stream, one run-loop turn after the row was materialized:
            // the table must already agree with the cell. A mismatch here is
            // the clip the user stares at for the REST of the turn (the settle
            // is minutes away).
            assertNoClipping(coordinator, "mid-stream, scrolled up")
        })

        sv.layoutSubtreeIfNeeded()
        coordinator.tableView.layoutSubtreeIfNeeded()
        spinRunLoop()
        assertNoClipping(coordinator, "after a stream that settled while scrolled up")

        // The settle must also have re-rendered the row the cells actually
        // showed streaming: the gate's own id still points at the FIRST
        // message, so a search that trusts only the gate leaves this row with
        // its half-streamed text and an immortal blinking caret.
        let tableView = coordinator.tableView!
        for row in 0..<tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TextRowView else { continue }
            XCTAssertFalse(cell.isStreamingRowForTesting,
                "row \(row): every message has settled, so no cell may still render as streaming")
        }
    }

    /// Streaming rows never clip while they grow: the row height and the cell's
    /// own layout stay in step through a realistic delta cadence (the 0.25s
    /// refresh gate batches like production) and across the settle.
    func testStreamingRowNeverClipsWhileItGrows() {
        let vm = SessionViewModel()
        let coordinator = Coordinator()
        let sv = coordinator.makeScrollView(viewModel: vm)
        sv.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        sv.layoutSubtreeIfNeeded()
        spinRunLoop()

        let thinking = "Now I need to verify the edit to `timers.rs` didn't break anything, since `event_loop.rs` was refactored without me touching it. The builds passed with both V8 and Boa, so all good. Now I'll run `cargo fmt` one more time to ensure formatting is clean, then show the final diff summary and generate a commit message."
        foldUserEcho(vm, id: "u1")
        streamAssistantThinking(vm, coordinator, id: "a1", text: thinking, checkEachDelta: { [self] in
            assertNoClipping(coordinator, "while streaming")
        })
        sv.layoutSubtreeIfNeeded()
        coordinator.tableView.layoutSubtreeIfNeeded()
        spinRunLoop()
        assertNoClipping(coordinator, "after the settle")
    }

    /// A real window resize (the chain the app sees: window → scroll view →
    /// clip view → table → column) re-wraps every row; the rows must grow with
    /// the text, in both directions.
    func testWindowResizeNeverClips() {
        let vm = SessionViewModel()
        let coordinator = Coordinator()
        let sv = coordinator.makeScrollView(viewModel: vm)
        sv.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let thinking = "Now I need to verify the edit to `timers.rs` didn't break anything, since `event_loop.rs` was refactored without me touching it. The builds passed with both V8 and Boa, so all good."
        for t in 0..<6 {
            foldTurn(vm.store, user: "question \(t)", reply: thinking)
        }
        // Materialize the rows BEFORE the window exists: a never-shown window
        // reads as occluded, and `applyModelChanges` (correctly) does no
        // rendering off-screen.
        vm.onTranscriptChange?()
        sv.layoutSubtreeIfNeeded()
        let (window, _) = makeWindow(sv)
        sv.layoutSubtreeIfNeeded()
        spinRunLoop()
        assertNoClipping(coordinator, "before the resize")
        let tableView = coordinator.tableView!
        let wideRow = tableView.rect(ofRow: 1).height

        window.setFrame(NSRect(x: 0, y: 0, width: 520, height: 700), display: true)
        sv.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        spinRunLoop()
        XCTAssertGreaterThan(tableView.rect(ofRow: 1).height, wideRow,
            "a narrower window wraps the reply more, so its row must grow")
        assertNoClipping(coordinator, "after narrowing the window")

        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: true)
        sv.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        spinRunLoop()
        assertNoClipping(coordinator, "after widening the window")
    }

    /// Folds a user message (the prompt echo), like sending a prompt.
    private func foldUserEcho(_ vm: SessionViewModel, id: String) {
        _ = vm.store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"\(id)\",\"content\":[{\"type\":\"text\",\"text\":\"go\"}]}}"))
        vm.onTranscriptChange?()
    }

    /// Streams `text` as one assistant message's thinking deltas at a realistic
    /// cadence (so the 0.25s refresh gate batches like production), then settles
    /// it. No user echo: this is a message WITHIN a turn, pi's normal shape.
    ///
    /// `scrolledUp` keeps following off for the whole message (the user is
    /// reading history while the agent works), and `peekAtTail` scrolls the
    /// streaming row into view halfway through — the user glancing at the tail
    /// without going all the way down, which materializes the cell.
    private func streamAssistantThinking(_ vm: SessionViewModel, _ coordinator: Coordinator, id: String, text: String,
                                         peekAtTail: Bool = false, sv: NSScrollView? = nil,
                                         scrolledUp: Bool = false,
                                         checkEachDelta: (() -> Void)? = nil) {
        _ = vm.store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"\(id)\",\"content\":[]}}"))
        if scrolledUp { coordinator.isFollowing = false }
        vm.onTranscriptChange?()
        if scrolledUp { coordinator.isFollowing = false }
        let chars = Array(text)
        var sent = 0
        while sent < chars.count {
            let upto = min(sent + 8, chars.count)
            let delta = String(chars[sent..<upto])
            sent = upto
            let json = try! String(data: JSONSerialization.data(withJSONObject: [
                "type": "message_update",
                "assistantMessageEvent": ["type": "thinking_delta", "delta": delta],
            ]), encoding: .utf8)!
            _ = vm.store.apply(frame(type: "message_update", json))
            vm.onTranscriptChange?()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if scrolledUp { coordinator.isFollowing = false }
            checkEachDelta?()
            if peekAtTail, sent >= chars.count / 2, let sv {
                let doc = sv.documentView!.frame.height
                let target = max(0, doc - sv.contentView.bounds.height - 30)
                if abs(sv.documentVisibleRect.minY - target) > 1 {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: target))
                    sv.reflectScrolledClipView(sv.contentView)
                    coordinator.tableView.layoutSubtreeIfNeeded()
                }
            }
        }
        let endJSON = try! String(data: JSONSerialization.data(withJSONObject: [
            "type": "message_end",
            "message": ["role": "assistant", "id": id, "stopReason": "end",
                        "content": [["type": "thinking", "thinking": text]]],
        ]), encoding: .utf8)!
        _ = vm.store.apply(frame(type: "message_end", endJSON))
        vm.onTranscriptChange?()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
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

    // MARK: - Settled streaming row (the caret leech)

    /// A just-settled assistant row must re-render (stop its blinking caret)
    /// even when the user has scrolled up (`isFollowing == false`). Before the
    /// fix, the streaming refresh ran behind `guard isFollowing`, so a cell
    /// that was configured streaming kept its caret timer running forever (the
    /// 0.35s redraw in Quartz Debug) until a tab switch re-created the cells
    /// from the already-finalized store. This drives that path: fold an
    /// in-progress turn (the row streams, so it has a live cell), disengage
    /// following, settle via `message_end`, and assert the cell stops
    /// rendering as streaming.
    func testStreamingRowSettleRendersWhileNotFollowing() {
        let vm = SessionViewModel()
        let coordinator = Coordinator()
        let sv = coordinator.makeScrollView(viewModel: vm)
        sv.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        sv.layoutSubtreeIfNeeded()
        // Let makeScrollView's deferred scroll-to-bottom land before we take
        // over, so no later run-loop turn surprises the follow state.
        spinRunLoop()

        // Fold an in-progress turn: the user echo + the assistant streaming.
        _ = vm.store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u0\",\"content\":[{\"type\":\"text\",\"text\":\"shuffle\"}]}}"))
        _ = vm.store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}"))
        _ = vm.store.apply(frame(type: "message_update",
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"delta\":\"hello\"}}"))
        vm.onTranscriptChange?()
        sv.layoutSubtreeIfNeeded()

        // Store index 1 is the assistant row; with a 2-row transcript in an
        // 800pt viewport it has a live cell configured as streaming.
        guard let cell = coordinator.tableView.view(atColumn: 0, row: 1, makeIfNecessary: false) as? TextRowView else {
            return XCTFail("the streaming assistant row should have a live cell")
        }
        XCTAssertTrue(cell.isStreamingRowForTesting,
            "precondition: the in-progress assistant row renders as streaming")

        // The user scrolls up to read while the reply is still streaming.
        coordinator.isFollowing = false

        // The turn settles (message_end). The store finalizes the row; the
        // settling must re-render the cell to stop its blinking caret even
        // though following is off.
        _ = vm.store.apply(frame(type: "message_end",
            "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}}"))
        vm.onTranscriptChange?()
        sv.layoutSubtreeIfNeeded()

        XCTAssertFalse(cell.isStreamingRowForTesting,
            "a settled streaming row must stop showing its caret even when not following")
    }

    // MARK: - Off-main height pre-measurement

    /// A settled row appended to the store must be scheduled for background
    /// measurement and the result must land in the session's height cache
    /// (so `heightOfRow` serves it instead of typesetting on the main
    /// thread). The seeded height must equal the authoritative measure — the
    /// "one measurement function" invariant.
    func testAppendSchedulesAndSeedsOffMainPremeasure() {
        let vm = SessionViewModel()
        let coordinator = Coordinator()
        let sv = coordinator.makeScrollView(viewModel: vm)
        sv.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        sv.layoutSubtreeIfNeeded()
        spinRunLoop() // let makeScrollView's deferred tail-scroll land

        // Fold ONE settled user message (no assistant reply): the only row is
        // a settled text row, so it is pre-measurable.
        _ = vm.store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"id\":\"u0\",\"content\":[{\"type\":\"text\",\"text\":\"hello world\"}]}}"))
        vm.onTranscriptChange?()

        // The pump drains the queue into the in-flight task synchronously, so
        // the observable signal is `premeasureInFlight`, not a non-empty queue.
        XCTAssertTrue(coordinator.premeasureInFlight,
            "an appended settled row starts the background pre-measure")

        spinRunLoop() // let the detached measure task drain + store

        XCTAssertFalse(coordinator.premeasureInFlight, "the pre-measure task completed")
        XCTAssertTrue(coordinator.pendingPremeasure.isEmpty,
            "the pre-measure queue drains")
        let width = coordinator.tableView.tableColumns.first!.width
        let cache = coordinator.heightCacheForTesting(vm)
        let cached = cache?.heightIfPresent(for: "u0", width: width)
        XCTAssertNotNil(cached, "the pre-measured height landed in the session cache")
        guard let cached else { return }
        let direct = vm.store.entry(at: 0)!.measuredHeight(forWidth: width, bodySize: FontSettings.shared.bodySize)
        XCTAssertEqual(cached, direct, accuracy: 0.01,
            "the background-seeded height is the same value the main-thread measure produces")
    }

    /// A row appended in the STREAMING state must never be pre-measured — its
    /// height comes from the cell's incremental layout (re-measuring the
    /// growing text is the documented 100%-CPU regression). The queue must
    /// stay empty for a streaming append.
    func testStreamingAppendDoesNotSchedulePremeasure() {
        let vm = SessionViewModel()
        let coordinator = Coordinator()
        let sv = coordinator.makeScrollView(viewModel: vm)
        sv.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        sv.layoutSubtreeIfNeeded()
        spinRunLoop()

        // A streaming assistant row (no user echo — the message begins with
        // the assistant, so the store appends it directly as streaming).
        _ = vm.store.apply(frame(type: "message_start",
            "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"id\":\"a1\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}}"))
        vm.onTranscriptChange?()

        XCTAssertTrue(coordinator.pendingPremeasure.isEmpty,
            "a streaming row is measured by the cell's incremental layout, never pre-measured")
        XCTAssertFalse(coordinator.premeasureInFlight, "nothing was scheduled")
    }
}

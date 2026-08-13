import XCTest
@testable import Core

/// Regression tests for the streaming 100%-CPU path.
///
/// pi pushes a delta per token (~90/sec in captures). The transcript
/// coordinator must NOT re-render (re-measure) the streaming row on every
/// delta — each re-measure re-typesets the whole growing text, which costs
/// hundreds of ms for a large newline-heavy message and saturates the main
/// thread. `StreamingRefreshGate` caps refreshes at the batch interval
/// (~4/sec) plus the first chunk of a new message and the streaming→final
/// flag flip.
///
/// These tests replay a realistic thinking-delta stream through the REAL
/// `TranscriptStore` folding and the REAL gate, and assert the refresh count
/// is bounded by the interval — never per delta.
final class StreamingRefreshGateTests: XCTestCase {

    // MARK: - Gate unit behavior

    func testFirstChunkOfNewMessageFiresImmediately() {
        var gate = StreamingRefreshGate()
        // A brand-new streaming message with a first chunk must render now —
        // the user must see the first words immediately, not 0.25s later.
        XCTAssertTrue(gate.shouldRefresh(entryID: "m1", text: "The", thinking: "", isStreaming: true, now: 0))
        // Same content again: no refresh.
        XCTAssertFalse(gate.shouldRefresh(entryID: "m1", text: "The", thinking: "", isStreaming: true, now: 0.01))
    }

    func testContentChangeIsBatchedToInterval() {
        var gate = StreamingRefreshGate(batchInterval: 0.25)
        _ = gate.shouldRefresh(entryID: "m1", text: "The", thinking: "", isStreaming: true, now: 0)
        // Fast deltas: content changes but the interval hasn't elapsed.
        for i in 1...10 {
            let t = Double(i) * 0.01 // 10 deltas within 0.1s
            XCTAssertFalse(gate.shouldRefresh(entryID: "m1", text: "The user wants \(i)", thinking: "", isStreaming: true, now: t),
                           "delta at \(t)s must be batched away")
        }
        // After the interval elapses, the next content change refreshes.
        XCTAssertTrue(gate.shouldRefresh(entryID: "m1", text: "The user wants 11", thinking: "", isStreaming: true, now: 0.26))
    }

    func testSettleFlagFlipFiresImmediately() {
        var gate = StreamingRefreshGate(batchInterval: 0.25)
        _ = gate.shouldRefresh(entryID: "m1", text: "final", thinking: "", isStreaming: true, now: 0)
        // Streaming → final with UNCHANGED text must re-render immediately
        // (the old streaming version keeps its blinking caret otherwise).
        XCTAssertTrue(gate.shouldRefresh(entryID: "m1", text: "final", thinking: "", isStreaming: false, now: 0.001))
        // Settled and unchanged: no further refreshes.
        XCTAssertFalse(gate.shouldRefresh(entryID: "m1", text: "final", thinking: "", isStreaming: false, now: 0.01))
    }

    func testRunningToolCardBatchedToInterval() {
        var gate = StreamingRefreshGate(batchInterval: 0.25)
        _ = gate.shouldRefresh(entryID: "m1", text: "", thinking: "thinking", isStreaming: true, now: 0)
        XCTAssertFalse(gate.shouldRefreshRunningToolCard(now: 0.1))
        XCTAssertTrue(gate.shouldRefreshRunningToolCard(now: 0.26))
    }

    // MARK: - Full pipeline repro (store + gate)

    /// Replays a realistic thinking stream through the real store folding and
    /// the real gate, counting refreshes. Returns (deltas, refreshes, duration).
    private func replayThinkingStream(deltaInterval: TimeInterval, deltaText: String) -> (Int, Int, TimeInterval) {
        let store = TranscriptStore()
        var gate = StreamingRefreshGate()
        var frames: [RPCFrame] = []
        frames.append(frame(.messageStartUser(id: "user-1", text: "proceed")))
        frames.append(frame(.messageStartAssistant(id: "assistant-1")))
        let text = Array(deltaText)
        var i = 0
        let step = 30 // like the real capture: ~3-char deltas, but keep the test fast
        while i < text.count {
            let upto = min(i + step, text.count)
            frames.append(frame(.thinkingDelta(String(text[i..<upto]))))
            i = upto
        }
        frames.append(frame(.thinkingEnd(deltaText)))
        frames.append(frame(.messageEndAssistant(id: "assistant-1")))

        var refreshes = 0
        for (index, f) in frames.enumerated() {
            let now = Double(index) * deltaInterval
            let changed = store.apply(f)
            if changed {
                // The coordinator's scan: find the last streaming/matched row.
                var streamingEntry: TranscriptEntry?
                for eidx in stride(from: store.count - 1, through: 0, by: -1) {
                    if let e = store.entry(at: eidx), e.kind.isStreaming || e.id == gate.lastStreamedID {
                        streamingEntry = e
                        break
                    }
                }
                if let e = streamingEntry, case .assistantMessage(let text, let thinking, let isStreaming) = e.kind,
                   gate.shouldRefresh(entryID: e.id, text: text, thinking: thinking, isStreaming: isStreaming, now: now) {
                    refreshes += 1
                }
            }
        }
        let duration = Double(frames.count) * deltaInterval
        return (frames.count, refreshes, duration)
    }

    func testFastThinkingStreamRefreshCountIsBounded() {
        // ~14k chars of thinking streamed in ~3-char deltas at 50ms cadence —
        // the realistic capture pattern (~90 deltas/sec). A per-delta refresh
        // would fire ~570 times; the gate must cap it to ~duration/0.25 + a few.
        let thinking = String(repeating: "The user wants me to implement the proposed fixes. Let me think carefully. ", count: 300)
        let (deltas, refreshes, duration) = replayThinkingStream(deltaInterval: 0.05, deltaText: thinking)

        XCTAssertGreaterThan(deltas, 200, "sanity: the stream must have many deltas")
        let expectedUpperBound = Int(duration / 0.25) + 3 // interval refreshes + first chunk + settle
        XCTAssertLessThanOrEqual(refreshes, expectedUpperBound,
                                 "\(refreshes) refreshes over \(String(format: "%.1f", duration))s — the gate must batch, not refresh per delta")
        XCTAssertLessThan(refreshes, deltas / 4,
                          "refresh count \(refreshes) must be far below the delta count \(deltas)")
    }

    func testSlowStreamStillRefreshes() {
        // A slow stream (one delta per second, content always growing) must
        // still refresh on every delta — the interval cap only throttles FAST
        // streams; slow ones get each chunk immediately.
        var gate = StreamingRefreshGate(batchInterval: 0.25)
        _ = gate.shouldRefresh(entryID: "m1", text: "a", thinking: "", isStreaming: true, now: 0)
        XCTAssertTrue(gate.shouldRefresh(entryID: "m1", text: "ab", thinking: "", isStreaming: true, now: 1.0))
        XCTAssertTrue(gate.shouldRefresh(entryID: "m1", text: "abc", thinking: "", isStreaming: true, now: 2.0))
    }

    // MARK: - Frame synthesizers (mirror pi's RPC wire format)

    private enum Kind {
        case messageStartUser(id: String, text: String)
        case messageStartAssistant(id: String)
        case thinkingDelta(String)
        case thinkingEnd(String)
        case messageEndAssistant(id: String)
    }

    private func frame(_ kind: Kind) -> RPCFrame {
        let obj: [String: Any]
        let type: String
        switch kind {
        case .messageStartUser(let id, let text):
            type = "message_start"
            obj = ["type": type, "message": ["role": "user", "id": id, "content": [["type": "text", "text": text]]]]
        case .messageStartAssistant(let id):
            type = "message_start"
            obj = ["type": type, "message": ["role": "assistant", "id": id, "content": []]]
        case .thinkingDelta(let delta):
            type = "message_update"
            obj = ["type": type, "assistantMessageEvent": ["type": "thinking_delta", "delta": delta]]
        case .thinkingEnd(let content):
            type = "message_update"
            obj = ["type": type, "assistantMessageEvent": ["type": "thinking_end", "content": content]]
        case .messageEndAssistant(let id):
            type = "message_end"
            obj = ["type": type, "message": ["role": "assistant", "id": id, "content": [], "stopReason": "end"]]
        }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return RPCFrame(raw: data, type: type, id: nil, command: nil, success: nil, error: nil)
    }
}

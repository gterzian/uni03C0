import XCTest
@testable import Core

/// The store side of the file-change signal: folding a `tool_execution_end`
/// whose card is an `edit`/`write` call records the finished file's path,
/// consumed one-shot by the session view model after each awaited fold
/// (§2.2, the review's corrected bridge). Pure data — no pi process.
final class TranscriptStoreFileChangeSignalTests: XCTestCase {
    private func toolCallEnd(name: String, id: String, args: String) -> String {
        #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","contentIndex":1,"toolCall":{"type":"toolCall","id":"\#(id)","name":"\#(name)","arguments":\#(args)}}}"#
    }

    private func executionEnd(id: String) -> String {
        #"{"type":"tool_execution_end","toolCallId":"\#(id)","result":{"content":[{"type":"text","text":"ok"}]}}"#
    }

    private func completeLifecycle(store: TranscriptStore, name: String, id: String, args: String) {
        _ = store.apply(frame(type: "message_update", toolCallEnd(name: name, id: id, args: args)))
        _ = store.apply(frame(type: "tool_execution_start",
            #"{"type":"tool_execution_start","toolCallId":"\#(id)","toolName":"\#(name)","args":\#(args)}}"#))
        _ = store.apply(frame(type: "tool_execution_end", executionEnd(id: id)))
    }

    func testEditCompletionSurfacesPathOnce() {
        let store = TranscriptStore()
        completeLifecycle(
            store: store,
            name: "edit",
            id: "tc-edit",
            args: #"{"path":"/tmp/app.swift","edits":[{"oldText":"a","newText":"b"}]}"#
        )
        XCTAssertEqual(store.consumeCompletedFileEdit(), "/tmp/app.swift")
        XCTAssertNil(store.consumeCompletedFileEdit(), "the signal is one-shot")
    }

    func testWriteCompletionSurfacesPath() {
        let store = TranscriptStore()
        completeLifecycle(
            store: store,
            name: "write",
            id: "tc-write",
            args: #"{"path":"/tmp/w.swift","content":"new"}"#
        )
        XCTAssertEqual(store.consumeCompletedFileEdit(), "/tmp/w.swift")
    }

    func testNonFileToolDoesNotSignal() {
        let store = TranscriptStore()
        completeLifecycle(
            store: store,
            name: "bash",
            id: "tc-bash",
            args: #"{"command":"echo hi"}"#
        )
        XCTAssertNil(store.consumeCompletedFileEdit())
    }

    func testToolWithoutPathArgumentDoesNotSignal() {
        let store = TranscriptStore()
        // A write with no `path` argument (malformed) signals nothing.
        completeLifecycle(
            store: store,
            name: "write",
            id: "tc-w2",
            args: #"{"content":"new"}"#
        )
        XCTAssertNil(store.consumeCompletedFileEdit())
    }

    func testRebuildClearsPendingSignal() {
        let store = TranscriptStore()
        completeLifecycle(
            store: store,
            name: "edit",
            id: "tc-edit",
            args: #"{"path":"/tmp/app.swift","edits":[{"oldText":"a","newText":"b"}]}"#
        )
        // Session switch before the view model consumed the signal: the
        // rebuilt history has no "just completed" tool.
        _ = store.rebuild(from: [])
        XCTAssertNil(store.consumeCompletedFileEdit())
    }
}

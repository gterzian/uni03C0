import XCTest
@testable import PiCore

/// Integration tests against a live `pi --mode rpc` process. These require a
/// real pi install and API credentials, so they skip gracefully otherwise
/// (see `requirePi()` in TestSupport.swift).
final class PiSmokeTests: XCTestCase {

    private func makeController() -> PiProcessController {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return PiProcessController(
            executablePath: PiExecutable.resolve(),
            arguments: ["--mode", "rpc"],
            workingDirectory: cwd.path
        )
    }

    func testStateRoundTrip() async throws {
        try requirePi()
        let controller = makeController()
        await controller.start()
        defer { Task { await controller.terminate() } }

        let state = try await controller.send(.getState())
        XCTAssertEqual(state.success, true)
        let payload = state.dataPayload(SessionStatePayload.self)
        XCTAssertNotNil(payload, "get_state should return a session-state payload")
        XCTAssertNotNil(payload?.model, "session state should include a model")
    }

    func testAvailableModelsAndLevels() async throws {
        try requirePi()
        let controller = makeController()
        await controller.start()
        defer { Task { await controller.terminate() } }

        let models = try await controller.send(.getAvailableModels())
        let modelsPayload = models.dataPayload(ModelsPayload.self)
        XCTAssertNotNil(modelsPayload)
        XCTAssertFalse(modelsPayload?.models.isEmpty ?? true, "expected at least one model")

        let levels = try await controller.send(.getAvailableThinkingLevels())
        XCTAssertNotNil(levels.dataPayload(LevelsPayload.self))
    }

    func testPromptStreamsFullTurnSequence() async throws {
        try requirePi()
        let controller = makeController()
        let log = EventLog()
        let eventTask = Task {
            do {
                for try await frame in controller.events { log.append(frame.type) }
            } catch {
                // Stream ended or errored — nothing more to record.
            }
        }
        defer { eventTask.cancel() }

        await controller.start()
        let accepted = try await controller.send(.prompt(message: "Reply with exactly: OK"))
        XCTAssertEqual(accepted.success, true, "prompt should be accepted")

        // Wait for the turn to settle, then a moment for the trailing events.
        try await Task.sleep(for: .seconds(1))
        await controller.terminate()
        await eventTask.value

        let got = Set(log.values)
        for expected in ["agent_start", "turn_start", "message_start", "message_update", "message_end", "turn_end", "agent_end"] {
            XCTAssertTrue(got.contains(expected), "missing expected event \(expected); got \(log.values)")
        }
    }
}

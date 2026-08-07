import Foundation
import PiCore

/// Smoke test for the process/protocol layer (build order step 1):
/// spawn `pi --mode rpc`, confirm a round-trip, then run one real prompt and
/// print the event stream. No UI involved.
@main
struct PiCLITest {
    static func main() async {
        setbuf(stdout, nil)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let controller = PiProcessController(
            executablePath: PiExecutable.resolve(),
            arguments: ["--mode", "rpc"],
            workingDirectory: cwd.path
        )

        var eventLog: [String] = []
        let eventTask = Task {
            do {
                for try await frame in controller.events {
                    eventLog.append(frame.type)
                }
            } catch {
                eventLog.append("stream-error: \(error)")
            }
        }

        do {
            print("executable: \(PiExecutable.resolve())")

            print("starting…")
            await controller.start()
            print("started, sending get_state…")

            // Round-trip a state query.
            let state = try await controller.send(.getState())
            print("get_state success=\(state.success ?? false)")
            if let payload = state.dataPayload(SessionStatePayload.self) {
                print("  model: \(payload.model?.name ?? payload.model?.id ?? "nil")")
                print("  thinkingLevel: \(payload.thinkingLevel ?? "nil")")
                print("  sessionFile: \(payload.sessionFile ?? "nil")")
            }

            let models = try await controller.send(.getAvailableModels())
            if let payload = models.dataPayload(ModelsPayload.self) {
                print("get_available_models: \(payload.models.count) models")
                for m in payload.models.prefix(3) {
                    print("  - \(m.id) (\(m.provider ?? "?"))")
                }
            }

            let levels = try await controller.send(.getAvailableThinkingLevels())
            if let payload = levels.dataPayload(LevelsPayload.self) {
                print("get_available_thinking_levels: \(payload.levels.joined(separator: ", "))")
            }

            _ = try await controller.send(.setThinkingLevel(level: "low"))
            print("set_thinking_level: ok")

            // One real prompt to validate the streaming path end-to-end.
            print("prompt: sending…")
            let accepted = try await controller.send(.prompt(message: "Reply with exactly: OK"))
            print("prompt accepted=\(accepted.success ?? false)")

            // Wait for the turn to settle, then a moment for final events.
            try await Task.sleep(for: .seconds(1))
            await controller.terminate()
            await eventTask.value

            print("event sequence: \(eventLog.joined(separator: " → "))")

            let expected = ["agent_start", "turn_start", "message_start", "message_update", "message_end", "turn_end", "agent_end", "agent_settled"]
            let got = Set(eventLog)
            let missing = expected.filter { !got.contains($0) }
            if missing.isEmpty {
                print("SMOKE TEST PASSED")
            } else {
                print("SMOKE TEST FAILED — missing event types: \(missing.joined(separator: ", "))")
                exit(1)
            }
        } catch {
            print("SMOKE TEST FAILED — \(error)")
            eventTask.cancel()
            await controller.terminate()
            exit(1)
        }
    }
}

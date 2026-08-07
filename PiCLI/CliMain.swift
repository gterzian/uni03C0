import Foundation
import PiCore

/// Smoke test for the process/protocol layer (build order step 1):
/// spawn `pi --mode rpc`, confirm a round-trip, then run one real prompt and
/// print the event stream. No UI involved.
/// Thread-safe-enough event accumulator for CLI diagnostics (single producer
/// task, single consumer after termination).
final class EventLog: @unchecked Sendable {
    private var storage: [String] = []
    func append(_ entry: String) { storage.append(entry) }
    var values: [String] { storage }
}

@main
struct PiCLITest {
    static func main() async {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        if let resumeIndex = args.firstIndex(of: "--resume"), args.indices.contains(resumeIndex + 1) {
            await runResumeCheck(path: args[resumeIndex + 1])
            exit(0)
        }
        if let sessionsIndex = args.firstIndex(of: "--sessions"), args.indices.contains(sessionsIndex + 1) {
            runSessionsCheck(cwd: URL(fileURLWithPath: args[sessionsIndex + 1]))
            exit(0)
        }
        await runSmokeTest()
    }

    /// Verifies the session listing (Resume menu) for a project directory.
    static func runSessionsCheck(cwd: URL) {
        let dir = SessionListing.sessionsDirectory(for: cwd)
        print("sessions dir: \(dir.path)")
        print("exists: \(FileManager.default.fileExists(atPath: dir.path))")
        let list = SessionListing.recentSessions(for: cwd, limit: nil)
        for session in list.prefix(5) {
            print("  \(session.timestamp) | \(session.title) | \(session.path.lastPathComponent)")
        }
        print("total: \(list.count)")
        if list.isEmpty {
            print("SESSIONS CHECK FAILED: empty listing")
            exit(1)
        }
        print("SESSIONS CHECK PASSED")
    }

    /// Verifies the resume path against a real session file: switch_session to
    /// it, pull messages, and validate that the decoder handles every content
    /// shape in the file (including toolResult-role messages and string args).
    static func runResumeCheck(path: String) async {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let controller = PiProcessController(
            executablePath: PiExecutable.resolve(),
            arguments: ["--mode", "rpc"],
            workingDirectory: cwd.path
        )
        let log = EventLog()
        let eventTask = Task {
            for try await frame in controller.events { log.append(frame.type) }
        }
        defer { eventTask.cancel() }

        do {
            await controller.start()
            let switched = try await controller.send(.switchSession(path: path))
            print("switch_session success=\(switched.success ?? false)")
            let messages = try await controller.send(.getMessages())
            guard let payload = messages.dataPayload(MessagesPayload.self) else {
                print("RESUME CHECK FAILED: no messages payload")
                exit(1)
            }
            var roles: [String: Int] = [:]
            var blockTypes: [String: Int] = [:]
            var stringArgs = 0
            var parsedArgs = 0
            var textBlocks = 0
            for message in payload.messages {
                roles[message.role, default: 0] += 1
                for block in message.content ?? [] {
                    blockTypes[block.type, default: 0] += 1
                    if block.isToolCall {
                        if case .string = block.toolArguments {
                            stringArgs += 1
                            let pretty = block.toolArgumentsPretty(maxChars: 120)
                            if !pretty.isEmpty { parsedArgs += 1 }
                        }
                        if block.name == nil { print("  WARNING: tool call without name") }
                    }
                    if block.type == "text", !(block.text ?? "").isEmpty { textBlocks += 1 }
                }
            }
            print("messages: \(payload.messages.count), roles: \(roles)")
            print("block types: \(blockTypes)")
            print("tool calls with string args: \(stringArgs), parsed OK: \(parsedArgs), text blocks: \(textBlocks)")
            let toolResults = payload.messages.filter { $0.role == "toolResult" }.count
            let toolCalls = payload.messages.flatMap { $0.content ?? [] }.filter { $0.isToolCall }.count
            print("tool calls: \(toolCalls), toolResult messages: \(toolResults)")
            await controller.terminate()
            if payload.messages.count > 0 && blockTypes.keys.count > 0 {
                print("RESUME CHECK PASSED")
            } else {
                print("RESUME CHECK FAILED: nothing decoded")
                exit(1)
            }
        } catch {
            print("RESUME CHECK FAILED: \(error)")
            exit(1)
        }
    }

    static func runSmokeTest() async {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let controller = PiProcessController(
            executablePath: PiExecutable.resolve(),
            arguments: ["--mode", "rpc"],
            workingDirectory: cwd.path
        )

        let log = EventLog()
        let eventTask = Task {
            do {
                for try await frame in controller.events {
                    log.append(frame.type)
                }
            } catch {
                log.append("stream-error: \(error)")
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

            print("event sequence: \(log.values.joined(separator: " → "))")

            let expected = ["agent_start", "turn_start", "message_start", "message_update", "message_end", "turn_end", "agent_end", "agent_settled"]
            let got = Set(log.values)
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

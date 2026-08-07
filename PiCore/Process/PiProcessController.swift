import Foundation
import System
import Subprocess

/// Owns the lifetime of a single `pi --mode rpc` subprocess.
///
/// This is an actor so the `Subprocess.run` body closure (which holds the only
/// valid references to `StandardInputWriter` / the stdout sequence for the
/// process's whole life) can bridge I/O into the rest of the app without
/// escaping the closure:
///
/// - Commands go *in* via `send(_:)`, which encodes JSONL, writes it through
///   the bridged `StandardInputWriter`, and resolves against an
///   id → continuation map when the matching `response` frame arrives.
/// - Frames come *out* via the `events` AsyncThrowingStream (demuxed: command
///   responses matched by id are consumed by `send`; everything else —
///   `message_update`, `tool_execution_*`, `agent_*`, ... — is yielded).
///
/// Framing is manual and LF-only (see `JSONLFramer`): the stdlib's
/// `Character.isNewline` treats U+2028/U+2029 as line breaks, which are legal
/// inside JSON strings and would corrupt the stream.
///
/// The body closure runs off the main actor: `PiProcessController` is an
/// actor with nonisolated default isolation, so the stdout-read loop never
/// touches the main thread.
public actor PiProcessController {
    private let executablePath: String
    private let arguments: [String]
    private let workingDirectory: String?

    private var writer: StandardInputWriter?
    private var writerWaiters: [CheckedContinuation<StandardInputWriter, Error>] = []
    private var pending: [String: CheckedContinuation<RPCFrame, Error>] = [:]
    private var nextID: UInt64 = 0

    private let eventsContinuation: AsyncThrowingStream<RPCFrame, any Error>.Continuation
    public nonisolated let events: AsyncThrowingStream<RPCFrame, any Error>

    private var processTask: Task<Void, Never>?
    public private(set) var didExit = false

    public init(
        executablePath: String = PiExecutable.resolve(),
        arguments: [String] = ["--mode", "rpc"],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RPCFrame.self)
        self.events = stream
        self.eventsContinuation = continuation
    }

    deinit {
        // Safety net: if the controller is dropped while the process is alive,
        // signal EOF so the child exits rather than orphaning a node process.
        let writer = self.writer
        let task = self.processTask
        Task {
            try? await writer?.finish()
            task?.cancel()
        }
    }

    // MARK: - Lifecycle

    /// Spawns `pi --mode rpc` and begins pumping frames. Idempotent.
    public func start() async {
        guard processTask == nil else { return }
        processTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runProcess()
        }
    }

    /// Signals EOF on stdin (pi exits) and waits for the process to finish.
    public func terminate() async {
        await finishAndWait(timeout: .seconds(3))
        await failAllPending(with: PiError.userTerminated)
        eventsContinuation.finish()
    }

    private func finishAndWait(timeout: Duration) async {
        if let writer {
            try? await writer.finish()
        }
        guard let task = processTask else {
            didExit = true
            return
        }
        let race = Task {
            await task.value
        }
        do {
            try await Task.sleep(for: timeout)
            race.cancel()
            task.cancel()
        } catch {
            // task completed before timeout
        }
        didExit = true
    }

    // MARK: - Sending

    /// Sends a command and awaits its correlated `response` frame.
    @discardableResult
    public func send(_ request: RPCRequest) async throws -> RPCFrame {
        let writer = try await awaitWriter()
        var request = request
        request.id = request.id ?? makeID()
        let data = try request.jsonData()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RPCFrame, Error>) in
            // Hop back onto the actor to register the continuation, then write.
            Task { await self.dispatch(id: request.id!, continuation: cont, data: data, writer: writer) }
        }
    }

    private func dispatch(
        id: String,
        continuation: CheckedContinuation<RPCFrame, Error>,
        data: Data,
        writer: StandardInputWriter
    ) async {
        pending[id] = continuation
        do {
            let n = try await writer.write(data)
        } catch {
            pending.removeValue(forKey: id)
            continuation.resume(throwing: error)
        }
    }

    private func makeID() -> String {
        nextID &+= 1
        return "req-\(nextID)"
    }

    private func awaitWriter() async throws -> StandardInputWriter {
        if let writer { return writer }
        if didExit { throw PiError.disconnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<StandardInputWriter, Error>) in
            writerWaiters.append(cont)
        }
    }

    private func setWriter(_ writer: StandardInputWriter) async {
        self.writer = writer
        for waiter in writerWaiters {
            waiter.resume(returning: writer)
        }
        writerWaiters.removeAll()
    }

    // MARK: - Subprocess body

    private func runProcess() async {
        let execPath = FilePath(executablePath)
        let workDir: FilePath? = workingDirectory.map { FilePath($0) }
        do {
            _ = try await Subprocess.run(
                .path(execPath),
                arguments: Arguments(arguments),
                workingDirectory: workDir,
                input: .inputWriter,
                output: .sequence,
                error: .sequence
            ) { execution in
                await self.serve(execution)
            }
        } catch {
            await handleFatal(error)
        }
    }

    private func serve(_ execution: Execution<CustomWriteInput, SequenceOutput, SequenceOutput>) async {
        await setWriter(execution.standardInputWriter)

        // Drain stderr into synthetic frames (prefixed type) for diagnostics.
        let stderrTask = Task {
            var framer = JSONLFramer()
            do {
                for try await buffer in execution.standardError {
                    for record in framer.feed(Data(buffer: buffer)) {
                        if let line = String(data: record, encoding: .utf8) {
                                            self.eventsContinuation.yield(self.syntheticFrame(type: "stderr", text: line))
                        }
                    }
                }
            } catch {
                // stderr EOF or error — ignore
            }
        }

        // Read stdout until EOF (process exit).
        do {
            var framer = JSONLFramer()
                for try await buffer in execution.standardOutput {
                for record in framer.feed(Data(buffer: buffer)) {
                    await handleRecord(record)
                }
            }
                if let tail = framer.drain() {
                await handleRecord(tail)
            }
        } catch {
            // A sequence error also means the stream is done.
        }

        stderrTask.cancel()
        await failAllPending(with: PiError.disconnected)
        didExit = true
        eventsContinuation.finish()
    }

    private func handleFatal(_ error: any Error) async {
        await failAllPending(with: PiError.launchFailed(error.localizedDescription))
        eventsContinuation.finish()
    }

    private func syntheticFrame(type: String, text: String) -> RPCFrame {
        let data = Data("{\"type\":\"\(type)\",\"text\":\(String(data: try! JSONEncoder().encode(text), encoding: .utf8)!)}\n".utf8)
        return RPCFrame(raw: data, type: type, id: nil, command: nil, success: nil, error: nil)
    }

    // MARK: - Framing & demux

    private func handleRecord(_ record: Data) async {
        guard let light = try? JSONDecoder().decode(LightFrame.self, from: record) else {
            let raw = Data("{\"type\":\"parse_error\",\"error\":\"unparseable JSON line\"}\n".utf8)
            eventsContinuation.yield(RPCFrame(raw: raw, type: "parse_error", id: nil, command: nil, success: nil, error: "unparseable JSON line"))
            return
        }
        let frame = RPCFrame(
            raw: record,
            type: light.type,
            id: light.id,
            command: light.command,
            success: light.success,
            error: light.error,
            data: light.data
        )
        if frame.type == "response", let id = frame.id, let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: frame)
        } else {
            eventsContinuation.yield(frame)
        }
    }

    private func failAllPending(with error: any Error) async {
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
        for waiter in writerWaiters {
            waiter.resume(throwing: error)
        }
        writerWaiters.removeAll()
    }
}

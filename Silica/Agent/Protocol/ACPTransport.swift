import Darwin
import Foundation

/// One ordered ingress stream feeds all session state, like Zed's foreground dispatch.
@MainActor
final class ACPTransport {
    var onNotification: ((String, ACPJSON) -> Void)?
    var onRequest: ((String, ACPJSON, ACPJSON) -> Void)?
    var onDisconnect: ((String) -> Void)?

    private var kind: AgentKind = .codex
    private var process: Process?
    private var processTree: AgentProcessTree?
    private var cleanup: Task<AgentShutdownResult, Never>?
    private var input: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var consumer: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<ACPJSON, Error>.Continuation?
    private var pending: [String: CheckedContinuation<ACPJSON, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private let writes = DispatchQueue(label: "silica.acp.write")
    private var generation = UUID()
    private(set) var isConnected = false

    func start(executable: URL, cwd: URL, kind: AgentKind) async throws {
        let previous = await shutdown()
        guard previous.isComplete else { throw ACPError.message("Previous \(self.kind.displayName) processes are still stopping. Reconnect after they exit.") }
        try Task.checkCancellation()
        self.kind = kind
        let generation = UUID()
        self.generation = generation
        let stream = AsyncThrowingStream<ACPJSON, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        continuation = stream.continuation
        let reader = ACPStreamReader(continuation: stream.continuation, kind: kind)
        let process = Process()
        let incoming = Pipe(), outgoing = Pipe(), errors = Pipe()
        // A child can exit while the serial writer is blocked in write(2).
        // Report EPIPE through the request path instead of terminating the app.
        guard fcntl(outgoing.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw ACPError.message("Could not configure the \(kind.displayName) input pipe.")
        }
        process.executableURL = executable
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        environment["INITIAL_AGENT_MODE"] = kind.launchMode
        // Reuse the agent's own account/config. Never persist or log credentials here.
        process.environment = environment
        process.standardInput = outgoing
        process.standardOutput = incoming
        process.standardError = errors
        incoming.fileHandleForReading.readabilityHandler = { handle in reader.receive(handle.availableData) }
        // Keep diagnostics out of stdout, and drain stderr so it cannot block the agent.
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        self.process = process
        input = outgoing.fileHandleForWriting
        stdout = incoming.fileHandleForReading
        stderr = errors.fileHandleForReading
        do {
            try process.run()
            processTree = try AgentProcessTree(pid: process.processIdentifier, kind: kind)
        } catch {
            if process.isRunning { process.terminate(); kill(process.processIdentifier, SIGKILL) }
            close(); throw error
        }
        isConnected = true
        consumer = Task { [weak self] in
            do {
                for try await message in stream.stream {
                    guard let self, self.generation == generation, !Task.isCancelled else { return }
                    self.receive(message)
                }
                throw ACPError.message("\(kind.displayName) disconnected. Existing output and file changes are preserved.")
            } catch {
                guard let self, self.generation == generation, self.isConnected else { return }
                self.failPending(error)
                self.close()
                self.onDisconnect?(error.localizedDescription)
            }
        }
    }

    func request(_ method: String, params: ACPJSON, timeout: Duration? = .seconds(30)) async throws -> ACPJSON {
        let id = ACPJSON.string(UUID().uuidString)
        let key = id.requestKey!
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard isConnected else {
                    continuation.resume(throwing: ACPError.message("Connect \(kind.displayName) before sending a request."))
                    return
                }
                pending[key] = continuation
                if let timeout {
                    timeouts[key] = Task { [weak self, kind] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        self?.resolve(key, result: .failure(ACPError.message("\(kind.displayName) did not answer \(method) in time.")))
                    }
                }
                send(.object(["jsonrpc": .string("2.0"), "id": id, "method": .string(method), "params": params]))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(key, result: .failure(CancellationError())) }
        }
    }

    func notify(_ method: String, params: ACPJSON) {
        send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }

    func respond(id: ACPJSON, result: ACPJSON) {
        send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    func reject(id: ACPJSON, message: String) {
        send(.object(["jsonrpc": .string("2.0"), "id": id,
                      "error": .object(["code": .number(-32601), "message": .string(message)])]))
    }

    private func send(_ message: ACPJSON) {
        guard let input, isConnected else { return }
        do {
            var data = try JSONEncoder().encode(message)
            data.append(0x0A)
            let payload = data
            let generation = generation
            writes.async { [weak self] in
                do { try input.write(contentsOf: payload) } catch {
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.failPending(error)
                        self.close()
                        self.onDisconnect?("Could not write to \(self.kind.displayName). Reconnect to continue.")
                    }
                }
            }
        } catch { failPending(error) }
    }

    private func receive(_ message: ACPJSON) {
        if let method = message["method"].string {
            if message["id"].requestKey != nil {
                onRequest?(method, message["id"], message["params"])
            } else { onNotification?(method, message["params"]) }
        } else if let key = message["id"].requestKey {
            if message["error"].object != nil {
                let error = message["error"]
                let code = error["code"].integer ?? 0
                let detail = error["message"].string ?? "Unknown ACP error"
                resolve(key, result: .failure(ACPError.message("\(detail) (\(code))")))
            } else { resolve(key, result: .success(message["result"])) }
        }
    }

    private func resolve(_ key: String, result: Result<ACPJSON, Error>) {
        timeouts.removeValue(forKey: key)?.cancel()
        pending.removeValue(forKey: key)?.resume(with: result)
    }

    private func failPending(_ error: Error) {
        for key in Array(pending.keys) { resolve(key, result: .failure(error)) }
    }

    func close() {
        isConnected = false
        generation = UUID()
        failPending(ACPError.message("The \(kind.displayName) connection was closed."))
        consumer?.cancel(); consumer = nil
        continuation?.finish(); continuation = nil
        let process = process
        let input = input
        let stdout = stdout
        let stderr = stderr
        self.input = nil; self.stdout = nil; self.stderr = nil; self.process = nil
        guard process != nil || input != nil else { return }
        let tree = processTree
        // Preserve write ordering for EOF, but run process termination separately:
        // a full stdin pipe must not hold shutdown hostage on the writer queue.
        let writes = writes
        cleanup = Task.detached {
            let closeInput: @Sendable () -> Void = { writes.async { try? input?.close() } }
            let result: AgentShutdownResult
            if let tree { result = tree.shutdown(closeInput: closeInput) }
            else { closeInput(); result = .complete }
            if result.isComplete { process?.waitUntilExit() }
            // Continue draining during graceful shutdown so output pipes cannot
            // prevent the supervisor or child from exiting on their own.
            stdout?.readabilityHandler = nil
            stderr?.readabilityHandler = nil
            try? stdout?.close(); try? stderr?.close()
            return result
        }
    }

    @discardableResult
    func shutdown() async -> AgentShutdownResult {
        close()
        let tree = processTree
        var result = await cleanup?.value ?? .complete
        if !result.isComplete, let tree {
            let retry = Task.detached { tree.shutdown() }
            if processTree === tree { cleanup = retry }
            result = await retry.value
        }
        guard result.isComplete else { return result }
        if processTree === tree { processTree = nil }
        await withCheckedContinuation { continuation in
            writes.async { continuation.resume() }
        }
        return result
    }

    /// At the user's request, stop tracking processes that survived TERM/KILL
    /// (another owner, or stuck in the kernel). They stay outside this app's
    /// control; the next connection starts a fresh tree.
    func abandonProcesses() {
        close()
        processTree = nil; cleanup = nil
    }
}

/// The lock covers the byte buffer as readability callbacks may arrive concurrently.
nonisolated private final class ACPStreamReader: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = ACPLineDecoder()
    private var ended = false
    private let continuation: AsyncThrowingStream<ACPJSON, Error>.Continuation

    private let kind: AgentKind

    init(continuation: AsyncThrowingStream<ACPJSON, Error>.Continuation, kind: AgentKind) {
        self.continuation = continuation; self.kind = kind
    }

    func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        do {
            if data.isEmpty { try decoder.finish(); ended = true; continuation.finish(); return }
            for message in try decoder.append(data) {
                if case .dropped = continuation.yield(message) {
                    throw ACPError.message("\(kind.displayName) output exceeded the protocol queue limit. Partial output was preserved.")
                }
            }
        } catch { ended = true; continuation.finish(throwing: error) }
    }
}

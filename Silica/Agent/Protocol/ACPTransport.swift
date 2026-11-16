import Darwin
import Foundation

/// One ordered ingress stream feeds all session state, like Zed's foreground dispatch.
@MainActor
final class ACPTransport {
    var onNotification: ((String, ACPJSON) -> Void)?
    var onRequest: ((String, ACPJSON, ACPJSON) -> Void)?
    var onDisconnect: ((String) -> Void)?

    private var process: Process?
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

    func start(executable: URL, cwd: URL) throws {
        close()
        let generation = UUID()
        self.generation = generation
        let stream = AsyncThrowingStream<ACPJSON, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        continuation = stream.continuation
        let reader = ACPStreamReader(continuation: stream.continuation)
        let process = Process()
        let incoming = Pipe(), outgoing = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        environment["INITIAL_AGENT_MODE"] = "workspace-write"
        // Reuse Codex's own account/config. Never persist or log credentials here.
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
        do { try process.run() } catch { close(); throw error }
        isConnected = true
        consumer = Task { [weak self] in
            do {
                for try await message in stream.stream {
                    guard let self, self.generation == generation, !Task.isCancelled else { return }
                    self.receive(message)
                }
                throw ACPError.message("Codex disconnected. Existing output and file changes are preserved.")
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
                    continuation.resume(throwing: ACPError.message("Connect Codex before sending a request."))
                    return
                }
                pending[key] = continuation
                if let timeout {
                    timeouts[key] = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        self?.resolve(key, result: .failure(ACPError.message("Codex did not answer \(method) in time.")))
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
                        self.onDisconnect?("Could not write to Codex. Reconnect to continue.")
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
        failPending(ACPError.message("The Codex connection was closed."))
        consumer?.cancel(); consumer = nil
        continuation?.finish(); continuation = nil
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
        let process = process
        let input = input
        let stdout = stdout
        let stderr = stderr
        self.input = nil; self.stdout = nil; self.stderr = nil; self.process = nil
        // EOF lets the adapter dispose its Codex child; don't wait on the UI thread.
        writes.async {
            let descendants = process.flatMap { $0.isRunning ? AgentChildProcesses.descendants(of: $0.processIdentifier) : nil } ?? []
            try? input?.close()
            if let process {
                // The adapter supervisor uses up to five seconds to drain/terminate its child.
                let deadline = ProcessInfo.processInfo.systemUptime + 6
                while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { process.terminate() }
                let killDeadline = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning, ProcessInfo.processInfo.systemUptime < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            for pid in descendants where kill(pid, 0) == 0 { kill(pid, SIGTERM) }
            try? stdout?.close(); try? stderr?.close()
        }
    }

    func shutdown() async {
        close()
        await withCheckedContinuation { continuation in
            writes.async { continuation.resume() }
        }
    }
}

nonisolated private enum AgentChildProcesses {
    static func descendants(of parent: Int32) -> [Int32] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,ppid="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let relations = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> (Int32, Int32)? in
            let pair = line.split(whereSeparator: \.isWhitespace)
            guard pair.count == 2, let pid = Int32(pair[0]), let ppid = Int32(pair[1]) else { return nil }
            return (pid, ppid)
        }
        var found: Set<Int32> = [parent]
        var changed = true
        while changed {
            changed = false
            for (pid, ppid) in relations where found.contains(ppid) && !found.contains(pid) {
                found.insert(pid); changed = true
            }
        }
        found.remove(parent)
        return Array(found)
    }
}

/// The lock covers the byte buffer as readability callbacks may arrive concurrently.
nonisolated private final class ACPStreamReader: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = ACPLineDecoder()
    private var ended = false
    private let continuation: AsyncThrowingStream<ACPJSON, Error>.Continuation

    init(continuation: AsyncThrowingStream<ACPJSON, Error>.Continuation) { self.continuation = continuation }

    func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        do {
            if data.isEmpty { try decoder.finish(); ended = true; continuation.finish(); return }
            for message in try decoder.append(data) {
                if case .dropped = continuation.yield(message) {
                    throw ACPError.message("Codex output exceeded the protocol queue limit. Partial output was preserved.")
                }
            }
        } catch { ended = true; continuation.finish(throwing: error) }
    }
}

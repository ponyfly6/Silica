import Darwin
import Foundation

nonisolated struct AgentShutdownResult: Sendable {
    let remainingProcessIDs: [Int32]
    var isComplete: Bool { remainingProcessIDs.isEmpty }
    static let complete = AgentShutdownResult(remainingProcessIDs: [])
}

/// Retain identities while the adapter is alive: after EOF its children may be
/// reparented, and a PID alone could later identify an unrelated process.
nonisolated final class AgentProcessTree: @unchecked Sendable {
    private struct Identity: Hashable {
        let pid: Int32
        let seconds: UInt64
        let microseconds: UInt64

        init(_ info: proc_bsdinfo) {
            pid = Int32(info.pbi_pid)
            seconds = info.pbi_start_tvsec
            microseconds = info.pbi_start_tvusec
        }

        var isRunning: Bool {
            guard let info = AgentProcessTree.info(pid) else { return false }
            return Identity(info) == self && info.pbi_status != SZOMB
        }

        func signal(_ signal: Int32) { if isRunning { kill(pid, signal) } }
    }

    private let queue = DispatchQueue(label: "silica.acp.processes")
    private let root: Identity
    private var known: Set<Identity>
    private var timer: DispatchSourceTimer?
    private var didBeginShutdown = false

    init(pid: Int32, kind: AgentKind) throws {
        guard let info = Self.info(pid) else { throw ACPError.message("Could not track the \(kind.displayName) process.") }
        root = Identity(info)
        known = [root]
        queue.sync { sample() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    /// Called off the UI and writer queues. A blocked stdin write must not prevent
    /// escalation. Repeated calls retry only surviving, identity-checked processes.
    func shutdown(closeInput: @Sendable () -> Void = {}) -> AgentShutdownResult {
        queue.sync {
            timer?.cancel(); timer = nil
            sample()
            closeInput()
            if !didBeginShutdown {
                didBeginShutdown = true
                // EOF gives the adapter supervisor up to five seconds to stop its child.
                wait(seconds: 6, while: { root.isRunning })
            }
            for process in known { process.signal(SIGTERM) }
            wait(seconds: 0.5, while: { known.contains(where: \.isRunning) })
            // Discover children spawned during graceful shutdown before escalating.
            sample()
            for process in known { process.signal(SIGKILL) }
            wait(seconds: 1, while: { known.contains(where: \.isRunning) })
            return AgentShutdownResult(remainingProcessIDs: known.filter(\.isRunning).map(\.pid).sorted())
        }
    }

    private func wait(seconds: TimeInterval, while predicate: () -> Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            sample()
            Thread.sleep(forTimeInterval: 0.02)
        }
        sample()
    }

    private func sample() {
        known = Set(known.filter(\.isRunning))
        var pending = Array(known)
        var visited: Set<Identity> = []
        while let parent = pending.popLast() {
            guard visited.insert(parent).inserted, parent.isRunning else { continue }
            // Enumerate only owned subtrees, not every process on the machine.
            var capacity = max(32, Int(proc_listchildpids(parent.pid, nil, 0)) + 16)
            var pids: [Int32]
            var count: Int32
            repeat {
                pids = [Int32](repeating: 0, count: capacity)
                count = pids.withUnsafeMutableBytes { proc_listchildpids(parent.pid, $0.baseAddress, Int32($0.count)) }
                if count < capacity { break }
                capacity *= 2
            } while true
            guard count > 0 else { continue }
            for pid in pids.prefix(Int(count)) {
                guard let info = Self.info(pid), info.pbi_ppid == parent.pid else { continue }
                let identity = Identity(info)
                known.insert(identity)
                pending.append(identity)
            }
        }
    }

    private static func info(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}

import Darwin
import Foundation

nonisolated struct TerminalShell: Sendable {
    private let pid: pid_t
    private let seconds: UInt64
    private let microseconds: UInt64
    private let executable: String

    init?(pid: pid_t, executable: String) {
        guard pid > 0, let info = Self.info(pid) else { return nil }
        self.pid = pid
        seconds = info.pbi_start_tvsec
        microseconds = info.pbi_start_tvusec
        self.executable = URL(filePath: executable).resolvingSymlinksInPath().path
    }

    private static func info(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != SZOMB else { return nil }
        return info
    }

    private var shellInfo: proc_bsdinfo? {
        guard let info = Self.info(pid), info.pbi_start_tvsec == seconds,
              info.pbi_start_tvusec == microseconds else { return nil }
        return info
    }

    var hasForegroundJob: Bool {
        guard let info = shellInfo, Int32(bitPattern: info.e_tpgid) > 0 else { return false }
        if info.pbi_pgid != info.e_tpgid { return true }
        // An exec'd command keeps the login shell's PID and foreground group.
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let current = String(decoding: path.prefix { $0 != 0 }, as: UTF8.self)
        return URL(filePath: current).resolvingSymlinksInPath().path != executable
    }

    @concurrent func hangUp() async {
        guard shellInfo != nil else { return }
        // forkpty makes the shell the session and group leader. Signal each job
        // group once, before hanging up the leader can dismantle the session.
        let stride = MemoryLayout<pid_t>.stride
        let capacity = max(32, Int(proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)) / stride + 32)
        var members = [pid_t](repeating: 0, count: capacity)
        let bytes = members.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
        }
        var signalled = Set<pid_t>()
        for member in members.prefix(max(0, Int(bytes) / stride)) where member > 0 {
            let group = getpgid(member)
            if group > 0, group != pid, getsid(member) == pid, signalled.insert(group).inserted {
                killpg(group, SIGHUP)
            }
        }
        guard shellInfo != nil else { return }
        if getpgid(pid) == pid { killpg(pid, SIGHUP) }
        else { kill(pid, SIGHUP) }
        try? await Task.sleep(for: .milliseconds(200))
        guard shellInfo != nil else { return }
        kill(pid, SIGTERM)
        try? await Task.sleep(for: .milliseconds(250))
        if shellInfo != nil { kill(pid, SIGKILL) }
    }
}

import Foundation
import Darwin

@main
struct AgentCoreTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); count += 1
        }
        let frame = Data("{\"method\":\"test\",\"params\":{\"text\":\"🐱é\"}}\r\n".utf8)
        var decoder = ACPLineDecoder()
        var values: [ACPJSON] = []
        for byte in frame { values += try decoder.append(Data([byte])) }
        check(values.count == 1 && values[0]["params"]["text"].string == "🐱é", "UTF-8 fragmentation corrupted a message")
        try decoder.finish()
        var combined = ACPLineDecoder()
        let combinedValues = try combined.append(frame + frame)
        check(combinedValues.count == 2, "Multiple frames were not split")
        do { var small = ACPLineDecoder(maximumFrameBytes: 2); _ = try small.append(frame); preconditionFailure("Accepted oversized frame") }
        catch { count += 1 }
        do { var incomplete = ACPLineDecoder(); _ = try incomplete.append(Data("{\"id\":".utf8)); try incomplete.finish(); preconditionFailure("Ignored incomplete EOF") }
        catch { count += 1 }
        do { var invalid = ACPLineDecoder(); _ = try invalid.append(Data("[]\n".utf8)); preconditionFailure("Accepted non-object envelope") }
        catch { count += 1 }

        let turn = AgentTurn(number: 1, prompt: "fixture")
        turn.apply(.object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("tool"), "status": .string("in_progress"),
            "_meta": .object(["terminal_output_delta": .object(["data": .string("first\n")])])]))
        turn.apply(.object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("tool"), "title": .string("echo fixture"),
            "_meta": .object(["terminal_info": .object(["cwd": .string("/fixture")])])]))
        turn.apply(.object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("tool"), "status": .string("completed"),
            "_meta": .object(["terminal_output_delta": .object(["data": .string("second\n")]), "terminal_exit": .object(["exit_code": .number(3)])])]))
        check(turn.items.count == 1, "Tool patches created duplicate items")
        check(turn.items[0].output == "first\nsecond\n", "Terminal deltas were lost or repeated")
        check(turn.items[0].title == "echo fixture" && turn.items[0].cwd == "/fixture", "Omitted fields did not preserve old state")
        check(turn.items[0].exitCode == 3 && !turn.hasUnfinishedCommands, "Exit status was not independent of tool completion")
        let failedCommand = AgentTurn(number: 1, prompt: "failed command")
        failedCommand.apply(.object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("failed"), "status": .string("failed"),
            "_meta": .object(["terminal_info": .object([:])])]))
        check(failedCommand.hasUnfinishedCommands, "Tool failure is not evidence that its process exited")
        failedCommand.apply(.object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("failed"),
            "_meta": .object(["terminal_exit": .object(["signal": .string("SIGTERM")])])]))
        check(!failedCommand.hasUnfinishedCommands && failedCommand.items[0].exitCode == nil, "A signal exit must settle the terminal without inventing an exit code")
        for chunk in ["legacy one\n", "legacy two\n"] {
            turn.apply(.object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("legacy"),
                "_meta": .object(["terminal_output": .object(["data": .string(chunk)])])]))
        }
        check(turn.items.last?.output == "legacy one\nlegacy two\n", "Legacy terminal chunks must append rather than replace")
        turn.apply(.object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("read"), "kind": .string("read")]))
        turn.apply(.object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("read"), "status": .string("completed"),
            "_meta": .object(["terminal_output_delta": .object(["data": .string("file contents")])])]))
        check(!turn.hasUnfinishedCommands && turn.items.last?.output == "file contents", "Read tool output incorrectly requires terminal_exit")

        let overflow = AgentTurn(number: 1, prompt: "large timeline")
        for index in 0..<501 {
            overflow.apply(.object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("tool-\(index)"), "status": .string("completed")]))
        }
        overflow.apply(.object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("tool-500"),
            "_meta": .object(["terminal_info": .object(["terminal_id": .string("terminal")])])]))
        check(overflow.items.count == 500 && overflow.omittedToolCount == 1 && overflow.timelineNotice != nil, "Timeline overflow must be visible and bounded")
        check(overflow.hasUnfinishedCommands, "An undisplayed terminal must still hold completion open, even without cwd")
        overflow.apply(.object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("tool-500"),
            "_meta": .object(["terminal_exit": .object(["exit_code": .number(7)])])]))
        check(!overflow.hasUnfinishedCommands && overflow.timelineNotice?.contains("1 failed") == true, "An undisplayed command lost its exit/failure state")
        overflow.apply(.object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("tool-0"), "status": .string("failed")]))
        check(overflow.items[0].status == "failed", "Presentation overflow stopped updates to retained tools")

        let interrupted = AgentTurn(number: 1, prompt: "cancel")
        interrupted.apply(.object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("command"), "status": .string("completed"),
            "_meta": .object(["terminal_info": .object(["cwd": .string("/fixture")])])]))
        interrupted.apply(.object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("read"), "status": .string("in_progress")]))
        interrupted.apply(.object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("done"), "status": .string("completed")]))
        interrupted.finishTools("cancelled")
        check(!interrupted.hasUnfinishedCommands && interrupted.items[0].displayStatus == "cancelled" && interrupted.items[0].exitCode == nil, "Cancellation must settle commands without inventing exit codes")
        check(interrupted.items[1].displayStatus == "cancelled" && interrupted.items[2].displayStatus == "completed", "Cancellation changed a completed read or left an active tool running")
        interrupted.apply(.object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("command"), "status": .string("in_progress")]))
        check(interrupted.items[0].displayStatus == "cancelled" && !interrupted.hasUnfinishedCommands, "A late reported status revived a locally cancelled command")
        overflow.apply(.object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("hidden-running"), "status": .string("in_progress"),
            "_meta": .object(["terminal_info": .object([:])])]))
        overflow.finishTools("interrupted")
        check(!overflow.hasUnfinishedCommands && overflow.timelineNotice?.contains("1 cancelled or interrupted") == true, "Disconnect failed to settle hidden tools")

        let truncated = AgentTurn(number: 1, prompt: "bounded text")
        let largeText = String(repeating: "🐱", count: 70_000)
        truncated.apply(.object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["text": .string(largeText)])]))
        truncated.apply(.object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["text": .string("tail")])]))
        check(truncated.items[0].text.utf8.count <= 262_144 && truncated.items[0].textTruncated && !truncated.items[0].text.contains("�"), "Assistant truncation must be explicit and UTF-8 bounded")
        truncated.apply(.object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("output"),
            "_meta": .object(["terminal_output_delta": .object(["data": .string(String(repeating: "é", count: 600_000))])])]))
        check(truncated.items[1].output.utf8.count <= 1_048_576 && truncated.items[1].outputTruncated, "Tool output exceeded its byte cap")
        truncated.apply(.object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("output"),
            "content": .array([.object(["content": .object(["text": .string(String(repeating: "x", count: 1_048_577))])])])]))
        check(truncated.items[1].contentText.utf8.count == 1_048_576 && truncated.items[1].outputTruncated, "Structured output truncation was silent")
        var accepted = true
        for index in 1..<20_000 {
            accepted = overflow.apply(.object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("more-\(index)")]))
        }
        check(!accepted && overflow.eventLimitExceeded, "Exhausting lifecycle storage must request a stop, not silently drop tools")

        let fixture = URL(filePath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appending(path: "silica-agent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appending(path: path)) }
        try write("old.txt", "before\n")
        try write("dirty.txt", "pre-existing user edit\n")
        try write("delete.txt", "remove me\n")
        try write(".gitignore", "*.ignored\n")
        try write("skip.ignored", "ignored\n")
        let nonGit = try TurnSnapshot.capture(root: root)
        check(Set(nonGit.entries.keys) == ["old.txt", "dirty.txt", "delete.txt", ".gitignore"], "Non-Git discovery: \(nonGit.entries.keys.sorted())")
        let git = Process()
        git.executableURL = URL(filePath: "/usr/bin/git"); git.currentDirectoryURL = root
        git.arguments = ["init", "-q"]; try git.run(); git.waitUntilExit()
        let add = Process()
        add.executableURL = git.executableURL; add.currentDirectoryURL = root
        add.arguments = ["add", "old.txt", "dirty.txt", "delete.txt", ".gitignore"]
        try add.run(); add.waitUntilExit()
        // A tracked file remains eligible after a new ignore rule matches it.
        try write(".gitignore", "*.ignored\nold.txt\n")
        let before = try TurnSnapshot.capture(root: root)
        check(before.entries["old.txt"]?.text == "before\n", "Tracked ignored file was lost")
        check(before.entries["skip.ignored"] == nil, "Ignored untracked file was captured")
        try write("old.txt", "after\n")
        try write("new.txt", "new file\n")
        try FileManager.default.removeItem(at: root.appending(path: "delete.txt"))
        let after = try TurnSnapshot.capture(root: root, including: Set(before.entries.keys))
        let changes = after.changes(comparedTo: before)
        check(Set(changes.map(\.path)) == ["old.txt", "new.txt", "delete.txt"], "Turn changes included an existing edit or missed a new/deleted file")
        check(changes.first { $0.path == "delete.txt" }?.kind == .deleted, "Deleted file kind is wrong")
        check(changes.first { $0.path == "new.txt" }?.originalText == "", "New file requires an empty original")
        try write("old.txt", "later edit\n")
        check(changes.first { $0.path == "old.txt" }?.updatedText == "after\n", "A later edit changed the frozen review")
        let limited = try TurnSnapshot.capture(root: root, byteBudget: 0)
        check(limited.storedBytes == 0 && !limited.warnings.isEmpty, "Snapshot limits were silent")
        check(AgentPaths.overlaps(root, root.appending(path: "nested")), "Nested roots must share a lease")
        check(!AgentPaths.overlaps(root, URL(filePath: root.path + "-sibling")), "Path prefixes are not ancestry")
        check(AgentPaths.safeURL("../escape", root: root) == nil, "Accepted parent traversal")
        try FileManager.default.createSymbolicLink(at: root.appending(path: "outside"), withDestinationURL: URL(filePath: "/etc/hosts"))
        let links = try TurnSnapshot.capture(root: root)
        check(links.entries["outside"]?.bytes == nil, "Read an external symlink target")

        let transport = ACPTransport()
        var sequence: [Int] = []
        transport.onNotification = { _, params in if let value = params["sequence"].integer { sequence.append(value) } }
        transport.onRequest = { _, id, _ in transport.respond(id: id, result: .object(["outcome": .string("fixture-selected")])) }
        try await transport.start(executable: fixture, cwd: root)
        let echo = try await transport.request("echo", params: .object(["text": .string("roundtrip 🐱")]))
        check(echo["text"].string == "roundtrip 🐱", "RPC response was not matched to its request")
        _ = try await transport.request("notify", params: .object([:]))
        check(sequence == Array(0..<20), "Notifications were reordered relative to the response")
        let permission = try await transport.request("permission", params: .object([:]))
        check(permission["outcome"].string == "fixture-selected", "Agent-to-client response did not complete")
        do { _ = try await transport.request("hang", params: .null, timeout: .milliseconds(100)); preconditionFailure("Missing RPC timeout") }
        catch { count += 1 }
        let echoed = try await transport.request("echo", params: .string("after-timeout"))
        check(echoed.string == "after-timeout", "Timed-out continuation broke later responses")
        do { _ = try await transport.request("broken-eof", params: .null); preconditionFailure("Missing EOF error") }
        catch { count += 1 }
        await transport.shutdown()
        check(!transport.isConnected, "Shutdown did not close the transport")

        let processFixture = URL(filePath: CommandLine.arguments[2])
        for method in ["spawn-writer", "orphan", "spawn-on-eof", "block-stdin"] {
            let processTransport = ACPTransport()
            let heartbeat = root.appending(path: "\(method).heartbeat")
            try await processTransport.start(executable: processFixture, cwd: root)
            let result = try await processTransport.request(method, params: .object(["path": .string(heartbeat.path)]))
            var pid = result["pid"].integer.map { Int32($0) }
            defer { if let pid, isRunning(pid) { kill(pid, SIGKILL) } }
            if method == "orphan" { try await Task.sleep(for: .milliseconds(500)) }
            var blockedWrite: Task<Void, Never>?
            if method == "block-stdin" {
                blockedWrite = Task { _ = try? await processTransport.request("large-write", params: .object(["data": .string(String(repeating: "x", count: 1_048_576))])) }
                try await Task.sleep(for: .milliseconds(100))
            }
            let shutdown = await processTransport.shutdown()
            await blockedWrite?.value
            if method == "spawn-on-eof" {
                pid = Int32(try String(contentsOf: URL(filePath: heartbeat.path + ".pid"), encoding: .utf8))
            }
            check(shutdown.isComplete && pid.map({ !isRunning($0) }) == true, "\(method): shutdown left an owned process alive")
            let frozen = try Data(contentsOf: heartbeat)
            try await Task.sleep(for: .milliseconds(150))
            let later = try Data(contentsOf: heartbeat)
            check(frozen == later, "\(method): a child continued writing after shutdown returned")
        }
        print("PASS: \(count) ACP framing, ordered dispatch, RPC, tool events, cancellation boundaries and per-turn snapshot checks")
    }

    nonisolated static func isRunning(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status != SZOMB
    }
}

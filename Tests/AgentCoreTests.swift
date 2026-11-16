import Foundation

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
        for chunk in ["legacy one\n", "legacy two\n"] {
            turn.apply(.object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("legacy"),
                "_meta": .object(["terminal_output": .object(["data": .string(chunk)])])]))
        }
        check(turn.items.last?.output == "legacy one\nlegacy two\n", "Legacy terminal chunks must append rather than replace")
        turn.apply(.object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("read"), "kind": .string("read")]))
        turn.apply(.object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("read"), "status": .string("completed"),
            "_meta": .object(["terminal_output_delta": .object(["data": .string("file contents")])])]))
        check(!turn.hasUnfinishedCommands && turn.items.last?.output == "file contents", "Read tool output incorrectly requires terminal_exit")

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
        try transport.start(executable: fixture, cwd: root)
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
        print("PASS: \(count) ACP framing, ordered dispatch, RPC, tool events, cancellation boundaries and per-turn snapshot checks")
    }
}

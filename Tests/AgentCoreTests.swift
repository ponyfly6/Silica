import Foundation
import Darwin

@main
struct AgentCoreTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); count += 1
        }
        let preferred = 700.0
        let narrow = WorkspaceLayout.panelWidth(preferred: preferred, available: 920)
        check(narrow == 500 && 920 - narrow == WorkspaceLayout.minimumEditorWidth, "Narrow window squeezed the editor")
        check(WorkspaceLayout.panelWidth(preferred: preferred, available: 1300) == preferred, "Wider window lost the preferred width")
        check(WorkspaceLayout.panelWidth(preferred: 250, available: 720) == 300, "Panel fell below its minimum")
        check(WorkspaceLayout.panelWidth(preferred: 900, available: 1600) == 820, "Panel exceeded its maximum")

        let grouped: ACPJSON = .object(["id": .string("fixture-effort"), "category": .string("thought_level"),
            "type": .string("select"), "currentValue": .string("medium"), "options": .array([
                .object(["options": .array([.object(["value": .string("medium")])])]),
                .object(["options": .array([.object(["value": .string("high"), "name": .string("High")])])])
            ])])
        let levels = AgentConfigOption.parse(.array([grouped]))
        check(levels.first?.choices.map(\.name) == ["medium", "High"], "Grouped choices lost their order or display names")
        let model = AgentConfigOption(id: "backend-model", name: "Model", category: "model", value: "standard",
                                      choices: [.init(id: "small", name: "Small")])
        let options = levels + [model]
        check(AgentPreference.allCases == [.model, .thoughtLevel], "Reasoning must be restored after the model")
        check(AgentPreference.model.option(toApply: "small", in: options)?.id == model.id &&
              AgentPreference.thoughtLevel.option(toApply: "high", in: options)?.id == "fixture-effort", "Lost adapter-specific option IDs")
        check(AgentPreference.model.option(toApply: "removed", in: options) == nil, "Applied an unavailable model")
        check(AgentPreference.thoughtLevel.option(toApply: "medium", in: options) == nil, "Reapplied the current level")
        let reduced = AgentConfigOption(id: "fixture-effort", name: "Effort", category: "thought_level", value: "low",
                                        choices: [.init(id: "low", name: "Low")])
        check(AgentPreference.thoughtLevel.option(toApply: "high", in: [model, reduced]) == nil, "Applied a level missing after the model change")
        for preference in AgentPreference.allCases {
            check(preference.key(for: .codex) != preference.key(for: .claude), "Agents share a preference key")
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
        let decisions: [(AgentKind, [String], String?, AgentKind.ModeDecision)] = [
            (.codex, [], nil, .keep),
            (.claude, [], nil, .fail),
            (.codex, ["workspace-write", "read-only"], "read-only", .keep),
            (.codex, ["read-only", "workspace-write"], "workspace-write", .keep),
            (.codex, ["bypassPermissions", "workspace-write"], "danger-full-access", .switchTo("workspace-write")),
            (.codex, ["read-only", "bypassPermissions"], "danger-full-access", .fail),
            (.claude, ["default", "acceptEdits", "auto"], "bypassPermissions", .switchTo("auto")),
            (.claude, ["default", "acceptEdits"], "bypassPermissions", .switchTo("acceptEdits")),
            (.claude, ["plan", "default"], "unknown", .switchTo("default")),
            (.claude, ["plan", "dontAsk", "bypassPermissions"], "bypassPermissions", .fail)
        ]
        for (kind, offered, current, expected) in decisions {
            check(kind.modeDecision(offered: offered, current: current) == expected, "\(kind) mode policy for \(current ?? "unspecified"), \(offered)")
        }
        for mode in ["auto", "default", "acceptEdits", "plan", "dontAsk"] {
            check(AgentKind.claude.modeDecision(offered: [mode, "auto"], current: mode) == .keep, "Replaced allowed Claude mode \(mode)")
        }

        let support = root.appending(path: "support"), checkout = root.appending(path: "checkout"), bin = root.appending(path: "bin")
        for (kind, directory, name) in [(AgentKind.codex, "CodexACP", "codex-acp"), (.claude, "ClaudeACP", "claude-agent-acp")] {
            func find(_ path: String = "") -> URL? {
                kind.find(configuredPath: path, supportDirectory: support, checkoutFrom: checkout.appending(path: "build"), binDirectories: [bin])
            }
            let relative = "\(directory)/node_modules/.bin/\(name)"
            for candidate in [bin.appending(path: name), checkout.appending(path: "Tools/\(relative)"), support.appending(path: relative)] {
                try FileManager.default.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: fixture)
                check(find()?.standardizedFileURL == candidate.standardizedFileURL, "Wrong discovery precedence for \(name)")
            }
            check(find(fixture.path)?.standardizedFileURL == fixture.standardizedFileURL && find(root.path) == nil && find(root.appending(path: "missing").path) == nil,
                  "Explicit \(name) path should be authoritative and executable")
        }

        let claude = AgentTurn(number: 1, prompt: "Claude fixture")
        let path = root.appending(path: "main.swift").path
        claude.apply(.object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("toolu_edit"), "kind": .string("edit"),
            "locations": .array([.object(["path": .string(path), "line": .number(1)])])]), projectRoot: root)
        claude.apply(.object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("toolu_edit"), "status": .string("completed"),
            "content": .array([.object(["type": .string("diff"), "path": .string(path), "oldText": .string("old"), "newText": .string("new")])])]), projectRoot: root)
        check(claude.editedFiles == ["main.swift"], "Claude edit locations and diff paths should yield one project file")
        claude.apply(.object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("toolu_bash"), "kind": .string("execute"),
            "title": .string("Bash"), "rawInput": .object(["command": .string("pwd")])]))
        claude.apply(.object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("toolu_bash"), "status": .string("completed"),
            "content": .array([.object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string(root.path)])])])]))
        check(claude.items.last?.displayOutput == root.path && claude.items.last?.exitCode == nil && !claude.hasUnfinishedCommands,
              "Claude shell output should be visible and complete without a terminal exit")

        // Claude ACP 0.109.0 with the terminal-output extension. Both output reports describe the same bytes.
        let bashEvents = [
            #"{"sessionUpdate":"tool_call","toolCallId":"bash","kind":"execute","status":"pending","content":[{"type":"terminal","terminalId":"t"}],"_meta":{"claudeCode":{"toolName":"Bash"},"terminal_info":{"terminal_id":"t"}}}"#,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"bash","_meta":{"claudeCode":{"toolName":"Bash","toolResponse":{"stdout":"alpha\nadded\nOK","stderr":""}}}}"#,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"bash","_meta":{"terminal_output_delta":{"terminal_id":"t","data":"alpha\nadded\nOK"}}}"#,
            #"{"sessionUpdate":"tool_call_update","toolCallId":"bash","status":"completed","_meta":{"terminal_exit":{"terminal_id":"t","exit_code":0,"signal":null}}}"#
        ]
        for event in bashEvents.dropLast() { claude.apply(try JSONDecoder().decode(ACPJSON.self, from: Data(event.utf8))) }
        check(claude.items.last?.displayOutput == "alpha\nadded\nOK" && claude.items.last?.exitCode == nil && claude.hasUnfinishedCommands,
              "Claude display terminal must show one copy of stdout and wait for the reported exit")
        claude.apply(try JSONDecoder().decode(ACPJSON.self, from: Data(bashEvents.last!.utf8)))
        check(claude.items.last?.displayOutput == "alpha\nadded\nOK" && claude.items.last?.exitCode == 0 && !claude.hasUnfinishedCommands,
              "Claude terminal exit must settle its tool and preserve the output")

        func editEvent(_ event: String, _ id: String, _ kind: String?, locations: [String] = [], diffs: [String] = []) {
            var fields: [String: ACPJSON] = [
                "sessionUpdate": .string(event), "toolCallId": .string(id),
                "locations": .array(locations.map { .object(["path": .string($0)]) }),
                "content": .array(diffs.map { .object(["type": .string("diff"), "path": .string($0)]) }
                    + [.object(["type": .string("content"), "path": .string("irrelevant")])])
            ]
            fields["kind"] = kind.map(ACPJSON.string)
            turn.apply(.object(fields), projectRoot: root)
        }
        let outside = root.deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: root.appending(path: "outside"), withDestinationURL: outside)
        editEvent("tool_call", "patch", "edit", locations: ["one", root.appending(path: "one").path],
                  diffs: ["two", "../escape", outside.appending(path: "escape").path, "outside/missing"])
        editEvent("tool_call_update", "patch", nil, diffs: ["three", "one"])
        editEvent("tool_call_update", "delete", "delete", diffs: ["deleted"])
        editEvent("tool_call", "rename", "move", locations: ["old", "new"])
        for kind in ["read", "execute"] { editEvent("tool_call", kind, kind, locations: ["ignored"], diffs: ["ignored"]) }
        check(turn.editedFiles == ["one", "two", "three", "deleted", "old", "new"],
              "Incorrect project-relative edited files or order: \(turn.editedFiles)")
        editEvent("tool_call_update", "patch", nil, locations: (0..<501).map { "file-\($0)" })
        check(turn.editedFiles.count == 500 && turn.editedFiles.last == "file-493" && turn.editedFilesTruncated,
              "Edited file cap did not preserve the first 500 paths")

        let transport = ACPTransport()
        var sequence: [Int] = []
        transport.onNotification = { _, params in if let value = params["sequence"].integer { sequence.append(value) } }
        transport.onRequest = { _, id, _ in transport.respond(id: id, result: .object(["outcome": .string("fixture-selected")])) }
        try await transport.start(executable: fixture, cwd: root, kind: .codex)
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
            try await processTransport.start(executable: processFixture, cwd: root, kind: .codex)
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
        print("PASS: \(count) panel sizing, agent preferences, discovery, mode policy, ACP framing, ordered dispatch, RPC, tool events, process cleanup and edited-file checks")
    }

    nonisolated static func isRunning(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status != SZOMB
    }
}

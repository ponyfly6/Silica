import Foundation

/// Explicit opt-in integration test. Uses the real adapter and the user's Codex
/// login, but only sends synthetic files created in a disposable project.
@main
struct ACPLiveSmoke {
    @MainActor static func main() async throws {
        func require(_ condition: Bool, _ message: String = "Live integration assertion failed") throws {
            guard condition else { throw ACPError.message(message) }
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "silica-acp-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appending(path: path)) }
        try write("message.txt", "before\n")
        try write("keep.txt", "pre-existing user modification\n")
        try write("removed.txt", "delete this fixture\n")
        try write(".gitignore", "*.ignored\n")
        let transport = ACPTransport()
        var updates: [ACPJSON] = []
        var sessionID = ""
        var cancelling = false
        var cancellationSent = false
        var rejectedPermissions = 0
        transport.onNotification = { method, params in
            guard method == "session/update" else { return }
            let update = params["update"]
            updates.append(update)
            if cancelling, !cancellationSent,
               update["_meta"]["terminal_output_delta"]["data"].string?.contains("SILICA_CANCEL_READY") == true {
                cancellationSent = true
                transport.notify("session/cancel", params: .object(["sessionId": .string(sessionID)]))
            }
        }
        transport.onRequest = { method, id, params in
            if method == "session/request_permission" {
                if let reject = params["options"].array.first(where: { $0["kind"].string == "reject_once" }),
                   let option = reject["optionId"].string {
                    rejectedPermissions += 1
                    transport.respond(id: id, result: .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(option)])]))
                } else { transport.respond(id: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])])) }
            } else { transport.reject(id: id, message: "Not advertised in this test") }
        }
        let executable = URL(filePath: CommandLine.arguments[1])
        func initialize() async throws -> ACPJSON {
            try transport.start(executable: executable, cwd: root)
            return try await transport.request("initialize", params: .object([
                "protocolVersion": .number(1), "clientInfo": .object(["name": .string("silica-workbench-test"), "version": .string("0.1.0")]),
                "clientCapabilities": .object(["terminal": .bool(false), "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]),
                                               "_meta": .object(["terminal_output": .bool(true), "terminal_output_delta": .bool(true)])])
            ]))
        }
        func prompt(_ text: String) async throws -> ACPJSON {
            try await transport.request("session/prompt", params: .object([
                "sessionId": .string(sessionID), "prompt": .array([.object(["type": .string("text"), "text": .string(text)])])
            ]), timeout: .seconds(120))
        }
        do {
            let initialized = try await initialize()
            try require(initialized["protocolVersion"].integer == 1)
            let session = try await transport.request("session/new", params: .object(["cwd": .string(root.path), "mcpServers": .array([])]))
            guard let id = session["sessionId"].string else { throw ACPError.message("No session ID") }
            sessionID = id
            let options = AgentConfigOption.parse(session["configOptions"])
            if let effort = options.first(where: { $0.category == "thought_level" }), effort.choices.contains(where: { $0.id == "low" }) {
                _ = try await transport.request("session/set_config_option", params: .object([
                    "sessionId": .string(id), "configId": .string(effort.id), "value": .string("low")
                ]))
            }
            let before = try TurnSnapshot.capture(root: root)
            let result = try await prompt("Only modify this synthetic project: set message.txt to alpha plus a newline, create added.txt containing added plus a newline, delete removed.txt. Leave keep.txt and .gitignore unchanged. Run a command verifying those results and printing SILICA_TURN_ONE_OK. Do not leave background jobs running. Finish this small task without questions.")
            try require(result["stopReason"].string == "end_turn", "Turn one did not finish")
            let after = try TurnSnapshot.capture(root: root, including: Set(before.entries.keys))
            let firstChanges = after.changes(comparedTo: before)
            try JSONEncoder().encode(updates).write(to: root.appendingPathExtension("protocol.json"))
            try require(Set(firstChanges.map(\.path)) == ["message.txt", "added.txt", "removed.txt"], "Incorrect first-turn changes: \(firstChanges.map(\.path))")
            let firstTimeline = AgentTurn(number: 1, prompt: "test")
            for update in updates { firstTimeline.apply(update) }
            try require(firstTimeline.items.contains { $0.exitCode == 0 && $0.output.contains("SILICA_TURN_ONE_OK") }, "Command output or exit code was not delivered")
            try require(firstTimeline.items.contains { $0.kind == .assistant && !$0.text.isEmpty }, "No streamed answer")
            try require(!firstTimeline.hasUnfinishedCommands, "Finished first turn still requires an exit event")
            print("PASS: live turn one, streamed dialogue, command output/exit, added/modified/deleted review")

            try write("message.txt", "user follow-up\n")
            let beforeSecond = try TurnSnapshot.capture(root: root)
            updates = []
            let second = try await prompt("I manually changed message.txt. Read it again, preserve its existing first line exactly, and append beta followed by a newline. Do not change any other file. Run a command to verify the result and print SILICA_TURN_TWO_OK.")
            try require(second["stopReason"].string == "end_turn")
            let secondTimeline = AgentTurn(number: 2, prompt: "test")
            for update in updates { secondTimeline.apply(update) }
            try require(!secondTimeline.hasUnfinishedCommands, "Finished read/command tools still require an exit event")
            let afterSecond = try TurnSnapshot.capture(root: root, including: Set(beforeSecond.entries.keys))
            let secondChanges = afterSecond.changes(comparedTo: beforeSecond)
            try require(secondChanges.count == 1 && secondChanges[0].path == "message.txt")
            try require(secondChanges[0].originalText == "user follow-up\n" && secondChanges[0].updatedText == "user follow-up\nbeta\n")
            try require(firstChanges.first { $0.path == "message.txt" }?.updatedText == "alpha\n", "First review changed after turn two")
            let keptAfterSecond = try String(contentsOf: root.appending(path: "keep.txt"), encoding: .utf8)
            try require(keptAfterSecond == "pre-existing user modification\n")
            print("PASS: live turn two, manual edits preserved, correct new baseline, immutable previous review")

            let beforeCancel = try TurnSnapshot.capture(root: root)
            cancelling = true; updates = []
            let cancelled = try await prompt("Run exactly one command in the foreground: python3 -u -c \"from pathlib import Path; import time; Path('partial.txt').write_text('partial change\\n'); print('SILICA_CANCEL_READY', flush=True); time.sleep(15)\". Do not edit any other files or start any other task. Wait for the command to exit.")
            try require(cancellationSent, "Cancellation marker was not streamed")
            try require(cancelled["stopReason"].string == "cancelled", "Session cancellation did not reach the prompt")
            await transport.shutdown()
            let afterCancel = try TurnSnapshot.capture(root: root, including: Set(beforeCancel.entries.keys))
            try require(afterCancel.changes(comparedTo: beforeCancel).contains { $0.path == "partial.txt" }, "Cancelled task lost its partial file change")
            print("PASS: live cancellation, connection shutdown, partial change review")

            cancelling = false
            _ = try await initialize()
            _ = try await transport.request("session/load", params: .object(["sessionId": .string(sessionID), "cwd": .string(root.path), "mcpServers": .array([])]))
            let resumed = try await prompt("Reply exactly SILICA_RECONNECTED. Do not run tools or change files.")
            try require(resumed["stopReason"].string == "end_turn")
            print("PASS: live reconnect and session/load continuation")

            _ = try await transport.request("session/set_config_option", params: .object([
                "sessionId": .string(sessionID), "configId": .string("mode"), "value": .string("read-only")
            ]))
            _ = try await prompt("Use apply_patch to change keep.txt to changed. If permission is rejected, stop immediately and report rejection; do not retry, use another method, or request a broader mode.")
            let keptAfterPermission = try String(contentsOf: root.appending(path: "keep.txt"), encoding: .utf8)
            try require(keptAfterPermission == "pre-existing user modification\n", "A rejected/read-only operation changed the file")
            print(rejectedPermissions > 0 ? "PASS: live permission request rejected; file unchanged" : "NOTE: read-only kept the file unchanged without emitting a permission request")
            await transport.shutdown()
            print("LIVE_FIXTURE: \(root.path)")
        } catch {
            await transport.shutdown()
            print("LIVE_FIXTURE: \(root.path)")
            throw error
        }
    }
}

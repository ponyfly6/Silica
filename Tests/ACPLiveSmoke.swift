import Foundation

/// Explicit opt-in integration test. Uses the selected adapter and the user's
/// login, but only sends synthetic files created in a disposable project.
@main
struct ACPLiveSmoke {
    @MainActor static func main() async throws {
        func require(_ condition: Bool, _ message: String = "Live integration assertion failed") throws {
            guard condition else { throw ACPError.message(message) }
        }
        let environment = ProcessInfo.processInfo.environment
        guard let kind = AgentKind(rawValue: environment["AGENT"] ?? "codex") else { throw ACPError.message("Unknown AGENT") }
        let configured = environment["SILICA_\(kind.rawValue.uppercased())_ACP"] ?? ""
        guard let executable = kind.find(configuredPath: configured, checkoutFrom: URL(filePath: CommandLine.arguments[1])) else {
            throw ACPError.message("Install \(kind.displayName) with bash \(kind.installScript).")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "silica-acp-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appending(path: path)) }
        func read(_ path: String) throws -> String { try String(contentsOf: root.appending(path: path), encoding: .utf8) }
        try write("message.txt", "before\n")
        try write("keep.txt", "pre-existing user modification\n")
        try write("removed.txt", "delete this fixture\n")
        try write(".gitignore", "*.ignored\n")
        let transport = ACPTransport()
        var updates: [ACPJSON] = []
        var sessionID = ""
        let quotedRoot = "'" + root.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let inProject = "cd \(quotedRoot) && "
        let remove = inProject + "rm removed.txt"
        let verify = inProject + "cat message.txt added.txt && echo SILICA_TURN_ONE_OK"
        let verifyAgain = inProject + "cat message.txt && echo SILICA_TURN_TWO_OK"
        let cancelScript = """
        from pathlib import Path
        import time
        Path(__file__).with_name("partial.txt").write_text("partial change\\n")
        print("SILICA_CANCEL_READY", flush=True)
        time.sleep(15)
        """
        try write("cancel.py", cancelScript)
        let cancelCommand = inProject + "python3 -u cancel.py"
        var cancelling = false
        var testingRejection = false

        func permitsFixtureShell(_ tool: ACPJSON) -> Bool {
            guard kind == .claude, !testingRejection, tool["kind"].string == "execute",
                  let command = tool["rawInput"]["command"].string else { return false }
            // Accept the fixture operations with or without a quoted cd prefix.
            return command.components(separatedBy: "&&").allSatisfy { part in
                let operation = part.trimmingCharacters(in: .whitespaces)
                if operation.hasPrefix("cd ") {
                    let path = operation.dropFirst(3).trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                    return [root.path, root.resolvingSymlinksInPath().path].contains(path)
                }
                let words = operation.split(whereSeparator: { $0 == " " || $0 == "\t" }).map {
                    String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                }
                switch words.first {
                case "cat": return words == ["cat", "message.txt", "added.txt"] || words == ["cat", "message.txt"]
                case "echo": return words == ["echo", "SILICA_TURN_ONE_OK"] || words == ["echo", "SILICA_TURN_TWO_OK"]
                case "rm": return words == ["rm", "removed.txt"] || words == ["rm", "-f", "removed.txt"]
                case "python3": return cancelling && words == ["python3", "-u", "cancel.py"] && (try? read("cancel.py")) == cancelScript
                default: return false
                }
            }
        }
        var cancellationSent = false
        func cancelPrompt() {
            guard cancelling, !cancellationSent else { return }
            cancellationSent = true
            transport.notify("session/cancel", params: .object(["sessionId": .string(sessionID)]))
        }
        var rejectedFixtureWrites = 0
        transport.onNotification = { method, params in
            guard method == "session/update" else { return }
            let update = params["update"]
            updates.append(update)
            if kind == .codex, update["_meta"]["terminal_output_delta"]["data"].string?.contains("SILICA_CANCEL_READY") == true {
                cancelPrompt()
            }
        }
        transport.onRequest = { method, id, params in
            if method == "session/request_permission", params["sessionId"].string == sessionID {
                let tool = params["toolCall"]
                let allow = permitsFixtureShell(tool)
                let action = allow ? "allow_once" : "reject_once"
                if let choice = params["options"].array.first(where: { $0["kind"].string == action }),
                   let option = choice["optionId"].string {
                    if testingRejection {
                        let target = tool["rawInput"]["file_path"].string ?? tool["locations"].array.first?["path"].string
                        let command = tool["rawInput"]["command"].string ?? ""
                        if target.flatMap({ AgentPaths.relativePath($0, root: root) }) == "keep.txt" || command.contains("keep.txt") {
                            rejectedFixtureWrites += 1
                        }
                    }
                    transport.respond(id: id, result: .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(option)])]))
                } else { transport.respond(id: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])])) }
            } else { transport.reject(id: id, message: "Not advertised in this test") }
        }
        func initialize() async throws -> ACPJSON {
            try await transport.start(executable: executable, cwd: root, kind: kind)
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
        func setMode(_ value: String, options: [AgentConfigOption]) async throws {
            guard let mode = options.first(where: { $0.category == "mode" }), kind.allowedModes.contains(value),
                  mode.choices.contains(where: { $0.id == value }) else { throw ACPError.message("Missing smoke test mode \(value)") }
            let adjusted = try await transport.request("session/set_config_option", params: .object([
                "sessionId": .string(sessionID), "configId": .string(mode.id), "value": .string(value)
            ]))
            try require(AgentConfigOption.parse(adjusted["configOptions"]).contains { $0.id == mode.id && $0.value == value },
                        "The adapter did not confirm \(value) mode")
        }
        do {
            let initialized = try await initialize()
            try require(initialized["protocolVersion"].integer == 1)
            let session = try await transport.request("session/new", params: .object(["cwd": .string(root.path), "mcpServers": .array([])]))
            guard let id = session["sessionId"].string else { throw ACPError.message("No session ID") }
            sessionID = id
            let options = try await kind.sessionOptions(session, sessionID: id, transport: transport)
            if kind == .claude { try await setMode("acceptEdits", options: options) }
            if let effort = options.first(where: { $0.category == "thought_level" }), effort.choices.contains(where: { $0.id == "low" }) {
                _ = try await transport.request("session/set_config_option", params: .object([
                    "sessionId": .string(id), "configId": .string(effort.id), "value": .string("low")
                ]))
            }
            let result = try await prompt("Only modify this synthetic project: set message.txt to alpha plus a newline, create added.txt containing added plus a newline, delete removed.txt with this exact command: \(remove). Leave keep.txt and .gitignore unchanged. Use the edit tools for writing files. Run this verification command exactly: \(verify). Do not leave background jobs running. Finish this small task without questions.")
            try require(result["stopReason"].string == "end_turn", "Turn one did not finish")
            try require(try read("message.txt") == "alpha\n" && read("added.txt") == "added\n")
            try require(!FileManager.default.fileExists(atPath: root.appending(path: "removed.txt").path))
            try require(try read("keep.txt") == "pre-existing user modification\n" && read(".gitignore") == "*.ignored\n")
            let firstTimeline = AgentTurn(number: 1, prompt: "test")
            for update in updates { firstTimeline.apply(update) }
            try require(firstTimeline.items.contains { item in
                item.kind == .tool && item.displayOutput.contains("SILICA_TURN_ONE_OK") && (item.exitCode == 0 || (kind == .claude && !item.hasTerminal))
            }, "Command output was not delivered")
            try require(firstTimeline.items.contains { $0.kind == .assistant && !$0.text.isEmpty }, "No streamed answer")
            try require(!firstTimeline.hasUnfinishedCommands, "Finished first turn still requires an exit event")
            print("PASS: live turn one, streamed dialogue, command output, added/modified/deleted files")

            try write("message.txt", "user follow-up\n")
            updates = []
            let second = try await prompt("I manually changed message.txt. Read it again, preserve its existing first line exactly, and append beta followed by a newline. Do not change any other file. Run this verification command exactly: \(verifyAgain).")
            try require(second["stopReason"].string == "end_turn")
            let secondTimeline = AgentTurn(number: 2, prompt: "test")
            for update in updates { secondTimeline.apply(update) }
            try require(secondTimeline.items.contains { $0.kind == .tool && $0.displayOutput.contains("SILICA_TURN_TWO_OK") }, "Missing turn two command output")
            try require(!secondTimeline.hasUnfinishedCommands, "Finished read/command tools still require an exit event")
            try require(try read("message.txt") == "user follow-up\nbeta\n" && read("added.txt") == "added\n")
            let keptAfterSecond = try String(contentsOf: root.appending(path: "keep.txt"), encoding: .utf8)
            try require(keptAfterSecond == "pre-existing user modification\n")
            print("PASS: live turn two, external edit preserved on disk")

            cancelling = true
            // Claude can buffer shell output until completion. Observe the fixture write while the command sleeps.
            let cancel = Task {
                while kind == .claude, !Task.isCancelled {
                    if (try? read("partial.txt")) == "partial change\n" {
                        cancelPrompt()
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            defer { cancel.cancel() }
            let cancelled = try await prompt("Run exactly one command in the foreground: \(cancelCommand). Do not edit any other files or start any other task. Wait for the command to exit.")
            cancelling = false
            try require(cancellationSent, "The command did not reach its cancellation marker")
            try require(cancelled["stopReason"].string == "cancelled", "Session cancellation did not reach the prompt")
            await transport.shutdown()
            try require(try read("partial.txt") == "partial change\n", "Cancelled task lost its partial file change")
            print("PASS: live cancellation, connection shutdown, partial file on disk")

            _ = try await initialize()
            let loaded = try await transport.request("session/load", params: .object(["sessionId": .string(sessionID), "cwd": .string(root.path), "mcpServers": .array([])]))
            let loadedOptions = try await kind.sessionOptions(loaded, sessionID: sessionID, transport: transport)
            updates = []
            let resumed = try await prompt("Reply exactly SILICA_RECONNECTED. Do not run tools or change files.")
            try require(resumed["stopReason"].string == "end_turn")
            let reply = updates.filter { $0["sessionUpdate"].string == "agent_message_chunk" }.compactMap { $0["content"]["text"].string }.joined()
            try require(reply.contains("SILICA_RECONNECTED"), "Loaded session did not answer the new prompt")
            print("PASS: live reconnect and session/load continuation")

            testingRejection = true
            try await setMode(kind == .claude ? "default" : "read-only", options: loadedOptions)
            let edit = kind == .claude ? "Read keep.txt and use the Edit tool to replace its first line with changed."
                : "Use the shell tool with sandbox_permissions=require_escalated to run printf 'changed\\n' > keep.txt. Request approval for this fixture write."
            _ = try await prompt("\(edit) This is a permission test. After rejection, stop immediately. Do not retry or use another method.")
            try require(rejectedFixtureWrites == 1, "Expected one rejected ACP write to keep.txt, received \(rejectedFixtureWrites)")
            try require(try read("keep.txt") == "pre-existing user modification\n", "Rejected edit changed keep.txt")
            print("PASS: live permission request rejected; file unchanged")
            await transport.shutdown()
            print("LIVE_FIXTURE: \(root.path)")
        } catch {
            await transport.shutdown()
            print("LIVE_FIXTURE: \(root.path)")
            throw error
        }
    }
}

import Foundation

nonisolated enum AgentKind: String, CaseIterable {
    case codex, claude

    var displayName: String { self == .codex ? "Codex" : "Claude Code" }
    var executableName: String { self == .codex ? "codex-acp" : "claude-agent-acp" }
    var runtimeDirectory: String { self == .codex ? "CodexACP" : "ClaudeACP" }
    var installScript: String { "scripts/install-\(rawValue)-acp.sh" }
    var executableKey: String { "\(rawValue)ACPExecutable" }
    var loginHint: String {
        self == .codex ? "Run codex login in Terminal, then reconnect." : "Run claude in Terminal and log in, then reconnect."
    }

    var allowedModes: [String] {
        self == .codex ? ["workspace-write", "read-only"] : ["auto", "default", "acceptEdits", "plan", "dontAsk"]
    }
    var initialModes: [String] { self == .codex ? ["workspace-write"] : ["auto", "acceptEdits", "default"] }

    // Codex also accepts its initial mode at launch, before session configuration is available.
    var launchMode: String? { self == .codex ? initialModes.first : nil }

    enum ModeDecision: Equatable { case keep, switchTo(String), fail }

    func modeDecision(offered: [String], current: String?) -> ModeDecision {
        if let current = current ?? launchMode, allowedModes.contains(current) { return .keep }
        if let preferred = initialModes.first(where: offered.contains) { return .switchTo(preferred) }
        return .fail
    }

    @MainActor func sessionOptions(_ response: ACPJSON, sessionID: String, transport: ACPTransport) async throws -> [AgentConfigOption] {
        let options = AgentConfigOption.parse(response["configOptions"])
        let mode = options.first { $0.category == "mode" }
        switch modeDecision(offered: mode?.choices.map(\.id) ?? [], current: mode?.value) {
        case .keep: return options
        case .fail:
            throw ACPError.message("\(displayName) did not offer a supported initial permission mode (\(initialModes.joined(separator: ", "))).")
        case .switchTo(let value):
            guard let mode else { throw ACPError.message("\(displayName) did not report its permission mode.") }
            let adjusted = try await transport.request("session/set_config_option", params: .object([
                "sessionId": .string(sessionID), "configId": .string(mode.id), "value": .string(value)
            ]))
            let options = AgentConfigOption.parse(adjusted["configOptions"])
            guard options.contains(where: { $0.id == mode.id && $0.category == "mode" && $0.value == value }) else {
                throw ACPError.message("\(displayName) did not confirm \(value) mode.")
            }
            return options
        }
    }

    func find(configuredPath: String, supportDirectory: URL = URL.homeDirectory.appending(path: "Library/Application Support/Silica Workbench"),
              checkoutFrom: URL = Bundle.main.bundleURL.deletingLastPathComponent(),
              binDirectories: [URL] = [URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/usr/local/bin")]) -> URL? {
        func executable(_ url: URL) -> Bool {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
                && FileManager.default.isExecutableFile(atPath: url.path)
        }
        if !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(filePath: NSString(string: configuredPath).expandingTildeInPath)
            return executable(url) ? url : nil
        }
        let relativePath = "\(runtimeDirectory)/node_modules/.bin/\(executableName)"
        var candidates = [supportDirectory.appending(path: relativePath)]
        var directory = checkoutFrom
        for _ in 0..<8 {
            candidates.append(directory.appending(path: "Tools/\(relativePath)"))
            directory.deleteLastPathComponent()
        }
        candidates += binDirectories.map { $0.appending(path: executableName) }
        return candidates.first(where: executable)
    }
}

nonisolated enum AgentPreference: String, CaseIterable {
    // A model change can replace the available reasoning levels.
    case model, thoughtLevel = "thought_level"

    func key(for kind: AgentKind) -> String { "agent.\(kind.rawValue).\(rawValue)" }

    func option(toApply value: String, in options: [AgentConfigOption]) -> AgentConfigOption? {
        options.first { $0.category == rawValue && $0.value != value && $0.choices.contains { $0.id == value } }
    }
}

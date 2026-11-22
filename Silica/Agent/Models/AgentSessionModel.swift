import Foundation
import Observation

@Observable
final class AgentSessionModel {
    var draft = ""
    var attachments: [AgentAttachment] = []
    var attachmentNotice: String?
    private(set) var kind: AgentKind
    var executablePath: String {
        didSet { UserDefaults.standard.set(executablePath, forKey: kind.executableKey) }
    }
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var isBusy = false
    private(set) var isStopping = false
    private(set) var canForceDisconnect = false
    private(set) var errorMessage: String?
    private(set) var agentVersion = ""
    private(set) var turns: [AgentTurn] = []
    private(set) var permissions: [AgentPermission] = []
    private(set) var configOptions: [AgentConfigOption] = []
    private var sessionInfo = AgentSessionInfo()
    var availableCommands: [AgentCommand] { sessionInfo.commands }
    var sessionTitle: String? { sessionInfo.title }
    var contextUsage: AgentContextUsage? { sessionInfo.context }
    var rateLimit: AgentRateLimit? { sessionInfo.rateLimit }
    private(set) var accountPlan: String?
    private(set) var promptCapabilities = AgentPromptCapabilities()
    // session/new may publish metadata before its response identifies the new session.
    @ObservationIgnored private var startingSessions: [String: AgentSessionInfo]?
    @ObservationIgnored private var connectionPlan: String?
    /// Owned processes that outlived cleanup. Only the user can release the project then.
    private(set) var survivingProcessIDs: [Int32] = []
    @ObservationIgnored private var releasedProcessIDs: [Int32] = []
    @ObservationIgnored private weak var workspace: WorkspaceModel?
    @ObservationIgnored private let transport = ACPTransport()
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var stopTimer: Task<Void, Never>?
    @ObservationIgnored private var pendingUpdates: [ACPJSON] = []
    @ObservationIgnored private var currentTurn: AgentTurn?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var closed = false

    init(workspace: WorkspaceModel) {
        let selected = UserDefaults.standard.string(forKey: "selectedAgent").flatMap(AgentKind.init(rawValue:)) ?? .codex
        self.kind = selected
        self.executablePath = UserDefaults.standard.string(forKey: selected.executableKey) ?? ""
        self.workspace = workspace
        transport.onNotification = { [weak self] method, params in self?.receive(method, params: params) }
        transport.onRequest = { [weak self] method, id, params in self?.handleRequest(method, id: id, params: params) }
        transport.onDisconnect = { [weak self] message in
            guard let self else { return }
            self.flushUpdates()
            self.isConnected = false
            self.errorMessage = message
            self.cancelPermissions()
            self.operation?.cancel()
        }
    }

    var statusLabel: String {
        if isStopping { return "Stopping…" }
        if let currentTurn, isBusy { return currentTurn.status }
        if isConnecting { return "Connecting…" }
        if isBusy { return "Preparing…" }
        return isConnected ? "Connected" : "Disconnected"
    }

    func connect() {
        guard !closed, !isConnected, !isBusy, !isConnecting else { return }
        isConnecting = true
        operation = Task { [weak self] in
            defer { self?.isConnecting = false }
            do { try await self?.establishConnection() }
            catch { self?.errorMessage = error.localizedDescription; self?.transport.close(); self?.isConnected = false }
        }
    }

    private func establishConnection() async throws {
        if isConnected { return }
        guard !closed, let workspace else { throw CancellationError() }
        guard let executable = kind.find(configuredPath: executablePath) else {
            throw ACPError.message("\(kind.displayName) ACP was not found. Run \(kind.installScript) from the checkout, or choose an installed \(kind.executableName) executable below. Node.js is required for the npm runtime.")
        }
        isConnecting = true; errorMessage = nil
        defer { isConnecting = false }
        releasedProcessIDs = []
        connectionPlan = nil
        try await transport.start(executable: executable, cwd: workspace.rootURL.resolvingSymlinksInPath(), kind: kind)
        survivingProcessIDs = []
        let initialized = try await transport.request("initialize", params: .object([
            "protocolVersion": .number(1),
            "clientInfo": .object(["name": .string("silica-workbench"), "title": .string("Silica Workbench"), "version": .string("0.1.0")]),
            "clientCapabilities": .object(["fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]),
                                           "terminal": .bool(false), "_meta": .object(["terminal_output": .bool(true), "terminal_output_delta": .bool(true)])])
        ]), timeout: .seconds(20))
        guard initialized["protocolVersion"].integer == 1 else { throw ACPError.message("The adapter did not negotiate ACP v1.") }
        agentVersion = initialized["agentInfo"]["version"].string ?? "unknown"
        let capabilities = initialized["agentCapabilities"]["promptCapabilities"]
        promptCapabilities = AgentPromptCapabilities(image: capabilities["image"].boolean, embeddedContext: capabilities["embeddedContext"].boolean)
        let response: ACPJSON
        do {
            if let sessionID, initialized["agentCapabilities"]["loadSession"].boolean {
                response = try await transport.request("session/load", params: .object([
                    "sessionId": .string(sessionID), "cwd": .string(workspace.rootURL.resolvingSymlinksInPath().path), "mcpServers": .array([])
                ]))
            } else {
                startingSessions = [:]
                defer { startingSessions = nil }
                response = try await transport.request("session/new", params: .object([
                    "cwd": .string(workspace.rootURL.resolvingSymlinksInPath().path), "mcpServers": .array([])
                ]))
                sessionID = response["sessionId"].string
                sessionInfo = sessionID.flatMap { startingSessions?[$0] } ?? AgentSessionInfo()
                accountPlan = connectionPlan
            }
        } catch let error as ACPError {
            throw ACPError.message("\(error.localizedDescription) \(kind.loginHint)")
        }
        guard let sessionID else { throw ACPError.message("\(kind.displayName) did not create a session. \(kind.loginHint)") }
        configOptions = try await kind.sessionOptions(response, sessionID: sessionID, transport: transport)
        isConnected = true
        for preference in AgentPreference.allCases {
            guard let value = UserDefaults.standard.string(forKey: preference.key(for: kind)),
                  let option = preference.option(toApply: value, in: configOptions) else { continue }
            do { try await updateConfiguration(option, value: value, sessionID: sessionID) }
            catch {
                guard isConnected, !Task.isCancelled else { throw error }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updateConfiguration(_ option: AgentConfigOption, value: String, sessionID: String) async throws {
        let response = try await transport.request("session/set_config_option", params: .object([
            "sessionId": .string(sessionID), "configId": .string(option.id), "value": .string(value)
        ]))
        try Task.checkCancellation()
        if case .array = response["configOptions"] {
            applyConfiguration(response["configOptions"])
        } else {
            throw ACPError.message("\(kind.displayName) did not return updated configuration options.")
        }
        guard isConnected else { throw ACPError.message(errorMessage ?? "Disconnected") }
        guard configOptions.contains(where: { $0.id == option.id && $0.category == option.category && $0.value == value }) else {
            throw ACPError.message("\(kind.displayName) did not confirm \(option.name) “\(value)”.")
        }
    }

    func setConfiguration(_ option: AgentConfigOption, value: String) {
        guard isConnected, !isBusy, !isConnecting, let sessionID, let option = configOptions.first(where: { $0.id == option.id }),
              option.choices.contains(where: { $0.id == value }) else { return }
        if option.category == "mode", !kind.allowedModes.contains(value) { return }
        isConnecting = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isConnecting = false }
            do {
                try await updateConfiguration(option, value: value, sessionID: sessionID)
                if let preference = AgentPreference(rawValue: option.category) {
                    UserDefaults.standard.set(value, forKey: preference.key(for: kind))
                }
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func attach(_ attachment: AgentAttachment) throws {
        try AgentPrompt.validate(attachments + [attachment], capabilities: isConnected ? promptCapabilities : nil)
        attachments.append(attachment)
    }

    var canSend: Bool {
        !isBusy && !isConnecting && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func send() {
        guard canSend, !closed else { return }
        guard draft.utf8.count <= 32_768 else { errorMessage = "Keep a message under 32 KiB."; return }
        guard turns.count < 100 else { errorMessage = "Silica keeps up to 100 turns in a chat. Start a new chat to continue."; return }
        isBusy = true; isStopping = false; canForceDisconnect = false; errorMessage = nil
        attachmentNotice = nil
        let prompt = draft, files = attachments
        operation = Task { [weak self] in await self?.runTurn(prompt, files: files) }
    }

    private func runTurn(_ prompt: String, files: [AgentAttachment]) async {
        guard let workspace else { isBusy = false; return }
        var lease: UUID?
        let root = workspace.rootURL
        let turn = AgentTurn(number: turns.count + 1, prompt: prompt, attachmentNames: files.map(\.name))
        var failed = false
        var cancelled = false
        do {
            try await establishConnection()
            try Task.checkCancellation()
            let blocks: [ACPJSON]
            do {
                blocks = try AgentPrompt.blocks(text: prompt, root: root, attachments: files, capabilities: promptCapabilities) {
                    AgentPrompt.projectFile($0, root: root)
                }
            } catch {
                attachmentNotice = error.localizedDescription
                isBusy = false
                return
            }
            lease = try AgentWorkspaceCoordinator.shared.acquire(for: root)
            guard let sessionID else { throw ACPError.message("The agent session is missing.") }
            currentTurn = turn; turns.append(turn)
            if draft == prompt { draft = "" }
            turn.status = "Running"
            let response = try await transport.request("session/prompt", params: .object([
                "sessionId": .string(sessionID), "prompt": .array(blocks)
            ]), timeout: nil)
            if response["stopReason"].string != "cancelled" {
                let sent = Set(files.map(\.id))
                attachments.removeAll { sent.contains($0.id) }
            }
            flushUpdates()
            turn.usage = AgentTurnUsage(response)
            try Task.checkCancellation()
            // A prompt response is not evidence that a background command exited.
            while response["stopReason"].string != "cancelled", turn.hasUnfinishedCommands {
                // The prompt RPC already returned; there is no pending response
                // for session/cancel to finish. Stop must leave this wait too.
                if isStopping { throw CancellationError() }
                turn.status = "Waiting for command exit"
                try await Task.sleep(for: .milliseconds(100))
                flushUpdates()
            }
            switch response["stopReason"].string {
            case "end_turn": turn.status = "Completed"
            case "cancelled": turn.status = "Cancelled"; cancelled = true
            default: turn.status = "Stopped: \(response["stopReason"].string ?? "unknown reason")"
            }
        } catch is CancellationError {
            if turn.eventLimitExceeded { turn.status = "Failed" }
            else { turn.status = isStopping || transport.isConnected ? "Cancelled" : "Interrupted" }
            cancelled = turn.status == "Cancelled"; failed = true
        } catch {
            flushUpdates()
            turn.status = "Failed"; failed = true
            errorMessage = error.localizedDescription
        }
        stopTimer?.cancel(); stopTimer = nil
        flushUpdates(); cancelPermissions()
        if failed || cancelled || isStopping {
            if currentTurn === turn, draft.isEmpty { draft = prompt }
            let finalStatus = turn.status
            turn.status = "Stopping processes…"
            await shutdownProcesses()
            isConnected = false
            turn.status = finalStatus
        }
        turn.finishTools(cancelled || isStopping ? "cancelled" : "interrupted")
        turn.endedAt = .now
        currentTurn = nil
        if let lease { AgentWorkspaceCoordinator.shared.release(lease) }
        workspace.refresh()
        isBusy = false; isStopping = false; canForceDisconnect = false
    }

    func stop() {
        guard isBusy, !isStopping else { return }
        isStopping = true
        flushUpdates(); cancelPermissions()
        if let sessionID { transport.notify("session/cancel", params: .object(["sessionId": .string(sessionID)])) }
        // Cancel preparation immediately; a running prompt is allowed to return its tail.
        if currentTurn == nil { operation?.cancel() }
        stopTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.isBusy else { return }
            self.canForceDisconnect = true
        }
    }

    func disconnect() {
        guard !isBusy || canForceDisconnect else { return }
        guard !isConnecting || isBusy else { return }
        let idle = !isBusy
        if idle { isConnecting = true }
        Task { [weak self] in
            await self?.stopAndDisconnect()
            if idle { self?.isConnecting = false }
        }
    }

    /// One cleanup attempt. If owned processes survive it, the running turn keeps
    /// the lease until they exit or the user releases them.
    func stopAndDisconnect() async {
        cancelPermissions()
        if let sessionID { transport.notify("session/cancel", params: .object(["sessionId": .string(sessionID)])) }
        operation?.cancel()
        let result = await transport.shutdown()
        isConnected = false
        guard releasedProcessIDs.isEmpty else { return }
        guard result.isComplete else { noteSurvivors(result); return }
        survivingProcessIDs = []
        await operation?.value
    }

    /// The user accepts that the surviving processes are outside Silica's control:
    /// the turn finishes and releases its lease.
    func releaseSurvivingProcesses() async {
        guard !survivingProcessIDs.isEmpty else { return }
        releasedProcessIDs = survivingProcessIDs; survivingProcessIDs = []
        transport.abandonProcesses()
        isConnected = false
        errorMessage = "Released the project while \(kind.displayName) processes \(Self.list(releasedProcessIDs)) were still running."
        await operation?.value
    }

    private func shutdownProcesses() async {
        while true {
            let result = await transport.shutdown()
            guard releasedProcessIDs.isEmpty else { return }
            if result.isComplete { survivingProcessIDs = []; return }
            // Do not release a lease while a known
            // owned writer is still alive. Retry cleanup without blocking AppKit.
            noteSurvivors(result)
            await Task.detached { try? await Task.sleep(for: .seconds(1)) }.value
        }
    }

    private func noteSurvivors(_ result: AgentShutdownResult) {
        survivingProcessIDs = result.remainingProcessIDs
        errorMessage = "\(kind.displayName) processes \(Self.list(survivingProcessIDs)) did not stop. "
            + (isBusy ? "Other tasks must wait while Silica keeps trying." : "Reconnect after they exit.")
        if isBusy { canForceDisconnect = true }
    }

    private static func list(_ ids: [Int32]) -> String { ids.map(String.init).joined(separator: ", ") }

    func newChat() {
        guard !isBusy, !isConnecting else { return }
        operation?.cancel(); transport.close(); isConnected = false
        sessionID = nil; turns = []; configOptions = []; errorMessage = nil; agentVersion = ""
        sessionInfo = AgentSessionInfo(); accountPlan = nil; promptCapabilities = AgentPromptCapabilities()
        if workspace?.isAgentPanelVisible == true { connect() }
    }

    func selectAgent(_ selected: AgentKind) {
        guard kind != selected, !isBusy, !isConnecting, survivingProcessIDs.isEmpty else { return }
        draft = ""; attachments = []; attachmentNotice = nil
        kind = selected
        executablePath = UserDefaults.standard.string(forKey: selected.executableKey) ?? ""
        UserDefaults.standard.set(selected.rawValue, forKey: "selectedAgent")
        newChat()
    }

    func close() {
        closed = true
        cancelPermissions(); operation?.cancel(); flushTask?.cancel(); stopTimer?.cancel()
        transport.close()
    }

    private func receive(_ method: String, params: ACPJSON) {
        if method == "_auth/status_update" || method == "auth/status_update" {
            if let plan = params["authStatus"]["account"]["plan"].string {
                connectionPlan = plan
                accountPlan = plan
            }
            return
        }
        guard method == "session/update", let id = params["sessionId"].string else { return }
        let update = params["update"]
        switch update["sessionUpdate"].string {
        case "available_commands_update", "session_info_update", "usage_update":
            if startingSessions != nil {
                startingSessions?[id, default: AgentSessionInfo()].apply(update)
            } else if id == sessionID {
                sessionInfo.apply(update)
                if update["sessionUpdate"].string == "usage_update", let cost = AgentCost(update["cost"]) { currentTurn?.cost = cost }
            }
            return
        case "config_option_update":
            if id == sessionID, isConnected { applyConfiguration(update["configOptions"]) }
            return
        default: break
        }
        guard id == sessionID, currentTurn != nil else { return } // Ignore session/load transcript replay.
        pendingUpdates.append(update)
        if pendingUpdates.count >= 128 { flushUpdates() }
        else if flushTask == nil {
            flushTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                self?.flushUpdates()
            }
        }
    }

    private func applyConfiguration(_ values: ACPJSON) {
        configOptions = AgentConfigOption.parse(values)
        let current = configOptions.first { $0.category == "mode" }?.value
        guard kind.modeDecision(offered: [], current: current) == .keep else {
            errorMessage = "\(kind.displayName) reported an unsupported permission mode. Reconnect to continue."
            transport.close(); isConnected = false; operation?.cancel()
            return
        }
    }

    private func flushUpdates() {
        flushTask?.cancel(); flushTask = nil
        let updates = pendingUpdates; pendingUpdates.removeAll(keepingCapacity: true)
        if let currentTurn {
            for update in updates {
                if !currentTurn.apply(update, projectRoot: workspace?.rootURL) { stopForEventLimit() }
            }
        }
    }

    private func stopForEventLimit() {
        errorMessage = "\(kind.displayName) exceeded the tool-state limit. This turn is stopping; partial output and changes are preserved."
        operation?.cancel()
    }

    private func handleRequest(_ method: String, id: ACPJSON, params: ACPJSON) {
        flushUpdates()
        guard method == "session/request_permission", params["sessionId"].string == sessionID,
              currentTurn != nil, !isStopping else {
            if method == "session/request_permission" { transport.respond(id: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])])) }
            else { transport.reject(id: id, message: "This client did not advertise \(method).") }
            return
        }
        guard permissions.count < 32, id.requestKey != nil else {
            transport.respond(id: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])]))
            return
        }
        var tool = params["toolCall"].object ?? [:]
        tool["sessionUpdate"] = .string("tool_call_update")
        if currentTurn?.apply(.object(tool), projectRoot: workspace?.rootURL) == false {
            stopForEventLimit()
            transport.respond(id: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])]))
            return
        }
        let permission = AgentPermission(requestID: id,
            title: tool["rawInput"]?["command"].string ?? tool["title"]?.string ?? "\(kind.displayName) requests permission",
            cwd: tool["rawInput"]?["cwd"].string ?? workspace?.rootURL.path ?? "",
            options: params["options"].array.compactMap { option in
                guard let id = option["optionId"].string, let kind = option["kind"].string,
                      ["allow_once", "allow_always", "reject_once", "reject_always"].contains(kind) else { return nil }
                return AgentPermission.Option(id: id, name: option["name"].string ?? id, kind: kind)
            })
        guard !permission.options.isEmpty else {
            transport.respond(id: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])]))
            return
        }
        if !permissions.contains(where: { $0.id == permission.id }) { permissions.append(permission) }
    }

    func answer(_ permission: AgentPermission, option: AgentPermission.Option) {
        guard permissions.contains(where: { $0.id == permission.id }), permission.options.contains(where: { $0.id == option.id }) else { return }
        permissions.removeAll { $0.id == permission.id }
        transport.respond(id: permission.requestID, result: .object([
            "outcome": .object(["outcome": .string("selected"), "optionId": .string(option.id)])
        ]))
    }

    private func cancelPermissions() {
        let outstanding = permissions; permissions = []
        for permission in outstanding {
            transport.respond(id: permission.requestID, result: .object(["outcome": .object(["outcome": .string("cancelled")])]))
        }
    }
}

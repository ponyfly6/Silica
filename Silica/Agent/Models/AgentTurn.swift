import Foundation
import Observation

nonisolated struct AgentTimelineItem: Identifiable {
    enum Kind { case assistant, tool, notice }
    let id: String
    var kind: Kind
    var title = ""
    var text = ""
    var status = "pending"
    var toolKind = ""
    var messageID: String?
    var cwd = ""
    var output = ""
    var contentText = ""
    var exitCode: Int?
    var hasTerminal = false
    var terminalDidExit = false
    var outputTruncated = false
    var textTruncated = false
    var localStatus: String?

    var displayOutput: String { output.isEmpty ? contentText : output }
    var displayStatus: String { localStatus ?? status }
    var isAwaitingExit: Bool {
        hasTerminal && exitCode == nil && !terminalDidExit && !["cancelled", "interrupted"].contains(displayStatus)
    }

    mutating func finish(_ reason: String) {
        if isAwaitingExit || !["completed", "failed", "cancelled", "interrupted"].contains(displayStatus) {
            localStatus = reason
        }
    }
}

@MainActor @Observable
final class AgentTurn: Identifiable {
    let id = UUID()
    let number: Int
    let prompt: String
    let attachmentNames: [String]
    let startedAt = Date.now
    var endedAt: Date?
    var usage: AgentTurnUsage?
    var cost: AgentCost?
    var status = "Preparing"
    var items: [AgentTimelineItem] = []
    private(set) var changes = AgentChanges()
    private var answerStart = 0
    private var overflowAnswer: AgentTimelineItem?
    var transcript: (work: [AgentTimelineItem], answer: [AgentTimelineItem]) {
        let tail = items[answerStart...]
        return (Array(items[..<answerStart]) + tail.filter { $0.kind != .assistant },
                tail.filter { $0.kind == .assistant } + [overflowAnswer].compactMap { $0 })
    }

    var stepSummary: (count: Int, failed: Int, cancelled: Int) {
        let tools = items.filter { $0.kind == .tool } + hiddenTools.values
        return (tools.count, tools.filter { $0.displayStatus == "failed" || ($0.exitCode ?? 0) != 0 }.count,
                tools.filter { ["cancelled", "interrupted"].contains($0.displayStatus) }.count)
    }
    private var latestToolID: String?
    private(set) var currentStepTitle = ""
    private var fallbackMessageID = UUID().uuidString
    // Keep lifecycle metadata even after the presentation limit. If that bounded
    // metadata store fills too, stop the turn instead of losing execution state.
    private var hiddenTools: [String: AgentTimelineItem] = [:]
    private(set) var entriesTruncated = false
    private(set) var eventLimitExceeded = false
    private static let itemLimit = 500
    private static let hiddenToolLimit = 20_000
    private static let textLimit = 262_144
    private static let outputLimit = 1_048_576

    init(number: Int, prompt: String, attachmentNames: [String] = []) {
        self.number = number
        self.prompt = prompt
        self.attachmentNames = attachmentNames
    }

    var hasUnfinishedCommands: Bool {
        items.contains { $0.kind == .tool && $0.isAwaitingExit } || hiddenTools.values.contains { $0.isAwaitingExit }
    }

    var omittedToolCount: Int { hiddenTools.count }
    var timelineNotice: String? {
        guard entriesTruncated else { return nil }
        let failed = hiddenTools.values.filter { $0.displayStatus == "failed" || ($0.exitCode ?? 0) != 0 }.count
        let interrupted = hiddenTools.values.filter { ["cancelled", "interrupted"].contains($0.displayStatus) }.count
        return "Timeline details limited to 500 entries. \(hiddenTools.count) additional tools: \(failed) failed, \(interrupted) cancelled or interrupted. Their execution states are still tracked."
    }

    func finishTools(_ reason: String) {
        for index in items.indices where items[index].kind == .tool { items[index].finish(reason) }
        for id in Array(hiddenTools.keys) { hiddenTools[id]?.finish(reason) }
    }

    @discardableResult
    func apply(_ update: ACPJSON, projectRoot: URL? = nil) -> Bool {
        switch update["sessionUpdate"].string {
        case "agent_message_chunk":
            guard let text = update["content"]["text"].string else { return true }
            let id = update["messageId"].string ?? fallbackMessageID
            if let index = items[answerStart...].firstIndex(where: { $0.messageID == id }) {
                Self.append(text, to: &items[index])
            } else if items.count < Self.itemLimit {
                var item = AgentTimelineItem(id: "message-\(items.count)", kind: .assistant, messageID: id)
                Self.append(text, to: &item)
                items.append(item)
            } else {
                // Preserve the answer even when earlier tools exhausted the timeline.
                var item = overflowAnswer ?? AgentTimelineItem(id: "overflow-answer", kind: .assistant)
                if let previous = item.messageID, previous != id { Self.append("\n\n", to: &item) }
                item.messageID = id
                Self.append(text, to: &item)
                overflowAnswer = item
            }
        case "tool_call", "tool_call_update":
            guard let id = update["toolCallId"].string else { return true }
            if let index = items.firstIndex(where: { $0.id == id && $0.kind == .tool }) {
                patch(&items[index], update: update, root: projectRoot, retainDetails: true)
            } else if hiddenTools[id] != nil || items.count >= Self.itemLimit {
                entriesTruncated = true
                guard hiddenTools[id] != nil || hiddenTools.count < Self.hiddenToolLimit else {
                    eventLimitExceeded = true; return false
                }
                let isNew = hiddenTools[id] == nil
                var tool = hiddenTools[id] ?? AgentTimelineItem(id: id, kind: .tool)
                patch(&tool, update: update, root: projectRoot, retainDetails: false)
                hiddenTools[id] = tool
                if isNew { beginAnswer(after: id) }
            } else {
                var tool = AgentTimelineItem(id: id, kind: .tool)
                patch(&tool, update: update, root: projectRoot, retainDetails: true)
                items.append(tool)
                beginAnswer(after: id)
            }
            if latestToolID == id, let title = update["rawInput"]["command"].string ?? update["title"].string {
                currentStepTitle = Self.prefix(title, bytes: 256)
            }
        case "plan":
            if latestToolID == nil, let step = update["entries"].array.first(where: { $0["status"].string == "in_progress" }) {
                currentStepTitle = Self.prefix(step["content"].string ?? "", bytes: 256)
            }
            let text = update["entries"].array.compactMap { item -> String? in
                guard let content = item["content"].string else { return nil }
                return "\(item["status"].string ?? "pending"): \(content)"
            }.joined(separator: "\n")
            if let index = items.firstIndex(where: { $0.kind == .notice && $0.id == "plan" }) {
                items[index].text = Self.prefix(text, bytes: Self.textLimit)
                items[index].textTruncated = text.utf8.count > Self.textLimit
            } else if !text.isEmpty, items.count < Self.itemLimit {
                items.append(AgentTimelineItem(id: "plan", kind: .notice, title: "Plan", text: Self.prefix(text, bytes: Self.textLimit),
                                               textTruncated: text.utf8.count > Self.textLimit))
            } else if !text.isEmpty { entriesTruncated = true }
        default: return true
        }
        return true
    }

    private func beginAnswer(after id: String) {
        answerStart = items.count
        overflowAnswer = nil
        fallbackMessageID = UUID().uuidString
        latestToolID = id
        currentStepTitle = "Tool call"
    }

    private static func append(_ text: String, to item: inout AgentTimelineItem) {
        let remaining = max(0, textLimit - item.text.utf8.count)
        item.text += prefix(text, bytes: remaining)
        item.textTruncated = item.textTruncated || text.utf8.count > remaining
    }

    private func patch(_ item: inout AgentTimelineItem, update: ACPJSON, root: URL?, retainDetails: Bool) {
        if let kind = update["kind"].string { item.toolKind = kind }
        if ["edit", "delete", "move"].contains(item.toolKind), let root {
            changes.record(update, call: item.id, kind: item.toolKind, root: root)
        }
        if let status = update["status"].string { item.status = status }
        let meta = update["_meta"]
        if meta["terminal_info"].object != nil || update["content"].array.contains(where: { $0["type"].string == "terminal" }) {
            item.hasTerminal = true
        }
        if let exit = meta["terminal_exit"]["exit_code"].integer { item.exitCode = exit }
        if meta["terminal_exit"].object != nil { item.terminalDidExit = true }
        if meta["terminal_exit"]["signal"].string != nil { item.status = "failed" }
        guard retainDetails else { return }
        if let title = update["rawInput"]["command"].string ?? update["title"].string {
            item.title = Self.prefix(title, bytes: 16_384)
            item.textTruncated = item.textTruncated || title.utf8.count > 16_384
        }
        if let cwd = meta["terminal_info"]["cwd"].string ?? update["rawInput"]["cwd"].string { item.cwd = cwd }
        if update.object?["content"] != nil {
            let text = update["content"].array.compactMap { $0["content"]["text"].string }.joined(separator: "\n")
            item.contentText = Self.prefix(text, bytes: Self.outputLimit)
            item.outputTruncated = item.outputTruncated || text.utf8.count > Self.outputLimit
        }
        // Read/search/list deltas do not imply a terminal and need no exit event.
        if let delta = meta["terminal_output_delta"]["data"].string ?? meta["terminal_output"]["data"].string {
            let remaining = max(0, Self.outputLimit - item.output.utf8.count)
            item.output += Self.prefix(delta, bytes: remaining)
            item.outputTruncated = item.outputTruncated || delta.utf8.count > remaining
        }
        if let signal = meta["terminal_exit"]["signal"].string {
            let suffix = "\nTerminated by signal \(signal)"
            let remaining = max(0, Self.outputLimit - item.output.utf8.count)
            item.output += Self.prefix(suffix, bytes: remaining)
            item.outputTruncated = item.outputTruncated || suffix.utf8.count > remaining
        }
    }

    private static func prefix(_ text: String, bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        let bytes = text.utf8.prefix(limit)
        var end = bytes.endIndex
        while end > bytes.startIndex {
            if let result = String(bytes: bytes[..<end], encoding: .utf8) { return result }
            end = bytes.index(before: end)
        }
        return ""
    }
}

nonisolated struct AgentPermission: Identifiable {
    struct Option: Identifiable {
        let id: String
        let name: String
        let kind: String
    }
    let requestID: ACPJSON
    let title: String
    let cwd: String
    let options: [Option]
    var id: String { requestID.requestKey! }
}

nonisolated struct AgentConfigOption: Identifiable {
    struct Choice: Identifiable { let id: String; let name: String }
    let id: String
    let name: String
    let category: String
    let value: String
    let choices: [Choice]

    static func parse(_ values: ACPJSON) -> [AgentConfigOption] {
        values.array.compactMap { item in
            guard item["type"].string == "select", let id = item["id"].string,
                  let value = item["currentValue"].string else { return nil }
            let options = item["options"].array.flatMap { option in
                option["options"].array.isEmpty ? [option] : option["options"].array
            }
            return AgentConfigOption(id: id, name: item["name"].string ?? id, category: item["category"].string ?? "",
                value: value, choices: options.compactMap { option in
                    guard let value = option["value"].string else { return nil }
                    return Choice(id: value, name: option["name"].string ?? value)
                })
        }
    }
}

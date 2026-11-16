import Foundation
import Observation

nonisolated struct AgentTimelineItem: Identifiable {
    enum Kind { case assistant, tool, notice }
    let id: String
    var kind: Kind
    var title = ""
    var text = ""
    var status = "pending"
    var operation = ""
    var cwd = ""
    var output = ""
    var contentText = ""
    var exitCode: Int?
    var hasTerminal = false
    var outputTruncated = false
}

@MainActor @Observable
final class AgentTurn: Identifiable {
    let id = UUID()
    let number: Int
    let prompt: String
    let startedAt = Date()
    var baselineCapturedAt: Date?
    var endedAt: Date?
    var status = "Preparing"
    var items: [AgentTimelineItem] = []
    var changes: [TurnFileChange] = []
    var warnings: [String] = []
    var reviewFailure: String?
    var revision = 0
    private var fallbackMessageID = UUID().uuidString
    private static let textLimit = 262_144
    private static let outputLimit = 1_048_576

    init(number: Int, prompt: String) { self.number = number; self.prompt = prompt }

    var storedBytes: Int { changes.reduce(0) { $0 + $1.storedBytes } }
    var hasUnfinishedCommands: Bool {
        items.contains { $0.kind == .tool && $0.hasTerminal && $0.exitCode == nil && $0.status != "failed" }
    }

    func apply(_ update: ACPJSON) {
        switch update["sessionUpdate"].string {
        case "agent_message_chunk":
            guard let text = update["content"]["text"].string else { return }
            let id = update["messageId"].string ?? fallbackMessageID
            if let index = items.firstIndex(where: { $0.id == id && $0.kind == .assistant }) {
                if items[index].text.utf8.count < Self.textLimit { items[index].text += text }
            } else if items.count < 500 {
                items.append(AgentTimelineItem(id: id, kind: .assistant, text: String(text.prefix(Self.textLimit))))
            }
        case "tool_call", "tool_call_update":
            guard let id = update["toolCallId"].string else { return }
            let index: Int
            if let existing = items.firstIndex(where: { $0.id == id && $0.kind == .tool }) { index = existing }
            else {
                guard items.count < 500 else { return }
                items.append(AgentTimelineItem(id: id, kind: .tool)); index = items.count - 1
                fallbackMessageID = UUID().uuidString
            }
            if let title = update["title"].string { items[index].title = String(title.prefix(16_384)) }
            if let status = update["status"].string { items[index].status = status }
            if let operation = update["kind"].string { items[index].operation = operation }
            if let command = update["rawInput"]["command"].string { items[index].title = String(command.prefix(16_384)) }
            if let cwd = update["rawInput"]["cwd"].string { items[index].cwd = cwd }
            if update.object?["content"] != nil {
                items[index].contentText = String(update["content"].array.compactMap { $0["content"]["text"].string }.joined(separator: "\n").prefix(Self.outputLimit))
            }
            let meta = update["_meta"]
            if let cwd = meta["terminal_info"]["cwd"].string { items[index].cwd = cwd; items[index].hasTerminal = true }
            if update["content"].array.contains(where: { $0["type"].string == "terminal" }) { items[index].hasTerminal = true }
            // These are the pinned Codex adapter's display-terminal metadata,
            // also handled by Zed's ACP v1 compatibility layer.
            if let delta = meta["terminal_output_delta"]["data"].string ?? meta["terminal_output"]["data"].string {
                // The adapter also sends deltas for read/search/list tools, which
                // have no display terminal and never emit terminal_exit.
                let remaining = max(0, Self.outputLimit - items[index].output.utf8.count)
                items[index].output += String(decoding: delta.utf8.prefix(remaining), as: UTF8.self)
                if delta.utf8.count > remaining { items[index].outputTruncated = true }
            }
            if let exit = meta["terminal_exit"]["exit_code"].integer { items[index].exitCode = exit }
            if let signal = meta["terminal_exit"]["signal"].string {
                items[index].status = "failed"
                items[index].output += "\nTerminated by signal \(signal)"
            }
        case "plan":
            let text = update["entries"].array.compactMap { item -> String? in
                guard let content = item["content"].string else { return nil }
                return "\(item["status"].string ?? "pending"): \(content)"
            }.joined(separator: "\n")
            if let index = items.firstIndex(where: { $0.id == "plan" }) { items[index].text = String(text.prefix(Self.textLimit)) }
            else if !text.isEmpty { items.append(AgentTimelineItem(id: "plan", kind: .notice, title: "Plan", text: String(text.prefix(Self.textLimit)))) }
        default: return
        }
        revision += 1
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

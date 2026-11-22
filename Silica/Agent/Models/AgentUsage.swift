import Foundation

nonisolated struct AgentCommand {
    let name: String
    let description: String
    let hint: String?
}

nonisolated struct AgentCost: Equatable {
    let amount: Double
    let currency: String

    init?(_ value: ACPJSON) {
        guard case let .number(amount) = value["amount"], let currency = value["currency"].string else { return nil }
        self.amount = amount
        self.currency = currency
    }
}

nonisolated struct AgentContextUsage {
    let used: Int
    let size: Int
    let cost: AgentCost?
    let model: String?
}

nonisolated struct AgentRateLimit {
    let fields: [String: ACPJSON]
    var status: String? { fields["status"]?.string }
    var rateLimitType: String? { fields["rateLimitType"]?.string }
    var utilization: Double? {
        if case let .number(value) = fields["utilization"] { return value }
        return nil
    }
    var resetsAt: Int? { fields["resetsAt"]?.integer }
}

nonisolated struct AgentSessionInfo {
    var commands: [AgentCommand] = []
    var title: String?
    var context: AgentContextUsage?
    var rateLimit: AgentRateLimit?

    mutating func apply(_ update: ACPJSON) {
        switch update["sessionUpdate"].string {
        case "available_commands_update":
            commands = update["availableCommands"].array.compactMap {
                guard let name = $0["name"].string, let description = $0["description"].string else { return nil }
                return AgentCommand(name: name, description: description, hint: $0["input"]["hint"].string)
            }
        case "session_info_update":
            if let title = update["title"].string { self.title = title }
        case "usage_update":
            let meta = update["_meta"]
            if let limit = meta["_claude/rateLimit"].object { rateLimit = AgentRateLimit(fields: limit) }
            if let used = update["used"].integer, let size = update["size"].integer {
                context = AgentContextUsage(used: used, size: size, cost: AgentCost(update["cost"]), model: meta["_claude/model"].string)
            }
        default: break
        }
    }
}

nonisolated struct AgentPromptCapabilities {
    var image = false
    var embeddedContext = false
}

nonisolated struct AgentTurnUsage {
    let inputTokens: Int
    let outputTokens: Int
    let cachedReadTokens: Int?
    let cachedWriteTokens: Int?
    let totalTokens: Int
    let reasoningOutputTokens: Int?

    init?(_ result: ACPJSON) {
        let usage = result["usage"]
        guard let input = usage["inputTokens"].integer, let output = usage["outputTokens"].integer,
              let total = usage["totalTokens"].integer else { return nil }
        inputTokens = input
        outputTokens = output
        totalTokens = total
        cachedReadTokens = usage["cachedReadTokens"].integer
        cachedWriteTokens = usage["cachedWriteTokens"].integer
        reasoningOutputTokens = result["_meta"]["quota"]["token_count"]["reasoningOutputTokens"].integer
    }
}

extension AgentTurnUsage {
    nonisolated var cacheHitFraction: Double? {
        guard let read = cachedReadTokens, let write = cachedWriteTokens else { return nil }
        let total = Double(inputTokens) + Double(read) + Double(write)
        return total > 0 ? Double(read) / total : nil
    }
}

nonisolated func compactTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 { return "\(count / 1_000_000)M" }
    if count >= 1_000 { return "\(count / 1_000)K" }
    return String(count)
}

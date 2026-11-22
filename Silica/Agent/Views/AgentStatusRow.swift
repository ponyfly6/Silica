import SwiftUI

struct AgentStatusRow: View {
    let model: AgentSessionModel
    @State private var showsUsage = false

    var body: some View {
        HStack(spacing: 6) {
            let mode = model.configOptions.first { $0.category == "mode" }
            let choices = mode?.choices.filter { model.kind.allowedModes.contains($0.id) } ?? []
            Menu {
                if let mode { agentConfigPicker(model, option: mode, choices: choices) }
            } label: {
                Text(mode?.selectedName ?? (model.isConnected ? model.kind.launchMode : nil) ?? "Permissions")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton).controlSize(.mini)
            .disabled(!model.isConnected || model.isBusy || model.isConnecting || choices.isEmpty)
            .accessibilityLabel("Permission mode").help("Permission mode")
            Spacer(minLength: 0)
            if let usage = model.contextUsage {
                Button { showsUsage.toggle() } label: {
                    HStack(spacing: 5) {
                        ProgressView(value: min(1, max(0, fraction(usage))))
                            .progressViewStyle(.linear).controlSize(.mini).frame(width: 28)
                        Text("\(compactTokenCount(usage.used)) / \(compactTokenCount(usage.size))")
                    }
                }
                .fixedSize().buttonStyle(.plain).help("Context and token usage")
                .popover(isPresented: $showsUsage) { details(usage) }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func fraction(_ usage: AgentContextUsage) -> Double {
        usage.size > 0 ? Double(usage.used) / Double(usage.size) : 0
    }

    private func details(_ context: AgentContextUsage) -> some View {
        let turns = model.turns
        let totals = turns.compactMap { $0.usage?.totalTokens }
        let costs = Dictionary(grouping: turns.compactMap(\.cost), by: \.currency)
        return VStack(alignment: .leading, spacing: 5) {
            Text("Usage").font(.headline)
            LabeledContent("Context", value: "\(context.used.formatted()) / \(context.size.formatted()) (\(fraction(context).formatted(.percent.precision(.fractionLength(0...1)))))")
            if let name = context.model ?? model.configOptions.first(where: { $0.category == "model" })?.selectedName {
                LabeledContent("Model", value: name)
            }
            if let turn = turns.last {
                Divider()
                Text("Last turn").bold()
                if let usage = turn.usage {
                    LabeledContent("Input", value: usage.inputTokens.formatted())
                    LabeledContent("Output", value: usage.outputTokens.formatted())
                    if let n = usage.reasoningOutputTokens { LabeledContent("Reasoning", value: n.formatted()) }
                    if let n = usage.cachedReadTokens { LabeledContent("Cache read", value: n.formatted()) }
                    if let n = usage.cachedWriteTokens { LabeledContent("Cache write", value: n.formatted()) }
                    if let hit = usage.cacheHitFraction {
                        LabeledContent("Cache hit", value: hit.formatted(.percent.precision(.fractionLength(0...1))))
                    }
                }
                if let cost = turn.cost { costRow(cost.amount, currency: cost.currency) }
                if turn.cost == nil && turn.usage == nil { Text("Usage unavailable").foregroundStyle(.secondary) }
            }
            if !totals.isEmpty || !costs.isEmpty {
                Divider()
                Text("This chat").bold()
                if !totals.isEmpty { LabeledContent("Total tokens", value: totals.reduce(Decimal.zero) { $0 + Decimal($1) }.formatted()) }
                ForEach(costs.keys.sorted(), id: \.self) { currency in
                    costRow(costs[currency, default: []].reduce(0) { $0 + $1.amount }, currency: currency)
                }
            }
        }
        .font(.callout).padding(14).frame(minWidth: 250)
    }

    private func costRow(_ amount: Double, currency: String) -> some View {
        LabeledContent("Cost", value: "\(amount.formatted(.number.precision(.fractionLength(0...6)))) \(currency)")
    }
}

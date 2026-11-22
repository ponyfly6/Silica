import SwiftUI

struct AgentTurnView: View {
    let turn: AgentTurn
    let workspace: WorkspaceModel
    let edit: () -> Void
    @State private var hovering = false
    @State private var showsWork = false

    var body: some View {
        let transcript = turn.transcript
        VStack(alignment: .leading, spacing: 10) {
            userMessage
            if !transcript.work.isEmpty || turn.entriesTruncated {
                DisclosureGroup(isExpanded: $showsWork) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(transcript.work) { item in
                            switch item.kind {
                            case .assistant: message(item)
                            case .tool: AgentToolView(item: item)
                            case .notice:
                                Text(item.title).font(.caption.bold())
                                Text(verbatim: item.text).font(.caption).textSelection(.enabled)
                                if item.textTruncated { truncated }
                            }
                        }
                        if let notice = turn.timelineNotice {
                            Text(notice).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                } label: {
                    HStack(spacing: 6) {
                        if turn.endedAt == nil { ProgressView().controlSize(.mini) }
                        Text(workLabel).lineLimit(2).truncationMode(.tail)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(transcript.answer) { item in message(item) }
            if !transcript.answer.isEmpty {
                AgentCopyButton(text: transcript.answer.map(\.text).joined(separator: "\n\n"), label: "Copy answer as Markdown")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !turn.changes.paths.isEmpty { AgentChangeSummary(changes: turn.changes, workspace: workspace) }
            if turn.endedAt != nil, turn.status != "Completed" {
                Text(turn.status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Turn \(turn.number)")
        .environment(\.openURL, OpenURLAction { openLink($0) })
    }

    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: 3) {
            VStack(alignment: .leading, spacing: 4) {
                if !turn.prompt.isEmpty { Text(verbatim: turn.prompt).font(.callout).textSelection(.enabled) }
                if !turn.attachmentNames.isEmpty {
                    Label(turn.attachmentNames.joined(separator: ", "), systemImage: "paperclip").font(.caption)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 12))
            HStack(spacing: 8) {
                AgentCopyButton(text: turn.prompt, label: "Copy message")
                Button(action: edit) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Edit in composer").accessibilityLabel("Edit in composer")
            }
            .font(.caption).foregroundStyle(.secondary).opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.85 }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var workLabel: String {
        guard let end = turn.endedAt else {
            return turn.currentStepTitle.isEmpty ? "Working…" : "Working… · \(turn.currentStepTitle)"
        }
        let seconds = max(0, Int(end.timeIntervalSince(turn.startedAt)))
        let duration = seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
        let steps = turn.stepSummary
        var label = "Worked for \(duration) · \(steps.count) \(steps.count == 1 ? "step" : "steps")"
        if steps.failed > 0 { label += " · \(steps.failed) failed" }
        if steps.cancelled > 0 { label += " · \(steps.cancelled) cancelled" }
        return label
    }

    @ViewBuilder private func message(_ item: AgentTimelineItem) -> some View {
        AgentMarkdownView(source: item.text)
        if item.textTruncated { truncated }
    }

    private var truncated: some View {
        Text("Message truncated at 256 KiB").font(.caption).foregroundStyle(.secondary)
    }

    private func openLink(_ url: URL) -> OpenURLAction.Result {
        if ["https", "http"].contains(url.scheme?.lowercased()) { return .systemAction }
        guard url.scheme == nil || url.isFileURL else { return .discarded }
        var path = url.path(percentEncoded: false)
        var line: Int?
        if let colon = path.lastIndex(of: ":"), let number = Int(path[path.index(after: colon)...]), number > 0 {
            path = String(path[..<colon])
            line = number
        }
        guard let relative = AgentPaths.relativePath(path, root: workspace.rootURL) else { return .discarded }
        let target = workspace.rootURL.appending(path: relative)
        guard FileManager.default.fileExists(atPath: target.path) else { return .discarded }
        workspace.openFromQuickOpen(target, line: line)
        return .handled
    }
}

private struct AgentChangeSummary: View {
    let changes: AgentChanges
    let workspace: WorkspaceModel
    @State private var expanded = false

    var body: some View {
        let files = changes.files
        let known = files.compactMap(\.counts)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("Changed \(files.count)\(changes.truncated ? "+" : "") \(files.count == 1 ? "file" : "files")").fontWeight(.medium)
                    Spacer(minLength: 2)
                    if !changes.truncated, known.count == files.count { counts(known.reduce(.init(), +)) }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").imageScale(.small)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .help("Shows edits reported by agent tools. Changes made through shell commands are not counted.")
            if expanded {
                ForEach(files) { file in
                    Button {
                        if let path = AgentPaths.relativePath(file.path, root: workspace.rootURL) {
                            workspace.openFromQuickOpen(workspace.rootURL.appending(path: path))
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: file.path).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            if let label = file.label { Text(label).foregroundStyle(.secondary) }
                            else if let value = file.counts { counts(value) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(file.path)
                }
                if changes.truncated { Text("Showing the first 500 files.").foregroundStyle(.secondary) }
            }
        }
        .font(.caption).padding(9)
        .background(.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }

    private func counts(_ value: AgentLineCounts) -> some View {
        HStack(spacing: 4) {
            Text("+\(value.added)").foregroundStyle(.green)
            Text("−\(value.removed)").foregroundStyle(.red)
        }.monospacedDigit()
    }
}

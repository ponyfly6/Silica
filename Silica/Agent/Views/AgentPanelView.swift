import SwiftUI

struct AgentPanelView: View {
    @Bindable var model: AgentSessionModel
    let workspace: WorkspaceModel
    @State private var showsConnection = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                Text("Codex").font(.headline)
                Spacer(minLength: 0)
                Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .disabled(model.isBusy || model.isConnecting)
                    .help("New chat · clears this window’s in-memory conversation and review snapshots")
                    .accessibilityLabel("New Codex chat")
                Button { workspace.toggleAgentPanel() } label: { Image(systemName: "sidebar.right") }
                    .help("Hide Codex").accessibilityLabel("Hide Codex panel")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .frame(height: WorkspaceLayout.titleBarHeight).padding(.horizontal, 12)

            VStack(spacing: 0) {
                connectionBar
                Divider()
                transcript
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                ForEach(model.permissions) { permission in
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Permission requested", systemImage: "hand.raised").font(.headline)
                        Text(permission.title).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text(permission.cwd).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        ViewThatFits(in: .horizontal) {
                            HStack { permissionButtons(permission) }
                            VStack(alignment: .leading) { permissionButtons(permission) }
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08))
                }
                Divider()
                composer
            }
            .glassEffect(.regular, in: .rect(cornerRadius: WorkspaceLayout.cardCornerRadius))
            .padding([.trailing, .bottom], WorkspaceLayout.cardInset)
        }
        .frame(width: 360)
    }

    private var connectionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(model.isConnected ? .green : .secondary).frame(width: 6, height: 6)
                Text(model.statusLabel).font(.caption).lineLimit(2)
                Spacer(minLength: 0)
                if model.isConnecting || model.isBusy { ProgressView().controlSize(.mini) }
                if !model.isBusy {
                    Button(model.isConnected ? "Disconnect" : "Connect") {
                        if model.isConnected { model.disconnect() } else { model.connect() }
                    }
                    .disabled(model.isConnecting).controlSize(.small)
                }
                Button { showsConnection.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Connection settings").accessibilityLabel("Codex connection settings")
            }
            if showsConnection {
                TextField("codex-acp executable (auto-detect)", text: $model.executablePath)
                    .textFieldStyle(.roundedBorder).disabled(model.isConnected || model.isBusy || model.isConnecting)
                Text("Uses your existing Codex login. Adapter \(model.agentVersion.isEmpty ? "not connected" : model.agentVersion).")
                    .font(.caption).foregroundStyle(.secondary)
                Text("If your login expires, run codex login in Terminal, then reconnect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.configOptions.filter { ["mode", "model", "thought_level"].contains($0.category) }) { option in
                Picker(option.name, selection: Binding(get: { option.value }, set: { model.setConfiguration(option, value: $0) })) {
                    ForEach(option.choices.filter { option.category != "mode" || ["workspace-write", "read-only"].contains($0.id) }) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                .font(.caption).controlSize(.small).disabled(model.isBusy || model.isConnecting || !model.isConnected)
            }
        }
        .padding(10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.turns.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Work on this project with Codex").font(.headline)
                            Text("Ask a question or describe a change. Each task captures a baseline so you can review its files afterward.")
                            Text("Chat and review history stay in this window until it is closed or you start a new chat.")
                        }
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 18)
                    }
                    ForEach(model.turns) { turn in
                        AgentTurnView(turn: turn, workspace: workspace)
                    }
                    Color.clear.frame(height: 1).id("agent-bottom")
                }
                .padding(12)
            }
            .onChange(of: model.turns.last?.revision) { proxy.scrollTo("agent-bottom", anchor: .bottom) }
            .onChange(of: model.turns.count) { proxy.scrollTo("agent-bottom", anchor: .bottom) }
            .onChange(of: model.turns.last?.endedAt) { proxy.scrollTo("agent-bottom", anchor: .bottom) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Message Codex").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.draft)
                .font(.body).scrollContentBackground(.hidden)
                .frame(minHeight: 60, idealHeight: 80, maxHeight: 120)
                .padding(5).background(.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                .accessibilityLabel("Message Codex")
            HStack {
                Text(model.isBusy ? "Project editing is protected" : "Snapshots cover non-ignored project files")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if model.canForceDisconnect {
                    Button("End Connection", role: .destructive) { model.disconnect() }.controlSize(.small)
                } else if model.isBusy {
                    Button("Stop") { model.stop() }.disabled(model.isStopping).controlSize(.small)
                } else {
                    Button("Send") { model.send() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isConnecting)
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder private func permissionButtons(_ permission: AgentPermission) -> some View {
        ForEach(permission.options) { option in
            Button(option.name, role: option.kind.hasPrefix("reject") ? .destructive : nil) {
                model.answer(permission, option: option)
            }
            .controlSize(.small)
        }
    }
}

private struct AgentTurnView: View {
    let turn: AgentTurn
    let workspace: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Turn \(turn.number)").fontWeight(.medium)
                Spacer()
                Text(turn.status).foregroundStyle(.secondary)
            }.font(.caption)
            Text(turn.prompt).textSelection(.enabled).font(.callout)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.05), in: .rect(cornerRadius: 8))
            ForEach(turn.items) { item in
                switch item.kind {
                case .assistant:
                    Text((try? AttributedString(markdown: item.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(item.text))
                        .font(.callout).textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            if url.scheme == "https" || url.scheme == "http" { return .systemAction }
                            guard url.scheme == nil || url.isFileURL else { return .discarded }
                            let target = url.path.hasPrefix("/") ? URL(filePath: url.path) : workspace.rootURL.appending(path: url.path)
                            let root = workspace.rootURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                            let components = target.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                            guard components.count > root.count, components.starts(with: root),
                                  FileManager.default.fileExists(atPath: target.path) else { return .discarded }
                            workspace.open(target)
                            return .handled
                        })
                case .notice:
                    DisclosureGroup(item.title) { Text(item.text).font(.caption).textSelection(.enabled) }
                case .tool:
                    AgentToolView(item: item)
                }
            }
            if let failure = turn.reviewFailure {
                Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if turn.endedAt != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Observed this turn · \(turn.changes.count) \(turn.changes.count == 1 ? "file" : "files")").font(.caption).foregroundStyle(.secondary)
                    ForEach(turn.changes) { change in
                        VStack(alignment: .leading, spacing: 2) {
                            Button { workspace.reviewAgentChange(change, turn: turn) } label: {
                                HStack {
                                    Text(change.path).lineLimit(2).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Text(change.kind.rawValue).foregroundStyle(.secondary)
                                }.font(.caption).contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(change.originalText == nil || change.updatedText == nil)
                            .help(change.path)
                            if let note = change.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    if !turn.warnings.isEmpty {
                        DisclosureGroup("Capture limitations (\(turn.warnings.count))") {
                            Text(turn.warnings.joined(separator: "\n")).font(.caption2).textSelection(.enabled)
                        }.font(.caption)
                    }
                    Text("Ignored files and external symlinks are excluded. Text capture is limited to 1 MiB per file. External edits during a task may also appear here.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AgentToolView: View {
    let item: AgentTimelineItem
    private var awaitingExit: Bool { item.hasTerminal && item.exitCode == nil && item.status != "failed" }
    private var symbol: String {
        if awaitingExit { return "clock" }
        if item.status == "failed" || (item.exitCode ?? 0) != 0 { return "xmark.circle" }
        return item.status == "completed" ? "checkmark.circle" : "clock"
    }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).textSelection(.enabled)
                if !item.cwd.isEmpty { Text(item.cwd).foregroundStyle(.secondary).textSelection(.enabled) }
                let output = item.output.isEmpty ? item.contentText : item.output
                if !output.isEmpty {
                    ScrollView([.horizontal, .vertical]) { Text(output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 180)
                }
                if item.outputTruncated { Text("Output truncated at 1 MiB").foregroundStyle(.secondary) }
            }
            .font(.system(.caption, design: .monospaced))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                Text(item.title.isEmpty ? "Tool call" : item.title).lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(item.exitCode.map { "exit \($0)" } ?? (awaitingExit ? "Awaiting exit" : item.status)).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(8).background(.primary.opacity(0.035), in: .rect(cornerRadius: 8))
    }
}

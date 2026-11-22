import SwiftUI

struct AgentPanelView: View {
    @Bindable var model: AgentSessionModel
    let workspace: WorkspaceModel
    @State private var showsConnection = false
    @State private var confirmsRelease = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                Picker("Agent", selection: Binding(get: { model.kind }, set: model.selectAgent)) {
                    ForEach(AgentKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                .disabled(model.isBusy || model.isConnecting || !model.survivingProcessIDs.isEmpty)
                .help("Switch agents and start a new chat in this window")
                Spacer(minLength: 0)
                Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .disabled(model.isBusy || model.isConnecting)
                    .help("New chat · clears this window’s in-memory conversation")
                    .accessibilityLabel("New \(model.kind.displayName) chat")
                Button { workspace.toggleAgentPanel() } label: { Image(systemName: "sidebar.right") }
                    .help("Hide \(model.kind.displayName) (⌘R)").accessibilityLabel("Hide \(model.kind.displayName) panel")
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
                    .buttonStyle(.borderless).help("Connection settings").accessibilityLabel("\(model.kind.displayName) connection settings")
            }
            if showsConnection {
                TextField("\(model.kind.executableName) executable (auto-detect)", text: $model.executablePath)
                    .textFieldStyle(.roundedBorder).disabled(model.isConnected || model.isBusy || model.isConnecting)
                Text("Uses your existing \(model.kind.displayName) login. Adapter \(model.agentVersion.isEmpty ? "not connected" : model.agentVersion).")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.kind.loginHint)
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.configOptions.filter { ["mode", "model", "thought_level"].contains($0.category) }) { option in
                Picker(option.name, selection: Binding(get: { option.value }, set: { model.setConfiguration(option, value: $0) })) {
                    ForEach(option.choices.filter { option.category != "mode" || model.kind.allowedModes.contains($0.id) }) { choice in
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
                            Text("Work on this project with \(model.kind.displayName)").font(.headline)
                            Text("Ask a question or describe a change. Select a file below a turn to read it.")
                            Text("Chat history stays in this window until it is closed or you start a new chat.")
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
            Text("Message \(model.kind.displayName)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.draft)
                .focused($isComposerFocused)
                .task {
                    // Let the native text view join the window before requesting focus.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    isComposerFocused = true
                }
                .font(.body).scrollContentBackground(.hidden)
                .frame(minHeight: 60, idealHeight: 80, maxHeight: 120)
                .padding(5).background(.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                .accessibilityLabel("Message \(model.kind.displayName)")
            HStack {
                Spacer(minLength: 0)
                if !model.survivingProcessIDs.isEmpty {
                    Button("Release Project…", role: .destructive) { confirmsRelease = true }.controlSize(.small)
                } else if model.canForceDisconnect {
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
        .alert("Release the project while \(model.kind.displayName) processes are still running?", isPresented: $confirmsRelease) {
            Button("Release Project", role: .destructive) { Task { await model.releaseSurvivingProcesses() } }
            Button("Keep Waiting", role: .cancel) {}
        } message: {
            Text("Processes \(model.survivingProcessIDs.map(String.init).joined(separator: ", ")) ignored termination and may keep changing files. Releasing the project allows another task to start. Check them in Activity Monitor.")
        }
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
            if let notice = turn.timelineNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
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
                    if item.textTruncated { Text("Message truncated at 256 KiB").font(.caption).foregroundStyle(.secondary) }
                case .notice:
                    DisclosureGroup(item.title) { Text(item.text).font(.caption).textSelection(.enabled) }
                    if item.textTruncated { Text("Details truncated at 256 KiB").font(.caption).foregroundStyle(.secondary) }
                case .tool:
                    AgentToolView(item: item)
                }
            }
            if !turn.editedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Edited by agent · \(turn.editedFiles.count) \(turn.editedFiles.count == 1 ? "file" : "files")")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(turn.editedFiles, id: \.self) { path in
                        Button(path) {
                            let url = workspace.rootURL.appending(path: path)
                            workspace.open(url)
                            workspace.reveal(url)
                        }
                        .buttonStyle(.link).font(.caption).lineLimit(2).truncationMode(.middle).help(path)
                    }
                    if turn.editedFilesTruncated {
                        Text("Showing the first 500 files.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Changes made through shell commands are not listed.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AgentToolView: View {
    let item: AgentTimelineItem
    private var awaitingExit: Bool { item.isAwaitingExit }
    private var symbol: String {
        if awaitingExit { return "clock" }
        if ["failed", "cancelled", "interrupted"].contains(item.displayStatus) || (item.exitCode ?? 0) != 0 { return "xmark.circle" }
        return item.displayStatus == "completed" ? "checkmark.circle" : "clock"
    }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).textSelection(.enabled)
                if !item.cwd.isEmpty { Text(item.cwd).foregroundStyle(.secondary).textSelection(.enabled) }
                if !item.displayOutput.isEmpty {
                    ScrollView([.horizontal, .vertical]) { Text(item.displayOutput).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 180)
                }
                if item.outputTruncated { Text("Output truncated at 1 MiB").foregroundStyle(.secondary) }
                if item.textTruncated { Text("Command details truncated at 16 KiB").foregroundStyle(.secondary) }
            }
            .font(.system(.caption, design: .monospaced))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                Text(item.title.isEmpty ? "Tool call" : item.title).lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(item.exitCode.map { "exit \($0)" } ?? (awaitingExit ? "Awaiting exit" : item.displayStatus)).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(8).background(.primary.opacity(0.035), in: .rect(cornerRadius: 8))
    }
}

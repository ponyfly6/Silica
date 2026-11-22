import SwiftUI

struct AgentPanelView: View {
    @Bindable var model: AgentSessionModel
    let workspace: WorkspaceModel
    @State private var showsConnection = false
    @State private var isScrollingTranscript = false
    @State private var focusRequest = 0

    var body: some View {
        let title = model.sessionTitle.flatMap { $0.isEmpty ? nil : $0 } ?? model.kind.displayName
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(model.isConnected ? Color.green : .secondary).frame(width: 6, height: 6)
                    .help(model.statusLabel).accessibilityLabel(model.statusLabel)
                Text(title).font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.tail).help(title)
                Spacer(minLength: 0)
                Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .disabled(model.isBusy || model.isConnecting)
                    .help("New chat · clears this window’s in-memory conversation")
                    .accessibilityLabel("New \(model.kind.displayName) chat")
                Button { showsConnection.toggle() } label: { Image(systemName: "gearshape") }
                    .help("Connection settings").accessibilityLabel("Connection settings")
                    .popover(isPresented: $showsConnection) { connectionSettings }
                Button { workspace.toggleAgentPanel() } label: { Image(systemName: "sidebar.right") }
                    .help("Hide \(model.kind.displayName) (⌘R)").accessibilityLabel("Hide \(model.kind.displayName) panel")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .frame(height: WorkspaceLayout.titleBarHeight).padding(.horizontal, 12)

            VStack(spacing: 0) {
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
                AgentComposerView(model: model, index: workspace.quickOpen, focusRequest: focusRequest)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: WorkspaceLayout.cardCornerRadius))
            .padding([.trailing, .bottom], WorkspaceLayout.cardInset)
        }
    }

    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.kind.displayName) connection").font(.headline)
            TextField("\(model.kind.executableName) executable (auto-detect)", text: $model.executablePath)
                .textFieldStyle(.roundedBorder).disabled(model.isConnected || model.isBusy || model.isConnecting)
            Text("Adapter \(model.agentVersion.isEmpty ? "not connected" : model.agentVersion)")
            Text(model.kind.loginHint).foregroundStyle(.secondary)
            HStack {
                Text(model.statusLabel).lineLimit(1)
                Spacer()
                Button(model.isConnected ? "Disconnect" : "Connect") {
                    if model.isConnected { model.disconnect() } else { model.connect() }
                }
                .disabled(model.isConnecting || model.isBusy)
            }
        }
        .font(.callout).padding(12).frame(width: 270)
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
                        AgentTurnView(turn: turn, workspace: workspace) {
                            model.draft = turn.prompt
                            focusRequest += 1
                        }
                    }
                    Color.clear.frame(height: 1).id("agent-bottom")
                }
                .padding(12)
            }
            .onScrollPhaseChange { _, phase in isScrollingTranscript = phase != .idle }
            .onScrollGeometryChange(for: TranscriptScroll.self) { geometry in
                TranscriptScroll(height: geometry.contentSize.height,
                                 bottomGap: geometry.contentSize.height - geometry.visibleRect.maxY)
            } action: { previous, current in
                if !isScrollingTranscript, current.height > previous.height, previous.bottomGap < 64, current.bottomGap > 0 {
                    proxy.scrollTo("agent-bottom", anchor: .bottom)
                }
            }
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

private struct TranscriptScroll: Equatable {
    let height: CGFloat
    let bottomGap: CGFloat
}

struct AgentToolView: View {
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

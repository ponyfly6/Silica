import SwiftUI
import SwiftTerm

struct SidePanelView: View {
    let workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Side panel", selection: Binding(get: { workspace.visiblePanel ?? .agent }, set: workspace.showPanel)) {
                    Text("Agent").tag(WorkspaceModel.PanelTab.agent)
                    Text("Terminal").tag(WorkspaceModel.PanelTab.terminal)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                Spacer()
                Button { workspace.hidePanel() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Hide side panel").accessibilityLabel("Hide side panel")
            }
            .padding(.horizontal, 12).frame(height: WorkspaceLayout.titleBarHeight)

            if workspace.isAgentPanelVisible {
                AgentPanelView(model: workspace.agent, workspace: workspace)
            } else if let view = workspace.terminal.view {
                VStack(spacing: 0) {
                    TerminalSurface(view: view)
                        .id(ObjectIdentifier(view))
                        .task(id: ObjectIdentifier(view)) {
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            workspace.terminal.focus()
                        }
                    if workspace.terminal.exited {
                        Divider()
                        HStack {
                            Text("Process exited").foregroundStyle(.secondary)
                            Spacer()
                            Button("Restart") { workspace.terminal.restart() }
                        }
                        .font(.caption).controlSize(.small).padding(8)
                    }
                }
                .clipShape(.rect(cornerRadius: WorkspaceLayout.cardCornerRadius))
                .padding([.bottom, .trailing], WorkspaceLayout.cardInset)
            }
        }
    }
}

private struct TerminalSurface: NSViewRepresentable {
    let view: ShellTerminalView

    func makeNSView(context: Context) -> ShellTerminalView { view }

    func updateNSView(_ view: ShellTerminalView, context: Context) {
        let settings = EditorSettings.shared
        let font = settings.editorFont(ofSize: settings.fontSize)
        if view.font != font { view.font = font }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShellTerminalView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

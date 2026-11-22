import AppKit
import SwiftUI

/// Window root for a workspace: resolves the project bookmark, then shows the editor.
struct WorkspaceWindow: View {
    let projectID: RecentProject.ID?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    @State private var workspace: WorkspaceModel?
    @State private var errorMessage: String?

    @MainActor private static var openCount = 0

    var body: some View {
        Group {
            if let workspace {
                WorkspaceView(workspace: workspace)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Can’t Open Project", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Open Project…") { ProjectOpener(openWindow: openWindow).chooseAndOpen() }
                        .buttonStyle(.glassProminent)
                }
                .frame(minWidth: 500, minHeight: 360)
            } else {
                // Must be a real view: onAppear doesn't fire on an empty Group.
                ProgressView()
                    .frame(minWidth: 500, minHeight: 360)
            }
        }
        .onAppear {
            ExternalOpener.shared.openWindow = openWindow
            Self.openCount += 1
            dismissWindow(id: WindowID.welcome)
            load()
        }
        .onDisappear {
            if let workspace, KeyWorkspace.shared.current === workspace {
                KeyWorkspace.shared.current = nil
            }
            if let workspace { ExternalOpener.shared.workspaceDidClose(workspace) }
            workspace?.close()
            Self.openCount -= 1
            if Self.openCount == 0 {
                openWindow(id: WindowID.welcome)
            }
        }
    }

    private func load() {
        guard workspace == nil else { return }
        guard let projectID else {
            // e.g. a restored window that never had a project: just close it.
            dismiss()
            return
        }
        do {
            let url = try RecentProjectsStore.shared.resolveURL(for: projectID)
            let workspace = WorkspaceModel(rootURL: url)
            self.workspace = workspace
            ExternalOpener.shared.workspaceDidOpen(workspace, projectID: projectID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct WorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    @AppStorage("sidebarWidth") private var sidebarWidth = WorkspaceLayout.defaultSidebarWidth
    @AppStorage("agentPanelWidth") private var agentPanelWidth = WorkspaceLayout.defaultPanelWidth
    @State private var dragStartWidth: Double?

    private var visibleSidebarWidth: Double {
        workspace.isSidebarVisible ? WorkspaceLayout.clampedSidebarWidth(sidebarWidth) : 0
    }

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.width - visibleSidebarWidth
            let panelWidth = WorkspaceLayout.panelWidth(preferred: agentPanelWidth, available: available)
            HStack(spacing: 0) {
                if workspace.isSidebarVisible {
                    FileTreeView(workspace: workspace)
                        .frame(width: visibleSidebarWidth)
                        .overlay(alignment: .trailing) {
                            resizeHandle(leading: false, width: visibleSidebarWidth) { proposed in
                                let reserved = workspace.isAgentPanelVisible ? WorkspaceLayout.panelWidthRange.lowerBound : 0
                                sidebarWidth = WorkspaceLayout.clampedSidebarWidth(min(proposed, geometry.size.width - reserved - WorkspaceLayout.minimumEditorWidth))
                            }
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                EditorArea(workspace: workspace)
                if workspace.isAgentPanelVisible {
                    AgentPanelView(model: workspace.agent, workspace: workspace)
                        .frame(width: panelWidth)
                        .overlay(alignment: .leading) {
                            resizeHandle(leading: true, width: panelWidth) { proposed in
                                let width = WorkspaceLayout.panelWidth(preferred: proposed, available: available)
                                if width != panelWidth { agentPanelWidth = width }
                            }
                            .onTapGesture(count: 2) { agentPanelWidth = WorkspaceLayout.defaultPanelWidth }
                        }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if workspace.isQuickOpenVisible {
                QuickOpenOverlay(workspace: workspace)
            }
        }
        .frame(minWidth: max(640, visibleSidebarWidth + WorkspaceLayout.minimumEditorWidth
                             + (workspace.isAgentPanelVisible ? WorkspaceLayout.panelWidthRange.lowerBound : 0)),
               minHeight: workspace.isAgentPanelVisible ? 520 : 400)
        .containerBackground(for: .window) {
            VisualEffectView()
        }
        .navigationTitle(workspace.name)
        .background(KeyWindowTracker(workspace: workspace))
        .background(AgentCloseGuard(workspace: workspace))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.refresh()
        }
    }

    private func resizeHandle(leading: Bool, width: Double, resize: @escaping (Double) -> Void) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .offset(x: leading ? -4 : 4)
            .pointerStyle(.frameResize(position: leading ? .leading : .trailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? width
                        dragStartWidth = start
                        resize(start + (leading ? -value.translation.width : value.translation.width))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}

struct SidebarToggleButton: View {
    let workspace: WorkspaceModel

    var body: some View {
        Button {
            workspace.toggleSidebar()
        } label: {
            Image(systemName: "sidebar.left")
        }
        // Same plain icon style as the Refresh and Collapse buttons in the sidebar header.
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(workspace.isSidebarVisible ? "Hide Sidebar (⌘B)" : "Show Sidebar (⌘B)")
    }
}

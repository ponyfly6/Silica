import AppKit
import Observation

/// A single writer across duplicate windows and parent/child project roots.
@Observable
final class AgentWorkspaceCoordinator {
    static let shared = AgentWorkspaceCoordinator()
    private var leases: [UUID: URL] = [:]
    @ObservationIgnored private let workspaces = NSHashTable<WorkspaceModel>.weakObjects()

    func register(_ workspace: WorkspaceModel) {
        workspaces.add(workspace)
        workspace.applyAgentEditProtection()
    }

    func unregister(_ workspace: WorkspaceModel) { workspaces.remove(workspace) }

    func isLocked(_ root: URL) -> Bool { root.isFileURL && leases.values.contains { AgentPaths.overlaps($0, root) } }

    func acquire(for workspace: WorkspaceModel) throws -> UUID {
        guard !isLocked(workspace.rootURL) else {
            throw ACPError.message("A task is already running in this project or an overlapping project window.")
        }
        // Any window can have a tab or symlink into this project; each saves only those files.
        let root = workspace.rootURL
        guard workspaces.allObjects.allSatisfy({ $0.saveBeforeAgentTurn(in: root) }) else { throw CancellationError() }
        guard !isLocked(workspace.rootURL) else { throw ACPError.message("Another overlapping project started a task while files were being saved.") }
        let id = UUID()
        leases[id] = workspace.rootURL.resolvingSymlinksInPath()
        // An unrelated window can have a file (or symlink) into this project open.
        for peer in workspaces.allObjects { peer.applyAgentEditProtection() }
        return id
    }

    func release(_ id: UUID) {
        leases[id] = nil
        for workspace in workspaces.allObjects { workspace.applyAgentEditProtection() }
    }
}

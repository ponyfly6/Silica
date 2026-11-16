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

    func isLocked(_ root: URL) -> Bool { leases.values.contains { AgentPaths.overlaps($0, root) } }

    func acquire(for workspace: WorkspaceModel) throws -> UUID {
        guard !isLocked(workspace.rootURL) else {
            throw ACPError.message("A task is already running in this project or an overlapping project window.")
        }
        let peers = workspaces.allObjects.filter { AgentPaths.overlaps($0.rootURL, workspace.rootURL) }
        guard peers.allSatisfy({ $0.saveBeforeAgentTurn() }) else { throw CancellationError() }
        guard !isLocked(workspace.rootURL) else { throw ACPError.message("Another overlapping project started a task while files were being saved.") }
        let id = UUID()
        leases[id] = workspace.rootURL.resolvingSymlinksInPath()
        for peer in peers { peer.applyAgentEditProtection() }
        return id
    }

    func release(_ id: UUID) {
        leases[id] = nil
        for workspace in workspaces.allObjects { workspace.applyAgentEditProtection() }
    }
}

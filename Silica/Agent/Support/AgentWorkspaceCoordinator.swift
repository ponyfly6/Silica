import Foundation

/// Only one running task may own a project or an overlapping project root.
@MainActor
final class AgentWorkspaceCoordinator {
    static let shared = AgentWorkspaceCoordinator()
    private var leases: [UUID: URL] = [:]

    func isLocked(_ root: URL) -> Bool { leases.values.contains { AgentPaths.overlaps($0, root) } }

    func acquire(for root: URL) throws -> UUID {
        guard !isLocked(root) else {
            throw ACPError.message("A task is already running in this project or an overlapping project window.")
        }
        let id = UUID()
        leases[id] = root.resolvingSymlinksInPath()
        return id
    }

    func release(_ id: UUID) { leases[id] = nil }
}

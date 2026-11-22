import Foundation

nonisolated enum AgentPaths {
    static func overlaps(_ first: URL, _ second: URL) -> Bool {
        let a = first.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let b = second.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return a.starts(with: b) || b.starts(with: a)
    }

    static func relativePath(_ path: String, root: URL) -> String? {
        guard !path.isEmpty, !path.utf8.contains(0), path.utf8.count < PATH_MAX else { return nil }
        let target = path.hasPrefix("/") ? URL(filePath: path) : root.appending(path: path)
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard let resolved = resolve(target) else { return nil }
        let components = resolved.pathComponents
        guard components.count > base.count, components.starts(with: base) else { return nil }
        return components.dropFirst(base.count).joined(separator: "/")
    }

    /// Foundation can leave the entire path unresolved when the last component is missing.
    /// Follow existing parents for delete/move events, including symlinks in those parents.
    private static func resolve(_ url: URL) -> URL? {
        if FileManager.default.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL
        }
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { return nil }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path, let resolved = resolve(parent) else { return nil }
        return resolved.appending(path: url.lastPathComponent).standardizedFileURL
    }
}

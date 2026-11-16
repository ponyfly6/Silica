import Foundation

nonisolated enum CodexRuntime {
    static func find(configuredPath: String) -> URL? {
        if !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(filePath: NSString(string: configuredPath).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        var candidates = [URL.homeDirectory.appending(path: "Library/Application Support/Silica Workbench/CodexACP/node_modules/.bin/codex-acp"),
                          URL(filePath: "/opt/homebrew/bin/codex-acp"), URL(filePath: "/usr/local/bin/codex-acp")]
        // Development checkouts keep the pinned runtime outside the application sources.
        var directory = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(directory.appending(path: "Tools/CodexACP/node_modules/.bin/codex-acp"))
            directory.deleteLastPathComponent()
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

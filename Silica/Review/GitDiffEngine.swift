import Darwin
import Foundation

/// Works on immutable text, independently of repository state and the UI.
/// Run on a worker task: waiting for the bounded child process must not block AppKit.
nonisolated enum GitDiffEngine {
    static let maximumInputBytes = 1_048_576
    private static let maximumOutputBytes = 8 * 1_048_576

    static func compare(original: String, updated: String) throws -> UnifiedDiff {
        try Task.checkCancellation()
        guard original.utf8.count <= maximumInputBytes, updated.utf8.count <= maximumInputBytes else {
            throw DiffError.inputTooLarge
        }
        guard !original.contains("\0"), !updated.contains("\0") else { throw DiffError.binary }
        // String equality normalizes Unicode; a code review must preserve byte differences.
        if original.utf8.elementsEqual(updated.utf8) { return .empty }
        guard let executable = executableURL() else { throw DiffError.gitUnavailable }

        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appending(path: "silica-diff-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        try Data(original.utf8).write(to: directory.appending(path: "before"), options: .atomic)
        try Data(updated.utf8).write(to: directory.appending(path: "after"), options: .atomic)
        let output = directory.appending(path: "output")
        let errors = directory.appending(path: "errors")
        manager.createFile(atPath: output.path, contents: nil)
        manager.createFile(atPath: errors.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdout.close(); try? stderr.close() }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.arguments = ["--no-pager", "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color",
                             "--diff-algorithm=histogram", "--unified=3", "--", "before", "after"]
        // Start with a small environment, so GIT_EXTERNAL_DIFF, GIT_CONFIG_COUNT,
        // repository pointers and user configuration cannot change this comparison.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                               "HOME": directory.path, "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_ATTR_NOSYSTEM": "1",
                               "GIT_TERMINAL_PROMPT": "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(0.2)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }
        let start = ProcessInfo.processInfo.systemUptime
        while process.isRunning {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - start < 5 else { throw DiffError.timeout }
            guard byteCount(output) <= maximumOutputBytes, byteCount(errors) <= maximumOutputBytes else {
                throw DiffError.outputTooLarge
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try Task.checkCancellation()
        guard byteCount(output) <= maximumOutputBytes, byteCount(errors) <= maximumOutputBytes else {
            throw DiffError.outputTooLarge
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 || process.terminationStatus == 1 else {
            let data = try Data(contentsOf: errors)
            throw DiffError.failed(String(decoding: data.prefix(2_048), as: UTF8.self))
        }
        let data = try Data(contentsOf: output)
        guard let patch = String(data: data, encoding: .utf8) else { throw DiffError.invalidPatch }
        let result = try UnifiedDiff.parse(patch)
        guard process.terminationStatus == 0 || result.additions + result.deletions > 0 else {
            throw DiffError.invalidPatch
        }
        return result
    }

    private static func byteCount(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func executableURL() -> URL? {
        let paths = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(filePath: $0) }
    }
}

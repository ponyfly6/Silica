import CryptoKit
import Darwin
import Foundation

nonisolated enum AgentPaths {
    static func overlaps(_ first: URL, _ second: URL) -> Bool {
        let a = first.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let b = second.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return a.starts(with: b) || b.starts(with: a)
    }

    static func safeURL(_ path: String, root: URL) -> URL? {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              path.split(separator: "/").first != ".git" else { return nil }
        let candidate = root.appending(path: path)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard resolved.count > base.count, resolved.starts(with: base) else { return nil }
        return candidate
    }
}

nonisolated struct SnapshotEntry: Sendable {
    let fingerprint: String
    let bytes: Data?
    let limitation: String?

    var text: String? {
        guard let bytes else { return nil }
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: bytes, encoding: .utf16LittleEndian) }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(data: bytes, encoding: .utf16BigEndian) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: bytes.dropFirst(3), encoding: .utf8) }
        guard !bytes.contains(0) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}

nonisolated struct TurnFileChange: Identifiable, Sendable {
    enum Kind: String, Sendable { case added = "Added", modified = "Modified", deleted = "Deleted" }
    let path: String
    let before: SnapshotEntry?
    let after: SnapshotEntry?
    var id: String { path }
    var kind: Kind { before == nil ? .added : (after == nil ? .deleted : .modified) }
    var originalText: String? { before == nil ? "" : before?.text }
    var updatedText: String? { after == nil ? "" : after?.text }
    var storedBytes: Int { (before?.bytes?.count ?? 0) + (after?.bytes?.count ?? 0) }
    var note: String? {
        if let limitation = before?.limitation ?? after?.limitation { return limitation }
        guard let old = originalText, let new = updatedText else { return "Binary or unsupported text encoding; no text diff is available." }
        if old.utf8.elementsEqual(new.utf8) { return "Encoding or byte metadata changed; decoded text is unchanged." }
        return nil
    }
}

nonisolated struct TurnSnapshot: Sendable {
    let capturedAt: Date
    let entries: [String: SnapshotEntry]
    let warnings: [String]
    let storedBytes: Int
    static let maximumFileBytes = 1_048_576

    static func capture(root: URL, including knownPaths: Set<String> = [], byteBudget: Int = 50 * 1_048_576) throws -> TurnSnapshot {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var warnings: [String] = []
        let paths: Set<String>
        if let listed = try gitFiles(root: root) { paths = Set(listed).union(knownPaths) }
        else { paths = try Set(scan(root: root, warnings: &warnings)).union(knownPaths) }
        let started = ProcessInfo.processInfo.systemUptime
        var entries: [String: SnapshotEntry] = [:]
        var total = 0
        for (index, path) in paths.sorted().enumerated() {
            try Task.checkCancellation()
            if index >= 20_000 || ProcessInfo.processInfo.systemUptime - started > 15 {
                // A missing enumerated entry must not be mistaken for a deletion.
                throw ACPError.message("The project is too large to capture a reliable turn baseline (20,000 files / 15 seconds). Narrow the project folder.")
            }
            guard let url = AgentPaths.safeURL(path, root: root) else {
                entries[path] = SnapshotEntry(fingerprint: "outside-root", bytes: nil, limitation: "Symlink outside the project; contents were not read.")
                continue
            }
            if let entry = try read(url, remainingBudget: max(0, byteBudget - total)) {
                entries[path] = entry
                total += entry.bytes?.count ?? 0
                if let limitation = entry.limitation, warnings.count < 40 { warnings.append("\(path): \(limitation)") }
            }
        }
        return TurnSnapshot(capturedAt: .now, entries: entries, warnings: warnings, storedBytes: total)
    }

    func changes(comparedTo before: TurnSnapshot) -> [TurnFileChange] {
        Set(entries.keys).union(before.entries.keys).sorted().compactMap { path in
            let old = before.entries[path], new = entries[path]
            guard old?.fingerprint != new?.fingerprint else { return nil }
            return TurnFileChange(path: path, before: old, after: new)
        }
    }

    private static func read(_ url: URL, remainingBudget: Int) throws -> SnapshotEntry? {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            return SnapshotEntry(fingerprint: "unreadable", bytes: nil, limitation: "File metadata could not be read.")
        }
        let metadata = "\(attributes.st_mode):\(attributes.st_size):\(attributes.st_mtimespec.tv_sec):\(attributes.st_mtimespec.tv_nsec):\(attributes.st_ctimespec.tv_sec):\(attributes.st_ctimespec.tv_nsec)"
        if attributes.st_mode & S_IFMT == S_IFLNK {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "unreadable"
            return SnapshotEntry(fingerprint: "link:\(target)", bytes: nil, limitation: "Symlink; contents were not followed.")
        }
        guard attributes.st_mode & S_IFMT == S_IFREG else {
            return SnapshotEntry(fingerprint: metadata, bytes: nil, limitation: "Not a regular file.")
        }
        guard attributes.st_size <= maximumFileBytes, attributes.st_size <= remainingBudget else {
            return SnapshotEntry(fingerprint: metadata, bytes: nil, limitation: "Content not captured: file or review storage limit.")
        }
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else {
                return SnapshotEntry(fingerprint: metadata, bytes: nil, limitation: "File could not be opened safely.")
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var start = stat(), end = stat()
            guard fstat(descriptor, &start) == 0, start.st_mode & S_IFMT == S_IFREG,
                  start.st_size <= maximumFileBytes, start.st_size <= remainingBudget else {
                return SnapshotEntry(fingerprint: metadata, bytes: nil, limitation: "File changed while capturing its version.")
            }
            let bytes = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
            guard fstat(descriptor, &end) == 0, bytes.count == end.st_size,
                  start.st_size == end.st_size, start.st_mtimespec.tv_sec == end.st_mtimespec.tv_sec,
                  start.st_mtimespec.tv_nsec == end.st_mtimespec.tv_nsec else {
                if attempt == 0 { continue }
                return SnapshotEntry(fingerprint: metadata, bytes: nil, limitation: "File changed repeatedly during capture; this version is incomplete.")
            }
            let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let entry = SnapshotEntry(fingerprint: fingerprint, bytes: bytes, limitation: nil)
            guard entry.text != nil else {
                return SnapshotEntry(fingerprint: fingerprint, bytes: nil, limitation: "Binary or unsupported text encoding; content not retained.")
            }
            return entry
        }
        return nil
    }

    private static func gitFiles(root: URL) throws -> [String]? {
        let executable = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let executable else { return nil }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "silica-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let output = scratch.appending(path: "files")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.currentDirectoryURL = root
        process.arguments = ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "."]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate(); kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let start = ProcessInfo.processInfo.systemUptime
        while process.isRunning {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - start < 5 else { throw ACPError.message("Git file discovery timed out.") }
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 4 * 1_048_576 else { throw ACPError.message("Git file discovery exceeded its size limit.") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = try Data(contentsOf: output)
        guard data.count <= 4 * 1_048_576 else { throw ACPError.message("Git file discovery exceeded its size limit.") }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func scan(root: URL, warnings: inout [String]) throws -> [String] {
        // Directory enumeration may expand /var to /private/var even when the
        // supplied root is standardized the other way around on macOS.
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let started = ProcessInfo.processInfo.systemUptime
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            errorHandler: { _, _ in failed = true; return true }) else { throw ACPError.message("Cannot enumerate the project folder.") }
        let base = GitIgnoreStack().adding(GitIgnoreFile(base: "", url: root.appending(path: ".gitignore")))
        var rules: [String: GitIgnoreStack] = ["": base]
        var paths: [String] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - started < 15 else {
                throw ACPError.message("Project discovery timed out; choose a smaller project folder.")
            }
            // Canonicalize the parent, preserving the final symlink itself.
            let parentComponents = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard parentComponents.starts(with: rootComponents) else {
                throw ACPError.message("Project enumeration escaped its root.")
            }
            let path = (Array(parentComponents.dropFirst(rootComponents.count)) + [url.lastPathComponent]).joined(separator: "/")
            let parent = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
            let inherited = rules[parent] ?? base
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
            if isDirectory {
                if [".git", ".hg", ".svn", "node_modules", ".build", ".derivedData", "DerivedData", "build", "Pods"].contains(url.lastPathComponent)
                    || inherited.isIgnored(path, isDirectory: true) { enumerator.skipDescendants() }
                else { rules[path] = inherited.adding(GitIgnoreFile(base: path, url: url.appending(path: ".gitignore"))) }
            } else if url.lastPathComponent != ".DS_Store", !inherited.isIgnored(path, isDirectory: false) {
                paths.append(path)
            }
            guard paths.count <= 20_000 else { throw ACPError.message("More than 20,000 project files; choose a smaller project folder.") }
        }
        if failed { warnings.append("Some directories could not be enumerated; coverage is incomplete.") }
        return paths
    }
}

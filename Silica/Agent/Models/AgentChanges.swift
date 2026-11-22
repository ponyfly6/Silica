import Foundation

nonisolated struct AgentLineCounts: Equatable {
    var added = 0
    var removed = 0

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(added: lhs.added + rhs.added, removed: lhs.removed + rhs.removed)
    }
}

nonisolated struct AgentFileChange: Identifiable {
    let path: String
    var id: String { path }
    let counts: AgentLineCounts?
    let label: String?
}

nonisolated struct AgentChanges {
    private struct Contribution {
        var counts: AgentLineCounts?
        var label: String?

        init(diff: ACPJSON, kind: String) {
            guard let new = diff["newText"].string else { return }
            let old = diff["oldText"].string
            label = kind == "delete" && new.isEmpty ? "deleted" : old == nil ? "new" : nil
            guard var before = Self.lines(old ?? ""), var after = Self.lines(new) else { return }
            while let first = before.first, first == after.first {
                before.removeFirst()
                after.removeFirst()
            }
            while let last = before.last, last == after.last {
                before.removeLast()
                after.removeLast()
            }
            // Bound exact diff work during a transcript flush. For a large middle, count the whole replacement.
            if !before.isEmpty, !after.isEmpty, before.count <= 2_000, after.count <= 2_000 {
                let delta = after.difference(from: before)
                counts = AgentLineCounts(added: delta.insertions.count, removed: delta.removals.count)
            } else {
                counts = AgentLineCounts(added: after.count, removed: before.count)
            }
        }

        init() {}

        private static func lines(_ text: String) -> ArraySlice<Substring>? {
            guard text.utf8.count <= 2 * 1024 * 1024 else { return nil }
            if text.isEmpty { return [] }
            var lines = text.split(maxSplits: 20_001, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            if lines.last?.isEmpty == true { lines.removeLast() }
            return lines.count <= 20_000 ? lines[...] : nil
        }
    }

    private(set) var paths: [String] = []
    private(set) var truncated = false
    private var callsByPath: [String: [String: Contribution]] = [:]

    var files: [AgentFileChange] {
        paths.map { path in
            let calls = callsByPath[path]!.values
            let known = calls.compactMap(\.counts)
            return AgentFileChange(path: path, counts: known.count == calls.count ? known.reduce(.init(), +) : nil,
                                   label: calls.count == 1 ? calls.first?.label : nil)
        }
    }

    mutating func record(_ update: ACPJSON, call: String, kind: String, root: URL) {
        for location in update["locations"].array {
            guard let path = accept(location, root: root) else { continue }
            if callsByPath[path]?[call] == nil { callsByPath[path, default: [:]][call] = Contribution() }
        }
        for diff in update["content"].array where diff["type"].string == "diff" {
            guard let path = accept(diff, root: root) else { continue }
            callsByPath[path, default: [:]][call] = Contribution(diff: diff, kind: kind)
        }
    }

    private mutating func accept(_ entry: ACPJSON, root: URL) -> String? {
        guard let raw = entry["path"].string, let path = AgentPaths.relativePath(raw, root: root) else { return nil }
        if callsByPath[path] == nil {
            guard paths.count < 500 else { truncated = true; return nil }
            paths.append(path)
        }
        return path
    }
}

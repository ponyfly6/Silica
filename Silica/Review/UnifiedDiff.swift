import Foundation

nonisolated struct UnifiedDiff: Sendable {
    let id = UUID()
    struct Row: Sendable {
        enum Kind: Sendable, Equatable { case hunk, context, addition, deletion, notice }
        let kind: Kind
        let text: String
        let oldLine: Int?
        let newLine: Int?
    }

    let rows: [Row]
    let additions: Int
    let deletions: Int

    static let empty = UnifiedDiff(rows: [], additions: 0, deletions: 0)

    /// Parses a single-file patch. Hunk counts, rather than file-header-looking
    /// text, delimit content: source code may itself begin with --- or +++.
    static func parse(_ patch: String, maximumRows: Int = 20_000) throws -> UnifiedDiff {
        var rows: [Row] = []
        var oldLine = 0, newLine = 0, oldRemaining = 0, newRemaining = 0
        var additions = 0, deletions = 0
        let expression = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        // Splitting Characters misses LF inside a CRLF grapheme cluster.
        for line in patch.utf8.split(separator: 0x0A, omittingEmptySubsequences: false) {
            try Task.checkCancellation()
            let text = String(decoding: line, as: UTF8.self)
            if text.hasPrefix("@@ ") {
                guard oldRemaining == 0, newRemaining == 0,
                      let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
                    throw DiffError.invalidPatch
                }
                func number(_ group: Int, default fallback: Int = 1) throws -> Int {
                    let range = match.range(at: group)
                    if range.location == NSNotFound { return fallback }
                    guard let swiftRange = Range(range, in: text), let value = Int(text[swiftRange]) else {
                        throw DiffError.invalidPatch
                    }
                    return value
                }
                oldLine = try number(1)
                oldRemaining = try number(2)
                newLine = try number(3)
                newRemaining = try number(4)
                // Bound hostile/invalid headers before incrementing line counters.
                guard oldLine <= Int.max - oldRemaining, newLine <= Int.max - newRemaining else {
                    throw DiffError.invalidPatch
                }
                rows.append(Row(kind: .hunk, text: text, oldLine: nil, newLine: nil))
            } else if text == "\\ No newline at end of file" {
                guard let previous = rows.last, previous.oldLine != nil || previous.newLine != nil else {
                    throw DiffError.invalidPatch
                }
                rows.append(Row(kind: .notice, text: "No newline at end of file", oldLine: nil, newLine: nil))
            } else if oldRemaining > 0 || newRemaining > 0 {
                switch text.first {
                case " ":
                    guard oldRemaining > 0, newRemaining > 0 else { throw DiffError.invalidPatch }
                    rows.append(Row(kind: .context, text: String(text.dropFirst()), oldLine: oldLine, newLine: newLine))
                    oldLine += 1; newLine += 1; oldRemaining -= 1; newRemaining -= 1
                case "+":
                    guard newRemaining > 0 else { throw DiffError.invalidPatch }
                    rows.append(Row(kind: .addition, text: String(text.dropFirst()), oldLine: nil, newLine: newLine))
                    newLine += 1; newRemaining -= 1; additions += 1
                case "-":
                    guard oldRemaining > 0 else { throw DiffError.invalidPatch }
                    rows.append(Row(kind: .deletion, text: String(text.dropFirst()), oldLine: oldLine, newLine: nil))
                    oldLine += 1; oldRemaining -= 1; deletions += 1
                default: throw DiffError.invalidPatch
                }
            } else if text.hasPrefix("Binary files ") {
                throw DiffError.binary
            } else if !(text.isEmpty || text.hasPrefix("diff --git ") || text.hasPrefix("index ")
                        || text.hasPrefix("--- ") || text.hasPrefix("+++ ")
                        || text.hasPrefix("new file mode ") || text.hasPrefix("deleted file mode ")) {
                throw DiffError.invalidPatch
            }
            guard rows.count <= maximumRows else { throw DiffError.outputTooLarge }
        }
        guard oldRemaining == 0, newRemaining == 0 else { throw DiffError.invalidPatch }
        return UnifiedDiff(rows: rows, additions: additions, deletions: deletions)
    }
}

nonisolated enum DiffError: LocalizedError {
    case gitUnavailable, inputTooLarge, outputTooLarge, binary, invalidPatch, timeout, failed(String)

    var errorDescription: String? {
        switch self {
        case .gitUnavailable: "Git is required to compare file versions. Install Git or the Xcode command line tools, then try again."
        case .inputTooLarge: "File review supports text versions up to 1 MiB each. Open the file to inspect its contents."
        case .outputTooLarge: "This difference is too large to display (8 MiB or 20,000 rows). No partial result is shown."
        case .binary: "Binary content cannot be displayed as a text difference."
        case .invalidPatch: "Git returned a difference that could not be read completely. Try comparing again."
        case .timeout: "The comparison exceeded five seconds. Open the file to inspect it or try a smaller comparison."
        case .failed(let detail): "The comparison failed. \(detail)"
        }
    }
}

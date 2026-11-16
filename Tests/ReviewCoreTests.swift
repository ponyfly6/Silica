import Foundation

@main
struct ReviewCoreTests {
    static func main() async throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            count += 1
        }
        func rejects(_ patch: String, limit: Int = 20_000) {
            do {
                _ = try UnifiedDiff.parse(patch, maximumRows: limit)
                preconditionFailure("Accepted an incomplete or oversized patch")
            } catch { count += 1 }
        }
        let same = try GitDiffEngine.compare(original: "hello\n", updated: "hello\n")
        check(same.rows.isEmpty, "Equal inputs should not run a comparison")

        let changed = try GitDiffEngine.compare(original: "first\nold\nlast\n", updated: "first\nnew\nlast\n")
        check(changed.additions == 1 && changed.deletions == 1, "Incorrect replacement counts")
        let deletion = changed.rows.first { $0.kind == .deletion }!
        let addition = changed.rows.first { $0.kind == .addition }!
        check(deletion.oldLine == 2 && deletion.newLine == nil, "Incorrect old line")
        check(addition.newLine == 2 && addition.oldLine == nil, "Incorrect new line")

        let created = try GitDiffEngine.compare(original: "", updated: "one\ntwo\n")
        check(created.additions == 2 && created.deletions == 0, "Empty original must support additions")
        check(created.rows.first { $0.kind == .addition }?.newLine == 1, "Zero-length hunk starts at line 1")
        let removed = try GitDiffEngine.compare(original: "one\ntwo\n", updated: "")
        check(removed.additions == 0 && removed.deletions == 2, "Empty updated must support deletions")

        let noNewline = try GitDiffEngine.compare(original: "old", updated: "new")
        check(noNewline.rows.filter { $0.kind == .notice }.count == 2, "Missing final newline notices were lost")
        let crlf = try GitDiffEngine.compare(original: "one\r\nold\r\n", updated: "one\r\nnew\r\n")
        check(crlf.additions == 1 && crlf.deletions == 1, "CRLF patch parsing failed")
        check(crlf.rows.first { $0.kind == .addition }?.text == "new\r", "CR bytes must survive parsing")

        let indentation = try GitDiffEngine.compare(original: "def run():\n    work()\n", updated: "def run():\nwork()\n")
        check(indentation.additions == 1 && indentation.deletions == 1, "Indentation changes must remain visible")
        let unicode = try GitDiffEngine.compare(original: "let icon = \"🐱\"\n", updated: "let icon = \"🐶\"\n")
        check(unicode.rows.contains { $0.text.contains("🐶") && $0.kind == .addition }, "UTF-8 must be preserved")
        let canonical = try GitDiffEngine.compare(original: "\u{00E9}\n", updated: "e\u{0301}\n")
        check(canonical.additions == 1 && canonical.deletions == 1, "Canonical-equivalent Unicode still changes source bytes")
        let headers = try GitDiffEngine.compare(original: "--- code\n@@ old\n", updated: "+++ code\n@@ new\n")
        check(headers.additions == 2 && headers.deletions == 2, "Source resembling patch headers was misread")

        let manyOld = (1...40).map { "line \($0)\n" }.joined()
        let manyNew = manyOld.replacingOccurrences(of: "line 2\n", with: "change 2\n")
            .replacingOccurrences(of: "line 38\n", with: "change 38\n")
        let hunks = try GitDiffEngine.compare(original: manyOld, updated: manyNew)
        check(hunks.rows.filter { $0.kind == .hunk }.count == 2, "Separated hunks must retain separate line ranges")
        check(hunks.rows.contains { $0.newLine == 38 && $0.kind == .addition }, "Second hunk numbering is wrong")

        rejects("@@ -1,2 +1,2 @@\n-old\n+new\n")
        rejects("@@ -1 +1 @@\n-old\n+new\n", limit: 2)
        rejects("@@ -9999999999999999999999999 +1 @@\n-old\n+new\n")
        rejects("Binary files before and after differ\n")
        rejects("@@ -1 +1 @@\n?not a patch\n")

        do {
            _ = try GitDiffEngine.compare(original: "", updated: String(repeating: "x", count: GitDiffEngine.maximumInputBytes + 1))
            preconditionFailure("Accepted oversized input")
        } catch DiffError.inputTooLarge { count += 1 }
        do {
            _ = try GitDiffEngine.compare(original: "old", updated: "new\0")
            preconditionFailure("Accepted NUL as text")
        } catch DiffError.binary { count += 1 }

        let oldExternalDiff = ProcessInfo.processInfo.environment["GIT_EXTERNAL_DIFF"]
        setenv("GIT_EXTERNAL_DIFF", "/usr/bin/false", 1)
        defer {
            if let oldExternalDiff { setenv("GIT_EXTERNAL_DIFF", oldExternalDiff, 1) }
            else { unsetenv("GIT_EXTERNAL_DIFF") }
        }
        let isolated = try GitDiffEngine.compare(original: "before\n", updated: "after\n")
        check(isolated.additions == 1, "External diff environment must not affect comparisons")

        let cancelled = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try GitDiffEngine.compare(original: "before", updated: "after")
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Ignored cancellation") }
        catch is CancellationError { count += 1 }

        print("PASS: \(count) checks for Git execution, patch parsing, whitespace, Unicode, bounds, isolation and cancellation")
    }
}

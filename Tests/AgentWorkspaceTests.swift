import AppKit
import Darwin
@testable import Silica

@main
struct AgentWorkspaceTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); count += 1
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "silica-workspace-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
        }
        let a = root.appending(path: "a"), b = root.appending(path: "b")
        for folder in [a, b] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let protectedFile = a.appending(path: "file.txt")
        let otherFile = b.appending(path: "other.txt")
        let alias = b.appending(path: "alias.txt")
        try Data("original\n".utf8).write(to: protectedFile)
        try Data("other\n".utf8).write(to: otherFile)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: protectedFile)
        let workspaceA = WorkspaceModel(rootURL: a), workspaceB = WorkspaceModel(rootURL: b)
        defer { workspaceA.close(); workspaceB.close() }
        workspaceA.open(protectedFile)
        workspaceB.newUntitledFile()
        let untitled = workspaceB.activeBuffer!
        workspaceB.open(otherFile)
        workspaceB.open(alias)
        workspaceB.open(protectedFile)
        // Only edits a task could touch are saved first; others in that window stay unsaved.
        let unrelatedEdit = workspaceB.buffers[otherFile]!
        unrelatedEdit.isDirty = true
        workspaceB.buffers[alias]!.isDirty = true
        check(workspaceB.dirtyFiles(under: a).map(\.url) == [alias], "Pre-task save must cover aliases into the project and nothing else")
        workspaceB.buffers[alias]!.isDirty = false
        // With an unrelated edit pending, acquiring must not prompt (a modal would hang here).
        let lease = try AgentWorkspaceCoordinator.shared.acquire(for: workspaceA)
        check(unrelatedEdit.isDirty && tryContents(otherFile) == "other\n", "Starting a task saved an unrelated file in another window")
        do { _ = try AgentWorkspaceCoordinator.shared.acquire(for: workspaceA); preconditionFailure("Duplicate root lease was allowed") }
        catch { count += 1 }
        let nestedRoot = a.appending(path: "nested")
        try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
        let nested = WorkspaceModel(rootURL: nestedRoot)
        defer { nested.close() }
        do { _ = try AgentWorkspaceCoordinator.shared.acquire(for: nested); preconditionFailure("Nested root lease was allowed") }
        catch { count += 1 }
        check(workspaceA.isAgentEditingLocked && !workspaceB.isAgentEditingLocked, "The unrelated root should remain usable")
        check(workspaceB.buffers[alias]?.textController?.textView.isEditable == false
              && workspaceB.buffers[protectedFile]?.textController?.textView.isEditable == false,
              "Acquiring a lease did not protect aliases and external tabs in unrelated windows")
        check(workspaceB.buffers[otherFile]?.textController?.textView.isEditable == true, "Unrelated files were unnecessarily locked")
        check(untitled.textController!.textView.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "draft"),
              "An unrelated untitled draft was incorrectly treated as a filesystem target")
        let newlyOpened = a.appending(path: "new-tab.txt")
        try Data("new\n".utf8).write(to: newlyOpened)
        workspaceB.open(newlyOpened)
        check(workspaceB.activeBuffer?.textController?.textView.isEditable == false, "A tab opened after acquisition bypassed protection")
        let normal = workspaceB.buffers[otherFile]!
        check(!workspaceB.save(normal, as: a.appending(path: "save-as.txt")), "Cross-project Save As bypassed the lease")
        do { try normal.write(to: protectedFile); preconditionFailure("Direct writes bypassed protection") } catch { count += 1 }
        let aliasBuffer = workspaceB.buffers[alias]!
        aliasBuffer.textController!.textView.string = "must not save\n"
        do { try aliasBuffer.save(); preconditionFailure("Symlink save bypassed protection") } catch { count += 1 }
        workspaceB.activate(alias)
        workspaceB.saveActive()
        workspaceB.createItem(named: "created.txt", in: a, isDirectory: false)
        workspaceB.createItem(named: "../a/traversal.txt", in: b, isDirectory: false)
        workspaceB.rename(protectedFile, to: "renamed.txt")
        workspaceB.duplicate(protectedFile)
        workspaceB.moveToTrash(protectedFile)
        check(tryContents(protectedFile) == "original\n", "A protected mutation changed or deleted the target")
        check(!FileManager.default.fileExists(atPath: a.appending(path: "save-as.txt").path)
              && !FileManager.default.fileExists(atPath: a.appending(path: "created.txt").path)
              && !FileManager.default.fileExists(atPath: a.appending(path: "traversal.txt").path)
              && !FileManager.default.fileExists(atPath: a.appending(path: "file copy.txt").path), "A target-path mutation was not guarded")
        // A link retargeted after the last UI refresh must still be checked at edit/write time.
        let retargeted = b.appending(path: "retargeted.txt")
        try FileManager.default.createSymbolicLink(at: retargeted, withDestinationURL: otherFile)
        workspaceB.open(retargeted)
        let retargetedBuffer = workspaceB.activeBuffer!
        try FileManager.default.removeItem(at: retargeted)
        try FileManager.default.createSymbolicLink(at: retargeted, withDestinationURL: protectedFile)
        check(retargetedBuffer.textController!.textView.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "x") == false,
              "A stale editable view bypassed a retargeted symlink check")
        do { try retargetedBuffer.save(); preconditionFailure("Retargeted symlink save bypassed protection") } catch { count += 1 }
        try Data("agent update\n".utf8).write(to: protectedFile)
        workspaceA.refresh()
        check(workspaceA.activeBuffer?.textController?.textView.string == "agent update\n"
              && workspaceA.activeBuffer?.textController?.textView.isEditable == false,
              "Protection blocked disk synchronization or made the editor writable afterward")
        AgentWorkspaceCoordinator.shared.release(lease)
        check(workspaceB.buffers[alias]?.textController?.textView.isEditable == true, "Releasing a lease did not restore alias editing")
        try aliasBuffer.save()
        check(tryContents(protectedFile) == "must not save\n", "Saving did not work after release")
        check(workspaceB.save(normal, as: a.appending(path: "allowed.txt")), "Save As did not work after release")

        let fixture = CommandLine.arguments[1]
        for scenario in ["cancel", "disconnect", "force-disconnect", "wait-after-response", "overflow"] {
            let folder = root.appending(path: scenario)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let workspace = WorkspaceModel(rootURL: folder)
            defer { workspace.close() }
            workspace.agent.executablePath = fixture
            workspace.agent.draft = "fixture:\(scenario)"
            workspace.agent.send()
            if ["cancel", "force-disconnect", "wait-after-response"].contains(scenario) {
                try await waitUntil { workspace.agent.turns.first?.items.isEmpty == false
                    && (scenario != "wait-after-response" || workspace.agent.turns.first?.status == "Waiting for command exit") }
                check(workspace.isAgentEditingLocked, "Running turn did not acquire editing protection")
                if scenario == "force-disconnect" { await workspace.agent.stopAndDisconnect() }
                else { workspace.agent.stop() }
            }
            var unlockedWhileWriting = false
            try await waitUntil {
                if let raw = tryContents(folder.appending(path: "writer.pid")), let pid = Int32(raw), isRunning(pid),
                   !workspace.isAgentEditingLocked { unlockedWhileWriting = true }
                return !workspace.agent.isBusy
            }
            let turn = workspace.agent.turns[0]
            check(!workspace.isAgentEditingLocked && !turn.hasUnfinishedCommands, "\(scenario): finalization left a lease or hanging tool")
            check(!unlockedWhileWriting, "\(scenario): the lease was released while an owned writer was running")
            if scenario == "overflow" {
                check(turn.status == "Completed" && turn.omittedToolCount == 1 && turn.timelineNotice?.contains("1 failed") == true,
                      "Hidden terminal completion/failure was lost")
                check(turn.changes.contains { $0.path == "late.txt" }, "Final snapshot ran before the hidden terminal exited")
                await workspace.agent.stopAndDisconnect()
            } else {
                let expected = ["disconnect", "force-disconnect"].contains(scenario) ? "interrupted" : "cancelled"
                check(turn.items[0].displayStatus == expected && turn.items[0].exitCode == nil, "\(scenario): tool terminal state is incorrect")
                let pid = Int32(try String(contentsOf: folder.appending(path: "writer.pid"), encoding: .utf8))!
                check(!isRunning(pid), "\(scenario): editing was unlocked before the owned writer stopped")
                let frozen = turn.changes.first { $0.path == "heartbeat" }?.updatedText
                try await Task.sleep(for: .milliseconds(150))
                check(frozen != nil && frozen == tryContents(folder.appending(path: "heartbeat")), "\(scenario): final snapshot was not stable")
            }
        }
        print("PASS: \(count) real workspace path-protection and AgentSessionModel lifecycle checks")
    }

    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(25)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ACPError.message("Offline workspace scenario timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    nonisolated static func tryContents(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    nonisolated static func isRunning(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status != SZOMB
    }
}

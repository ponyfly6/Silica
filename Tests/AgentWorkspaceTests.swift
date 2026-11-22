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
        let project = root.appending(path: "project", directoryHint: .isDirectory)
        let nested = project.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = project.appending(path: "file.txt")
        try Data("original\n".utf8).write(to: file)
        let viewer = WorkspaceModel(rootURL: project)
        defer { viewer.close() }
        viewer.open(file)
        let textView = viewer.activeBuffer!.textController!.textView
        check(!textView.isEditable && textView.isSelectable, "File text must be read-only and selectable")
        let coordinator = AgentWorkspaceCoordinator.shared
        let lease = try coordinator.acquire(for: project)
        let alias = root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        for overlap in [project, nested, root, alias] {
            do { _ = try coordinator.acquire(for: overlap); preconditionFailure("Overlapping root acquired a second lease") }
            catch { count += 1 }
        }
        let sibling = root.appending(path: "project-other")
        let peer = try coordinator.acquire(for: sibling)
        coordinator.release(peer)
        check(coordinator.isLocked(project) && !coordinator.isLocked(sibling), "Independent lease release affected another project")
        textView.setSelectedRange(NSRange(location: 1, length: 2))
        try Data("original updated\n".utf8).write(to: file)
        viewer.refresh()
        check(textView.string == "original updated\n" && textView.selectedRange() == NSRange(location: 1, length: 2),
              "Disk reload lost the new text or the selection")
        check(!textView.isEditable && textView.isSelectable, "Disk refresh made a file editable")
        coordinator.release(lease)
        check(!coordinator.isLocked(nested) && !textView.isEditable, "Releasing a lease must only enable another task")
        let next = try coordinator.acquire(for: nested)
        coordinator.release(next)

        let marker = project.appending(path: "added.txt")
        try Data().write(to: marker)
        try Data("watched contents\n".utf8).write(to: file, options: .atomic)
        try await waitUntil {
            textView.string == "watched contents\n" && viewer.root.children?.contains { $0.url == marker } == true
        }
        check(viewer.activeBuffer?.textController?.textView === textView, "Watcher replaced an open text view")
        try FileManager.default.removeItem(at: file)
        viewer.refresh()
        check(viewer.activeBuffer?.isMissingOnDisk == true && viewer.activeBuffer?.textController == nil,
              "Deleted file still shows stale source")
        try Data("restored\n".utf8).write(to: file)
        viewer.refresh()
        check(viewer.activeBuffer?.textController?.textView.string == "restored\n", "Recreated file did not reload")

        let fixture = CommandLine.arguments[1]
        viewer.agent.selectAgent(.codex)
        viewer.agent.executablePath = fixture
        viewer.agent.draft = "fixture:permission-edit"
        viewer.agent.send()
        try await waitUntil { !viewer.agent.permissions.isEmpty }
        viewer.agent.selectAgent(.claude)
        check(viewer.agent.kind == .codex, "Busy chat switched agents")
        let permission = viewer.agent.permissions[0]
        viewer.agent.answer(permission, option: permission.options[0])
        try await waitUntil { !viewer.agent.isBusy }
        check(viewer.agent.turns.first?.editedFiles == ["permission.txt"], "Lost edit path reported only in a permission request")
        let claudeFixture = root.appending(path: "claude-fixture")
        try FileManager.default.copyItem(at: URL(filePath: fixture), to: claudeFixture)
        viewer.agent.draft = "unsent"
        viewer.agent.selectAgent(.claude)
        check(!viewer.agent.isConnected && viewer.agent.turns.isEmpty && viewer.agent.draft.isEmpty
              && viewer.agent.configOptions.isEmpty && viewer.agent.agentVersion.isEmpty, "Switching agents retained Codex chat state")
        check(viewer.agent.kind == .claude && viewer.agent.executablePath != fixture, "Claude inherited the Codex executable")
        viewer.agent.executablePath = claudeFixture.path
        viewer.agent.connect()
        viewer.agent.selectAgent(.codex)
        check(viewer.agent.kind == .claude, "Connecting chat switched agents")
        try await waitUntil { !viewer.agent.isConnecting }
        let mode = viewer.agent.configOptions.first { $0.category == "mode" }
        check(viewer.agent.isConnected && mode?.value == "auto" && tryContents(project.appending(path: "selected-mode")) == "auto",
              "Claude session failed to negotiate auto: \(viewer.agent.errorMessage ?? "no error")")
        viewer.agent.setConfiguration(mode!, value: "bypassPermissions")
        check(!viewer.agent.isConnecting && viewer.agent.isConnected, "Requested bypassPermissions")
        let otherWindow = WorkspaceModel(rootURL: sibling)
        defer { otherWindow.close() }
        check(otherWindow.agent.kind == .claude && otherWindow.agent.executablePath == claudeFixture.path, "New window lost saved agent settings")
        viewer.agent.selectAgent(.codex)
        check(viewer.agent.executablePath == fixture && !viewer.agent.isConnected && otherWindow.agent.kind == .claude,
              "Switching back lost the Codex executable or changed another window")
        await viewer.agent.stopAndDisconnect()

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
                check(coordinator.isLocked(folder), "Running turn did not acquire the project lease")
                workspace.agent.stop()
                if scenario == "force-disconnect" {
                    try await waitUntil { workspace.agent.canForceDisconnect }
                    check(coordinator.isLocked(folder), "Stalled cancellation released the lease before End Connection")
                    workspace.agent.disconnect()
                }
            }
            var unlockedWhileWriting = false
            try await waitUntil {
                if let raw = tryContents(folder.appending(path: "writer.pid")), let pid = Int32(raw), isRunning(pid),
                   !coordinator.isLocked(folder) { unlockedWhileWriting = true }
                return !workspace.agent.isBusy
            }
            let turn = workspace.agent.turns[0]
            check(!coordinator.isLocked(folder) && !turn.hasUnfinishedCommands, "\(scenario): finalization left a lease or hanging tool")
            check(!unlockedWhileWriting, "\(scenario): the lease was released while an owned writer was running")
            if scenario == "overflow" {
                check(turn.status == "Completed" && turn.omittedToolCount == 1 && turn.timelineNotice?.contains("1 failed") == true,
                      "Hidden terminal completion/failure was lost")
                check(tryContents(folder.appending(path: "late.txt")) == "written before terminal exit\n", "Turn finished before the hidden terminal exited")
                check(turn.editedFiles == ["edited.txt"], "Turn must list the ACP edit and omit the terminal write")
                await workspace.agent.stopAndDisconnect()
            } else {
                let expected = scenario == "disconnect" ? "interrupted" : "cancelled"
                check(turn.items[0].displayStatus == expected && turn.items[0].exitCode == nil, "\(scenario): tool terminal state is incorrect")
                let pid = Int32(try String(contentsOf: folder.appending(path: "writer.pid"), encoding: .utf8))!
                check(!isRunning(pid), "\(scenario): the lease was released before the owned writer stopped")
                let frozen = tryContents(folder.appending(path: "heartbeat"))
                try await Task.sleep(for: .milliseconds(150))
                check(frozen != nil && frozen == tryContents(folder.appending(path: "heartbeat")), "\(scenario): heartbeat changed after lease release")
            }
        }
        print("PASS: \(count) read-only viewer, workspace lease and AgentSessionModel lifecycle checks")
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

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window shows, so none flashes in the other appearance.
        EditorSettings.shared.applyAppearance()
    }

    /// Files and folders from Finder's Open With, the Dock icon or `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalOpener.shared.open(urls)
    }

    /// Quitting asks about running agents and foreground commands in each project window first, in a sheet,
    /// so the answer comes back later.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AgentCloseGuard.GuardView.confirmQuitting { proceed in
            if proceed {
                WorkspaceTerminal.hangUpForQuit { sender.reply(toApplicationShouldTerminate: true) }
            } else {
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}

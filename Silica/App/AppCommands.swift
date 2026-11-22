import SwiftUI

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    /// The project in the key window. Tracked from AppKit key-window changes, since
    /// `focusedSceneValue` came back nil while the editor's NSTextView had focus.
    @ObservedObject private var keyWorkspace = KeyWorkspace.shared
    private var workspace: WorkspaceModel? { keyWorkspace.current }
    @ObservedObject private var updater = AppUpdater.shared

    private var recents: RecentProjectsStore { .shared }
    private var settings: EditorSettings { .shared }
    private var opener: ProjectOpener { ProjectOpener(openWindow: openWindow) }

    var body: some Commands {
        // Lets Finder's open requests at launch open windows before any exists.
        let _ = ExternalOpener.shared.provide(openWindow)

        // About lives in Settings, next to the open-source licenses.
        CommandGroup(replacing: .appInfo) {
            Button("About Silica") {
                UserDefaults.standard.set(SettingsView.Pane.about.rawValue, forKey: SettingsView.paneKey)
                openWindow(id: WindowID.settings)
            }

            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }

        // Settings is a regular Window scene (so it can resize), which doesn't get
        // the Settings… item on its own.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: WindowID.settings) }
                .keyboardShortcut(",")
        }

        CommandGroup(replacing: .newItem) {
            Button("Open…") { opener.chooseAndOpen() }
                .keyboardShortcut("o")

            Menu("Open Recent") {
                ForEach(recents.projects) { project in
                    Button(project.name) { opener.open(project) }
                }
                Divider()
                Button("Clear Menu") { recents.clear() }
                    .disabled(recents.projects.isEmpty)
            }

            Divider()

            Button("Quick Open…") { workspace?.toggleQuickOpen() }
                .keyboardShortcut("p")
                .disabled(workspace == nil)

            Divider()

            Button("Welcome Window") { openWindow(id: WindowID.welcome) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
        }

        // No printing; ⌘P is Quick Open, as in other code editors.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(replacing: .saveItem) {
            // As in VS Code: ⌘W closes the tab, and the window once no tabs are left.
            Button("Close Tab") {
                if let workspace, workspace.activeTab != nil {
                    workspace.closeActiveTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")

            // ⇧⌘W is also handled by KeyWorkspace.installKeyboardShortcuts().
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .sidebar) {
            let agentName = workspace?.agent.kind.displayName ?? "Agent"
            Button(workspace?.isAgentPanelVisible == true ? "Hide \(agentName)" : "Show \(agentName)") { workspace?.toggleAgentPanel() }
                .keyboardShortcut("r")
                .disabled(workspace == nil)

            Divider()
            Button(workspace?.isSidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") {
                workspace?.toggleSidebar()
            }
            .keyboardShortcut("b")
            .disabled(workspace == nil)

            // ⇧⌘E and ⇧⌘F are also handled by KeyWorkspace.installKeyboardShortcuts().
            Button("Explorer") { workspace?.showExplorer() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(workspace == nil)

            Button("Find in Project") { workspace?.showSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(workspace == nil)

            Button("Filter Files") { workspace?.focusTreeFilter() }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(workspace == nil)

            Button("Refresh Explorer") { workspace?.refresh() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(workspace == nil)

            Divider()

            // ⇧⌘V itself is handled by KeyWorkspace.installKeyboardShortcuts().
            Button(workspace?.activeBuffer?.isShowingPreview == true ? "Show Markdown" : "Show Preview") {
                workspace?.activeBuffer?.togglePreview()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(workspace?.activeBuffer?.isMarkdown != true)

            Divider()

            // The file tabs, not the window tabs of the Window menu's Show Next Tab, which
            // has ⌃Tab as well: this menu comes first, so the file tabs get the key.
            // ⇧⌘] and ⇧⌘[ do the same; see KeyWorkspace.installKeyboardShortcuts().
            let hasOtherTabs = (workspace?.openTabs.count ?? 0) > 1

            Button("Select Next Tab") { workspace?.activateTab(offsetBy: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(!hasOtherTabs)

            Button("Select Previous Tab") { workspace?.activateTab(offsetBy: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(!hasOtherTabs)
        }

        CommandGroup(after: .sidebar) {
            Divider()

            Toggle("Word Wrap", isOn: Binding(
                get: { settings.wrapsLines },
                set: { settings.wrapsLines = $0 }
            ))
            .keyboardShortcut("z", modifiers: .option)

            Toggle("Minimap", isOn: Binding(
                get: { settings.showsMinimap },
                set: { settings.showsMinimap = $0 }
            ))

            Divider()

            // ⌘= also zooms in; see EditorSettings.installKeyboardShortcuts().
            Button("Increase Font Size") { settings.increaseFontSize() }
                .keyboardShortcut("+")
                .disabled(!settings.canIncreaseFontSize)

            Button("Decrease Font Size") { settings.decreaseFontSize() }
                .keyboardShortcut("-")
                .disabled(!settings.canDecreaseFontSize)

            Button("Reset Font Size") { settings.resetFontSize() }
                .keyboardShortcut("0")
                .disabled(settings.isDefaultFontSize)
        }

        CommandGroup(after: .textEditing) {
            findButton("Find in File…", action: .showFindInterface)
                .keyboardShortcut("f")
            findButton("Find Next", action: .nextMatch)
                .keyboardShortcut("g")
            findButton("Find Previous", action: .previousMatch)
                .keyboardShortcut("g", modifiers: [.command, .shift])
            findButton("Use Selection for Find", action: .setSearchString)
                .keyboardShortcut("e")
        }

        CommandMenu("Viewer") {
            Button("Go to Line…") { workspace?.showGoToLine() }
                .keyboardShortcut("l")
                .disabled(workspace?.activeBuffer?.textController == nil)
        }
    }

    private func findButton(_ title: LocalizedStringKey, action: NSTextFinder.Action) -> some View {
        let view = workspace?.activeBuffer?.textController?.textView
        return Button(title) {
            if let view, let window = view.window { window.makeFirstResponder(view) }
            let item = NSMenuItem()
            item.tag = action.rawValue
            NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)), to: nil, from: item)
        }
        .disabled(view == nil)
    }
}

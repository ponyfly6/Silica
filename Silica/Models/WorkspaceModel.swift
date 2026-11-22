import AppKit
import Foundation
import Observation
import SwiftUI

/// State for one open project window: the explorer tree and the open editor tabs.
@Observable
final class WorkspaceModel {
    let rootURL: URL
    let root: FileNode

    var selection: URL?
    /// The last file asked to be shown in the tree; `revealCount` changes on every
    /// request so the tree scrolls even when the same file is revealed twice.
    private(set) var revealedURL: URL?
    private(set) var revealCount = 0
    var isSidebarVisible = true
    /// What the sidebar shows: the file tree or Find in Project.
    var sidebarMode: SidebarMode = .explorer
    let search: ProjectSearchModel
    /// Text in the explorer's filter field; the tree shows only matching names.
    var treeFilter = "" {
        didSet { if treeFilter != oldValue { scheduleTreeFilter() } }
    }
    /// Project-relative paths the filtered tree shows; `nil` when not filtering.
    private(set) var treeFilterResult: TreeFilter.Result?
    /// Bumped to put the cursor in the filter field (⌥⌘J).
    var treeFilterFocusRequest = 0
    @ObservationIgnored private var treeFilterItems: [QuickOpenItem]?
    @ObservationIgnored private var treeFilterTask: Task<Void, Never>?
    private(set) var isQuickOpenVisible = false
    let quickOpen: QuickOpenModel
    private(set) var openTabs: [URL] = [] {
        didSet { scheduleSessionSave() }
    }
    private(set) var activeTab: URL? {
        didSet { scheduleSessionSave() }
    }
    private(set) var buffers: [URL: EditorBuffer] = [:]
    enum PanelTab { case agent, terminal }
    private(set) var visiblePanel: PanelTab?
    var isAgentPanelVisible: Bool { visiblePanel == .agent }
    let terminal: WorkspaceTerminal
    @ObservationIgnored lazy var agent = AgentSessionModel(workspace: self)
    @ObservationIgnored private var sidebarHiddenForPanel = false

    var needsCloseConfirmation: Bool { agent.isBusy || agent.isConnecting || terminal.hasForegroundJob }

    /// The project's window, to bring forward when a file is opened in it from outside.
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var isAccessingScope: Bool
    @ObservationIgnored private var watcher: ProjectWatcher?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var isRestoringSession = false
    @ObservationIgnored private var sessionSaveTask: Task<Void, Never>?

    var name: String { root.name }

    var activeBuffer: EditorBuffer? {
        activeTab.flatMap { buffers[$0] }
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.terminal = WorkspaceTerminal(directory: rootURL)
        self.isAccessingScope = rootURL.startAccessingSecurityScopedResource()
        self.root = FileNode(root: rootURL)
        self.quickOpen = QuickOpenModel(rootURL: rootURL)
        self.search = ProjectSearchModel(rootURL: rootURL)
        root.isExpanded = true
        root.loadChildrenIfNeeded()
        // Keep the tree and open files in step with changes made by other apps.
        watcher = ProjectWatcher(url: rootURL) { [weak self] in
            self?.refresh()
        }
        restoreSession()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        terminal.stop()
        agent.close()
        saveSession()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        watcher?.stop()
        watcher = nil
        if isAccessingScope {
            rootURL.stopAccessingSecurityScopedResource()
            isAccessingScope = false
        }
    }

    // MARK: Explorer

    func handleSelectionChange() {
        guard let url = selection else { return }
        if url.hasDirectoryPath {
            if let node = node(for: url) { toggleExpansion(of: node) }
        } else {
            open(url)
        }
    }

    func toggleExpansion(of node: FileNode) {
        withAnimation(.snappy(duration: 0.2)) { node.isExpanded.toggle() }
    }

    /// Expands or collapses the selected folder; returns `false` if nothing changed.
    func setSelectedFolderExpanded(_ expanded: Bool) -> Bool {
        guard let url = selection, url.hasDirectoryPath, let node = node(for: url),
              node.isExpanded != expanded else { return false }
        toggleExpansion(of: node)
        return true
    }

    func toggleSidebar() {
        sidebarHiddenForPanel = false
        withAnimation(.snappy) { isSidebarVisible.toggle() }
    }

    func toggleAgentPanel() {
        if visiblePanel == .agent { hidePanel() }
        else { showPanel(.agent) }
    }

    func toggleTerminal() {
        if visiblePanel == .terminal && terminal.hasFocus { hidePanel() }
        else { showPanel(.terminal) }
    }

    func hidePanel() {
        hideQuickOpen()
        visiblePanel = nil
        if sidebarHiddenForPanel { isSidebarVisible = true; sidebarHiddenForPanel = false }
        if let editor = activeBuffer?.textController?.textView { window?.makeFirstResponder(editor) }
    }

    func showPanel(_ tab: PanelTab) {
        hideQuickOpen()
        if visiblePanel == nil {
            let defaults = UserDefaults.standard
            let sidebar = defaults.object(forKey: "sidebarWidth") as? Double ?? WorkspaceLayout.defaultSidebarWidth
            let panel = defaults.object(forKey: "agentPanelWidth") as? Double ?? WorkspaceLayout.defaultPanelWidth
            let needed = WorkspaceLayout.clampedSidebarWidth(sidebar) + WorkspaceLayout.minimumEditorWidth
                + WorkspaceLayout.panelWidth(preferred: panel, available: .infinity)
            if isSidebarVisible, let width = window?.contentView?.bounds.width, width < needed {
                isSidebarVisible = false; sidebarHiddenForPanel = true
            }
        }
        visiblePanel = tab
        switch tab {
        case .agent: agent.connect()
        case .terminal:
            terminal.startIfNeeded()
            terminal.focus()
        }
    }

    // MARK: Sidebar modes

    enum SidebarMode {
        case explorer, search
    }

    func showExplorer() {
        if !isSidebarVisible { toggleSidebar() }
        sidebarMode = .explorer
    }

    /// Find in Project: shows the search sidebar and focuses its field.
    func showSearch() {
        if !isSidebarVisible { toggleSidebar() }
        sidebarMode = .search
        search.focusRequest += 1
    }

    /// Opens a search result with the match selected.
    func openSearchMatch(_ url: URL, range: NSRange) {
        open(url)
        guard let buffer = buffers[url] else { return }
        if buffer.isShowingPreview { buffer.setShowingPreview(false) }
        // Once the editor for the file is in the window.
        DispatchQueue.main.async {
            buffer.textController?.reveal(range)
        }
    }

    // MARK: Quick Open

    func toggleQuickOpen() {
        if isQuickOpenVisible {
            hideQuickOpen()
        } else {
            showQuickOpen(query: "")
        }
    }

    /// Go to Line (⌘L): Quick Open with ":" typed, as in VS Code.
    func showGoToLine() {
        guard activeBuffer?.textController != nil else { return }
        showQuickOpen(query: ":")
    }

    private func showQuickOpen(query: String) {
        quickOpen.prepareForPresentation(activeFile: activeTab, query: query)
        if !isQuickOpenVisible {
            withAnimation(.snappy(duration: 0.18)) { isQuickOpenVisible = true }
        }
    }

    /// Lines in the active file, for the Go to Line prompt.
    var activeLineCount: Int? {
        activeBuffer?.textController?.lineCount
    }

    func goToLineFromQuickOpen(_ line: Int) {
        hideQuickOpen()
        goToLine(line)
    }

    private func goToLine(_ line: Int) {
        guard let buffer = activeBuffer, let controller = buffer.textController else { return }
        if buffer.isShowingPreview { buffer.setShowingPreview(false) }
        DispatchQueue.main.async { controller.goToLine(line) }
    }

    func hideQuickOpen() {
        guard isQuickOpenVisible else { return }
        withAnimation(.snappy(duration: 0.18)) { isQuickOpenVisible = false }
        // Give typing focus back to the editor.
        if let textView = activeBuffer?.textController?.textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    /// Opens a Quick Open result; "name:42" also jumps to line 42.
    func openFromQuickOpen(_ url: URL, line: Int? = nil) {
        hideQuickOpen()
        open(url)
        reveal(url)
        if let line { goToLine(line) }
    }

    /// Expands the folders above `url` so its row exists, selects it and asks the
    /// tree to scroll to it.
    func reveal(_ url: URL) {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { return }
        var current = root
        for name in components.dropFirst(rootComponents.count).dropLast() {
            var next = current.children?.first { $0.name == name }
            if next == nil {
                // The folder may have appeared since the tree last read the disk.
                current.reload()
                next = current.children?.first { $0.name == name }
            }
            guard let folder = next, folder.isDirectory else { return }
            if !folder.isExpanded { folder.isExpanded = true }
            current = folder
        }
        if current.children?.contains(where: { $0.url == url }) == false {
            current.reload()
        }
        selection = url
        revealedURL = url
        revealCount += 1
    }

    /// Re-reads the tree and checks open files against the disk.
    func refresh() {
        root.reload()
        syncOpenFilesWithDisk()
        search.refresh()
        // Files may have come or gone: filter a fresh list.
        treeFilterItems = nil
        if treeFilterResult != nil { scheduleTreeFilter(after: .milliseconds(300)) }
    }

    // MARK: Tree filter

    var isFilteringTree: Bool {
        !treeFilter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Filter Files (⌥⌘J): shows the explorer and focuses its filter field.
    func focusTreeFilter() {
        showExplorer()
        treeFilterFocusRequest += 1
    }

    private func scheduleTreeFilter(after delay: Duration = .milliseconds(120)) {
        treeFilterTask?.cancel()
        let query = treeFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            treeFilterResult = nil
            return
        }
        let root = rootURL
        let cached = treeFilterItems
        treeFilterTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let (items, result) = await Task.detached(priority: .userInitiated) {
                let items = cached ?? ProjectFileIndex.scan(root: root)
                return (items, TreeFilter.filter(items, by: query))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.treeFilterItems = items
            self.loadFolders(in: result.visiblePaths)
            self.treeFilterResult = result
        }
    }

    /// Reads the folders a filtered tree passes through, without expanding them, so
    /// clearing the filter brings back the tree as it was.
    private func loadFolders(in paths: Set<String>) {
        for path in paths.sorted(by: { $0.count < $1.count }) {
            var current = root
            for name in path.split(separator: "/") {
                current.loadChildrenIfNeeded()
                guard let next = current.children?.first(where: { $0.name == name }) else { break }
                current = next
            }
            if current.isDirectory { current.loadChildrenIfNeeded() }
        }
    }

    private func syncOpenFilesWithDisk() {
        for url in openTabs {
            guard let buffer = buffers[url], buffer.syncWithDisk() else { continue }
            // A deleted, newly readable or reclassified file needs a fresh buffer.
            buffers[url] = makeBuffer(for: url)
        }
    }

    func collapseAll() {
        root.collapseAll()
    }

    func relativePath(of url: URL) -> String {
        let rootPath = rootURL.path(percentEncoded: false).trimmingTrailingSlash
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func node(for url: URL) -> FileNode? {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { return nil }
        var current = root
        for name in components.dropFirst(rootComponents.count) {
            guard let next = current.children?.first(where: { $0.name == name }) else { return nil }
            current = next
        }
        return current
    }

    // MARK: Tabs

    func open(_ url: URL) {
        if buffers[url] == nil {
            buffers[url] = makeBuffer(for: url)
        }
        if !openTabs.contains(url) {
            if let active = activeTab, let index = openTabs.firstIndex(of: active) {
                openTabs.insert(url, at: index + 1)
            } else {
                openTabs.append(url)
            }
        }
        activate(url)
    }

    private func makeBuffer(for url: URL) -> EditorBuffer {
        let buffer = EditorBuffer(url: url)
        // Links in a Markdown preview open other project files here, like Quick Open.
        buffer.openFile = { [weak self] target in
            self?.open(target)
            self?.reveal(target)
        }
        return buffer
    }

    func activate(_ url: URL) {
        activeTab = url
        quickOpen.noteOpened(url)
        if selection != url {
            selection = url
        }
    }

    /// Select Next Tab / Select Previous Tab: the tab `offset` places along the bar from the
    /// active one, going round from either end to the other.
    func activateTab(offsetBy offset: Int) {
        let count = openTabs.count
        guard count > 1, let activeTab, let index = openTabs.firstIndex(of: activeTab) else { return }
        activate(openTabs[((index + offset) % count + count) % count])
    }

    /// Puts a tab at another place in the tab bar (dragging it there).
    func moveTab(_ url: URL, to index: Int) {
        guard let current = openTabs.firstIndex(of: url) else { return }
        let target = min(max(index, 0), openTabs.count - 1)
        guard target != current else { return }
        var tabs = openTabs
        tabs.remove(at: current)
        tabs.insert(url, at: target)
        openTabs = tabs
    }

    func closeActiveTab() {
        if let activeTab { closeTab(activeTab) }
    }

    func closeOtherTabs(than url: URL) {
        for other in openTabs where other != url {
            closeTab(other)
        }
    }

    func closeTab(_ url: URL) {
        guard let index = openTabs.firstIndex(of: url) else { return }
        openTabs.remove(at: index)
        buffers[url] = nil

        if activeTab == url {
            if openTabs.isEmpty {
                activeTab = nil
                selection = nil
            } else {
                activate(openTabs[min(index, openTabs.count - 1)])
            }
        }
    }

    // MARK: Session

    /// Reopens the tabs the project had last time, with their cursor and scroll
    /// positions (unless turned off in Settings).
    private func restoreSession() {
        guard EditorSettings.shared.restoresTabs,
              let session = ProjectSessionStore.session(for: rootURL) else { return }
        isRestoringSession = true
        defer { isRestoringSession = false }

        isSidebarVisible = session.isSidebarVisible
        for tab in session.tabs {
            let url = sessionURL(for: tab.path)
            var isDirectory: ObjCBool = false
            guard !openTabs.contains(url),
                  FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let buffer = makeBuffer(for: url)
            buffers[url] = buffer
            openTabs.append(url)
            buffer.textController?.restorePosition(cursor: tab.cursor, topLine: tab.topLine)
        }
        let active = session.activeTab.map(sessionURL(for:)).flatMap { openTabs.contains($0) ? $0 : nil } ?? openTabs.first
        if let active {
            activate(active)
            reveal(active)
        }
    }

    /// Remembers the open tabs; called on changes (batched), on close and on quit.
    func saveSession() {
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        let tabs = openTabs.map { url in
            let controller = buffers[url]?.textController
            return ProjectSession.Tab(
                path: relativePath(of: url),
                cursor: controller?.cursorLocation,
                topLine: controller?.savedTopLine
            )
        }
        let session = ProjectSession(
            tabs: tabs,
            activeTab: activeTab.map(relativePath(of:)),
            isSidebarVisible: isSidebarVisible,
            savedAt: .now
        )
        ProjectSessionStore.save(session, for: rootURL)
    }

    private func scheduleSessionSave() {
        guard !isRestoringSession else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveSession()
        }
    }

    /// A saved path: relative to the project, or absolute.
    private func sessionURL(for path: String) -> URL {
        let absolute = path.hasPrefix("/") ? path : rootURL.path(percentEncoded: false).trimmingTrailingSlash + "/" + path
        return URL(filePath: absolute, directoryHint: .notDirectory)
    }

    func confirmClosing(in window: NSWindow, terminalConfirmed: Bool = false, completion: @escaping (Bool) -> Void) {
        let busyAgent = agent.isBusy || agent.isConnecting
        let busyTerminal = !terminalConfirmed && terminal.hasForegroundJob
        guard busyAgent || busyTerminal else { completion(true); return }
        let survivors = agent.survivingProcessIDs
        let alert = NSAlert()
        let hangupMessage = "Closing hangs up the shell. Jobs started with nohup can keep running."
        if !busyAgent && survivors.isEmpty {
            alert.messageText = "A command is still running in the terminal."
            alert.informativeText = hangupMessage
        } else if survivors.isEmpty {
            alert.messageText = "\(agent.kind.displayName) is still working in this window."
            alert.informativeText = "Stopping closes this connection. Files already changed remain on disk."
        } else {
            alert.messageText = "Some \(agent.kind.displayName) processes did not stop."
            alert.informativeText = "Processes \(survivors.map(String.init).joined(separator: ", ")) ignored termination and may keep changing files in this project after the window closes."
        }
        if busyTerminal && (busyAgent || !survivors.isEmpty) {
            alert.informativeText += " A command is still running in the terminal. \(hangupMessage)"
        }
        alert.addButton(withTitle: "Keep Open")
        alert.addButton(withTitle: survivors.isEmpty ? "Stop and Close" : "Close Anyway")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { completion(false); return }
            Task {
                if !survivors.isEmpty { await self.agent.releaseSurvivingProcesses() }
                else if busyAgent { await self.agent.stopAndDisconnect() }
                self.confirmClosing(in: window, terminalConfirmed: terminalConfirmed || busyTerminal, completion: completion)
            }
        }
    }
}

import AppKit
import Darwin
import Observation
import SwiftTerm

@Observable
final class WorkspaceTerminal {
    private let directory: URL
    private(set) var view: ShellTerminalView?
    private(set) var exited = false
    @ObservationIgnored private var shell: TerminalShell?
    private static let openTerminals = NSHashTable<WorkspaceTerminal>.weakObjects()
    private static let pendingHangups = DispatchGroup()

    init(directory: URL) { self.directory = directory }

    var hasForegroundJob: Bool { shell?.hasForegroundJob == true }

    var hasFocus: Bool {
        guard let view, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    func focus() {
        if let view { view.window?.makeFirstResponder(view) }
    }

    func startIfNeeded() {
        guard view == nil else { return }
        let settings = EditorSettings.shared
        let terminal = ShellTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400),
                                         font: settings.editorFont(ofSize: settings.fontSize), options: .init())
        view = terminal
        exited = false
        terminal.onExit = { [weak self, weak terminal] in
            guard let self, let terminal, self.view === terminal else { return }
            self.shell = nil
            Self.openTerminals.remove(self)
            self.exited = true
        }

        var env = ProcessInfo.processInfo.environment
        let candidates = [getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }, env["SHELL"]]
        let shell = candidates.compactMap { $0 }.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) } ?? "/bin/zsh"
        env["SHELL"] = shell
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Silica"
        if env["LANG", default: ""].isEmpty { env["LANG"] = "en_US.UTF-8" }
        var paths = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").components(separatedBy: ":")
        for path in [URL.homeDirectory.appending(path: ".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"] where !paths.contains(path) {
            paths.append(path)
        }
        env["PATH"] = paths.joined(separator: ":")
        terminal.startProcess(executable: shell, environment: env.map { "\($0.key)=\($0.value)" },
                              execName: "-" + URL(filePath: shell).lastPathComponent, currentDirectory: directory.path)
        self.shell = TerminalShell(pid: terminal.process.shellPid, executable: shell)
        if self.shell != nil { Self.openTerminals.add(self) }
    }

    func restart() {
        stop()
        startIfNeeded()
    }

    func stop() {
        Self.openTerminals.remove(self)
        if let shell, let process = view?.process {
            self.shell = nil
            Self.pendingHangups.enter()
            Task {
                await shell.hangUp()
                // SwiftTerm's process deinitializer sends TERM to its child.
                // Keep it alive until the shell has had its hang-up grace period.
                withExtendedLifetime(process) {}
                Self.pendingHangups.leave()
            }
        }
        view?.onExit = nil
        view?.updateUiClosed()
        view = nil
    }

    static func hangUpForQuit(completion: @escaping @MainActor @Sendable () -> Void) {
        for terminal in openTerminals.allObjects { terminal.stop() }
        pendingHangups.notify(queue: .main) { completion() }
    }
}

final class ShellTerminalView: LocalProcessTerminalView {
    var onExit: (() -> Void)?

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        onExit?()
    }

    override func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        super.processFailedToStart(source, error: error)
        onExit?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { configureNativeColors() }
    }
}

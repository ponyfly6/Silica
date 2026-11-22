import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AgentComposerTextView: NSTextView {
    var send: () -> Void = {}
    var suggestionKey: (UInt16) -> Bool = { _ in false }
    var addImage: (Data, String) -> Void = { _, _ in }
    var addFiles: ([URL]) -> Void = { _ in }
    private var committingMarkedText = false

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let enter = event.keyCode == 36 || event.keyCode == 76
        if hasMarkedText() {
            if enter {
                committingMarkedText = true
                defer { committingMarkedText = false }
                if inputContext?.handleEvent(event) != true { unmarkText() }
            } else { super.keyDown(with: event) }
            return
        }
        if flags.isEmpty, suggestionKey(event.keyCode) { return }
        if enter, flags.isEmpty || flags == .command { send(); return }
        if enter, flags == .shift { insertNewline(nil); return }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if committingMarkedText, selector == #selector(insertNewline(_:)) { unmarkText(); return }
        super.doCommand(by: selector)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private let imageTypes: [UTType] = [.png, .jpeg, .gif, .webP]

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable {
            let types = imageTypes.map { NSPasteboard.PasteboardType($0.identifier) } + [.tiff, .fileURL]
            if NSPasteboard.general.availableType(from: types) != nil { return true }
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let files = fileURLs(board) { addFiles(files); return }
        for type in imageTypes {
            if let data = board.data(forType: .init(type.identifier)), let mime = type.preferredMIMEType {
                addImage(data, mime)
                return
            }
        }
        if let tiff = board.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) { addImage(png, "image/png"); return }
        super.paste(sender)
    }

    private func fileURLs(_ board: NSPasteboard) -> [URL]? {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender.draggingPasteboard) == nil ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [.fileURL]) == nil ? super.draggingUpdated(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.availableType(from: [.fileURL]) != nil || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = fileURLs(sender.draggingPasteboard) { addFiles(urls); return true }
        return super.performDragOperation(sender)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
        }
    }
}

struct AgentComposerInput: NSViewRepresentable {
    let editor: AgentComposerTextView
    @Binding var text: String
    let onSelection: (NSRange) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 0, height: 2)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.autoresizingMask = .width
        editor.string = text
        editor.delegate = context.coordinator
        editor.registerForDraggedTypes([.fileURL])
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let layout = editor.layoutManager,
              let container = editor.textContainer, let font = editor.font else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: font)
        let height = max(line, layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        return CGSize(width: width, height: ceil(min(8 * line, height) + 2 * editor.textContainerInset.height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentComposerInput
        init(_ parent: AgentComposerInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            parent.text = parent.editor.string
            parent.onSelection(parent.editor.selectedRange())
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            parent.onSelection(parent.editor.selectedRange())
        }
    }
}

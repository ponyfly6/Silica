import SwiftUI
import ImageIO

struct AgentComposerView: View {
    @Bindable var model: AgentSessionModel
    let index: QuickOpenModel
    let focusRequest: Int
    @State private var editor = AgentComposerTextView()
    @State private var completion: Completion?
    @State private var selection = 0
    @State private var confirmsRelease = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !model.survivingProcessIDs.isEmpty {
                Button("Release Project…", role: .destructive) { confirmsRelease = true }
            } else if model.canForceDisconnect {
                Button("End Connection", role: .destructive) { model.disconnect() }
            }
            if let notice = model.attachmentNotice {
                Text(notice).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let completion { suggestions(completion) }
            VStack(alignment: .leading, spacing: 8) {
                if !model.attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(model.attachments) { file in
                                AttachmentChip(file: file) {
                                    model.attachments.removeAll { $0.id == file.id }
                                    model.attachmentNotice = nil
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                ZStack(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text("Message \(model.kind.displayName) — @ to mention files, / for commands")
                            .font(.body).foregroundStyle(.tertiary).padding(.vertical, 2)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    AgentComposerInput(editor: editor, text: $model.draft, onSelection: updateCompletion)
                        .accessibilityLabel("Message \(model.kind.displayName)")
                }
                HStack(spacing: 6) {
                    Button(action: chooseFiles) { Image(systemName: "paperclip") }
                        .help("Attach files").accessibilityLabel("Attach files")
                    Button("@") { insertTrigger("@") }.help("Mention a project file").accessibilityLabel("Mention a file")
                    Button("/") { insertTrigger("/") }.help("Insert a command").accessibilityLabel("Insert a command")
                    agentMenu
                    modelMenu
                    Spacer(minLength: 0)
                    Button {
                        if model.isBusy { model.stop() } else { model.send() }
                    } label: {
                        Image(systemName: model.isBusy ? "stop.fill" : "arrow.up")
                            .font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
                            .foregroundStyle(.white)
                            .background(model.canSend || model.isBusy ? Color.accentColor : Color.secondary, in: .circle)
                    }
                    .fixedSize().disabled(model.isBusy ? model.isStopping : !model.canSend)
                    .accessibilityLabel(model.isBusy ? "Stop" : "Send").help(model.isBusy ? "Stop" : "Send (⌘Return)")
                }
                .buttonStyle(.plain).menuStyle(.borderlessButton).menuIndicator(.hidden)
                .font(.caption).controlSize(.small)
            }
            .padding(8)
            .background(.background.opacity(0.6), in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)).allowsHitTesting(false) }
            .dropDestination(for: URL.self) { urls, _ in addFiles(urls); return true }
            AgentStatusRow(model: model)
        }
        .padding(8)
        .onAppear {
            editor.send = { model.send() }
            editor.suggestionKey = handleKey
            editor.addFiles = addFiles
            editor.addImage = addImage
        }
        .onDisappear {
            editor.send = {}; editor.suggestionKey = { _ in false }
            editor.addFiles = { _ in }; editor.addImage = { _, _ in }
        }
        .onChange(of: focusRequest) { editor.window?.makeFirstResponder(editor) }
        .alert("Release the project while \(model.kind.displayName) processes are still running?", isPresented: $confirmsRelease) {
            Button("Release Project", role: .destructive) { Task { await model.releaseSurvivingProcesses() } }
            Button("Keep Waiting", role: .cancel) {}
        } message: {
            Text("Processes \(model.survivingProcessIDs.map(String.init).joined(separator: ", ")) ignored termination and may keep changing files. Releasing the project allows another task to start. Check them in Activity Monitor.")
        }
    }

    private var agentMenu: some View {
        Menu {
            Picker("Agent", selection: Binding(get: { model.kind }, set: model.selectAgent)) {
                ForEach(AgentKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 2) { Text(model.kind.displayName); Image(systemName: "chevron.down").imageScale(.small) }
        }
        .fixedSize().disabled(model.isBusy || model.isConnecting || !model.survivingProcessIDs.isEmpty)
        .help("Switch agents and start a new chat in this window")
    }

    private var modelMenu: some View {
        let options = AgentPreference.allCases.compactMap { preference in model.configOptions.first { $0.category == preference.rawValue } }
        let names = options.map(\.selectedName)
        let title = names.isEmpty ? "Model" : names.joined(separator: " · ")
        return ViewThatFits(in: .horizontal) {
            configurationMenu(options) { Text(title) }
            configurationMenu(options) { Text(names.first ?? "Model") }
            configurationMenu(options) { Image(systemName: "slider.horizontal.3") }
        }
        .disabled(options.isEmpty || !model.isConnected || model.isBusy || model.isConnecting)
        .accessibilityLabel("Model and reasoning").accessibilityValue(title).help(title)
    }

    private func configurationMenu(_ options: [AgentConfigOption], @ViewBuilder label: () -> some View) -> some View {
        Menu {
            ForEach(options) { option in
                Section(option.category == "model" ? "Model" : "Reasoning") {
                    agentConfigPicker(model, option: option, choices: option.choices)
                }
            }
        } label: { label() }
        .fixedSize()
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if let window = editor.window {
            panel.beginSheetModal(for: window) { if $0 == .OK { addFiles(panel.urls) } }
        }
    }

    private func addFiles(_ urls: [URL]) {
        var errors: [String] = []
        for url in urls {
            if model.attachments.count == AgentPrompt.countLimit { errors.append(AgentPrompt.countLimitMessage); break }
            do { try model.attach(AgentAttachment.file(url)) }
            catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        model.attachmentNotice = errors.first.map { errors.count > 1 ? "\($0) (+\(errors.count - 1) more)" : $0 }
    }

    private func addImage(_ data: Data, mime: String) {
        do {
            try model.attach(.init(name: "Pasted image", url: nil, byteCount: data.count, content: .image(data, mime: mime)))
            model.attachmentNotice = nil
        } catch { model.attachmentNotice = error.localizedDescription }
    }

    private struct Completion: Equatable {
        let trigger: Character
        let query: String
        let range: NSRange

        init?(_ text: String, caret: NSRange) {
            guard caret.length == 0, let range = Range(caret, in: text) else { return nil }
            let prefix = text[..<range.lowerBound]
            let start = prefix.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
            let token = text[start..<range.lowerBound]
            guard let first = token.first, first == "@" || (first == "/" && start == text.startIndex) else { return nil }
            trigger = first
            query = String(token.dropFirst())
            let end = text[range.lowerBound...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            self.range = NSRange(start..<end, in: text)
        }
    }

    private func updateCompletion(_ caret: NSRange) {
        let next = editor.hasMarkedText() ? nil : Completion(editor.string, caret: caret)
        guard completion != next else { return }
        if next?.trigger == "@", completion?.trigger != "@", !index.isIndexing { index.reindex() }
        completion = next
        selection = 0
    }

    private func insertTrigger(_ trigger: String) {
        editor.window?.makeFirstResponder(editor)
        var range = editor.selectedRange()
        var insertion = trigger
        if trigger == "/" {
            range = NSRange(location: 0, length: editor.string.hasPrefix("/") ? 1 : 0)
            if !editor.string.isEmpty && !editor.string.hasPrefix("/") { insertion += " " }
        } else if let selected = Range(range, in: editor.string) {
            if editor.string[..<selected.lowerBound].last?.isWhitespace == false { insertion = " @" }
            if editor.string[selected.upperBound...].first?.isWhitespace == false { insertion += " " }
        }
        editor.insertText(insertion, replacementRange: range)
        let caret = range.location + (insertion.hasPrefix(" ") ? 2 : 1)
        editor.setSelectedRange(.init(location: caret, length: 0))
        updateCompletion(editor.selectedRange())
    }

    private func choices(_ completion: Completion) -> [AgentCommand] {
        if completion.trigger == "/" {
            return model.availableCommands.filter { completion.query.isEmpty || $0.name.localizedCaseInsensitiveContains(completion.query) }
        }
        return index.mentionFiles(matching: completion.query, limit: 40).map { AgentCommand(name: $0, description: "", hint: nil) }
    }

    private func accept(_ choice: AgentCommand, for value: Completion) {
        editor.window?.makeFirstResponder(editor)
        let text = editor.string as NSString
        var range = value.range
        if NSMaxRange(range) < text.length, text.character(at: NSMaxRange(range)) == 32 { range.length += 1 }
        editor.insertText("\(value.trigger)\(choice.name) ", replacementRange: range)
        completion = nil
    }

    private func handleKey(_ code: UInt16) -> Bool {
        guard let completion else { return false }
        if code == 53 { self.completion = nil; return true }
        guard [125, 126, 36, 76, 48].contains(code) else { return false }
        let rows = choices(completion)
        guard !rows.isEmpty else { return false }
        if code == 125 || code == 126 {
            selection = (selection + (code == 125 ? 1 : -1) + rows.count) % rows.count
        } else { accept(rows[min(selection, rows.count - 1)], for: completion) }
        return true
    }

    private func suggestions(_ completion: Completion) -> some View {
        let rows = choices(completion)
        return Group {
            if rows.isEmpty {
                Text(completion.trigger == "@" && index.isIndexing ? "Finding files…" : "No matches")
                    .font(.caption).foregroundStyle(.secondary).padding(5)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(rows.indices, id: \.self) { i in
                                let row = rows[i]
                                Button { accept(row, for: completion) } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("\(completion.trigger)\(row.name)" + (row.hint.map { "  \($0)" } ?? ""))
                                            .lineLimit(1).truncationMode(.middle)
                                        if !row.description.isEmpty { Text(row.description).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    .font(.caption).padding(4).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(i == selection ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 4))
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain).id(i)
                            }
                        }
                    }
                    .frame(maxHeight: 112).fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selection) { proxy.scrollTo(selection) }
                }
            }
        }
        .padding(3).background(.regularMaterial, in: .rect(cornerRadius: 7))
    }
}

extension AgentConfigOption {
    var selectedName: String { choices.first { $0.id == value }?.name ?? value }
}

func agentConfigPicker(_ model: AgentSessionModel, option: AgentConfigOption, choices: [AgentConfigOption.Choice]) -> some View {
    Picker(option.name, selection: Binding(get: { option.value }, set: { model.setConfiguration(option, value: $0) })) {
        ForEach(choices) { Text($0.name).tag($0.id) }
    }.pickerStyle(.inline)
}

private struct AttachmentChip: View {
    let file: AgentAttachment
    let remove: () -> Void
    @State private var hovering = false
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 4) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 2).resizable().scaledToFit().frame(width: 22, height: 22)
            } else { Image(systemName: "doc") }
            Text(file.name).font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: 120)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).opacity(hovering ? 1 : 0)
                .accessibilityLabel("Remove \(file.name)")
        }
        .padding(4).background(.primary.opacity(0.06), in: .rect(cornerRadius: 5))
        .onHover { hovering = $0 }.help(file.name)
        .task(id: file.id) {
            if case let .image(data, _) = file.content,
               let source = CGImageSourceCreateWithData(data as CFData, nil) {
                thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 48,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary)
            }
        }
    }
}

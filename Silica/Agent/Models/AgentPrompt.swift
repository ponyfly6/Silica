import Foundation
import UniformTypeIdentifiers

nonisolated struct AgentAttachment: Identifiable {
    enum Content {
        case image(Data, mime: String)
        case text(String)
        case link
    }

    let id = UUID()
    let name: String
    let url: URL?
    let byteCount: Int
    let content: Content

    static func file(_ url: URL) throws -> Self {
        guard url.isFileURL else { throw ACPError.message("Choose a local file.") }
        let file = url.resolvingSymlinksInPath()
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw ACPError.message("Choose a regular file.")
        }
        let type = values.contentType
        let mime = type?.preferredMIMEType
        let isImage = ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime)
        if isImage && size > AgentPrompt.imageLimit { throw ACPError.message(AgentPrompt.imageLimitMessage) }
        if size > AgentPrompt.totalLimit { throw ACPError.message(AgentPrompt.totalLimitMessage) }

        let content: Content
        if isImage || size <= AgentPrompt.textLimit {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: size + 1) ?? Data()
            guard data.count == size else { throw ACPError.message("The file changed. Attach it again.") }
            if isImage, let mime {
                content = .image(data, mime: mime)
            } else if let text = decodeText(data, type: type) {
                content = .text(text)
            } else { content = .link }
        } else { content = .link }
        return Self(name: url.lastPathComponent, url: url, byteCount: size, content: content)
    }

    private static func decodeText(_ data: Data, type: UTType?) -> String? {
        if let type, [.image, .audiovisualContent, .archive, .pdf, .executable].contains(where: { type.conforms(to: $0) }),
           !type.conforms(to: .text) { return nil }
        let encoding: String.Encoding
        if data.starts(with: [0xff, 0xfe, 0, 0]) || data.starts(with: [0, 0, 0xfe, 0xff]) { encoding = .utf32 }
        else if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { encoding = .utf16 }
        else { encoding = .utf8 }
        guard let text = String(data: data, encoding: encoding),
              !text.unicodeScalars.contains(where: { $0.value < 32 && !$0.properties.isWhitespace }) else { return nil }
        return text
    }
}

nonisolated enum AgentPrompt {
    static let countLimit = 10
    static let countLimitMessage = "Attach up to 10 files per message."
    static let imageLimit = 5 * 1_048_576
    static let totalLimit = 10 * 1_048_576
    static let textLimit = 256 * 1024
    static let imageLimitMessage = "Each image must be 5 MB or smaller."
    static let totalLimitMessage = "Attachments must total 10 MB or less."

    static func validate(_ attachments: [AgentAttachment], capabilities: AgentPromptCapabilities?) throws {
        guard attachments.count <= countLimit else { throw ACPError.message(countLimitMessage) }
        var total = 0
        for attachment in attachments {
            if case let .image(data, _) = attachment.content {
                guard data.count <= imageLimit else { throw ACPError.message(imageLimitMessage) }
                guard capabilities?.image != false else { throw ACPError.message("This agent does not accept image attachments.") }
            }
            guard attachment.byteCount <= totalLimit - total else { throw ACPError.message(totalLimitMessage) }
            total += attachment.byteCount
        }
    }

    static func projectFile(_ path: String, root: URL) -> URL? {
        guard path.utf8.count < PATH_MAX, !path.utf8.contains(0) else { return nil }
        let url = path.hasPrefix("/") ? URL(filePath: path) : root.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path),
              let relative = AgentPaths.relativePath(path, root: root) else { return nil }
        let file = root.resolvingSymlinksInPath().appending(path: relative)
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return file
    }

    static func blocks(text: String, root: URL, attachments: [AgentAttachment], capabilities: AgentPromptCapabilities,
                       resolveMention: (String) -> URL?) throws -> [ACPJSON] {
        try validate(attachments, capabilities: capabilities)
        let prefix = text.hasPrefix("/") ? "" : "Workspace: \(root.path). Finish commands before ending the task; this client does not support detached background jobs.\n\n"
        var blocks: [ACPJSON] = [.object(["type": .string("text"), "text": .string(prefix + text)])]
        var rest = text[...]
        while !rest.isEmpty {
            rest = rest.drop(while: \.isWhitespace)
            let token = rest.prefix { !$0.isWhitespace }
            rest = rest[token.endIndex...]
            guard token.first == "@", token.count > 1 else { continue }
            var path = String(token.dropFirst())
            // A completed path can contain spaces. Consume only as much text as names a file.
            var tail = rest
            var match: URL?
            while path.utf8.count < PATH_MAX {
                if let file = resolveMention(path) {
                    match = file
                    rest = tail
                }
                let spaces = tail.prefix { $0 == " " }
                let word = tail[spaces.endIndex...].prefix { !$0.isWhitespace }
                guard !spaces.isEmpty, !word.isEmpty, word.first != "@" else { break }
                path += spaces + word
                tail = tail[word.endIndex...]
            }
            if let match { blocks.append(link(match, name: match.lastPathComponent)) }
        }
        for attachment in attachments {
            switch attachment.content {
            case let .image(data, mime):
                blocks.append(.object(["type": .string("image"), "mimeType": .string(mime), "data": .string(data.base64EncodedString())]))
            case let .text(text) where capabilities.embeddedContext && attachment.byteCount <= textLimit:
                guard let url = attachment.url else { throw ACPError.message("Missing file URL for \(attachment.name).") }
                blocks.append(.object(["type": .string("resource"), "resource": .object([
                    "uri": .string(url.absoluteString), "mimeType": .string("text/plain"), "text": .string(text)
                ])]))
            default:
                guard let url = attachment.url else { throw ACPError.message("Missing file URL for \(attachment.name).") }
                blocks.append(link(url, name: attachment.name))
            }
        }
        return blocks
    }

    private static func link(_ url: URL, name: String) -> ACPJSON {
        .object(["type": .string("resource_link"), "uri": .string(url.absoluteString), "name": .string(name)])
    }
}

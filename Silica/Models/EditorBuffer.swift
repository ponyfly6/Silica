import AppKit
import Darwin
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// One open file. Text files own a live `TextController` so each tab keeps
/// its selection and scroll position.
@Observable
final class EditorBuffer: Identifiable {
    enum Content {
        case text(TextController)
        case image(ImageFile)
        case binary
        case tooLarge(Int64)
        case unreadable(String)
    }

    let url: URL
    let content: Content
    private var encoding: String.Encoding = .utf8
    let isMissingOnDisk: Bool
    @ObservationIgnored private var diskAttributes: FileAttributes?

    /// Where the cursor is, for the status bar.
    struct CursorStatus: Equatable {
        var line = 1
        var column = 1
        var selectedLength = 0
    }

    var cursor = CursorStatus()
    var indentation = EditorTextView.Indentation(usesTabs: false, width: 4)

    /// Markdown files can switch between their source and a rendered preview.
    let isMarkdown: Bool
    private(set) var isShowingPreview = false
    /// Created the first time the preview is shown, then kept with the tab.
    @ObservationIgnored private(set) var preview: MarkdownPreview?
    /// Opens a project file a preview link points to.
    @ObservationIgnored var openFile: ((URL) -> Void)?

    var id: URL { url }
    var name: String { url.lastPathComponent }

    var textController: TextController? {
        if case .text(let controller) = content { controller } else { nil }
    }

    /// A decoded image shown read-only in the editor card.
    struct ImageFile {
        let image: NSImage
        let pixelSize: CGSize
        let byteCount: Int64
        /// e.g. "PNG", "JPEG", "WebP".
        let format: String
    }

    private static let maxFileSize: Int64 = 20 * 1024 * 1024
    private static let maxImageSize: Int64 = 200 * 1024 * 1024

    init(url: URL) {
        self.url = url
        self.isMarkdown = SyntaxLanguage(url: url) == .markdown

        // From the file system, not URL's resource cache, which can be stale when a
        // changed file is opened again.
        let attributes = Self.attributes(of: url)
        diskAttributes = attributes
        isMissingOnDisk = attributes == nil
        let size = attributes?.size ?? 0

        if Self.isImage(url) {
            if size > Self.maxImageSize {
                content = .tooLarge(size)
            } else if let image = Self.loadImage(url, byteCount: size) {
                content = .image(image)
            } else {
                content = .unreadable("“\(url.lastPathComponent)” couldn’t be decoded as an image.")
            }
            return
        }

        if size > Self.maxFileSize {
            content = .tooLarge(size)
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            content = .unreadable(error.localizedDescription)
            return
        }

        guard !Self.looksBinary(data), let (text, encoding) = Self.decode(data) else {
            content = .binary
            return
        }

        self.encoding = encoding
        let controller = TextController(text: text, language: SyntaxLanguage(url: url))
        content = .text(controller)
        controller.buffer = self
        controller.updateStatus()
    }

    // MARK: Status

    var language: SyntaxLanguage? { SyntaxLanguage(url: url) }

    /// e.g. "UTF-8", for the status bar.
    var encodingName: String {
        switch encoding {
        case .utf8: "UTF-8"
        case .utf16, .utf16BigEndian, .utf16LittleEndian: "UTF-16"
        case .ascii: "ASCII"
        case .isoLatin1: "ISO Latin 1"
        case .windowsCP1252: "Windows 1252"
        case .macOSRoman: "Mac Roman"
        case .shiftJIS: "Shift JIS"
        default: String.localizedName(of: encoding)
        }
    }

    /// "LF", "CRLF" or "CR".
    var lineEndingName: String {
        switch textController?.lineEnding {
        case "\r\n": "CRLF"
        case "\r": "CR"
        default: "LF"
        }
    }

    // MARK: Markdown preview

    func togglePreview() {
        setShowingPreview(!isShowingPreview)
    }

    /// Switches between source and preview, keeping roughly the same place in the
    /// document. `sourceLine` (from a double-click) puts the cursor on that source line.
    func setShowingPreview(_ show: Bool, sourceLine: Int? = nil) {
        guard isMarkdown, let controller = textController, show != isShowingPreview else { return }
        if show {
            let preview = self.preview ?? makePreview()
            self.preview = preview
            preview.show(markdown: controller.textView.string, line: controller.topVisibleLine())
            isShowingPreview = true
        } else if let sourceLine {
            isShowingPreview = false
            DispatchQueue.main.async { controller.scroll(toLine: sourceLine, placingCursor: true) }
        } else {
            preview?.topVisibleLine { [weak self] line in
                self?.isShowingPreview = false
                DispatchQueue.main.async { controller.scroll(toLine: line) }
            }
        }
    }

    private func makePreview() -> MarkdownPreview {
        let preview = MarkdownPreview(fileURL: url)
        preview.onOpenFile = { [weak self] url in self?.openFile?(url) }
        preview.onShowSourceLine = { [weak self] line in self?.setShowingPreview(false, sourceLine: line) }
        return preview
    }

    // MARK: Changes on disk

    /// Returns true when the content type may have changed and the tab needs a new buffer.
    func syncWithDisk() -> Bool {
        let attributes = Self.attributes(of: url)
        guard attributes != diskAttributes else { return false }
        guard let attributes, attributes.size <= Self.maxFileSize, let controller = textController,
              let data = try? Data(contentsOf: url) else { return true }
        guard !Self.looksBinary(data), let (text, encoding) = Self.decode(data) else { return true }
        diskAttributes = attributes
        self.encoding = encoding
        guard controller.replaceText(with: text) else { return false }
        if isShowingPreview, let preview {
            preview.topVisibleLine { line in
                preview.show(markdown: controller.textView.string, line: line)
            }
        }
        return false
    }

    private struct FileAttributes: Equatable {
        let size: Int64
        let inode: UInt64
        let changeSeconds: Int
        let changeNanoseconds: Int
    }

    /// stat follows symlinks. The inode and change time also catch atomic replacements
    /// that preserve the original file size and modification date.
    private static func attributes(of url: URL) -> FileAttributes? {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return FileAttributes(size: info.st_size, inode: info.st_ino,
                              changeSeconds: info.st_ctimespec.tv_sec, changeNanoseconds: info.st_ctimespec.tv_nsec)
    }

    /// Raster image formats ImageIO can decode. SVG opens as source text.
    private static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    private static func loadImage(_ url: URL, byteCount: Int64) -> ImageFile? {
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        var pixelSize = CGSize(width: image.size.width, height: image.size.height)
        var format = url.pathExtension.uppercased()
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                pixelSize = CGSize(width: width, height: height)
            }
            if let typeID = CGImageSourceGetType(source) as String?,
               let name = UTType(typeID)?.preferredFilenameExtension {
                format = name == "jpeg" ? "JPEG" : name == "webp" ? "WebP" : name.uppercased()
            }
        }
        return ImageFile(image: image, pixelSize: pixelSize, byteCount: byteCount, format: format)
    }

    private static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    private static func decode(_ data: Data) -> (String, String.Encoding)? {
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8)
        }
        var converted: NSString?
        var usedLossy: ObjCBool = false
        let raw = NSString.stringEncoding(
            for: data,
            encodingOptions: [.allowLossyKey: false],
            convertedString: &converted,
            usedLossyConversion: &usedLossy
        )
        guard raw != 0, let converted else { return nil }
        return (converted as String, String.Encoding(rawValue: raw))
    }
}

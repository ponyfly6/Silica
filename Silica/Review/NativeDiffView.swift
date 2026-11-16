import AppKit
import SwiftUI

/// The text system owns selection, copy, find, accessibility and scrolling.
/// Line numbers live in a ruler, so copying code does not copy the gutter.
struct NativeDiffView: NSViewRepresentable {
    let difference: UnifiedDiff
    let font: NSFont

    func makeNSView(context: Context) -> DiffScrollView { DiffScrollView() }

    func updateNSView(_ nsView: DiffScrollView, context: Context) {
        nsView.display(difference, font: font)
    }
}

final class DiffScrollView: NSScrollView {
    private let diffText = ReviewTextView(usingTextLayoutManager: true)
    private var gutter: DiffLineNumberRuler!
    private var displayedID: UUID?
    private var displayedFont: NSFont?

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        diffText.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        diffText.minSize = .zero
        diffText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        diffText.isVerticallyResizable = true
        diffText.isHorizontallyResizable = true
        diffText.textContainer?.widthTracksTextView = false
        diffText.textContainer?.containerSize = NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        diffText.isEditable = false
        diffText.isSelectable = true
        diffText.isRichText = false
        diffText.usesFindBar = true
        diffText.isIncrementalSearchingEnabled = true
        diffText.drawsBackground = false
        diffText.textContainerInset = NSSize(width: 10, height: 12)
        diffText.setAccessibilityLabel("File difference. Added and removed lines are identified in the line number gutter.")
        documentView = diffText
        gutter = DiffLineNumberRuler(textView: diffText, scrollView: self)
        verticalRulerView = gutter
        hasVerticalRuler = true
        rulersVisible = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ difference: UnifiedDiff, font: NSFont) {
        guard displayedID != difference.id || displayedFont != font else { return }
        displayedID = difference.id
        displayedFont = font
        let content = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width
            * CGFloat(EditorSettings.shared.tabWidth)
        paragraph.tabStops = []
        var starts: [Int] = []
        for row in difference.rows {
            starts.append(content.length)
            // CR and Unicode separators are visible symbols, not extra display rows.
            let text = row.text.replacingOccurrences(of: "\r", with: "␍")
                .replacingOccurrences(of: "\u{2028}", with: "␤")
                .replacingOccurrences(of: "\u{2029}", with: "␤") + "\n"
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ]
            switch row.kind {
            case .addition: attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.13)
            case .deletion: attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.13)
            case .hunk:
                attributes[.foregroundColor] = SyntaxTheme.lineNumber
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.1)
            case .notice: attributes[.foregroundColor] = SyntaxTheme.lineNumber
            case .context: break
            }
            content.append(NSAttributedString(string: text, attributes: attributes))
        }
        let selection = diffText.selectedRange()
        diffText.textStorage?.setAttributedString(content)
        diffText.font = font
        diffText.setSelectedRange(NSRange(location: min(selection.location, content.length), length: 0))
        gutter.configure(rows: difference.rows, starts: starts, fontSize: font.pointSize)
    }
}

private final class ReviewTextView: NSTextView {
    // Vibrant secondary labels disappear against the glass card in dark mode.
    override var allowsVibrancy: Bool { false }
}

final class DiffLineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var rows: [UnifiedDiff.Row] = []
    private var starts: [Int] = []
    private var digits = 3
    private var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 100
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
            name: NSView.frameDidChangeNotification, object: textView)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    func configure(rows: [UnifiedDiff.Row], starts: [Int], fontSize: CGFloat) {
        self.rows = rows
        self.starts = starts
        font = .monospacedDigitSystemFont(ofSize: max(fontSize - 2, 9), weight: .regular)
        let largest = rows.reduce(1) { max($0, $1.oldLine ?? 0, $1.newLine ?? 0) }
        digits = max(3, String(largest).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        ruleThickness = CGFloat(digits * 2 + 5) * digitWidth + 14
        needsDisplay = true
    }

    @objc private func redraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let manager = textView.textLayoutManager,
              let content = manager.textContentManager, !starts.isEmpty else { return }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect
        let start = manager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, visible.minY - origin.y)))?
            .rangeInElement.location ?? manager.documentRange.location
        var last = -1
        manager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            guard fragment.layoutFragmentFrame.minY + origin.y <= visible.maxY else { return false }
            let baseOffset = content.offset(from: manager.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let offset = baseOffset + line.characterRange.location
                let index = self.rowIndex(at: offset)
                guard index != last, self.starts[index] == offset else { continue }
                last = index
                let row = self.rows[index]
                let marker: String
                switch row.kind {
                case .addition: marker = "+"
                case .deletion: marker = "−"
                default: marker = " "
                }
                let old = row.kind == .hunk ? "old" : (row.oldLine.map(String.init) ?? "")
                let new = row.kind == .hunk ? "new" : (row.newLine.map(String.init) ?? "")
                let label = old.padding(toLength: self.digits, withPad: " ", startingAt: 0)
                    + "  " + new.padding(toLength: self.digits, withPad: " ", startingAt: 0) + " " + marker
                let baseline = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
                let point = self.convert(NSPoint(x: 0, y: baseline), from: textView)
                NSAttributedString(string: label, attributes: [.font: self.font, .foregroundColor: SyntaxTheme.lineNumber])
                    .draw(at: NSPoint(x: 7, y: point.y - self.font.ascender))
            }
            return true
        }
    }

    private func rowIndex(at offset: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

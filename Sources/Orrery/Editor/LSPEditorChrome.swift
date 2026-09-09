import AppKit

/// Completion list drawn with `EditorTheme` colours so it matches the editor, not the system
/// menu. Hosted as a sibling overlay next to the caret.
final class CompletionPopupView: NSView {
    static let rowHeight: CGFloat = 22
    static let defaultWidth: CGFloat = 380
    static let maxVisibleRows = 8

    private(set) var items: [LSPCompletionItem] = []
    private(set) var prefix: String = ""
    private(set) var selectedIndex: Int = 0
    private(set) var visibleItems: [LSPCompletionItem] = []

    var onAccept: ((LSPCompletionItem) -> Void)?

    var selectedItem: LSPCompletionItem? {
        visibleItems.indices.contains(selectedIndex) ? visibleItems[selectedIndex] : nil
    }
    var labels: [String] { visibleItems.map(\.label) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    override var isOpaque: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { false }

    func setItems(_ items: [LSPCompletionItem], prefix: String) {
        self.items = items
        selectedIndex = 0
        applyFilter(prefix)
    }

    func applyFilter(_ prefix: String) {
        self.prefix = prefix
        if prefix.isEmpty {
            visibleItems = items
        } else {
            let p = prefix.lowercased()
            visibleItems = items.filter {
                $0.label.lowercased().hasPrefix(p) || $0.insertText.lowercased().hasPrefix(p)
            }
        }
        if selectedIndex >= visibleItems.count {
            selectedIndex = max(0, visibleItems.count - 1)
        }
        frame.size = intrinsicContentSize
        needsDisplay = true
    }

    func move(_ delta: Int) {
        guard !visibleItems.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), visibleItems.count - 1)
        needsDisplay = true
    }

    @discardableResult
    func accept() -> LSPCompletionItem? {
        guard let item = selectedItem else { return nil }
        onAccept?(item)
        return item
    }

    override var intrinsicContentSize: NSSize {
        let rows = max(1, min(Self.maxVisibleRows, visibleItems.count))
        return NSSize(width: Self.defaultWidth, height: CGFloat(rows) * Self.rowHeight + 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        EditorTheme.background.setFill()
        bounds.fill()
        EditorTheme.gutterText.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        let maxRows = Self.maxVisibleRows
        let first: Int
        if visibleItems.count <= maxRows {
            first = 0
        } else {
            first = min(max(0, selectedIndex - maxRows + 1), visibleItems.count - maxRows)
        }
        let shown = visibleItems.dropFirst(first).prefix(maxRows)
        let startY = bounds.height - 2
        for (offset, item) in shown.enumerated() {
            let index = first + offset
            let y = startY - CGFloat(offset + 1) * Self.rowHeight
            let row = NSRect(x: 1, y: y, width: bounds.width - 2, height: Self.rowHeight)
            if index == selectedIndex {
                EditorTheme.currentLine.setFill()
                row.fill()
                EditorTheme.keyword.setFill()
                NSRect(x: 1, y: y, width: 3, height: Self.rowHeight).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: EditorTheme.font,
                .foregroundColor: EditorTheme.plain,
            ]
            (item.label as NSString).draw(
                in: NSRect(x: 10, y: y + 3, width: bounds.width - 18, height: Self.rowHeight - 4),
                withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let startY = bounds.height - 2
        let offset = Int(floor((startY - point.y) / Self.rowHeight))
        let maxRows = Self.maxVisibleRows
        let first: Int
        if visibleItems.count <= maxRows {
            first = 0
        } else {
            first = min(max(0, selectedIndex - maxRows + 1), visibleItems.count - maxRows)
        }
        let index = first + offset
        if visibleItems.indices.contains(index) {
            selectedIndex = index
            needsDisplay = true
            _ = accept()
        }
    }
}

/// Hover documentation card. Colours come from `EditorTheme`, not the system popover material.
final class HoverCardView: NSView {
    private let field = NSTextField(wrappingLabelWithString: "")
    private(set) var displayedText: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        field.isEditable = false
        field.isSelectable = true
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.textColor = EditorTheme.plain
        field.font = NSFont.systemFont(ofSize: max(11, EditorTheme.fontSize - 1))
        field.maximumNumberOfLines = 16
        field.lineBreakMode = .byWordWrapping
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { true }

    func setText(_ text: String) {
        displayedText = Self.plain(text)
        field.stringValue = displayedText
        field.textColor = EditorTheme.plain
        field.font = NSFont.systemFont(ofSize: max(11, EditorTheme.fontSize - 1))
        let width: CGFloat = 420
        let size = field.sizeThatFits(NSSize(width: width - 20, height: 800))
        let height = min(260, max(32, size.height + 16))
        field.frame = NSRect(x: 10, y: 8, width: width - 20, height: height - 16)
        setFrameSize(NSSize(width: width, height: height))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        EditorTheme.background.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.fill()
        EditorTheme.gutterText.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    static func plain(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "```swift", with: "")
        text = text.replacingOccurrences(of: "```", with: "")
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

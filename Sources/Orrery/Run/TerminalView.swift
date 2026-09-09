import AppKit
import SwiftUI

// MARK: - Palette

/// Terminal colours resolved against the app theme: the default ground matches the editor, the
/// 16 ANSI colours are tuned per appearance, and the 256-palette is computed the way xterm
/// defines it.
enum TerminalPalette {

    static var defaultForeground: NSColor { EditorTheme.plain }
    static var defaultBackground: NSColor { EditorTheme.background }
    static var cursor: NSColor { NSColor.controlAccentColor }
    static var selection: NSColor { NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55) }

    private static let lightANSI: [(Int, Int, Int)] = [
        (0, 0, 0), (194, 54, 33), (37, 137, 37), (173, 137, 0),
        (25, 90, 200), (150, 60, 160), (30, 135, 145), (190, 190, 190),
        (110, 110, 110), (235, 85, 70), (55, 180, 55), (200, 165, 20),
        (75, 130, 240), (190, 100, 200), (60, 175, 185), (240, 240, 240),
    ]
    private static let darkANSI: [(Int, Int, Int)] = [
        (55, 59, 65), (255, 105, 90), (105, 210, 100), (215, 185, 80),
        (95, 155, 255), (215, 130, 225), (90, 200, 210), (200, 205, 212),
        (120, 128, 138), (255, 135, 120), (135, 230, 130), (230, 205, 110),
        (130, 180, 255), (230, 160, 240), (120, 220, 230), (255, 255, 255),
    ]

    private static func ansi(_ index: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (red, green, blue) = (isDark ? darkANSI : lightANSI)[index]
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                           blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    /// xterm's 256 palette: 16 ANSI, a 6×6×6 cube, then 24 greys.
    static func indexed(_ index: Int) -> NSColor {
        switch index {
        case 0...15:
            return ansi(index)
        case 16...231:
            let value = index - 16
            let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
            let red = steps[value / 36], green = steps[(value / 6) % 6], blue = steps[value % 6]
            return NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
        case 232...255:
            let grey = CGFloat(8 + (index - 232) * 10) / 255
            return NSColor(srgbRed: grey, green: grey, blue: grey, alpha: 1)
        default:
            return defaultForeground
        }
    }

    static func color(_ colour: TermColor, foreground: Bool) -> NSColor {
        switch colour {
        case .default: return foreground ? defaultForeground : defaultBackground
        case let .indexed(index): return indexed(index)
        case let .rgb(red, green, blue):
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                           blue: CGFloat(blue) / 255, alpha: 1)
        }
    }
}

// MARK: - Grid view

/// Draws the emulator's grid and turns keys and clicks into PTY bytes. Lives as the document
/// view of a scroll view; scrollback is simply the rows above the live screen.
final class TerminalGridView: NSView {

    weak var session: TerminalSession?

    private var cellWidth: CGFloat = 8
    private var cellHeight: CGFloat = 16
    private var ascent: CGFloat = 12
    private var font = EditorTheme.font
    private var boldFont = EditorTheme.font

    /// Selection in display-row coordinates, ordered start ≤ end.
    private var selectionAnchor: (row: Int, col: Int)?
    private var selectionHead: (row: Int, col: Int)?

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func accessibilityValue() -> Any? { session?.emulator.screenText() ?? "" }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(session: TerminalSession) {
        self.session = session
        super.init(frame: .zero)
        recomputeMetrics()
        NotificationCenter.default.addObserver(
            self, selector: #selector(fontChanged), name: .editorFontChanged, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func fontChanged() {
        recomputeMetrics()
        fitToClipView()
        needsDisplay = true
    }

    private func recomputeMetrics() {
        font = EditorTheme.font
        boldFont = NSFont.monospacedSystemFont(ofSize: EditorTheme.fontSize, weight: .bold)
        cellWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        cellHeight = ceil(font.ascender - font.descender + font.leading) + 1
        ascent = font.ascender
    }

    // MARK: Sizing

    /// Called when the clip view changes size or the grid content grows: resizes the PTY to the
    /// visible cell count and the document to the scrollback length.
    func fitToClipView() {
        guard let session, let clip = enclosingScrollView?.contentView else { return }
        // SwiftUI creates the scroll view with a zero/transient fitting size. Sending that
        // size to a newly launched CLI makes its first output wrap into two-column lines.
        guard window != nil, clip.bounds.width >= cellWidth * 20,
              clip.bounds.height >= cellHeight * 2 else { return }
        let cols = max(2, Int(clip.bounds.width / cellWidth))
        let rows = max(2, Int(clip.bounds.height / cellHeight))
        session.resize(cols: cols, rows: rows)
        let height = max(clip.bounds.height,
                         CGFloat(session.emulator.displayRowCount) * cellHeight)
        let size = NSSize(width: clip.bounds.width, height: height)
        if frame.size != size { setFrameSize(size) }
    }

    func refresh(scrollToBottom: Bool) {
        guard session != nil, let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let wasPinned = clip.bounds.maxY >= frame.height - cellHeight - 2
        fitToClipView()
        if scrollToBottom || wasPinned {
            scroll(NSPoint(x: 0, y: max(0, frame.height - clip.bounds.height)))
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let session else { return }
        let emulator = session.emulator

        TerminalPalette.defaultBackground.setFill()
        dirtyRect.fill()

        let firstRow = max(0, Int(dirtyRect.minY / cellHeight))
        let lastRow = min(emulator.displayRowCount - 1, Int(dirtyRect.maxY / cellHeight) + 1)
        guard firstRow <= lastRow else { return }

        for row in firstRow...lastRow {
            drawRow(emulator.displayRow(row), at: row, emulator: emulator)
        }

        if emulator.cursorVisible && session.isRunning {
            drawCursor(emulator)
        }
    }

    private func rectFor(row: Int, col: Int, width: Int = 1) -> NSRect {
        NSRect(x: CGFloat(col) * cellWidth, y: CGFloat(row) * cellHeight,
               width: cellWidth * CGFloat(width), height: cellHeight)
    }

    private func drawRow(_ cells: [TermCell], at row: Int, emulator: TerminalEmulator) {
        let y = CGFloat(row) * cellHeight
        var col = 0
        while col < cells.count {
            // One run: consecutive cells with the same style.
            let style = cells[col].style
            var end = col + 1
            while end < cells.count && cells[end].style == style { end += 1 }

            var fg = TerminalPalette.color(style.foreground, foreground: true)
            var bg = TerminalPalette.color(style.background, foreground: false)
            if style.attributes.contains(.bold), case let .indexed(index) = style.foreground,
               index < 8 {
                fg = TerminalPalette.indexed(index + 8)   // bold brightens the base colours
            }
            if style.attributes.contains(.reverse) { swap(&fg, &bg) }
            if style.attributes.contains(.dim) { fg = fg.withAlphaComponent(0.6) }

            if style.background != .default || style.attributes.contains(.reverse) {
                bg.setFill()
                rectFor(row: row, col: col, width: end - col).fill()
            }

            if !style.attributes.contains(.hidden) {
                var text = ""
                for cell in cells[col..<end] where !cell.isContinuation {
                    text.append(cell.character)
                }
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    var attributes: [NSAttributedString.Key: Any] = [
                        .font: style.attributes.contains(.bold) ? boldFont : font,
                        .foregroundColor: fg,
                    ]
                    if style.attributes.contains(.italic) {
                        attributes[.obliqueness] = 0.18
                    }
                    if style.attributes.contains(.underline) {
                        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }
                    if style.attributes.contains(.strikethrough) {
                        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    }
                    NSAttributedString(string: text, attributes: attributes)
                        .draw(at: NSPoint(x: CGFloat(col) * cellWidth, y: y))
                }
            }
            col = end
        }

        // Selection overlays the text so the run merging above stays simple.
        if let range = selectedRange() {
            let (start, endSel) = range
            if row >= start.row && row <= endSel.row {
                let fromCol = row == start.row ? start.col : 0
                let toCol = row == endSel.row ? endSel.col : emulator.cols
                if toCol > fromCol {
                    TerminalPalette.selection.setFill()
                    rectFor(row: row, col: fromCol, width: toCol - fromCol)
                        .fill(using: .sourceOver)
                }
            }
        }
    }

    private func drawCursor(_ emulator: TerminalEmulator) {
        let rect = rectFor(row: emulator.cursorDisplayRow, col: emulator.cursorCol)
        let focused = window?.firstResponder == self
        if focused {
            TerminalPalette.cursor.setFill()
            rect.fill()
            let cell = emulator.cell(row: emulator.cursorRow, col: emulator.cursorCol)
            if !cell.isContinuation && cell.character != " " {
                NSAttributedString(string: String(cell.character), attributes: [
                    .font: font, .foregroundColor: TerminalPalette.defaultBackground,
                ]).draw(at: rect.origin)
            }
        } else {
            TerminalPalette.cursor.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let session, session.isRunning else { return super.keyDown(with: event) }
        if event.modifierFlags.contains(.command) { return super.keyDown(with: event) }
        clearSelection()

        if let bytes = translate(event, applicationCursor: session.emulator.applicationCursorKeys) {
            session.send(text: bytes)
            return
        }
        interpretKeyEvents([event])
    }

    /// The escape encodings programs expect; nil means "plain text, let input handling do it".
    private func translate(_ event: NSEvent, applicationCursor: Bool) -> String? {
        let option = event.modifierFlags.contains(.option)
        switch event.specialKey {
        case .some(.upArrow): return applicationCursor ? "\u{1B}OA" : "\u{1B}[A"
        case .some(.downArrow): return applicationCursor ? "\u{1B}OB" : "\u{1B}[B"
        case .some(.rightArrow): return option ? "\u{1B}f" : (applicationCursor ? "\u{1B}OC" : "\u{1B}[C")
        case .some(.leftArrow): return option ? "\u{1B}b" : (applicationCursor ? "\u{1B}OD" : "\u{1B}[D")
        case .some(.home): return "\u{1B}[H"
        case .some(.end): return "\u{1B}[F"
        case .some(.pageUp): return "\u{1B}[5~"
        case .some(.pageDown): return "\u{1B}[6~"
        case .some(.deleteForward): return "\u{1B}[3~"
        default: break
        }
        switch event.keyCode {
        case 36, 76: return "\r"          // return, keypad enter
        case 48: return "\t"
        case 51: return "\u{7F}"          // delete key sends DEL
        case 53: return "\u{1B}"          // escape
        default: break
        }
        if event.modifierFlags.contains(.control) {
            // macOS supplies the control code in `characters` for letters; space needs help.
            if event.charactersIgnoringModifiers == " " { return "\u{0}" }
            if let characters = event.characters, !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ $0.value < 0x20 || $0.value == 0x7F }) {
                return characters
            }
        }
        if option, let base = event.charactersIgnoringModifiers, base.count == 1,
           let scalar = base.unicodeScalars.first, scalar.isASCII {
            return "\u{1B}" + base        // option as meta
        }
        return nil
    }

    override func insertText(_ insertString: Any) {
        let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        session?.send(text: text)
    }

    override func doCommand(by selector: Selector) {
        // Everything meaningful was translated in keyDown; the rest must not beep.
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        session?.paste(text)
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard let session else { return }
        selectionAnchor = (0, 0)
        selectionHead = (session.emulator.displayRowCount - 1, session.emulator.cols)
        needsDisplay = true
    }

    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(copy(_:)) { return selectedText() != nil }
        return super.responds(to: selector)
    }

    // MARK: Selection

    private func cellAt(_ point: NSPoint) -> (row: Int, col: Int) {
        (max(0, Int(point.y / cellHeight)), max(0, Int(round(point.x / cellWidth))))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        selectionAnchor = cellAt(point)
        selectionHead = selectionAnchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        selectionHead = cellAt(point)
        autoscroll(with: event)
        needsDisplay = true
    }

    private func clearSelection() {
        guard selectionAnchor != nil else { return }
        selectionAnchor = nil
        selectionHead = nil
        needsDisplay = true
    }

    private func selectedRange() -> ((row: Int, col: Int), (row: Int, col: Int))? {
        guard let anchor = selectionAnchor, let head = selectionHead,
              anchor != head else { return nil }
        if anchor.row < head.row || (anchor.row == head.row && anchor.col < head.col) {
            return (anchor, head)
        }
        return (head, anchor)
    }

    func selectedText() -> String? {
        guard let session, let (start, end) = selectedRange() else { return nil }
        var lines: [String] = []
        for row in start.row...min(end.row, session.emulator.displayRowCount - 1) {
            let cells = session.emulator.displayRow(row)
            let fromCol = row == start.row ? min(start.col, cells.count) : 0
            let toCol = row == end.row ? min(end.col, cells.count) : cells.count
            guard toCol > fromCol else { lines.append(""); continue }
            var line = ""
            for cell in cells[fromCol..<toCol] where !cell.isContinuation {
                line.append(cell.character)
            }
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.fitToClipView()
        }
    }
}

// MARK: - SwiftUI wrapper

struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = TerminalPalette.defaultBackground

        let grid = TerminalGridView(session: session)
        scrollView.documentView = grid

        scrollView.contentView.postsFrameChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scrollView.contentView,
            queue: .main) { [weak grid] _ in
            Task { @MainActor in grid?.fitToClipView(); grid?.needsDisplay = true }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        _ = session.revision   // registers the observation that drives repaints
        guard let grid = scrollView.documentView as? TerminalGridView else { return }
        grid.session = session
        grid.refresh(scrollToBottom: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var observer: NSObjectProtocol?
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// The Terminal tab of the bottom pane: a header naming the shell and its state, the grid, and
/// a restart control.
struct TerminalPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session = model.terminal {
                TerminalHostView(session: session)
            } else {
                Text("No terminal session.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if let session = model.terminal {
                let shellName = (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
                let label = session.title.isEmpty
                    ? (shellName as NSString).lastPathComponent : session.title
                Text(label).font(.caption).fontWeight(.medium)
                if let failure = session.startFailure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                } else if let status = session.exitStatus {
                    Text("shell exited (\(status))").font(.caption).foregroundStyle(.orange)
                } else if session.isRunning {
                    Text(model.projectURL?.lastPathComponent ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    session.restart(in: model.projectURL)
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Kill the shell and start a new one in the project directory")
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

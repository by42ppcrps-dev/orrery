import Foundation

// MARK: - Cells

/// A terminal colour. Indexed covers the 16 ANSI colours and the xterm 256 palette;
/// rgb is 24-bit "truecolor".
enum TermColor: Equatable, Hashable {
    case `default`
    case indexed(Int)
    case rgb(UInt8, UInt8, UInt8)
}

struct TermAttributes: OptionSet, Equatable, Hashable {
    let rawValue: Int
    static let bold          = TermAttributes(rawValue: 1 << 0)
    static let dim           = TermAttributes(rawValue: 1 << 1)
    static let italic        = TermAttributes(rawValue: 1 << 2)
    static let underline     = TermAttributes(rawValue: 1 << 3)
    static let reverse       = TermAttributes(rawValue: 1 << 4)
    static let strikethrough = TermAttributes(rawValue: 1 << 5)
    static let hidden        = TermAttributes(rawValue: 1 << 6)
}

struct TermStyle: Equatable, Hashable {
    var foreground: TermColor = .default
    var background: TermColor = .default
    var attributes: TermAttributes = []
}

struct TermCell: Equatable {
    var character: Character = " "
    var style = TermStyle()
    /// The right half of a double-width character. Rendered as nothing.
    var isContinuation = false
}

// MARK: - Emulator

/// The terminal's model: a grid of styled cells, a scrollback, and a parser for the escape
/// sequences real programs emit. Pure Foundation — no AppKit — so `--audit` drives it
/// headlessly, byte for byte.
///
/// Scope, stated honestly: this is not a complete VT520. It implements the xterm subset that
/// shells, compilers, git, less and vim actually use — cursor addressing, scroll regions, the
/// alternate screen, deferred autowrap, BCE erase, 16/256/24-bit colour, DEC special graphics,
/// tab stops, and the DA/DSR/window-size reports programs block on. Sequences outside that set
/// are consumed and dropped rather than printed as garbage. There is no mouse reporting and no
/// line reflow on resize.
final class TerminalEmulator {

    // MARK: Geometry and content

    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var screen: [[TermCell]]
    private(set) var scrollback: [[TermCell]] = []
    let scrollbackLimit: Int

    /// 0-based, always within the grid. The VT100 keeps the cursor in the last column after
    /// printing there and only wraps when the *next* character arrives; `pendingWrap` is that.
    private(set) var cursorRow = 0
    private(set) var cursorCol = 0
    private var pendingWrap = false

    // MARK: Modes

    private(set) var cursorVisible = true
    private(set) var usingAlternateScreen = false
    private(set) var applicationCursorKeys = false
    private(set) var bracketedPaste = false
    private(set) var mouseModes: Set<Int> = []
    private(set) var title = ""
    private var autowrap = true
    private var originMode = false
    private var insertMode = false

    // MARK: Scroll region (0-based, inclusive)

    private(set) var regionTop = 0
    private(set) var regionBottom: Int

    // MARK: Style and charset

    private var style = TermStyle()
    private var tabStops: Set<Int>
    /// G0/G1 charsets: true = DEC special graphics. SO/SI switch between them.
    private var charsetGraphics = [false, false]
    private var activeCharset = 0

    private struct SavedCursor {
        var row = 0, col = 0
        var style = TermStyle()
        var charsetGraphics = [false, false]
        var activeCharset = 0
        var originMode = false
    }
    private var savedCursor = SavedCursor()
    private var savedMainScreen: [[TermCell]]?
    private var savedMainCursor = SavedCursor()

    // MARK: Hooks

    /// Bytes the terminal answers with (cursor position reports, device attributes). The owner
    /// writes them back to the PTY.
    var onOutput: ((Data) -> Void)?
    var onBell: (() -> Void)?
    var onTitleChange: ((String) -> Void)?
    /// Bumped once per `feed`, so a renderer knows when to repaint without diffing the grid.
    private(set) var generation = 0

    // MARK: Parser state

    private enum ParseState {
        case ground
        case escape
        case escapeIntermediate(Character)   // ESC ( ) * + #
        case csi
        case osc
        case string                          // DCS / APC / PM / SOS, consumed to ST
    }
    private var state = ParseState.ground
    private var csiPrefix = ""
    private var csiParams = ""
    private var csiIntermediate = ""
    private var oscBuffer = ""
    private var oscSawEscape = false
    private var utf8Pending: [UInt8] = []
    private var utf8Needed = 0

    // MARK: Init

    init(cols: Int = 80, rows: Int = 24, scrollbackLimit: Int = 10_000) {
        self.cols = max(2, cols)
        self.rows = max(2, rows)
        self.scrollbackLimit = scrollbackLimit
        self.regionBottom = self.rows - 1
        self.screen = Array(repeating: Array(repeating: TermCell(), count: self.cols),
                            count: self.rows)
        self.tabStops = Set(stride(from: 8, to: self.cols, by: 8))
    }

    // MARK: Reading the grid

    /// Scrollback rows first, then the live screen — what a scrolling view renders.
    var displayRowCount: Int { scrollback.count + rows }

    func displayRow(_ index: Int) -> [TermCell] {
        if index < scrollback.count { return scrollback[index] }
        let row = index - scrollback.count
        return row < rows ? screen[row] : []
    }

    var cursorDisplayRow: Int { scrollback.count + cursorRow }

    /// One live-screen row as text, trailing blanks trimmed. For tests and copy.
    func text(row: Int) -> String {
        guard row >= 0, row < rows else { return "" }
        return Self.text(of: screen[row])
    }

    static func text(of cells: [TermCell]) -> String {
        var result = ""
        for cell in cells where !cell.isContinuation { result.append(cell.character) }
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    func screenText() -> String {
        (0..<rows).map { text(row: $0) }.joined(separator: "\n")
    }

    func cell(row: Int, col: Int) -> TermCell {
        guard row >= 0, row < rows, col >= 0, col < cols else { return TermCell() }
        return screen[row][col]
    }

    // MARK: Feeding

    func feed(_ text: String) { feed(Data(text.utf8)) }

    func feed(_ data: Data) {
        for byte in data { process(byte) }
        generation += 1
    }

    private func process(_ byte: UInt8) {
        switch state {
        case .ground: processGround(byte)
        case .escape: processEscape(byte)
        case .escapeIntermediate(let kind): processEscapeIntermediate(kind, byte)
        case .csi: processCSI(byte)
        case .osc: processOSC(byte)
        case .string: processStringBody(byte)
        }
    }

    // MARK: Ground state

    private func processGround(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            flushPendingUTF8()
            state = .escape
        case 0x07: onBell?()
        case 0x08: // BS
            flushPendingUTF8()
            pendingWrap = false
            cursorCol = max(0, cursorCol - 1)
        case 0x09: // TAB
            flushPendingUTF8()
            pendingWrap = false
            cursorCol = nextTabStop(after: cursorCol)
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            flushPendingUTF8()
            lineFeed()
        case 0x0D: // CR
            flushPendingUTF8()
            pendingWrap = false
            cursorCol = 0
        case 0x0E: activeCharset = 1 // SO
        case 0x0F: activeCharset = 0 // SI
        case 0x00...0x1F, 0x7F:
            break // remaining C0 controls and DEL are ignored on output
        default:
            decodeUTF8(byte)
        }
    }

    // MARK: UTF-8

    private func decodeUTF8(_ byte: UInt8) {
        if utf8Needed == 0 {
            switch byte {
            case 0x00...0x7F:
                printScalar(Unicode.Scalar(byte))
            case 0xC2...0xDF: utf8Pending = [byte]; utf8Needed = 1
            case 0xE0...0xEF: utf8Pending = [byte]; utf8Needed = 2
            case 0xF0...0xF4: utf8Pending = [byte]; utf8Needed = 3
            default:
                printScalar("\u{FFFD}")
            }
            return
        }
        guard byte & 0xC0 == 0x80 else {
            // The sequence broke off; show that something was there, then reprocess.
            flushPendingUTF8()
            process(byte)
            return
        }
        utf8Pending.append(byte)
        if utf8Pending.count == utf8Needed + 1 {
            let decoded = String(bytes: utf8Pending, encoding: .utf8)
            utf8Pending = []
            utf8Needed = 0
            for scalar in (decoded ?? "\u{FFFD}").unicodeScalars { printScalar(scalar) }
        }
    }

    private func flushPendingUTF8() {
        guard !utf8Pending.isEmpty else { return }
        utf8Pending = []
        utf8Needed = 0
        printScalar("\u{FFFD}")
    }

    // MARK: Printing

    private func printScalar(_ scalar: Unicode.Scalar) {
        var scalar = scalar
        if charsetGraphics[activeCharset], let mapped = Self.decGraphics[scalar] {
            scalar = mapped
        }
        let width = Self.width(of: scalar)
        if width == 0 {
            // A combining mark attaches to the character before the cursor.
            let col = max(0, cursorCol - (pendingWrap ? 0 : 1))
            if screen[cursorRow][col].character != " " || col == cursorCol {
                var cell = screen[cursorRow][col]
                cell.character = Character(String(cell.character) + String(scalar))
                screen[cursorRow][col] = cell
            }
            return
        }
        if pendingWrap && autowrap { wrapToNextLine() }
        if width == 2 && cursorCol == cols - 1 {
            if autowrap { wrapToNextLine() } else { return }
        }

        if insertMode {
            let shift = min(width, cols - cursorCol)
            screen[cursorRow].removeSubrange((cols - shift)..<cols)
            for _ in 0..<shift {
                screen[cursorRow].insert(blankCell(), at: cursorCol)
            }
        }

        screen[cursorRow][cursorCol] = TermCell(character: Character(scalar), style: style)
        if width == 2 {
            screen[cursorRow][cursorCol + 1] = TermCell(character: " ", style: style,
                                                        isContinuation: true)
        }
        let next = cursorCol + width
        if next >= cols {
            cursorCol = cols - 1
            pendingWrap = autowrap
        } else {
            cursorCol = next
            pendingWrap = false
        }
    }

    private func wrapToNextLine() {
        pendingWrap = false
        cursorCol = 0
        lineFeed()
    }

    private func lineFeed() {
        pendingWrap = false
        if cursorRow == regionBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func reverseLineFeed() {
        pendingWrap = false
        if cursorRow == regionTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    // MARK: Scrolling

    /// Erased and scrolled-in cells keep the current background ("back colour erase") because
    /// TERM=xterm-256color declares bce and full-screen programs rely on it.
    private func blankCell() -> TermCell {
        TermCell(character: " ", style: TermStyle(foreground: .default,
                                                  background: style.background))
    }

    private func blankRow() -> [TermCell] {
        Array(repeating: blankCell(), count: cols)
    }

    private func scrollUp(_ count: Int) {
        for _ in 0..<max(0, count) {
            let removed = screen[regionTop]
            if regionTop == 0 && regionBottom == rows - 1 && !usingAlternateScreen {
                pushScrollback(removed)
            }
            screen.remove(at: regionTop)
            screen.insert(blankRow(), at: regionBottom)
        }
    }

    private func scrollDown(_ count: Int) {
        for _ in 0..<max(0, count) {
            screen.remove(at: regionBottom)
            screen.insert(blankRow(), at: regionTop)
        }
    }

    private func pushScrollback(_ row: [TermCell]) {
        scrollback.append(row)
        if scrollback.count > scrollbackLimit {
            scrollback.removeFirst(scrollback.count - scrollbackLimit)
        }
    }

    // MARK: Escape state

    private func processEscape(_ byte: UInt8) {
        state = .ground
        switch Character(Unicode.Scalar(byte)) {
        case "[":
            csiPrefix = ""; csiParams = ""; csiIntermediate = ""
            state = .csi
        case "]":
            oscBuffer = ""; oscSawEscape = false
            state = .osc
        case "P", "_", "^", "X":
            state = .string
        case "(", ")", "*", "+", "#":
            state = .escapeIntermediate(Character(Unicode.Scalar(byte)))
        case "7": saveCursor()
        case "8": restoreCursor()
        case "D": lineFeed()
        case "M": reverseLineFeed()
        case "E": lineFeed(); cursorCol = 0
        case "H": tabStops.insert(cursorCol)
        case "c": hardReset()
        case "=", ">", "\\":
            break // keypad modes and a stray ST
        default:
            break
        }
    }

    private func processEscapeIntermediate(_ kind: Character, _ byte: UInt8) {
        state = .ground
        let selector = Character(Unicode.Scalar(byte))
        switch kind {
        case "(": charsetGraphics[0] = (selector == "0")
        case ")": charsetGraphics[1] = (selector == "0")
        case "#" where selector == "8": // DECALN
            screen = Array(repeating: Array(repeating: TermCell(character: "E"), count: cols),
                           count: rows)
            setCursor(row: 0, col: 0)
        default:
            break
        }
    }

    // MARK: CSI state

    private func processCSI(_ byte: UInt8) {
        switch byte {
        case 0x30...0x3B: // digits, ; :
            csiParams.append(Character(Unicode.Scalar(byte)))
        case 0x3C...0x3F: // ? > = <
            if csiParams.isEmpty && csiIntermediate.isEmpty {
                csiPrefix.append(Character(Unicode.Scalar(byte)))
            }
        case 0x20...0x2F:
            csiIntermediate.append(Character(Unicode.Scalar(byte)))
        case 0x40...0x7E:
            state = .ground
            dispatchCSI(Character(Unicode.Scalar(byte)))
        case 0x1B:
            state = .escape
        case 0x18, 0x1A: // CAN, SUB
            state = .ground
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            processGround(byte) // C0 controls execute inside a sequence
        default:
            state = .ground
        }
        if csiParams.count > 256 { state = .ground } // a runaway sequence is dropped
    }

    /// Parameters split on `;`, sub-parameters on `:` — `38;5;196` and `38:5:196` both arrive.
    private var parameterGroups: [[Int]] {
        guard !csiParams.isEmpty else { return [] }
        return csiParams.components(separatedBy: ";").map { group in
            group.components(separatedBy: ":").map { Int($0) ?? 0 }
        }
    }

    private func parameter(_ index: Int, default fallback: Int) -> Int {
        let groups = parameterGroups
        guard index < groups.count, let first = groups[index].first, first != 0 else {
            return fallback
        }
        return first
    }

    private func dispatchCSI(_ final: Character) {
        let n = max(1, parameter(0, default: 1))
        switch final {
        case "A": moveCursor(rowDelta: -n)
        case "B", "e": moveCursor(rowDelta: n)
        case "C", "a": setCursor(row: cursorRow, col: cursorCol + n)
        case "D": setCursor(row: cursorRow, col: cursorCol - n)
        case "E": moveCursor(rowDelta: n); cursorCol = 0
        case "F": moveCursor(rowDelta: -n); cursorCol = 0
        case "G", "`": setCursor(row: cursorRow, col: n - 1)
        case "d": setCursorAbsolute(row: n - 1, col: cursorCol)
        case "H", "f":
            setCursorAbsolute(row: parameter(0, default: 1) - 1,
                              col: parameter(1, default: 1) - 1)
        case "I":
            for _ in 0..<n { cursorCol = nextTabStop(after: cursorCol) }
        case "Z":
            for _ in 0..<n { cursorCol = previousTabStop(before: cursorCol) }
        case "J": eraseDisplay(parameter(0, default: 0))
        case "K": eraseLine(parameter(0, default: 0))
        case "L": insertLines(n)
        case "M": deleteLines(n)
        case "P": deleteCharacters(n)
        case "@": insertCharacters(n)
        case "X": eraseCharacters(n)
        case "S": scrollUp(n)
        case "T":
            if parameterGroups.count <= 1 { scrollDown(n) } // multi-param T is mouse tracking
        case "r":
            guard csiPrefix.isEmpty else { break }
            setScrollRegion(top: parameter(0, default: 1) - 1,
                            bottom: parameter(1, default: rows) - 1)
        case "m": selectGraphicRendition()
        case "h": setModes(true)
        case "l": setModes(false)
        case "c":
            if csiPrefix.isEmpty { respond("\u{1B}[?1;2c") }        // VT100 with AVO
            else if csiPrefix == ">" { respond("\u{1B}[>0;0;0c") }  // secondary DA: unnamed
        case "n":
            switch parameter(0, default: 0) {
            case 5: respond("\u{1B}[0n")
            case 6:
                let row = originMode ? cursorRow - regionTop : cursorRow
                respond("\u{1B}[\(row + 1);\(cursorCol + 1)R")
            default: break
            }
        case "s": saveCursor()
        case "u": restoreCursor()
        case "g":
            switch parameter(0, default: 0) {
            case 0: tabStops.remove(cursorCol)
            case 3: tabStops.removeAll()
            default: break
            }
        case "t":
            if parameter(0, default: 0) == 18 { respond("\u{1B}[8;\(rows);\(cols)t") }
        case "q":
            break // cursor style — accepted, not rendered differently
        default:
            break
        }
    }

    private func respond(_ text: String) {
        onOutput?(Data(text.utf8))
    }

    // MARK: Cursor

    private func setCursor(row: Int, col: Int) {
        pendingWrap = false
        cursorRow = min(max(0, row), rows - 1)
        cursorCol = min(max(0, col), cols - 1)
    }

    /// CUP/VPA honour origin mode: rows are then relative to the scroll region.
    private func setCursorAbsolute(row: Int, col: Int) {
        if originMode {
            setCursor(row: min(regionTop + max(0, row), regionBottom), col: col)
        } else {
            setCursor(row: row, col: col)
        }
    }

    /// Relative movement stops at the scroll region edge when the cursor starts inside it.
    private func moveCursor(rowDelta: Int) {
        pendingWrap = false
        let top = cursorRow >= regionTop ? regionTop : 0
        let bottom = cursorRow <= regionBottom ? regionBottom : rows - 1
        cursorRow = min(max(top, cursorRow + rowDelta), bottom)
    }

    private func saveCursor() {
        savedCursor = SavedCursor(row: cursorRow, col: cursorCol, style: style,
                                  charsetGraphics: charsetGraphics,
                                  activeCharset: activeCharset, originMode: originMode)
    }

    private func restoreCursor() {
        style = savedCursor.style
        charsetGraphics = savedCursor.charsetGraphics
        activeCharset = savedCursor.activeCharset
        originMode = savedCursor.originMode
        setCursor(row: savedCursor.row, col: savedCursor.col)
    }

    // MARK: Tabs

    private func nextTabStop(after col: Int) -> Int {
        let next = tabStops.filter { $0 > col }.min() ?? (cols - 1)
        return min(next, cols - 1)
    }

    private func previousTabStop(before col: Int) -> Int {
        tabStops.filter { $0 < col }.max() ?? 0
    }

    // MARK: Erase and edit

    private func eraseDisplay(_ mode: Int) {
        pendingWrap = false
        switch mode {
        case 0:
            eraseLine(0)
            for row in (cursorRow + 1)..<rows { screen[row] = blankRow() }
        case 1:
            eraseLine(1)
            for row in 0..<cursorRow { screen[row] = blankRow() }
        case 2:
            for row in 0..<rows { screen[row] = blankRow() }
        case 3:
            scrollback.removeAll()
        default:
            break
        }
    }

    private func eraseLine(_ mode: Int) {
        pendingWrap = false
        switch mode {
        case 0:
            for col in cursorCol..<cols { screen[cursorRow][col] = blankCell() }
        case 1:
            for col in 0...min(cursorCol, cols - 1) { screen[cursorRow][col] = blankCell() }
        case 2:
            screen[cursorRow] = blankRow()
        default:
            break
        }
    }

    private func insertLines(_ count: Int) {
        guard cursorRow >= regionTop, cursorRow <= regionBottom else { return }
        pendingWrap = false
        for _ in 0..<min(count, regionBottom - cursorRow + 1) {
            screen.remove(at: regionBottom)
            screen.insert(blankRow(), at: cursorRow)
        }
        cursorCol = 0
    }

    private func deleteLines(_ count: Int) {
        guard cursorRow >= regionTop, cursorRow <= regionBottom else { return }
        pendingWrap = false
        for _ in 0..<min(count, regionBottom - cursorRow + 1) {
            screen.remove(at: cursorRow)
            screen.insert(blankRow(), at: regionBottom)
        }
        cursorCol = 0
    }

    private func insertCharacters(_ count: Int) {
        pendingWrap = false
        let shift = min(count, cols - cursorCol)
        screen[cursorRow].removeSubrange((cols - shift)..<cols)
        for _ in 0..<shift { screen[cursorRow].insert(blankCell(), at: cursorCol) }
    }

    private func deleteCharacters(_ count: Int) {
        pendingWrap = false
        let removed = min(count, cols - cursorCol)
        screen[cursorRow].removeSubrange(cursorCol..<(cursorCol + removed))
        for _ in 0..<removed { screen[cursorRow].append(blankCell()) }
    }

    private func eraseCharacters(_ count: Int) {
        pendingWrap = false
        for col in cursorCol..<min(cols, cursorCol + count) {
            screen[cursorRow][col] = blankCell()
        }
    }

    // MARK: Scroll region

    private func setScrollRegion(top: Int, bottom: Int) {
        let newTop = min(max(0, top), rows - 1)
        let newBottom = min(max(0, bottom), rows - 1)
        guard newTop < newBottom else { return }
        regionTop = newTop
        regionBottom = newBottom
        setCursorAbsolute(row: 0, col: 0)
    }

    // MARK: SGR

    private func selectGraphicRendition() {
        let groups = parameterGroups.isEmpty ? [[0]] : parameterGroups
        var index = 0
        while index < groups.count {
            let group = groups[index]
            let code = group.first ?? 0
            switch code {
            case 0: style = TermStyle()
            case 1: style.attributes.insert(.bold)
            case 2: style.attributes.insert(.dim)
            case 3: style.attributes.insert(.italic)
            case 4:
                // 4:0 turns underline off; every other sub-style is drawn as an underline.
                if group.count > 1 && group[1] == 0 { style.attributes.remove(.underline) }
                else { style.attributes.insert(.underline) }
            case 7: style.attributes.insert(.reverse)
            case 8: style.attributes.insert(.hidden)
            case 9: style.attributes.insert(.strikethrough)
            case 21: style.attributes.insert(.underline)
            case 22: style.attributes.subtract([.bold, .dim])
            case 23: style.attributes.remove(.italic)
            case 24: style.attributes.remove(.underline)
            case 27: style.attributes.remove(.reverse)
            case 28: style.attributes.remove(.hidden)
            case 29: style.attributes.remove(.strikethrough)
            case 30...37: style.foreground = .indexed(code - 30)
            case 39: style.foreground = .default
            case 40...47: style.background = .indexed(code - 40)
            case 49: style.background = .default
            case 90...97: style.foreground = .indexed(code - 90 + 8)
            case 100...107: style.background = .indexed(code - 100 + 8)
            case 38, 48:
                var colour: TermColor?
                var consumed = 0
                if group.count >= 3 && group[1] == 5 {
                    colour = .indexed(min(255, max(0, group[2])))
                } else if group.count >= 5 && group[1] == 2 {
                    // 38:2:r:g:b, or 38:2:colourspace:r:g:b — take the last three.
                    let rgb = group.suffix(3).map { UInt8(min(255, max(0, $0))) }
                    colour = .rgb(rgb[0], rgb[1], rgb[2])
                } else if group.count == 1 {
                    // Semicolon form: 38;5;n or 38;2;r;g;b spread across groups.
                    let flat = groups[(index + 1)...].compactMap(\.first)
                    if flat.count >= 2 && flat[0] == 5 {
                        colour = .indexed(min(255, max(0, flat[1])))
                        consumed = 2
                    } else if flat.count >= 4 && flat[0] == 2 {
                        colour = .rgb(UInt8(min(255, max(0, flat[1]))),
                                      UInt8(min(255, max(0, flat[2]))),
                                      UInt8(min(255, max(0, flat[3]))))
                        consumed = 4
                    }
                }
                if let colour {
                    if code == 38 { style.foreground = colour } else { style.background = colour }
                }
                index += consumed
            case 5, 25:
                break // blink — accepted, not rendered
            default:
                break
            }
            index += 1
        }
    }

    // MARK: Modes

    private func setModes(_ on: Bool) {
        for group in parameterGroups {
            guard let mode = group.first else { continue }
            if csiPrefix == "?" {
                setPrivateMode(mode, on)
            } else if mode == 4 {
                insertMode = on
            }
        }
    }

    private func setPrivateMode(_ mode: Int, _ on: Bool) {
        switch mode {
        case 1: applicationCursorKeys = on
        case 6:
            originMode = on
            setCursorAbsolute(row: 0, col: 0)
        case 7: autowrap = on
        case 25: cursorVisible = on
        case 47: on ? enterAlternateScreen(clear: false, saveCursor: false)
                    : exitAlternateScreen(restoreCursor: false)
        case 1047: on ? enterAlternateScreen(clear: true, saveCursor: false)
                      : exitAlternateScreen(restoreCursor: false)
        case 1048: on ? saveCursor() : restoreCursor()
        case 1049: on ? enterAlternateScreen(clear: true, saveCursor: true)
                      : exitAlternateScreen(restoreCursor: true)
        case 1000, 1002, 1003, 1005, 1006, 1015:
            if on { mouseModes.insert(mode) } else { mouseModes.remove(mode) }
        case 2004: bracketedPaste = on
        default:
            break
        }
    }

    // MARK: Alternate screen

    private func enterAlternateScreen(clear: Bool, saveCursor shouldSave: Bool) {
        guard !usingAlternateScreen else { return }
        if shouldSave {
            savedMainCursor = SavedCursor(row: cursorRow, col: cursorCol, style: style,
                                          charsetGraphics: charsetGraphics,
                                          activeCharset: activeCharset, originMode: originMode)
        }
        savedMainScreen = screen
        usingAlternateScreen = true
        if clear {
            screen = Array(repeating: blankRow(), count: rows)
            setCursor(row: 0, col: 0)
        }
    }

    private func exitAlternateScreen(restoreCursor shouldRestore: Bool) {
        guard usingAlternateScreen else { return }
        usingAlternateScreen = false
        if var main = savedMainScreen {
            // The window may have been resized while the alternate screen was active.
            main = Self.fit(main, cols: cols, rows: rows)
            screen = main
        }
        savedMainScreen = nil
        if shouldRestore {
            style = savedMainCursor.style
            charsetGraphics = savedMainCursor.charsetGraphics
            activeCharset = savedMainCursor.activeCharset
            originMode = savedMainCursor.originMode
            setCursor(row: savedMainCursor.row, col: savedMainCursor.col)
        }
    }

    // MARK: OSC

    private func processOSC(_ byte: UInt8) {
        if oscSawEscape {
            oscSawEscape = false
            state = .ground
            finishOSC()
            if byte != UInt8(ascii: "\\") { state = .escape; processEscape(byte) }
            return
        }
        switch byte {
        case 0x07:
            state = .ground
            finishOSC()
        case 0x1B:
            oscSawEscape = true
        default:
            if oscBuffer.utf8.count < 4096 {
                oscBuffer.append(Character(Unicode.Scalar(byte)))
            }
        }
    }

    private func finishOSC() {
        let parts = oscBuffer.split(separator: ";", maxSplits: 1)
        if parts.count == 2, parts[0] == "0" || parts[0] == "2" {
            title = String(parts[1])
            onTitleChange?(title)
        }
        oscBuffer = ""
    }

    private func processStringBody(_ byte: UInt8) {
        if oscSawEscape {
            oscSawEscape = false
            if byte == UInt8(ascii: "\\") { state = .ground }
            return
        }
        if byte == 0x1B { oscSawEscape = true }
        if byte == 0x07 { state = .ground }
    }

    // MARK: Reset and resize

    private func hardReset() {
        screen = Array(repeating: Array(repeating: TermCell(), count: cols), count: rows)
        cursorRow = 0; cursorCol = 0; pendingWrap = false
        style = TermStyle()
        savedCursor = SavedCursor()
        regionTop = 0; regionBottom = rows - 1
        tabStops = Set(stride(from: 8, to: cols, by: 8))
        charsetGraphics = [false, false]; activeCharset = 0
        cursorVisible = true
        autowrap = true; originMode = false; insertMode = false
        applicationCursorKeys = false; bracketedPaste = false
        mouseModes.removeAll()
        if usingAlternateScreen { usingAlternateScreen = false; savedMainScreen = nil }
    }

    private static func fit(_ grid: [[TermCell]], cols: Int, rows: Int) -> [[TermCell]] {
        var grid = grid
        for index in grid.indices {
            if grid[index].count > cols {
                grid[index].removeSubrange(cols...)
            } else if grid[index].count < cols {
                grid[index].append(contentsOf: Array(repeating: TermCell(),
                                                     count: cols - grid[index].count))
            }
        }
        while grid.count > rows { grid.removeLast() }
        while grid.count < rows { grid.append(Array(repeating: TermCell(), count: cols)) }
        return grid
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(2, newCols), newRows = max(2, newRows)
        guard newCols != cols || newRows != rows else { return }

        // Keep the cursor's line: rows pushed off the top go to scrollback, not the bin.
        while cursorRow >= newRows {
            let top = screen.removeFirst()
            if !usingAlternateScreen { pushScrollback(top) }
            cursorRow -= 1
        }
        cols = newCols
        rows = newRows
        screen = Self.fit(screen, cols: cols, rows: rows)
        if let main = savedMainScreen { savedMainScreen = Self.fit(main, cols: cols, rows: rows) }
        for index in scrollback.indices where scrollback[index].count > cols {
            scrollback[index].removeSubrange(cols...)
        }

        regionTop = 0
        regionBottom = rows - 1
        cursorRow = min(cursorRow, rows - 1)
        cursorCol = min(cursorCol, cols - 1)
        pendingWrap = false
        tabStops = Set(stride(from: 8, to: cols, by: 8))
        generation += 1
    }

    // MARK: Width and charsets

    /// A wcwidth good enough for terminal output: CJK, Hangul, and emoji are two columns,
    /// combining marks are zero, everything else is one.
    static func width(of scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x0300...0x036F, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x20D0...0x20FF,
             0xFE00...0xFE0F, 0xFE20...0xFE2F:
            return 0
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1FAFF,
             0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// ESC ( 0 line drawing — what ncurses uses for window borders.
    static let decGraphics: [Unicode.Scalar: Unicode.Scalar] = [
        "`": "◆", "a": "▒", "f": "°", "g": "±", "j": "┘", "k": "┐", "l": "┌", "m": "└",
        "n": "┼", "o": "⎺", "p": "⎻", "q": "─", "r": "⎼", "s": "⎽", "t": "├", "u": "┤",
        "v": "┴", "w": "┬", "x": "│", "y": "≤", "z": "≥", "{": "π", "|": "≠", "}": "£",
        "~": "·",
    ]
}

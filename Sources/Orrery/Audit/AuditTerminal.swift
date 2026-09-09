import Foundation
import AppKit

/// The terminal, in three layers. The emulator checks feed bytes and read the grid — every
/// escape sequence class the pane claims to handle is asserted here. The PTY checks spawn real
/// processes and prove the terminal is a terminal: `tty` names a pty device, `stty` sees the
/// window size, colours and exit statuses arrive end to end. The rendering check draws the
/// real grid view and looks at the pixels, because that is the only place "it renders blank"
/// shows up.
@MainActor
enum AuditTerminal {

    static func run(_ audit: Auditor) async {
        emulatorChecks(audit)
        await ptyChecks(audit)
        renderingChecks(audit)
    }

    // MARK: - Rendering

    private static func renderingChecks(_ audit: Auditor) {
        let originalFontSize = EditorTheme.fontSize
        EditorTheme.fontSize = 30           // solid glyph interiors; see AuditRendering
        defer { EditorTheme.fontSize = originalFontSize }

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { continue }
            audit.section("Terminal — pixels on screen (\(name.rawValue))")

            let session = TerminalSession(directory: URL(fileURLWithPath: NSHomeDirectory()),
                                          cols: 40, rows: 8)
            session.emulator.feed("plain \u{1B}[31mREDRED\u{1B}[0m\r\n"
                                  + "\u{1B}[42m  green back  \u{1B}[0m")

            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
            let grid = TerminalGridView(session: session)
            scrollView.documentView = grid
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = appearance
            window.colorSpace = .sRGB
            window.contentView = scrollView
            grid.fitToClipView()
            window.layoutIfNeeded()

            let counts = AuditRendering.histogram(scrollView, scrollView.bounds)
            let tally = AuditRendering.classify(counts, [
                ("background", TerminalPalette.defaultBackground),
                ("plain", TerminalPalette.defaultForeground),
                ("red", TerminalPalette.indexed(1)),
                ("greenBack", TerminalPalette.indexed(2)),
            ], in: appearance)
            func visible(_ label: String, atLeast minimum: Int) {
                audit.check("terminal \(label) pixels are on screen",
                            (tally[label] ?? 0) >= minimum,
                            "\(tally[label] ?? 0) px — "
                            + tally.map { "\($0.key):\($0.value)" }.joined(separator: " "))
            }
            visible("plain", atLeast: 200)
            visible("red", atLeast: 100)
            visible("greenBack", atLeast: 400)
            audit.check("the terminal background fills the pane",
                        (tally["background"] ?? 0) > 100_000,
                        "\(tally["background"] ?? 0) px")
            window.contentView = nil
        }
    }

    // MARK: - Emulator

    private static func emulatorChecks(_ audit: Auditor) {
        audit.section("Terminal — text, cursor, wrap")
        var term = TerminalEmulator(cols: 10, rows: 4)
        term.feed("hello")
        audit.equal("plain text lands in the grid", term.text(row: 0), "hello")
        audit.equal("cursor advanced", term.cursorCol, 5)
        term.feed("\r\nworld")
        audit.equal("CR LF starts the next line", term.text(row: 1), "world")

        // Deferred wrap: printing into the last column must not wrap until the next character.
        term = TerminalEmulator(cols: 10, rows: 4)
        term.feed("0123456789")
        audit.equal("a full line stays on one row", term.text(row: 0), "0123456789")
        audit.equal("cursor holds at the last column", term.cursorRow, 0)
        term.feed("\r\nnext")
        audit.equal("newline after a full line moves one row, not two", term.text(row: 1), "next")
        term = TerminalEmulator(cols: 10, rows: 4)
        term.feed("0123456789X")
        audit.equal("the eleventh character wraps", term.text(row: 1), "X")

        term = TerminalEmulator(cols: 20, rows: 6)
        term.feed("\u{1B}[3;5Hmark")
        audit.equal("CUP addresses row 3 col 5", term.text(row: 2), "    mark")
        term.feed("\u{1B}[2;1Hab\u{8}X")
        audit.equal("backspace then overwrite", term.text(row: 1), "aX")

        audit.section("Terminal — colours and attributes")
        term = TerminalEmulator(cols: 40, rows: 4)
        term.feed("\u{1B}[31mr\u{1B}[92mg\u{1B}[38;5;196mp\u{1B}[38;2;1;2;3mt\u{1B}[0mn")
        audit.equal("SGR 31 is ANSI red", term.cell(row: 0, col: 0).style.foreground, .indexed(1))
        audit.equal("SGR 92 is bright green", term.cell(row: 0, col: 1).style.foreground,
                    .indexed(10))
        audit.equal("38;5;196 is palette 196", term.cell(row: 0, col: 2).style.foreground,
                    .indexed(196))
        audit.equal("38;2;… is truecolor", term.cell(row: 0, col: 3).style.foreground,
                    .rgb(1, 2, 3))
        audit.equal("SGR 0 resets", term.cell(row: 0, col: 4).style.foreground, .default)
        term.feed("\u{1B}[1;4;7mZ")
        let attributes = term.cell(row: 0, col: 5).style.attributes
        audit.check("bold, underline and reverse all recorded",
                    attributes.contains([.bold, .underline, .reverse]), "\(attributes)")
        term.feed("\u{1B}[m\u{1B}[38:5:33mc")
        audit.equal("colon-form SGR is accepted", term.cell(row: 0, col: 6).style.foreground,
                    .indexed(33))
        term.feed("\u{1B}[41m\u{1B}[2KQ")
        audit.equal("erase uses the current background (BCE)",
                    term.cell(row: 0, col: 20).style.background, .indexed(1))

        audit.section("Terminal — erase, insert, delete")
        term = TerminalEmulator(cols: 10, rows: 4)
        term.feed("aaaa\r\nbbbb\r\ncccc\u{1B}[2;2H\u{1B}[0J")
        audit.equal("ED 0 keeps text before the cursor", term.text(row: 1), "b")
        audit.equal("ED 0 clears below", term.text(row: 2), "")
        audit.equal("ED 0 keeps the row above", term.text(row: 0), "aaaa")
        term.feed("\u{1B}[2J")
        audit.equal("ED 2 clears everything", term.screenText(), "\n\n\n")
        term = TerminalEmulator(cols: 10, rows: 2)
        term.feed("abcdef\u{1B}[1;3H\u{1B}[K")
        audit.equal("EL 0 erases to the end", term.text(row: 0), "ab")
        term.feed("\r\nabcdef\u{1B}[2;3H\u{1B}[1K")
        audit.equal("EL 1 erases to the cursor", term.text(row: 1), "   def")
        term = TerminalEmulator(cols: 10, rows: 2)
        term.feed("abcdef\u{1B}[1;2H\u{1B}[2@")
        audit.equal("ICH shifts right", term.text(row: 0), "a  bcdef")
        term.feed("\u{1B}[1;2H\u{1B}[2P")
        audit.equal("DCH shifts left", term.text(row: 0), "abcdef")
        term.feed("\u{1B}[1;2H\u{1B}[2X")
        audit.equal("ECH blanks in place", term.text(row: 0), "a  def")

        audit.section("Terminal — scrolling, regions, scrollback")
        term = TerminalEmulator(cols: 10, rows: 5)
        term.feed("one\r\ntwo\r\nthree\r\nfour\r\nfive")
        term.feed("\u{1B}[2;4r")                       // region rows 2–4
        term.feed("\u{1B}[4;1H\n")                     // LF at region bottom scrolls the region
        audit.equal("region scroll moves row 3 up", term.text(row: 1), "three")
        audit.equal("region bottom is cleared", term.text(row: 3), "")
        audit.equal("outside the region is untouched", term.text(row: 0) + "/" + term.text(row: 4),
                    "one/five")
        term.feed("\u{1B}[2;1H\u{1B}M")                // RI at region top scrolls down
        audit.equal("reverse index inserts at the top", term.text(row: 1), "")
        audit.equal("…pushing the region down", term.text(row: 2), "three")

        term = TerminalEmulator(cols: 10, rows: 3)
        for index in 1...5 { term.feed("line\(index)\r\n") }
        audit.equal("scrolled-off rows land in scrollback",
                    TerminalEmulator.text(of: term.displayRow(0)), "line1")
        audit.equal("scrollback preserves order",
                    TerminalEmulator.text(of: term.displayRow(1)), "line2")
        audit.equal("the screen keeps the tail", term.text(row: 0), "line4")
        audit.check("display rows = scrollback + screen",
                    term.displayRowCount == term.scrollback.count + 3,
                    "\(term.displayRowCount)")

        term = TerminalEmulator(cols: 10, rows: 3)
        term.feed("abc\r\ndef\u{1B}[1;2H\u{1B}[L")
        audit.equal("IL pushes lines down", term.text(row: 1), "abc")
        term.feed("\u{1B}[M")
        audit.equal("DL pulls them back", term.text(row: 0) + term.text(row: 1), "abcdef")

        audit.section("Terminal — alternate screen and reports")
        term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("main content")
        term.feed("\u{1B}[?1049h")
        audit.equal("the alternate screen starts blank", term.screenText(), "\n\n\n")
        audit.check("alternate flag set", term.usingAlternateScreen)
        term.feed("vim would draw here")
        term.feed("\u{1B}[?1049l")
        audit.equal("leaving restores the main screen", term.text(row: 0), "main content")
        audit.equal("…and the cursor", term.cursorCol, 12)
        audit.check("alternate flag cleared", !term.usingAlternateScreen)
        var altScrollbackBefore = 0
        term = TerminalEmulator(cols: 10, rows: 3)
        term.feed("\u{1B}[?1049h")
        altScrollbackBefore = term.scrollback.count
        for index in 1...6 { term.feed("alt\(index)\r\n") }
        audit.equal("the alternate screen never writes scrollback",
                    term.scrollback.count, altScrollbackBefore)

        var replies: [String] = []
        term = TerminalEmulator(cols: 30, rows: 10)
        term.onOutput = { replies.append(String(decoding: $0, as: UTF8.self)) }
        term.feed("\u{1B}[4;7H\u{1B}[6n")
        audit.equal("DSR 6n reports the cursor", replies.last, "\u{1B}[4;7R")
        term.feed("\u{1B}[c")
        audit.equal("DA identifies a VT100", replies.last, "\u{1B}[?1;2c")
        term.feed("\u{1B}[18t")
        audit.equal("window size report", replies.last, "\u{1B}[8;10;30t")

        audit.section("Terminal — modes, tabs, charsets, unicode")
        term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("\u{1B}[?1h\u{1B}[?25l\u{1B}[?2004h")
        audit.check("DECCKM, cursor hide and bracketed paste tracked",
                    term.applicationCursorKeys && !term.cursorVisible && term.bracketedPaste)
        term.feed("\u{1B}[?1l\u{1B}[?25h\u{1B}[?2004l")
        audit.check("…and released",
                    !term.applicationCursorKeys && term.cursorVisible && !term.bracketedPaste)
        term.feed("\u{1B}]2;my title\u{7}")
        audit.equal("OSC 2 sets the title (BEL)", term.title, "my title")
        term.feed("\u{1B}]0;other\u{1B}\\")
        audit.equal("OSC 0 sets the title (ST)", term.title, "other")

        term = TerminalEmulator(cols: 30, rows: 3)
        term.feed("\tx")
        audit.equal("default tab stop at 8", term.text(row: 0), "        x")
        term.feed("\r\u{1B}[3G\u{1B}H\r\n\ty")
        audit.equal("HTS sets a custom stop", term.text(row: 1), "  y")

        term = TerminalEmulator(cols: 20, rows: 3)
        term.feed("\u{1B}(0qqq\u{1B}(B|")
        audit.equal("DEC graphics maps q to a line", term.text(row: 0), "───|")

        term = TerminalEmulator(cols: 20, rows: 3)
        let e = Array("é".utf8)                      // 0xC3 0xA9, split across feeds
        term.feed(Data([e[0]]))
        term.feed(Data([e[1]]))
        audit.equal("UTF-8 split across reads decodes", term.text(row: 0), "é")
        term.feed("漢")
        audit.check("a CJK character takes two cells",
                    term.cell(row: 0, col: 1).character == "漢"
                    && term.cell(row: 0, col: 2).isContinuation,
                    term.text(row: 0))

        term = TerminalEmulator(cols: 10, rows: 3)
        term.feed("\u{1B}[31mred\u{1B}7\u{1B}[0m\u{1B}[3;1Hmoved\u{1B}8X")
        audit.check("DECSC/DECRC restores position and colour",
                    term.cursorCol == 4 && term.cell(row: 0, col: 3).style.foreground
                        == .indexed(1),
                    "col=\(term.cursorCol)")

        term = TerminalEmulator(cols: 4, rows: 3)
        term.feed("\u{1B}#8")
        audit.equal("DECALN fills the screen", term.screenText(), "EEEE\nEEEE\nEEEE")

        audit.section("Terminal — resize and hostile input")
        term = TerminalEmulator(cols: 10, rows: 4)
        term.feed("keep me\r\nsecond")
        term.resize(cols: 6, rows: 3)
        audit.equal("narrowing truncates without corrupting", term.text(row: 0), "keep m")
        audit.check("cursor clamped inside the new grid",
                    term.cursorRow < 3 && term.cursorCol < 6,
                    "\(term.cursorRow),\(term.cursorCol)")
        term.resize(cols: 12, rows: 5)
        audit.equal("widening pads with blanks", term.text(row: 0), "keep m")
        term = TerminalEmulator(cols: 10, rows: 5)
        for index in 1...5 { term.feed("row\(index)\(index < 5 ? "\r\n" : "")") }
        term.resize(cols: 10, rows: 2)
        audit.check("shrinking keeps the cursor's line, pushing the top to scrollback",
                    term.text(row: term.cursorRow).hasPrefix("row5")
                    && term.scrollback.contains { TerminalEmulator.text(of: $0) == "row1" },
                    term.screenText())

        // The parser must survive arbitrary bytes without crashing or bending the grid.
        term = TerminalEmulator(cols: 20, rows: 6)
        var seed: UInt64 = 0x5EED
        var junk = Data()
        for _ in 0..<20_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            junk.append(UInt8(truncatingIfNeeded: seed >> 33))
        }
        term.feed(junk)
        let intact = term.screen.count == 6 && term.screen.allSatisfy { $0.count == 20 }
        audit.check("20,000 random bytes leave the grid intact", intact,
                    "\(term.screen.count) rows")
        audit.check("…and the cursor in bounds",
                    (0..<6).contains(term.cursorRow) && (0..<20).contains(term.cursorCol))
        term.feed("\u{1B}[999;999H\u{1B}[999A\u{1B}[999D end")
        audit.check("absurd cursor moves clamp", term.cursorRow == 0 || term.cursorRow == 5)
    }

    // MARK: - PTY

    /// Spawn a real command on the PTY and wait for it to exit, returning the session.
    private static func runOnPTY(_ command: String, cols: Int = 80, rows: Int = 24,
                                 directory: URL,
                                 environment extra: [String: String] = [:]) async
        -> TerminalSession {
        let session = TerminalSession(directory: directory, cols: cols, rows: rows)
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                           "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
                           "HOME": NSHomeDirectory()]
        for (key, value) in extra { environment[key] = value }
        session.start(executable: "/bin/sh", arguments: ["-c", command],
                      environment: environment)
        _ = await waitUntil(8) { session.exitStatus != nil }
        return session
    }

    @discardableResult
    private static func waitUntil(_ timeout: Double,
                                  _ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    private static func ptyChecks(_ audit: Auditor) async {
        await Auditor.withTemporaryDirectory { directory in
            audit.section("Terminal — a real PTY, not a pipe")

            let tty = await runOnPTY("tty", directory: directory)
            audit.check("the child's stdin is a pty device",
                        tty.emulator.text(row: 0).hasPrefix("/dev/ttys"),
                        tty.emulator.text(row: 0))
            audit.equal("a clean command exits 0", tty.exitStatus, 0)

            let size = await runOnPTY("stty size", cols: 100, rows: 30, directory: directory)
            audit.equal("the kernel reports the window size we set",
                        size.emulator.text(row: 0), "30 100")

            let term = await runOnPTY("printf %s \"$TERM\"", directory: directory)
            audit.equal("TERM reaches the child", term.emulator.text(row: 0), "xterm-256color")

            let colour = await runOnPTY(#"printf '\033[32mGREEN\033[0m plain\n'"#,
                                        directory: directory)
            audit.equal("an escape-coloured word survives the trip",
                        colour.emulator.text(row: 0), "GREEN plain")
            audit.equal("…and lands green in the grid",
                        colour.emulator.cell(row: 0, col: 0).style.foreground, .indexed(2))
            audit.equal("…while the plain part stays default",
                        colour.emulator.cell(row: 0, col: 6).style.foreground, .default)

            let status = await runOnPTY("exit 3", directory: directory)
            audit.equal("the exit status is reported", status.exitStatus, 3)

            // 200 columns: a temp path is longer than 80 and would wrap mid-name.
            let cwd = await runOnPTY("pwd", cols: 200, directory: directory)
            audit.check("the child starts in the project directory",
                        cwd.emulator.text(row: 0).hasSuffix(directory.lastPathComponent),
                        cwd.emulator.text(row: 0))

            // Bidirectional: type into `cat`, see the echo and the copy, then EOF ends it.
            let echo = TerminalSession(directory: directory, cols: 40, rows: 6)
            echo.start(executable: "/bin/cat", arguments: [],
                       environment: ["TERM": "xterm-256color"])
            let started = await waitUntil(4) { echo.isRunning }
            audit.check("cat started on the pty", started)
            echo.send(text: "typed\r")
            let echoed = await waitUntil(4) {
                echo.emulator.text(row: 0) == "typed" && echo.emulator.text(row: 1) == "typed"
            }
            audit.check("input echoes and cat repeats it", echoed,
                        echo.emulator.screenText())
            echo.send(Data([0x04]))                    // ^D
            let ended = await waitUntil(4) { echo.exitStatus != nil }
            audit.check("EOF ends the child", ended && echo.exitStatus == 0,
                        "\(String(describing: echo.exitStatus))")

            // A live resize must reach the child through the same ioctl the shell uses.
            let late = TerminalSession(directory: directory, cols: 80, rows: 24)
            late.start(executable: "/bin/sh", arguments: ["-c", "sleep 0.4; stty size"],
                       environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"])
            try? await Task.sleep(nanoseconds: 100_000_000)
            late.resize(cols: 90, rows: 40)
            _ = await waitUntil(6) { late.exitStatus != nil }
            audit.check("a resize while running reaches the child",
                        late.emulator.screenText().contains("40 90"),
                        late.emulator.screenText())

            // SIGHUP from terminate(), the way closing the pane kills a shell.
            let hang = TerminalSession(directory: directory, cols: 40, rows: 6)
            hang.start(executable: "/bin/sh", arguments: ["-c", "sleep 30"],
                       environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"])
            _ = await waitUntil(4) { hang.isRunning }
            hang.terminate()
            let killed = await waitUntil(6) { hang.exitStatus != nil }
            audit.check("terminate hangs up the job", killed,
                        "\(String(describing: hang.exitStatus))")
        }
    }
}

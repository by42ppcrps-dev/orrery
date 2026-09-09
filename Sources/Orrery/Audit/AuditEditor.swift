import AppKit

/// Editing behaviour, exercised through the real `CodeTextView` with no window attached.
/// Auto-indent, bracket handling and comment toggling are the parts of an editor that break
/// silently and are noticed only as "this feels wrong", so they get explicit checks.
@MainActor
enum AuditEditor {

    private static func makeView(_ language: Language, _ text: String)
        -> (CodeTextView, CodeDocument) {
        let document = CodeDocument(name: "scratch.\(language.extensions.first ?? "txt")",
                                    language: language, text: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        document.storage.addLayoutManager(layoutManager)
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400),
                                textContainer: container)
        view.configure()
        view.decorator = document.decorator
        view.language = language
        return (view, document)
    }

    static func run(_ audit: Auditor) {
        audit.section("Editor — indentation")

        func after(_ language: Language, _ text: String, caret: Int,
                   _ action: (CodeTextView) -> Void) -> String {
            let (view, _) = makeView(language, text)
            view.setSelectedRange(NSRange(location: caret, length: 0))
            action(view)
            return view.string
        }

        audit.equal("Python: newline after `:` indents",
                    after(Languages.python, "def f():", caret: 8) { $0.insertNewline(nil) },
                    "def f():\n    ")
        audit.equal("Python: newline keeps the existing indent",
                    after(Languages.python, "def f():\n    x = 1", caret: 18) {
                        $0.insertNewline(nil)
                    },
                    "def f():\n    x = 1\n    ")
        audit.equal("Swift: newline between braces opens a block",
                    after(Languages.swift, "func a() {}", caret: 10) { $0.insertNewline(nil) },
                    "func a() {\n    \n}")
        audit.equal("Go: newline after `{` uses a tab, matching gofmt",
                    after(Languages.go, "func a() {", caret: 10) { $0.insertNewline(nil) },
                    "func a() {\n\t")
        audit.equal("Markdown: newline adds no indent",
                    after(Languages.markdown, "# Title", caret: 7) { $0.insertNewline(nil) },
                    "# Title\n")

        do {
            let (view, _) = makeView(Languages.swift, "func a() {}")
            view.setSelectedRange(NSRange(location: 10, length: 0))
            view.insertNewline(nil)
            audit.equal("Swift: caret lands on the new indented line",
                        view.selectedRange().location, 15)
        }

        audit.section("Editor — tab and outdent")
        audit.equal("Tab mid-line inserts one indent unit",
                    after(Languages.python, "x", caret: 1) { $0.insertTab(nil) }, "x    ")
        do {
            let (view, _) = makeView(Languages.python, "a = 1\nb = 2\n")
            view.setSelectedRange(NSRange(location: 0, length: 12))
            view.insertTab(nil)
            audit.equal("Tab with a multi-line selection indents every line",
                        view.string, "    a = 1\n    b = 2\n")
            view.insertBacktab(nil)
            audit.equal("Shift-Tab puts it back", view.string, "a = 1\nb = 2\n")
        }
        do {
            let (view, _) = makeView(Languages.python, "        deep\n")
            view.setSelectedRange(NSRange(location: 0, length: 12))
            view.insertBacktab(nil)
            audit.equal("Shift-Tab removes exactly one level", view.string, "    deep\n")
        }
        audit.equal("Backspace in indentation removes a whole level",
                    after(Languages.python, "    x", caret: 4) { $0.deleteBackward(nil) }, "x")
        audit.equal("Backspace in text removes one character",
                    after(Languages.python, "abc", caret: 3) { $0.deleteBackward(nil) }, "ab")

        audit.section("Editor — brackets and quotes")
        audit.equal("Typing ( closes it",
                    after(Languages.swift, "", caret: 0) {
                        $0.insertText("(", replacementRange: NSRange(location: NSNotFound,
                                                                     length: 0))
                    }, "()")
        do {
            let (view, _) = makeView(Languages.swift, "()")
            view.setSelectedRange(NSRange(location: 1, length: 0))
            view.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
            audit.equal("Typing the closer steps over it instead of doubling", view.string, "()")
            audit.equal("…and the caret moved past it", view.selectedRange().location, 2)
        }
        audit.equal("An apostrophe after a letter is not an opening quote",
                    after(Languages.swift, "don", caret: 3) {
                        $0.insertText("'", replacementRange: NSRange(location: NSNotFound,
                                                                     length: 0))
                    }, "don'")
        audit.equal("No auto-close in front of a word",
                    after(Languages.swift, "abc", caret: 0) {
                        $0.insertText("(", replacementRange: NSRange(location: NSNotFound,
                                                                     length: 0))
                    }, "(abc")
        do {
            let (view, _) = makeView(Languages.swift, "abc")
            view.setSelectedRange(NSRange(location: 0, length: 3))
            view.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
            audit.equal("Typing a bracket over a selection wraps it", view.string, "(abc)")
            audit.equal("…and the selection still covers the text",
                        view.selectedRange(), NSRange(location: 1, length: 3))
        }
        audit.equal("Backspace between an empty pair removes both halves",
                    after(Languages.swift, "()", caret: 1) { $0.deleteBackward(nil) }, "")
        audit.equal("JSON only auto-closes its own pairs",
                    after(Languages.json, "", caret: 0) {
                        $0.insertText("'", replacementRange: NSRange(location: NSNotFound,
                                                                     length: 0))
                    }, "'")

        audit.section("Editor — comment toggle")
        do {
            let (view, _) = makeView(Languages.python, "x = 1\ny = 2\n")
            view.setSelectedRange(NSRange(location: 0, length: 12))
            view.toggleLineComment(nil)
            audit.equal("Python: comments the selection", view.string, "# x = 1\n# y = 2\n")
            view.toggleLineComment(nil)
            audit.equal("Python: toggles back", view.string, "x = 1\ny = 2\n")
        }
        do {
            let (view, _) = makeView(Languages.swift, "    let a = 1\n    let b = 2\n")
            view.setSelectedRange(NSRange(location: 0, length: 28))
            view.toggleLineComment(nil)
            audit.equal("Swift: the marker goes at the common indent, not column zero",
                        view.string, "    // let a = 1\n    // let b = 2\n")
            view.toggleLineComment(nil)
            audit.equal("Swift: toggles back", view.string, "    let a = 1\n    let b = 2\n")
        }
        do {
            let (view, _) = makeView(Languages.swift, "let a = 1\n\nlet b = 2\n")
            view.setSelectedRange(NSRange(location: 0, length: 21))
            view.toggleLineComment(nil)
            audit.equal("A blank line inside the selection is left alone",
                        view.string, "// let a = 1\n\n// let b = 2\n")
        }
        do {
            let (view, _) = makeView(Languages.html, "<p>hi</p>\n")
            view.setSelectedRange(NSRange(location: 0, length: 10))
            view.toggleLineComment(nil)
            audit.check("HTML falls back to its block comment",
                        view.string.contains("<!--") && view.string.contains("-->"),
                        view.string.debugDescription)
        }

        audit.section("Editor — line index and navigation")
        do {
            let (view, document) = makeView(Languages.swift,
                                            "one\ntwo\nthree\nfour\nfive\n")
            audit.equal("line count", document.decorator.lineStartOffsets.count, 6)
            audit.equal("offset 0 is line 1", document.decorator.lineNumber(at: 0), 1)
            audit.equal("offset 4 is line 2", document.decorator.lineNumber(at: 4), 2)
            audit.equal("offset 13 is line 3", document.decorator.lineNumber(at: 13), 3)
            audit.equal("range of line 3", document.decorator.range(ofLine: 3),
                        NSRange(location: 8, length: 5))
            view.goToLine(4)
            audit.equal("go to line 4 puts the caret at its start",
                        view.selectedRange().location, 14)
            audit.check("go to a line past the end does nothing bad",
                        { view.goToLine(999); return view.selectedRange().location <= 24 }())
        }
        do {
            // Line numbers must survive an edit that changes the line structure.
            let (_, document) = makeView(Languages.swift, "a\nb\nc\n")
            document.storage.replaceCharacters(in: NSRange(location: 2, length: 0),
                                               with: "x\ny\n")
            audit.equal("line index tracks an insertion",
                        document.decorator.lineStartOffsets.count, 6)
            audit.equal("line number after the insertion",
                        document.decorator.lineNumber(at: 6), 4)
        }

        audit.section("Editor — highlighting through the text storage")
        do {
            let (_, document) = makeView(Languages.swift, "let x = 1\n")
            let attributes = document.storage.attributes(at: 0, effectiveRange: nil)
            let colour = attributes[.foregroundColor] as? NSColor
            audit.check("a keyword is coloured in the storage",
                        colour == EditorTheme.keyword,
                        String(describing: colour))
            document.storage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "var")
            let after = document.storage.attributes(at: 0, effectiveRange: nil)[.foregroundColor]
                as? NSColor
            audit.check("re-typing a keyword re-colours it", after == EditorTheme.keyword)
            document.storage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "abc")
            let plain = document.storage.attributes(at: 0, effectiveRange: nil)[.foregroundColor]
                as? NSColor
            audit.check("a non-keyword loses the keyword colour", plain == EditorTheme.plain)
        }
        do {
            let (_, document) = makeView(Languages.swift, "let a = 1\nlet b = 2\n")
            document.diagnostics = [Diagnostic(file: document.url, line: 2, column: 5, length: 1,
                                               severity: .error, message: "bad",
                                               source: "audit")]
            let underline = document.storage.attributes(at: 14, effectiveRange: nil)[.underlineStyle]
            audit.check("a diagnostic underlines the right character", underline != nil)
            audit.equal("the gutter learns the line",
                        document.decorator.severityByLine()[2], Diagnostic.Severity.error)
            audit.check("a clean character is not underlined",
                        document.storage.attributes(at: 0,
                                                    effectiveRange: nil)[.underlineStyle] == nil)
        }
    }
}

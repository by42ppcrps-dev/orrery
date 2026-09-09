import AppKit

/// Pixel proof that syntax highlighting is not Swift-only.
///
/// `AuditRendering` already proves the editor paints keyword/string/comment/number pixels for
/// Swift. These checks drive the same view stack for the other languages the editor claims to
/// highlight, and classify real pixels against the theme — because a tokenizer that is right
/// while the text view still draws everything in `plain` is the exact class of bug the Swift
/// rendering audit was written to catch.
@MainActor
enum AuditPolyglot {

    private struct Need {
        var label: String
        var kind: TokenKind
        var colour: NSColor
        var minimum: Int
    }

    private struct Spec {
        var id: String
        var filename: String
        var source: String
        var needs: [Need]
        /// Extra palette entries so a kind this grammar emits is not classified as a neighbour
        /// we then assert on. Never includes a colour identical to an asserted kind under a
        /// different name (light-mode `tag` == `keyword`).
        var extraPalette: [(String, NSColor)]
    }

    static func run(_ audit: Auditor) {
        let specs = makeSpecs()

        audit.section("Polyglot — language registry")
        var resolved: [(Spec, Language)] = []
        for spec in specs {
            if let language = Languages.byID(spec.id) {
                audit.check("Languages.byID(\"\(spec.id)\") resolves", true)
                resolved.append((spec, language))
            } else {
                audit.check("Languages.byID(\"\(spec.id)\") resolves", false, "got nil")
            }
        }

        for (spec, language) in resolved {
            audit.section("Polyglot — \(language.name) sample")
            let tokens = Tokenizer.tokens(for: spec.source, language: language)
            for need in spec.needs {
                let n = tokens.filter { $0.kind == need.kind }.count
                audit.check("the \(language.name) sample contains \(need.label) tokens",
                            n > 0,
                            "tokenizer emitted \(n) \(need.kind.rawValue) token(s)")
            }

            for name in [NSAppearance.Name.aqua, .darkAqua] {
                guard let appearance = NSAppearance(named: name) else { continue }
                audit.section("Polyglot — \(language.name) (\(name.rawValue))")
                check(audit, spec: spec, language: language, appearance: appearance)
            }
        }
    }

    private static func check(_ audit: Auditor, spec: Spec, language: Language,
                              appearance: NSAppearance) {
        let originalFontSize = EditorTheme.fontSize
        EditorTheme.fontSize = 30
        defer { EditorTheme.fontSize = originalFontSize }

        let document = CodeDocument(name: spec.filename, language: language, text: spec.source)
        let stack = CodeEditorView.makeStack(for: document)
        let scrollView = stack.scrollView

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = appearance
        window.colorSpace = .sRGB
        window.contentView = scrollView
        scrollView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        stack.textView.isHorizontallyResizable = true
        stack.textView.autoresizingMask = []
        stack.container.widthTracksTextView = false
        stack.container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                               height: CGFloat.greatestFiniteMagnitude)
        stack.textView.sizeToFit()
        stack.ruler.resizeToFit(lineCount: document.lineCount)
        window.layoutIfNeeded()
        // Baseline through the same rehighlight path the flatten cycle uses, so the
        // differential compares like with like (the pristine render used to differ once
        // a font-reset bug re-applied traits mid-cycle — reviewer finding, run 4 round 2).
        document.decorator.rehighlightAll()
        window.layoutIfNeeded()

        let counts = AuditRendering.histogram(scrollView, scrollView.bounds)
        let samples = counts.values.reduce(0, +)
        audit.check("the editor renders more than a flat colour", counts.count > 20,
                    "\(counts.count) distinct colours over \(samples) samples")

        var palette: [(String, NSColor)] = [
            ("background", EditorTheme.background),
            ("currentLine", EditorTheme.currentLine),
            ("gutterBack", EditorTheme.gutterBack),
            ("gutterText", EditorTheme.gutterText),
            ("plain", EditorTheme.plain),
        ]
        for need in spec.needs { palette.append((need.label, need.colour)) }
        palette.append(contentsOf: spec.extraPalette)
        let tally = AuditRendering.classify(counts, palette, in: appearance)

        // Nearest-neighbour classification assigns antialiased `plain` pixels to some
        // token colours in light mode (`key` and `heading` sit on that gray ramp), so
        // "≥40 pixels nearest to heading" still passes after heading highlighting is
        // gone. The pixels must be caused by that kind: flattening it to `plain` has
        // to drop the classified count by the same threshold.
        for need in spec.needs {
            flatten(document, kind: need.kind)
            window.layoutIfNeeded()
            let after = AuditRendering.classify(
                AuditRendering.histogram(scrollView, scrollView.bounds),
                palette, in: appearance)[need.label] ?? 0
            document.decorator.rehighlightAll()
            window.layoutIfNeeded()
            let found = tally[need.label] ?? 0
            let caused = found - after
            audit.check("\(need.label) pixels are on screen", caused >= need.minimum,
                        "\(found) px, \(after) after flattening \(need.label) → plain, "
                        + "delta \(caused), wanted \(need.minimum) — tally "
                        + tally.sorted { $0.value > $1.value }.prefix(6)
                            .map { "\($0.key):\($0.value)" }.joined(separator: " "))
        }

        // The bug this file's reviewer caught: NSTextView.configure() used to reset the font
        // across the whole storage, flattening the decorator's bold headings. Re-running
        // configure() must leave a Markdown heading bold.
        if language.id == "markdown" {
            stack.textView.configure()
            let headingFont = document.storage.attribute(
                .font, at: 2, effectiveRange: nil) as? NSFont
            let stillBold = headingFont.map {
                NSFontManager.shared.traits(of: $0).contains(.boldFontMask)
            } ?? false
            audit.check("a heading keeps its bold trait through view configuration",
                        stillBold, headingFont?.fontName ?? "no font attribute")
        }

        window.contentView = nil
        document.decorator.onRehighlight = nil
        document.storage.removeLayoutManager(stack.layoutManager)
    }

    /// Recolour every token of `kind` as `plain`, leaving the rest of the highlighting.
    private static func flatten(_ document: CodeDocument, kind: TokenKind) {
        let storage = document.storage
        let tokens = Tokenizer.tokens(for: document.text, language: document.language)
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(document.decorator.baseAttributes, range: whole)
        for token in tokens {
            let range = NSRange(location: token.range.location,
                                length: min(token.range.length,
                                            max(0, storage.length - token.range.location)))
            guard range.location >= 0, range.location < storage.length, range.length > 0 else {
                continue
            }
            let colour = token.kind == kind ? EditorTheme.plain : EditorTheme.color(for: token.kind)
            storage.addAttribute(.foregroundColor, value: colour, range: range)
            if token.kind != kind, let traits = EditorTheme.traits(for: token.kind) {
                storage.addAttribute(.font, value: EditorTheme.font(traits), range: range)
            }
        }
        storage.endEditing()
    }

    // MARK: - Samples

    private static func makeSpecs() -> [Spec] {
        // Thresholds match AuditRendering: keyword/string/comment 40, number 10. Heading, tag
        // and JSON key use 40 — they are whole tokens at 30pt, same stem-width argument. Never
        // drop a floor because a colour was missing; that is a defect, not a threshold problem.
        let keyword40 = 40, string40 = 40, comment40 = 40, number10 = 10

        return [
            Spec(id: "python", filename: "sample.py", source: """
                # Count items in the basket.
                def total(name):
                    label = "basket"
                    count = 42
                    if name is None:
                        return count
                    return 0

                """,
                 needs: [
                    Need(label: "keyword", kind: .keyword, colour: EditorTheme.keyword, minimum: keyword40),
                    Need(label: "string", kind: .string, colour: EditorTheme.string, minimum: string40),
                    Need(label: "comment", kind: .comment, colour: EditorTheme.comment, minimum: comment40),
                    Need(label: "number", kind: .number, colour: EditorTheme.number, minimum: number10),
                 ],
                 extraPalette: [
                    ("type", EditorTheme.type),
                    ("builtin", EditorTheme.builtin),
                    ("function", EditorTheme.function),
                    ("attribute", EditorTheme.attribute),
                 ]),

            // JSON keys are `.key`, values `.string`, true/false/null `.builtin`. The scanner
            // also accepts jsonc comments, but this sample does not contain any, and JSON has
            // no keyword tokens — so those kinds are not asserted.
            Spec(id: "json", filename: "sample.json", source: """
                {
                  "name": "grok-studio",
                  "count": 42,
                  "ratio": -1.5,
                  "ok": true,
                  "empty": null,
                  "tags": ["alpha", "beta"]
                }

                """,
                 needs: [
                    Need(label: "string", kind: .string, colour: EditorTheme.string, minimum: string40),
                    Need(label: "number", kind: .number, colour: EditorTheme.number, minimum: number10),
                    Need(label: "key", kind: .key, colour: EditorTheme.key, minimum: keyword40),
                 ],
                 extraPalette: [
                    ("builtin", EditorTheme.builtin),
                    ("escape", EditorTheme.escape),
                 ]),

            Spec(id: "javascript", filename: "sample.js", source: """
                // Greet the caller once.
                function greet(name) {
                  const msg = "hello";
                  let n = 42;
                  if (n > 0) {
                    return msg;
                  }
                }

                """,
                 needs: [
                    Need(label: "keyword", kind: .keyword, colour: EditorTheme.keyword, minimum: keyword40),
                    Need(label: "string", kind: .string, colour: EditorTheme.string, minimum: string40),
                    Need(label: "comment", kind: .comment, colour: EditorTheme.comment, minimum: comment40),
                    Need(label: "number", kind: .number, colour: EditorTheme.number, minimum: number10),
                 ],
                 extraPalette: [
                    ("type", EditorTheme.type),
                    ("builtin", EditorTheme.builtin),
                    ("function", EditorTheme.function),
                    ("escape", EditorTheme.escape),
                 ]),

            Spec(id: "c", filename: "sample.c", source: """
                /* Report a status code. */
                int main(void) {
                    // greeting
                    const char *msg = "hello";
                    int n = 42;
                    if (n > 0) {
                        return 0;
                    }
                }

                """,
                 needs: [
                    Need(label: "keyword", kind: .keyword, colour: EditorTheme.keyword, minimum: keyword40),
                    Need(label: "string", kind: .string, colour: EditorTheme.string, minimum: string40),
                    Need(label: "comment", kind: .comment, colour: EditorTheme.comment, minimum: comment40),
                    Need(label: "number", kind: .number, colour: EditorTheme.number, minimum: number10),
                 ],
                 extraPalette: [
                    ("type", EditorTheme.type),
                    ("builtin", EditorTheme.builtin),
                    ("function", EditorTheme.function),
                    ("directive", EditorTheme.directive),
                    ("escape", EditorTheme.escape),
                 ]),

            // Markdown emits heading, string (code span), comment (blockquote), emphasis, link,
            // and `.keyword` only for fences/list markers. This sample has none of those, so
            // keyword/number are not asserted. Emphasis is omitted from the palette: its
            // colour sits on the antialiased edge of `plain` and would steal body-text pixels.
            Spec(id: "markdown", filename: "sample.md", source: """
                # Polyglot Heading Here

                Use a `code span` here.

                ## Another Heading Line

                > a quoted remark

                See `more code` too.

                """,
                 needs: [
                    Need(label: "heading", kind: .heading, colour: EditorTheme.heading, minimum: keyword40),
                    Need(label: "string", kind: .string, colour: EditorTheme.string, minimum: string40),
                    Need(label: "comment", kind: .comment, colour: EditorTheme.comment, minimum: comment40),
                 ],
                 extraPalette: [
                    ("link", EditorTheme.link),
                 ]),

            // HTML tags are `.tag` (not `.keyword` — same light-mode colour, different kind).
            Spec(id: "html", filename: "sample.html", source: """
                <div class="row">
                  <!-- a visible comment -->
                  <span id="main" title="hello">
                    text
                  </span>
                  <b class="x">y</b>
                </div>
                <p class="note">ok</p>

                """,
                 needs: [
                    Need(label: "tag", kind: .tag, colour: EditorTheme.tag, minimum: keyword40),
                    Need(label: "string", kind: .string, colour: EditorTheme.string, minimum: string40),
                    Need(label: "comment", kind: .comment, colour: EditorTheme.comment, minimum: comment40),
                 ],
                 extraPalette: [
                    ("key", EditorTheme.key),
                    ("directive", EditorTheme.directive),
                    ("escape", EditorTheme.escape),
                 ]),
        ]
    }
}

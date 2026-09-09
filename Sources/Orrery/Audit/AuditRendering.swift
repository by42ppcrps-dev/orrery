import AppKit

/// Proof that the editor actually puts pixels on screen.
///
/// Every other check in this suite passed while the editor rendered a completely blank page:
/// the tokenizer was right, the text storage was right, the geometry was right, and a ruler
/// painting outside its own bounds covered the lot. These checks render the real view stack and
/// look at the resulting pixels, which is the only way that class of bug shows up.
@MainActor
enum AuditRendering {

    /// How many times each colour appears in a rendering of `view`.
    static func histogram(_ view: NSView, _ rect: NSRect) -> [NSColor: Int] {
        guard rect.width > 1, rect.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return [:] }
        view.cacheDisplay(in: rect, to: rep)
        var counts: [NSColor: Int] = [:]
        for y in 0..<Int(rep.pixelsHigh) {
            for x in 0..<Int(rep.pixelsWide) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                counts[colour, default: 0] += 1
            }
        }
        return counts
    }

    /// Which theme colour each rendered pixel is closest to.
    ///
    /// Exact colour matching does not survive contact with a real renderer: macOS font smoothing
    /// blends every glyph toward its background, so a keyword drawn as #9B2393 lands on screen
    /// as #AD3CA4 and no threshold distinguishes "wrong colour" from "antialiased". Nearest-
    /// neighbour classification against the palette asks the question that actually matters —
    /// is there text on screen whose colour is the keyword colour and not the background?
    static func classify(_ counts: [NSColor: Int], _ palette: [(String, NSColor)],
                         in appearance: NSAppearance) -> [String: Int] {
        var resolved: [(String, NSColor)] = []
        appearance.performAsCurrentDrawingAppearance {
            resolved = palette.compactMap { name, colour in
                colour.usingColorSpace(.sRGB).map { (name, $0) }
            }
        }
        var tally: [String: Int] = [:]
        for (sample, occurrences) in counts {
            guard let sRGB = sample.usingColorSpace(.sRGB) else { continue }
            var bestName = ""
            var best = Double.greatestFiniteMagnitude
            for (name, target) in resolved {
                let distance = abs(sRGB.redComponent - target.redComponent)
                    + abs(sRGB.greenComponent - target.greenComponent)
                    + abs(sRGB.blueComponent - target.blueComponent)
                if distance < best { best = distance; bestName = name }
            }
            tally[bestName, default: 0] += occurrences
        }
        return tally
    }

    static func run(_ audit: Auditor) {
        // Both appearances: a theme that only reads correctly in one of them is a real defect,
        // and the audit machine's own setting should not decide which one gets tested.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { continue }
            audit.section("Rendering — the editor actually draws (\(name.rawValue))")
            check(audit, appearance)
        }
    }

    private static func check(_ audit: Auditor, _ appearance: NSAppearance) {
        // Rendered large on purpose. At a normal 13pt a monospace stem is about one pixel wide
        // and antialiasing blends nearly every pixel toward the background, so "is this colour
        // on screen" cannot be answered. Bigger glyphs have solid interiors.
        let originalFontSize = EditorTheme.fontSize
        EditorTheme.fontSize = 30
        defer { EditorTheme.fontSize = originalFontSize }

        let source = """
        import Foundation

        // A comment that should be grey.
        struct Widget {
            let name = "a string literal"
            let count = 42
            func run() -> Int { return count }
        }

        """
        let document = CodeDocument(name: "Render.swift", language: Languages.swift, text: source)
        let stack = CodeEditorView.makeStack(for: document)
        let scrollView = stack.scrollView

        // Put it in a window and give it a real size, exactly as the app's layout does.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = appearance
        // Render into sRGB. On a wide-gamut display the backing store is Display P3, and a
        // saturated colour written as sRGB comes back with different components — which makes
        // "is the keyword colour on screen" unanswerable for exactly the colours that matter.
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

        let bounds = scrollView.bounds
        let counts = histogram(scrollView, bounds)
        let samples = counts.values.reduce(0, +)

        audit.check("the editor renders more than a flat colour", counts.count > 20,
                    "\(counts.count) distinct colours over \(samples) samples")
        let palette: [(String, NSColor)] = [
            ("background", EditorTheme.background),
            ("currentLine", EditorTheme.currentLine),
            ("gutterBack", EditorTheme.gutterBack),
            ("gutterText", EditorTheme.gutterText),
            ("plain", EditorTheme.plain),
            ("keyword", EditorTheme.keyword),
            ("type", EditorTheme.type),
            ("string", EditorTheme.string),
            ("comment", EditorTheme.comment),
            ("number", EditorTheme.number),
            ("function", EditorTheme.function),
        ]
        let tally = classify(counts, palette, in: appearance)

        func visible(_ label: String, atLeast minimum: Int) {
            let found = tally[label] ?? 0
            audit.check("\(label) pixels are on screen", found >= minimum,
                        "\(found) px, wanted \(minimum) — tally "
                        + tally.sorted { $0.value > $1.value }.prefix(6)
                            .map { "\($0.key):\($0.value)" }.joined(separator: " "))
        }
        visible("keyword", atLeast: 40)
        visible("string", atLeast: 40)
        visible("comment", atLeast: 40)
        visible("number", atLeast: 10)
        visible("type", atLeast: 10)
        visible("plain", atLeast: 200)

        // The specific bug this guards against: the gutter painted over the start of every
        // line, so `import Foundation` rendered as `Foundation`. Look only at the narrow strip
        // immediately right of the gutter, where line 1 begins with a keyword. Comparing whole-
        // view colour shares cannot see this — in dark mode the gutter and the editor
        // background are deliberately almost the same colour.
        let firstColumn = NSRect(x: stack.ruler.ruleThickness, y: 0, width: 70, height: 60)
        let columnTally = classify(histogram(scrollView, firstColumn), palette, in: appearance)
        let columnText = (columnTally["keyword"] ?? 0) + (columnTally["plain"] ?? 0)
            + (columnTally["type"] ?? 0)
        audit.check("the first characters of a line are not hidden by the gutter",
                    columnText >= 20,
                    "\(columnText) text pixels beside the gutter — "
                    + columnTally.sorted { $0.value > $1.value }.prefix(4)
                        .map { "\($0.key):\($0.value)" }.joined(separator: " "))

        // And the text must be pushed clear of it rather than hidden underneath.
        let clip = scrollView.contentView
        audit.check("the scroll view makes room for the gutter",
                    abs(clip.bounds.origin.x + stack.ruler.ruleThickness) < 1.0,
                    "clip bounds x = \(clip.bounds.origin.x), "
                    + "ruler = \(stack.ruler.ruleThickness)")

        // Line numbers themselves have to be drawn.
        let rulerTally = classify(histogram(stack.ruler, stack.ruler.bounds),
                                  [("back", EditorTheme.gutterBack),
                                   ("digits", EditorTheme.gutterText),
                                   ("current", EditorTheme.gutterCurrent)],
                                  in: appearance)
        let digits = (rulerTally["digits"] ?? 0) + (rulerTally["current"] ?? 0)
        audit.check("line numbers are drawn in the gutter", digits >= 40,
                    "\(digits) digit pixels, \(rulerTally["back"] ?? 0) background")

        // A view with a real frame must not report a degenerate size.
        audit.check("the text view sized itself to the document",
                    stack.textView.frame.height > 100 && stack.textView.frame.width > 100,
                    "\(stack.textView.frame)")

        window.contentView = nil
        document.decorator.onRehighlight = nil
        document.storage.removeLayoutManager(stack.layoutManager)
    }
}

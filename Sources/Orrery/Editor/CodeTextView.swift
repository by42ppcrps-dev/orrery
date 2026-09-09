import AppKit

// MARK: - Line number gutter

/// Line numbers plus a diagnostic mark per line. Uses the decorator's cached line index rather
/// than counting newlines on every scroll.
final class LineNumberRuler: NSRulerView {
    weak var codeView: CodeTextView?
    var severities: [Int: Diagnostic.Severity] = [:] { didSet { needsDisplay = true } }

    init(scrollView: NSScrollView, textView: CodeTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.codeView = textView
        self.clientView = textView
        self.ruleThickness = 48
        // A macOS view is free to paint outside its own bounds, and AppKit hands
        // `drawHashMarksAndLabels(in:)` a rect that can be larger than the ruler. Filling that
        // rect then covers the text with the gutter's background — the whole editor renders as
        // an empty page with line numbers down the side.
        self.clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    func resizeToFit(lineCount: Int) {
        let digits = max(2, String(max(1, lineCount)).count)
        let width = ceil(CGFloat(digits) * EditorTheme.fontSize * 0.62) + 26
        guard abs(width - ruleThickness) > 0.5 else { return }
        ruleThickness = width
        reserveSpace()
    }

    /// A scroll view makes room for a ruler by scrolling its clip view to a negative x origin.
    /// It works that out in `tile()`, and a clip view that is still zero-sized — which is what
    /// SwiftUI hands it — clamps the offset straight back to zero. Left alone, the gutter is
    /// painted over the first few characters of every line.
    func reserveSpace() {
        guard let scrollView, scrollView.rulersVisible, scrollView.bounds.width > 1 else { return }
        scrollView.tile()
        let clip = scrollView.contentView
        guard abs(clip.bounds.origin.x + ruleThickness) > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: -ruleThickness, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = codeView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        EditorTheme.gutterBack.setFill()
        bounds.intersection(rect).fill()

        let content = textView.string as NSString
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                     actualGlyphRange: nil)
        let starts = textView.decorator?.lineStartOffsets ?? [0]
        let inset = textView.textContainerInset.height
        let currentLine = textView.currentLineNumber

        var line = lineIndex(in: starts, for: charRange.location)   // 0-based
        var index = line < starts.count ? starts[line] : 0
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, EditorTheme.fontSize - 2),
                                                    weight: .regular)
        let boldFont = NSFont.monospacedDigitSystemFont(ofSize: max(9, EditorTheme.fontSize - 2),
                                                        weight: .semibold)
        let upperBound = NSMaxRange(charRange)

        while index <= content.length {
            let paragraph = content.lineRange(for: NSRange(location: min(index, content.length),
                                                           length: 0))
            let fragmentRect: NSRect
            if index >= content.length, content.length == 0 || content.hasSuffix("\n") {
                fragmentRect = layoutManager.extraLineFragmentRect
            } else {
                let glyph = layoutManager.glyphRange(forCharacterRange: paragraph,
                                                     actualCharacterRange: nil)
                var effective = NSRange()
                fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyph.location,
                                                              effectiveRange: &effective)
            }
            let y = fragmentRect.minY + inset - visible.minY
            if y > rect.maxY { break }

            let number = line + 1
            if y + fragmentRect.height >= rect.minY {
                let isCurrent = number == currentLine
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: isCurrent ? boldFont : font,
                    .foregroundColor: isCurrent ? EditorTheme.gutterCurrent : EditorTheme.gutterText,
                ]
                let label = NSAttributedString(string: "\(number)", attributes: attributes)
                let size = label.size()
                label.draw(at: NSPoint(x: ruleThickness - size.width - 8,
                                       y: y + (fragmentRect.height - size.height) / 2))

                if let severity = severities[number] {
                    let dot = NSRect(x: 4, y: y + fragmentRect.height / 2 - 3, width: 6, height: 6)
                    switch severity {
                    case .error: EditorTheme.errorTint.setFill()
                    case .warning: EditorTheme.warningTint.setFill()
                    case .info: EditorTheme.infoTint.setFill()
                    }
                    NSBezierPath(ovalIn: dot).fill()
                }
            }

            if index >= content.length { break }
            let next = paragraph.location + paragraph.length
            if next <= index { break }
            index = next
            line += 1
            if index > upperBound, y > rect.maxY { break }
        }
    }

    private func lineIndex(in starts: [Int], for offset: Int) -> Int {
        guard !starts.isEmpty else { return 0 }
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

// MARK: - Editor

/// The text view. Everything here is behaviour a code editor needs and a plain `TextEditor` does
/// not have: indentation that follows the language, bracket handling, comment toggling, a
/// current-line highlight, and bracket matching.
final class CodeTextView: NSTextView {
    var language: Language = Languages.plainText {
        didSet { if language.id != oldValue.id { needsDisplay = true } }
    }
    weak var decorator: SyntaxDecorator?
    var onSaveRequested: (() -> Void)?
    var onSelectionChanged: ((NSRange) -> Void)?
    /// line, column, generation token — ignore a reply whose token no longer matches.
    var onRequestHover: ((Int, Int, Int) -> Void)?
    var onRequestDefinition: ((Int, Int) -> Void)?
    var onRequestCompletions: ((Int, Int, Int) -> Void)?
    /// ⌘K: the selection (or the caret's whole line) to hand to an agent.
    var onEditWithAgent: ((NSRange, String) -> Void)?

    static let hoverDwellSeconds: TimeInterval = 0.4

    private var matchedBrackets: [NSRange] = []
    private var hoverTracking: NSTrackingArea?
    private var hoverTask: Task<Void, Never>?
    private(set) var hoverToken = 0
    private var hoverAnchor: NSPoint = .zero
    private var hoverCard: HoverCardView?
    private var completionPopup: CompletionPopupView?
    private var completionTask: Task<Void, Never>?
    private(set) var completionToken = 0
    private var completionItems: [LSPCompletionItem] = []
    private var suppressCompletion = false

    var currentLineNumber: Int {
        decorator?.lineNumber(at: min(selectedRange().location, string.utf16.count)) ?? 1
    }

    // MARK: Setup

    func configure() {
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        smartInsertDeleteEnabled = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        usesFindPanel = false
        textContainerInset = NSSize(width: 6, height: 8)
        backgroundColor = EditorTheme.background
        insertionPointColor = EditorTheme.plain
        drawsBackground = true
        // NSTextView's `font` setter restyles the WHOLE storage, flattening the bold/italic
        // trait fonts the decorator applied (Markdown headings lost their weight — found by
        // the polyglot pixel audit's reviewer). Typing attributes cover new text; the
        // decorator owns what is already styled.
        typingAttributes = decorator?.baseAttributes ?? [.font: EditorTheme.font]
        if decorator == nil { font = EditorTheme.font } else { decorator?.rehighlightAll() }
        updateTrackingAreas()
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let container = textContainer else { return }

        let selection = selectedRange()
        if selection.length == 0, !string.isEmpty || selection.location == 0 {
            let content = string as NSString
            let paragraph = content.lineRange(
                for: NSRange(location: min(selection.location, content.length), length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: paragraph,
                                                      actualCharacterRange: nil)
            var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            if paragraph.length == 0, content.length == 0 {
                lineRect = layoutManager.extraLineFragmentRect
            }
            lineRect.origin.x = 0
            lineRect.origin.y += textContainerInset.height
            lineRect.size.width = bounds.width
            if lineRect.height > 0, lineRect.intersects(rect) {
                EditorTheme.currentLine.setFill()
                lineRect.fill()
            }
        }

        for range in matchedBrackets {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                                      actualCharacterRange: nil)
            var box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            box.origin.x += textContainerInset.width
            box.origin.y += textContainerInset.height
            EditorTheme.bracketMatch.setFill()
            NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2).fill()
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity,
                                    stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateBracketMatch()
        onSelectionChanged?(selectedRange())
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
        needsDisplay = true
        if !stillSelecting {
            dismissHover()
            if isCompletionVisible, !suppressCompletion {
                refilterCompletionsOrDismiss()
            }
        }
    }

    private func updateBracketMatch() {
        matchedBrackets = []
        let content = string as NSString
        let caret = selectedRange().location
        guard selectedRange().length == 0, content.length > 0 else { return }

        let pairs: [(Character, Character)] = [("(", ")"), ("[", "]"), ("{", "}")]
        func character(at index: Int) -> Character? {
            guard index >= 0, index < content.length else { return nil }
            return Character(content.substring(with: NSRange(location: index, length: 1)))
        }
        // Match the bracket just before the caret first, then the one just after it.
        for probe in [caret - 1, caret] {
            guard let candidate = character(at: probe) else { continue }
            if let pair = pairs.first(where: { $0.0 == candidate }),
               let match = scanForward(from: probe, open: pair.0, close: pair.1, in: content) {
                matchedBrackets = [NSRange(location: probe, length: 1),
                                   NSRange(location: match, length: 1)]
                return
            }
            if let pair = pairs.first(where: { $0.1 == candidate }),
               let match = scanBackward(from: probe, open: pair.0, close: pair.1, in: content) {
                matchedBrackets = [NSRange(location: match, length: 1),
                                   NSRange(location: probe, length: 1)]
                return
            }
        }
    }

    /// Bounded so a file full of unbalanced brackets cannot stall the caret.
    private static let bracketScanLimit = 200_000

    private func scanForward(from index: Int, open: Character, close: Character,
                             in content: NSString) -> Int? {
        var depth = 0
        var position = index
        let limit = min(content.length, index + Self.bracketScanLimit)
        while position < limit {
            let character = Character(content.substring(with: NSRange(location: position, length: 1)))
            if character == open { depth += 1 }
            else if character == close { depth -= 1; if depth == 0 { return position } }
            position += 1
        }
        return nil
    }

    private func scanBackward(from index: Int, open: Character, close: Character,
                              in content: NSString) -> Int? {
        var depth = 0
        var position = index
        let limit = max(0, index - Self.bracketScanLimit)
        while position >= limit {
            let character = Character(content.substring(with: NSRange(location: position, length: 1)))
            if character == close { depth += 1 }
            else if character == open { depth -= 1; if depth == 0 { return position } }
            position -= 1
        }
        return nil
    }

    // MARK: Text helpers

    private var content: NSString { string as NSString }

    private func lineRange(at location: Int) -> NSRange {
        content.lineRange(for: NSRange(location: min(location, content.length), length: 0))
    }

    private func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// Insert without re-entering the auto-pair logic.
    private func typeRaw(_ text: String, replacing range: NSRange? = nil) {
        let target = range ?? selectedRange()
        guard shouldChangeText(in: target, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: target, with: text)
        didChangeText()
    }

    // MARK: Newline and indentation

    override func insertNewline(_ sender: Any?) {
        if acceptCompletion() { return }
        dismissHover()
        let caret = selectedRange()
        guard caret.length == 0 else { super.insertNewline(sender); return }

        let line = lineRange(at: caret.location)
        let head = content.substring(with: NSRange(location: line.location,
                                                   length: max(0, caret.location - line.location)))
        let indent = leadingWhitespace(of: head)
        let trimmed = head.trimmingCharacters(in: .whitespaces)

        let before = caret.location > 0
            ? content.substring(with: NSRange(location: caret.location - 1, length: 1)) : ""
        let after = caret.location < content.length
            ? content.substring(with: NSRange(location: caret.location, length: 1)) : ""
        let betweenPair = language.autoClosePairs.contains { $0.0 == before && $0.1 == after }
            && before != after

        var nextIndent = indent
        if !trimmed.isEmpty,
           language.indentAfterSuffixes.contains(where: { trimmed.hasSuffix($0) }) {
            nextIndent += language.indentUnit
        }

        if betweenPair {
            // Opening a block: the closer moves to its own line at the original indent.
            let insertion = "\n" + nextIndent + "\n" + indent
            typeRaw(insertion)
            setSelectedRange(NSRange(location: caret.location + 1 + nextIndent.utf16.count,
                                     length: 0))
        } else {
            typeRaw("\n" + nextIndent)
        }
        scrollRangeToVisible(selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        if acceptCompletion() { return }
        let selection = selectedRange()
        // A selection that covers more than one line indents the block; anything else inserts
        // one indent unit, which is what you want mid-line.
        guard selection.length > 0,
              content.substring(with: selection).contains("\n") else {
            typeRaw(language.indentUnit)
            return
        }
        shiftLines(in: selection, by: 1)
    }

    override func insertBacktab(_ sender: Any?) {
        shiftLines(in: selectedRange(), by: -1)
    }

    /// Indent or outdent every line the selection touches, keeping the selection over the
    /// same text afterwards.
    private func shiftLines(in selection: NSRange, by direction: Int) {
        let block = content.lineRange(for: selection)
        guard block.length > 0 || content.length == 0 else { return }
        let original = content.substring(with: block)
        let hadTrailingNewline = original.hasSuffix("\n")
        var lines = original.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }
        let unit = language.indentUnit

        var rebuilt: [String] = []
        for line in lines {
            if direction > 0 {
                rebuilt.append(line.isEmpty ? line : unit + line)
            } else if line.hasPrefix(unit) {
                rebuilt.append(String(line.dropFirst(unit.count)))
            } else if line.hasPrefix("\t") {
                rebuilt.append(String(line.dropFirst()))
            } else {
                let stripped = line.drop { $0 == " " }
                let removed = line.count - stripped.count
                rebuilt.append(removed > 0 ? String(line.dropFirst(min(removed, unit.count)))
                                           : line)
            }
        }
        var replacement = rebuilt.joined(separator: "\n")
        if hadTrailingNewline { replacement += "\n" }
        guard replacement != original else { return }

        typeRaw(replacement, replacing: block)
        let delta = (replacement as NSString).length - block.length
        if selection.length == 0 {
            // A caret with no selection is on exactly one line, so it moves by that line's own
            // change in width and stays over the same character.
            let firstDelta = (rebuilt.first?.utf16.count ?? 0) - (lines.first?.utf16.count ?? 0)
            let moved = min(max(block.location, selection.location + firstDelta),
                            block.location + block.length + delta)
            setSelectedRange(NSRange(location: moved, length: 0))
        } else {
            setSelectedRange(NSRange(location: block.location,
                                     length: max(0, block.length + delta)))
        }
    }

    // MARK: Auto-closing pairs

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        dismissHover()
        guard let typed = insertString as? String, typed.count == 1 else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let after = selection.location + selection.length < content.length
            ? content.substring(with: NSRange(location: selection.location + selection.length,
                                              length: 1))
            : ""
        let before = selection.location > 0
            ? content.substring(with: NSRange(location: selection.location - 1, length: 1)) : ""

        // Typing the closer that is already there just steps over it.
        if selection.length == 0, after == typed,
           language.autoClosePairs.contains(where: { $0.1 == typed }) {
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }

        guard let pair = language.autoClosePairs.first(where: { $0.0 == typed }) else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        // Wrap a selection in the pair rather than replacing it.
        if selection.length > 0 {
            let selected = content.substring(with: selection)
            typeRaw(pair.0 + selected + pair.1, replacing: selection)
            setSelectedRange(NSRange(location: selection.location + 1,
                                     length: (selected as NSString).length))
            return
        }

        // An apostrophe in `don't` is not an opening quote.
        if pair.0 == pair.1 {
            let previous = before.first
            if let previous, previous.isLetter || previous.isNumber || previous == "_" {
                super.insertText(insertString, replacementRange: replacementRange)
                return
            }
        }
        // Do not close in front of a word — you are almost always editing existing text.
        if let next = after.first, next.isLetter || next.isNumber || next == "_" {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        typeRaw(pair.0 + pair.1, replacing: selection)
        setSelectedRange(NSRange(location: selection.location + (pair.0 as NSString).length,
                                 length: 0))
    }

    override func deleteBackward(_ sender: Any?) {
        dismissHover()
        let selection = selectedRange()
        guard selection.length == 0, selection.location > 0 else {
            super.deleteBackward(sender)
            return
        }
        let before = content.substring(with: NSRange(location: selection.location - 1, length: 1))
        let after = selection.location < content.length
            ? content.substring(with: NSRange(location: selection.location, length: 1)) : ""

        // Backspacing between a freshly closed pair removes both halves.
        if language.autoClosePairs.contains(where: { $0.0 == before && $0.1 == after }) {
            typeRaw("", replacing: NSRange(location: selection.location - 1, length: 2))
            return
        }

        // Backspacing through indentation removes a whole level.
        let line = lineRange(at: selection.location)
        let head = content.substring(with: NSRange(location: line.location,
                                                   length: selection.location - line.location))
        let unitWidth = language.indentUnit == "\t" ? 1 : language.indentUnit.count
        if !head.isEmpty, head.allSatisfy({ $0 == " " }), head.count % unitWidth == 0,
           unitWidth > 1 {
            typeRaw("", replacing: NSRange(location: selection.location - unitWidth,
                                           length: unitWidth))
            return
        }
        super.deleteBackward(sender)
    }

    // MARK: Commands

    @objc func toggleLineComment(_ sender: Any?) {
        let selection = selectedRange()
        let block = content.lineRange(for: selection)
        guard block.length > 0 || content.length > 0 else { return }
        let original = content.substring(with: block)
        let hadTrailingNewline = original.hasSuffix("\n")
        var lines = original.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }
        guard !lines.isEmpty else { return }

        if let marker = language.lineComment {
            let meaningful = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let allCommented = !meaningful.isEmpty && meaningful.allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
            }
            let indent = meaningful
                .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
                .min() ?? 0
            lines = lines.map { line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
                if allCommented {
                    guard let markerRange = line.range(of: marker) else { return line }
                    var stripped = line
                    var end = markerRange.upperBound
                    if end < stripped.endIndex, stripped[end] == " " {
                        end = stripped.index(after: end)
                    }
                    stripped.removeSubrange(markerRange.lowerBound..<end)
                    return stripped
                }
                let cut = line.index(line.startIndex, offsetBy: min(indent, line.count))
                return String(line[line.startIndex..<cut]) + marker + " "
                    + String(line[cut...])
            }
        } else if let block = language.blockComment {
            let joined = lines.joined(separator: "\n")
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(block.open) && trimmed.hasSuffix(block.close) {
                var inner = trimmed
                inner.removeFirst(block.open.count)
                inner.removeLast(block.close.count)
                lines = inner.trimmingCharacters(in: .whitespaces).components(separatedBy: "\n")
            } else {
                lines = ["\(block.open) \(joined) \(block.close)"]
            }
        } else {
            NSSound.beep()
            return
        }

        var replacement = lines.joined(separator: "\n")
        if hadTrailingNewline { replacement += "\n" }
        typeRaw(replacement, replacing: block)
        let delta = (replacement as NSString).length - block.length
        setSelectedRange(NSRange(location: block.location,
                                 length: max(0, block.length + delta)))
    }

    @objc func editSelectionWithAgent(_ sender: Any?) {
        var selection = selectedRange()
        if selection.length == 0 { selection = content.lineRange(for: selection) }
        guard selection.length > 0, NSMaxRange(selection) <= content.length else { return }
        onEditWithAgent?(selection, content.substring(with: selection))
    }

    /// Applies an agent's replacement only if the range still holds what the agent saw, and
    /// registers it with the undo manager like typed text.
    func replaceForInlineEdit(range: NSRange, expecting original: String, with text: String) -> Bool {
        guard NSMaxRange(range) <= content.length, content.substring(with: range) == original else { return false }
        guard shouldChangeText(in: range, replacementString: text) else { return false }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: (text as NSString).length))
        return true
    }

    @objc func duplicateLine(_ sender: Any?) {
        let block = content.lineRange(for: selectedRange())
        let text = content.substring(with: block)
        let insertion = text.hasSuffix("\n") ? text : "\n" + text
        let at = NSRange(location: block.location + block.length, length: 0)
        typeRaw(insertion, replacing: at)
        setSelectedRange(NSRange(location: at.location + (insertion as NSString).length
                                 - block.length, length: 0))
    }

    @objc func deleteCurrentLine(_ sender: Any?) {
        let block = content.lineRange(for: selectedRange())
        typeRaw("", replacing: block)
        setSelectedRange(NSRange(location: min(block.location, (string as NSString).length),
                                 length: 0))
    }

    func goToLine(_ line: Int) {
        guard let range = decorator?.range(ofLine: line) else { return }
        setSelectedRange(NSRange(location: range.location, length: 0))
        scrollRangeToVisible(range)
        // Centre it rather than leaving it at the very bottom of the view.
        if let scrollView = enclosingScrollView, let layoutManager, let container = textContainer {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                                      actualCharacterRange: nil)
            let box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let target = max(0, box.midY - scrollView.contentSize.height / 2)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func select(_ range: NSRange) {
        let length = (string as NSString).length
        let safe = NSRange(location: min(range.location, length),
                           length: min(range.length, max(0, length - min(range.location, length))))
        setSelectedRange(safe)
        scrollRangeToVisible(safe)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "s" {
            onSaveRequested?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        dismissHover()
        guard !suppressCompletion else { return }
        if isCompletionVisible {
            refilterCompletionsOrDismiss()
            if let last = lastTypedCharacter(), last == "." {
                scheduleCompletions()
            }
        } else if shouldRequestCompletions() {
            scheduleCompletions()
        }
    }

    // MARK: - Hover, go-to-definition, completions

    var isCompletionVisible: Bool { completionPopup?.superview != nil }
    var isHoverVisible: Bool { hoverCard?.superview != nil }
    var completionLabels: [String] { completionPopup?.labels ?? [] }
    var selectedCompletionLabel: String? { completionPopup?.selectedItem?.label }
    var hoverDisplayedText: String? { hoverCard?.displayedText }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
        guard window != nil else { return }
        // The representable's first update can precede its real viewport size. Reserve the
        // line-number gutter after mounting so it does not cover the first characters.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            (self.enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.reserveSpace()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if let popup = completionPopup, popup.superview != nil {
            let inPopup = popup.convert(event.locationInWindow, from: nil)
            if popup.bounds.contains(inPopup) { return }
        }
        if isHoverVisible {
            let dx = point.x - hoverAnchor.x
            let dy = point.y - hoverAnchor.y
            if dx * dx + dy * dy > 16 { dismissHover() }
        }
        hoverAnchor = point
        hoverToken += 1
        let token = hoverToken
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            let nanos = UInt64(CodeTextView.hoverDwellSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self, self.hoverToken == token else { return }
            self.fireHover(at: point, token: token)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        dismissHover()
        hoverTask?.cancel()
    }

    override func mouseDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if command {
            let point = convert(event.locationInWindow, from: nil)
            if let (line, column) = lineColumn(atViewPoint: point) {
                onRequestDefinition?(line, column)
            }
            return
        }
        dismissHover()
        if isCompletionVisible { dismissCompletions() }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        dismissHover()
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isCompletionVisible {
            switch event.keyCode {
            case 126: moveCompletionHighlight(-1); return
            case 125: moveCompletionHighlight(1); return
            case 36, 76: _ = acceptCompletion(); return
            case 48: _ = acceptCompletion(); return
            case 53: dismissCompletions(); return
            default: break
            }
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .control, event.charactersIgnoringModifiers == " " {
            scheduleCompletions(immediate: true)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if isCompletionVisible || isHoverVisible {
            dismissCompletions()
            dismissHover()
            return
        }
        super.cancelOperation(sender)
    }

    override func moveUp(_ sender: Any?) {
        if isCompletionVisible { moveCompletionHighlight(-1); return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if isCompletionVisible { moveCompletionHighlight(1); return }
        super.moveDown(sender)
    }

    override func moveLeft(_ sender: Any?) {
        if isCompletionVisible { dismissCompletions() }
        dismissHover()
        super.moveLeft(sender)
    }

    override func moveRight(_ sender: Any?) {
        if isCompletionVisible { dismissCompletions() }
        dismissHover()
        super.moveRight(sender)
    }

    func dismissHover() {
        hoverToken += 1
        hoverTask?.cancel()
        hoverCard?.removeFromSuperview()
        hoverCard = nil
    }

    func presentHover(_ text: String) {
        let trimmed = HoverCardView.plain(text)
        guard !trimmed.isEmpty else { return }
        let card = hoverCard ?? HoverCardView(frame: .zero)
        card.setText(trimmed)
        if card.superview == nil {
            overlayHost().addSubview(card)
        }
        hoverCard = card
        let anchor = (hoverAnchor.x == 0 && hoverAnchor.y == 0) ? caretPoint() : hoverAnchor
        position(card, below: anchor)
    }

    func dismissCompletions() {
        completionToken += 1
        completionTask?.cancel()
        completionPopup?.removeFromSuperview()
        completionPopup = nil
        completionItems = []
    }

    func presentCompletions(_ items: [LSPCompletionItem], prefix: String? = nil) {
        let prefix = prefix ?? identifierPrefix()
        completionItems = items
        guard !items.isEmpty else {
            dismissCompletions()
            return
        }
        let popup = completionPopup ?? CompletionPopupView(frame: .zero)
        popup.onAccept = { [weak self] item in
            self?.applyCompletion(item)
        }
        popup.setItems(items, prefix: prefix)
        if popup.visibleItems.isEmpty {
            popup.removeFromSuperview()
            completionPopup = nil
            return
        }
        if popup.superview == nil {
            overlayHost().addSubview(popup)
        }
        completionPopup = popup
        position(popup, below: caretPoint())
    }

    func moveCompletionHighlight(_ delta: Int) {
        completionPopup?.move(delta)
    }

    @discardableResult
    func acceptCompletion() -> Bool {
        guard isCompletionVisible, let item = completionPopup?.selectedItem else { return false }
        applyCompletion(item)
        return true
    }

    func receiveCompletions(_ items: [LSPCompletionItem], token: Int) {
        guard token == completionToken else { return }
        presentCompletions(items)
    }

    func receiveHover(_ text: String?, token: Int) {
        guard token == hoverToken else { return }
        if let text, !text.isEmpty {
            presentHover(text)
        }
    }

    func lineColumn(atViewPoint point: NSPoint) -> (line: Int, column: Int)? {
        let index = characterIndexForInsertion(at: point)
        return lineColumn(atUTF16: index)
    }

    func lineColumn(atUTF16 index: Int) -> (line: Int, column: Int)? {
        let bounded = min(max(0, index), (string as NSString).length)
        if let decorator {
            let line = decorator.lineNumber(at: bounded)
            let start = decorator.range(ofLine: line)?.location ?? 0
            return (line, max(1, bounded - start + 1))
        }
        let ns = string as NSString
        var line = 1
        var start = 0
        var cursor = 0
        while cursor < bounded {
            let range = ns.lineRange(for: NSRange(location: cursor, length: 0))
            if NSMaxRange(range) <= bounded {
                line += 1
                start = NSMaxRange(range)
                cursor = start
            } else {
                start = range.location
                break
            }
        }
        return (line, max(1, bounded - start + 1))
    }

    // MARK: Completions internals

    private func shouldRequestCompletions() -> Bool {
        if identifierPrefix().count >= 1 { return true }
        return lastTypedCharacter() == "."
    }

    private func lastTypedCharacter() -> String? {
        let caret = selectedRange().location
        guard caret > 0 else { return nil }
        return content.substring(with: NSRange(location: caret - 1, length: 1))
    }

    private func identifierPrefix() -> String {
        content.substring(with: identifierPrefixRange())
    }

    private func identifierPrefixRange() -> NSRange {
        let ns = content
        let caret = min(selectedRange().location, ns.length)
        var start = caret
        let ident = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "_"))
        while start > 0 {
            let ch = ns.substring(with: NSRange(location: start - 1, length: 1))
            guard let scalar = ch.unicodeScalars.first, ident.contains(scalar) else { break }
            start -= 1
        }
        return NSRange(location: start, length: caret - start)
    }

    private func scheduleCompletions(immediate: Bool = false) {
        completionToken += 1
        let token = completionToken
        completionTask?.cancel()
        completionTask = Task { @MainActor [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard !Task.isCancelled, let self, self.completionToken == token else { return }
            self.requestCompletions(token: token)
        }
    }

    private func requestCompletions(token: Int) {
        guard let (line, column) = lineColumn(atUTF16: selectedRange().location) else { return }
        onRequestCompletions?(line, column, token)
    }

    private func fireHover(at point: NSPoint, token: Int) {
        guard !isCompletionVisible else { return }
        guard let (line, column) = lineColumn(atViewPoint: point) else { return }
        onRequestHover?(line, column, token)
    }

    private func refilterCompletionsOrDismiss() {
        guard let popup = completionPopup, popup.superview != nil else { return }
        let prefix = identifierPrefix()
        popup.applyFilter(prefix)
        if popup.visibleItems.isEmpty {
            dismissCompletions()
            return
        }
        position(popup, below: caretPoint())
    }

    private func applyCompletion(_ item: LSPCompletionItem) {
        suppressCompletion = true
        defer { suppressCompletion = false }
        let ns = content
        if let range = item.editRange,
           range.location >= 0, NSMaxRange(range) <= ns.length {
            typeRaw(item.insertText, replacing: range)
            setSelectedRange(NSRange(location: range.location + (item.insertText as NSString).length,
                                     length: 0))
        } else {
            let prefixRange = identifierPrefixRange()
            typeRaw(item.insertText, replacing: prefixRange)
            setSelectedRange(NSRange(location: prefixRange.location
                                     + (item.insertText as NSString).length, length: 0))
        }
        dismissCompletions()
    }

    private func overlayHost() -> NSView { self }

    private func caretPoint() -> NSPoint {
        var actual = NSRange()
        let rect = firstRect(forCharacterRange: selectedRange(), actualRange: &actual)
        let windowPoint: NSPoint
        if let window {
            windowPoint = window.convertPoint(fromScreen: NSPoint(x: rect.minX, y: rect.minY))
            return convert(windowPoint, from: nil)
        }
        if let layoutManager, let container = textContainer {
            let glyph = layoutManager.glyphRange(forCharacterRange: selectedRange(),
                                                 actualCharacterRange: nil)
            let box = layoutManager.boundingRect(forGlyphRange: glyph, in: container)
            return NSPoint(x: box.minX + textContainerOrigin.x,
                           y: box.minY + textContainerOrigin.y)
        }
        return NSPoint(x: 8, y: 8)
    }

    private func position(_ overlay: NSView, below point: NSPoint) {
        let host = overlayHost()
        var local = host.convert(point, from: self)
        let size = overlay.intrinsicContentSize.width > 0
            ? overlay.intrinsicContentSize : overlay.frame.size
        overlay.frame.size = size
        // NSView is not flipped here: origin is bottom-left. Place the popup just below the caret
        // in screen terms, which is a smaller y in this coordinate system when the caret is above.
        local.y -= size.height + 2
        local.x = max(0, local.x)
        if local.y < 0 { local.y = point.y + 4 }
        overlay.frame.origin = local
    }
}

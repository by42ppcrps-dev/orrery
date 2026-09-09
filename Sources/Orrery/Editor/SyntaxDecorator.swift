import AppKit

/// Owns the highlighting of one text storage. Lives on the document rather than the view, so a
/// file's colouring and its line index are correct even when nothing is on screen — which is
/// what lets `--audit` exercise this whole path headlessly.
@MainActor
final class SyntaxDecorator: NSObject, @preconcurrency NSTextStorageDelegate {
    private(set) var language: Language
    private let highlighter: IncrementalHighlighter
    private weak var storage: NSTextStorage?
    /// UTF-16 offset of the first character of each line. Kept here because the ruler needs it
    /// on every scroll and recomputing it from the string each time is O(document).
    private(set) var lineStartOffsets: [Int] = [0]

    var diagnostics: [Diagnostic] = [] {
        didSet { if diagnostics != oldValue { applyDiagnostics() } }
    }
    /// Called after each re-highlight so the ruler can redraw its diagnostic marks.
    var onRehighlight: (() -> Void)?
    /// Called when characters changed, whoever changed them. The document uses this to track
    /// dirtiness, so a programmatic edit is not silently treated as saved.
    var onCharactersChanged: (() -> Void)?

    init(language: Language) {
        self.language = language
        self.highlighter = IncrementalHighlighter(language: language)
        super.init()
    }

    func attach(to storage: NSTextStorage) {
        self.storage = storage
        storage.delegate = self
        rehighlightAll()
    }

    func setLanguage(_ language: Language) {
        guard language.id != self.language.id else { return }
        self.language = language
        rehighlightAll()
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        // Tab stops sized to the language's own indent unit, so a file that uses tabs lines up
        // the way the rest of that project's tooling shows it.
        let width = CGFloat(max(2, language.indentUnit == "\t" ? 4 : language.indentUnit.count))
        let advance = EditorTheme.font.maximumAdvancement.width
        paragraph.defaultTabInterval = width * advance
        paragraph.tabStops = []
        paragraph.lineHeightMultiple = 1.15
        return [.font: EditorTheme.font,
                .foregroundColor: EditorTheme.plain,
                .paragraphStyle: paragraph]
    }

    func rehighlightAll() {
        guard let storage else { return }
        let text = storage.string
        let tokens = highlighter.setLanguage(language, text: text)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: whole)
        apply(tokens, in: storage)
        storage.endEditing()
        recomputeLineStarts()
        applyDiagnostics()
        onRehighlight?()
    }

    func textStorage(_ storage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let text = storage.string
        let (dirty, tokens) = highlighter.update(text, editedRange: editedRange)
        let length = (text as NSString).length
        let safe = NSRange(location: min(dirty.location, length),
                           length: min(dirty.length, max(0, length - min(dirty.location, length))))
        // Attribute-only edits inside this callback are allowed; character edits are not.
        storage.setAttributes(baseAttributes, range: safe)
        apply(tokens, in: storage)
        recomputeLineStarts()
        applyDiagnostics(limitedTo: safe)
        onRehighlight?()
        onCharactersChanged?()
    }

    private func apply(_ tokens: [Token], in storage: NSTextStorage) {
        let length = storage.length
        for token in tokens {
            let range = NSRange(location: token.range.location,
                                length: min(token.range.length,
                                            max(0, length - token.range.location)))
            guard range.location >= 0, range.location < length, range.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: EditorTheme.color(for: token.kind),
                                 range: range)
            if let traits = EditorTheme.traits(for: token.kind) {
                storage.addAttribute(.font, value: EditorTheme.font(traits), range: range)
            }
        }
    }

    private func recomputeLineStarts() {
        guard let storage else { return }
        let text = storage.string as NSString
        var starts: [Int] = [0]
        var index = 0
        while index < text.length {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                              for: NSRange(location: index, length: 0))
            if lineEnd <= index { break }
            // A line only starts another one when it actually ended with a terminator. A file
            // whose last line has no newline must not gain a phantom empty line; one that ends
            // with a newline must, because the editor shows a caret position there.
            if contentsEnd < lineEnd { starts.append(lineEnd) }
            index = lineEnd
        }
        lineStartOffsets = starts
    }

    /// 1-based line number containing a UTF-16 offset.
    func lineNumber(at offset: Int) -> Int {
        var low = 0, high = lineStartOffsets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStartOffsets[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// UTF-16 range of a 1-based line, excluding its terminator.
    func range(ofLine line: Int) -> NSRange? {
        guard let storage, line >= 1, line <= lineStartOffsets.count else { return nil }
        let text = storage.string as NSString
        let start = lineStartOffsets[line - 1]
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                          for: NSRange(location: min(start, text.length), length: 0))
        return NSRange(location: lineStart, length: max(0, contentsEnd - lineStart))
    }

    private func applyDiagnostics(limitedTo limit: NSRange? = nil) {
        guard let storage else { return }
        let text = storage.string as NSString
        let scope = limit ?? NSRange(location: 0, length: text.length)
        guard scope.length >= 0, scope.location >= 0,
              scope.location + scope.length <= text.length else { return }
        if limit == nil {
            storage.removeAttribute(.underlineStyle, range: scope)
            storage.removeAttribute(.underlineColor, range: scope)
        }
        for diagnostic in diagnostics {
            guard let range = diagnostic.range(in: text) else { continue }
            let clipped = range.clamped(to: scope)
            guard clipped.length > 0 else { continue }
            storage.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.thick.rawValue
                                 | NSUnderlineStyle.patternDot.rawValue,
                                 range: clipped)
            storage.addAttribute(.underlineColor, value: tint(diagnostic.severity), range: clipped)
        }
    }

    private func tint(_ severity: Diagnostic.Severity) -> NSColor {
        switch severity {
        case .error: return EditorTheme.errorTint
        case .warning: return EditorTheme.warningTint
        case .info: return EditorTheme.infoTint
        }
    }

    /// Worst severity on each 1-based line, for the gutter.
    func severityByLine() -> [Int: Diagnostic.Severity] {
        var result: [Int: Diagnostic.Severity] = [:]
        for diagnostic in diagnostics {
            if let existing = result[diagnostic.line], existing <= diagnostic.severity { continue }
            result[diagnostic.line] = diagnostic.severity
        }
        return result
    }
}

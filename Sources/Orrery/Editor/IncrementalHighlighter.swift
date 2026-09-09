import Foundation

/// Keeps a document's syntax colouring current without re-tokenizing the whole file on every
/// keystroke.
///
/// Measured on this machine: a full pass over a 1 MB Swift file takes ~195 ms, which is far too
/// slow to run per keystroke. Building `SourceText` is ~11 ms/MB, so the strategy is to rebuild
/// that cheap index every edit and re-tokenize only from the start of the edited line forward,
/// stopping as soon as the scanner's line-end state matches what it was before the edit. Typing
/// inside a function re-scans one line; typing `/*` re-scans until the next `*/`.
///
/// `--audit` proves the incremental result is identical to a full pass after random edits, which
/// is the only way this optimization is safe to keep.
@MainActor
final class IncrementalHighlighter {
    private(set) var language: Language
    private(set) var source: SourceText
    /// State the scanner is in at the end of each line that has a trailing newline.
    /// `lineEndStates.count == source.lineCount - 1`.
    private var lineEndStates: [ScanState] = []

    init(language: Language, text: String = "") {
        self.language = language
        self.source = SourceText(text)
        _ = rebuild(text)
    }

    /// Full re-tokenize. Returns every token in the document.
    @discardableResult
    func rebuild(_ text: String) -> [Token] {
        source = SourceText(text)
        var tokens: [Token] = []
        var states: [ScanState] = []
        _ = Tokenizer.scan(source, 0..<source.count, language, initial: .normal,
                           tokens: &tokens, lineEndStates: &states)
        lineEndStates = normalize(states, lineCount: source.lineCount)
        return tokens
    }

    func setLanguage(_ language: Language, text: String) -> [Token] {
        self.language = language
        return rebuild(text)
    }

    /// Re-tokenize just enough of `text` to account for an edit at `editedRange`
    /// (a UTF-16 range in the *new* text). Returns the UTF-16 range whose colouring must be
    /// cleared and re-applied, together with the tokens for it.
    func update(_ text: String, editedRange: NSRange) -> (NSRange, [Token]) {
        let previousStates = lineEndStates
        let previousLineCount = previousStates.count + 1
        source = SourceText(text)
        let lineCount = source.lineCount

        let editStartChar = source.charIndex(utf16Offset: max(0, editedRange.location))
        let editEndChar = source.charIndex(
            utf16Offset: max(0, editedRange.location + max(0, editedRange.length)))
        let firstLine = source.lineIndex(containing: editStartChar)

        // Lines before the edited one are untouched, so their end states carry over unchanged.
        var states = Array(previousStates.prefix(min(firstLine, previousStates.count)))
        var state: ScanState = firstLine == 0
            ? .normal
            : (firstLine - 1 < previousStates.count ? previousStates[firstLine - 1] : .normal)

        let lineDelta = lineCount - previousLineCount
        var tokens: [Token] = []
        var line = firstLine
        var scannedEnd = source.lineStarts[min(firstLine, max(0, lineCount - 1))]
        var converged = false

        while line < lineCount {
            let range = source.lineRange(line)
            var produced: [ScanState] = []
            let endState = Tokenizer.scan(source, range, language, initial: state,
                                          tokens: &tokens, lineEndStates: &produced)
            scannedEnd = range.upperBound

            guard line + 1 < lineCount else { break }   // last line has no end state to record
            let recorded = produced.last ?? endState
            states.append(recorded)
            state = recorded

            // Past the edit and back in step with the previous run: everything below is
            // unaffected, so stop and reuse the old states.
            let previousIndex = line - lineDelta
            if range.lowerBound >= editEndChar, previousIndex >= 0,
               previousIndex < previousStates.count, previousStates[previousIndex] == recorded {
                states.append(contentsOf: previousStates[(previousIndex + 1)...])
                converged = true
                line += 1
                break
            }
            line += 1
        }

        lineEndStates = normalize(states, lineCount: lineCount)

        let startChar = source.lineStarts[min(firstLine, max(0, lineCount - 1))]
        let endChar = converged ? scannedEnd : source.count
        let location = source.starts[min(startChar, source.count)]
        let end = source.starts[min(max(endChar, startChar), source.count)]
        return (NSRange(location: location, length: end - location), tokens)
    }

    /// A scanner should emit exactly one state per newline. Pad or trim if one ever does not,
    /// so a grammar bug cannot corrupt the line index and mis-colour the rest of the file.
    private func normalize(_ states: [ScanState], lineCount: Int) -> [ScanState] {
        let wanted = max(0, lineCount - 1)
        if states.count == wanted { return states }
        if states.count > wanted { return Array(states.prefix(wanted)) }
        return states + Array(repeating: states.last ?? .normal, count: wanted - states.count)
    }
}

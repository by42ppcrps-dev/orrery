import Foundation

// MARK: - Scanner state

/// What the scanner is in the middle of at a line boundary. Anything that can straddle a
/// newline has to live here, or incremental re-highlighting after an edit gets it wrong.
enum ScanState: Equatable, Sendable {
    case normal
    case blockComment(depth: Int, doc: Bool)
    case multilineString(rule: Int)
    case markdownFence(info: String)
    case xmlComment
    case xmlCData
    /// Inside `<script>` or `<style>`, where the body is a different language.
    case xmlRaw(tag: String)
    /// Between `<name` and its `>`, scanning attributes. A tag may span lines.
    case xmlTag(tag: String, closing: Bool)
    /// Inside a quoted attribute value, which may also span lines.
    case xmlAttribute(tag: String, closing: Bool, quote: String)
    case yamlBlockScalar(indent: Int)
}

// MARK: - Document view

/// A string as characters plus their UTF-16 offsets, so token ranges line up with NSTextStorage
/// even when the file contains emoji or CJK.
struct SourceText {
    let chars: [Character]
    /// `starts[i]` is the UTF-16 offset of `chars[i]`; `starts[count]` is the total length.
    let starts: [Int]
    /// Character index of the first character of each line. Always begins with 0, so a document
    /// has `lineStarts.count` lines even when it ends without a newline.
    let lineStarts: [Int]

    init(_ text: String) {
        var chars: [Character] = []
        chars.reserveCapacity(text.count)
        var starts: [Int] = []
        starts.reserveCapacity(text.count + 1)
        var lineStarts: [Int] = [0]
        var offset = 0
        var index = 0
        for character in text {
            chars.append(character)
            starts.append(offset)
            offset += character.utf16.count
            index += 1
            // `isNewline` rather than `== "\n"`: Swift reads CRLF as a single Character, so a
            // Windows file would otherwise scan as one very long line.
            if character.isNewline { lineStarts.append(index) }
        }
        starts.append(offset)
        self.chars = chars
        self.starts = starts
        self.lineStarts = lineStarts
    }

    var count: Int { chars.count }
    var utf16Length: Int { starts[starts.count - 1] }
    var lineCount: Int { lineStarts.count }

    /// Character index of the first character at or after `utf16Offset`.
    func charIndex(utf16Offset: Int) -> Int {
        if utf16Offset <= 0 { return 0 }
        if utf16Offset >= utf16Length { return count }
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] < utf16Offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Index of the line containing `charIndex`.
    func lineIndex(containing charIndex: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= charIndex { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Character range of line `index`, including its trailing newline when it has one.
    func lineRange(_ index: Int) -> Range<Int> {
        guard index >= 0, index < lineStarts.count else { return count..<count }
        let start = lineStarts[index]
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] : count
        return start..<end
    }

    /// Clamped on purpose. A token range is used to colour text on every keystroke; a scanner
    /// bug should show up as a mis-coloured word, never as a crash in the user's editor.
    func range(_ from: Int, _ to: Int) -> NSRange {
        let low = min(max(0, from), count)
        let high = min(max(low, to), count)
        return NSRange(location: starts[low], length: starts[high] - starts[low])
    }

    func matches(_ needle: String, at index: Int) -> Bool {
        let needleChars = Array(needle)
        guard index + needleChars.count <= chars.count else { return false }
        for (offset, character) in needleChars.enumerated()
        where chars[index + offset] != character { return false }
        return true
    }

    func text(_ from: Int, _ to: Int) -> String {
        guard from < to, to <= chars.count else { return "" }
        return String(chars[from..<to])
    }
}

// MARK: - Tokenizer

enum Tokenizer {

    /// Tokenize a whole string. Used for tests, for short files, and as the reference the
    /// incremental path is checked against.
    static func tokens(for text: String, language: Language) -> [Token] {
        let source = SourceText(text)
        var out: [Token] = []
        var states: [ScanState] = []
        _ = scan(source, 0..<source.count, language, initial: .normal,
                 tokens: &out, lineEndStates: &states)
        return out
    }

    /// Scan a character-index range and return the state at its end. `lineEndStates` receives
    /// one entry per newline consumed, in order.
    @discardableResult
    static func scan(_ source: SourceText, _ unclamped: Range<Int>, _ language: Language,
                     initial: ScanState, tokens: inout [Token],
                     lineEndStates: inout [ScanState]) -> ScanState {
        let lower = min(max(0, unclamped.lowerBound), source.count)
        let range = lower..<min(max(lower, unclamped.upperBound), source.count)
        switch language.grammar {
        case let .code(rules):
            return scanCode(source, range, rules, initial: initial,
                            tokens: &tokens, lineEndStates: &lineEndStates)
        case .json:
            return scanJSON(source, range, initial: initial,
                            tokens: &tokens, lineEndStates: &lineEndStates)
        case .markdown:
            return scanMarkdown(source, range, initial: initial,
                                tokens: &tokens, lineEndStates: &lineEndStates)
        case .xml:
            return scanXML(source, range, initial: initial,
                           tokens: &tokens, lineEndStates: &lineEndStates)
        case .yaml:
            return scanYAML(source, range, initial: initial,
                            tokens: &tokens, lineEndStates: &lineEndStates)
        case .ini:
            return scanINI(source, range, initial: initial,
                           tokens: &tokens, lineEndStates: &lineEndStates)
        case .plain:
            for index in range where source.chars[index].isNewline { lineEndStates.append(.normal) }
            return .normal
        }
    }

    // MARK: - Shared helpers

    private static func isIdentifierStart(_ character: Character, _ extras: Set<Character>) -> Bool {
        character.isLetter || extras.contains(character)
    }

    private static func isIdentifierPart(_ character: Character, _ extras: Set<Character>) -> Bool {
        character.isLetter || character.isNumber || extras.contains(character)
    }

    private static func emit(_ tokens: inout [Token], _ source: SourceText,
                             _ from: Int, _ to: Int, _ kind: TokenKind) {
        guard to > from, from < source.count, to > 0 else { return }
        let range = source.range(from, to)
        guard range.length > 0 else { return }
        tokens.append(Token(range: range, kind: kind))
    }

    /// Index just past the run of horizontal whitespace starting at `index`.
    private static func skipSpaces(_ source: SourceText, _ index: Int, _ limit: Int) -> Int {
        var i = index
        while i < limit, source.chars[i] == " " || source.chars[i] == "\t" { i += 1 }
        return i
    }

    private static func lineEnd(_ source: SourceText, _ index: Int, _ limit: Int) -> Int {
        var i = index
        while i < limit, !source.chars[i].isNewline { i += 1 }
        return i
    }

    // MARK: - Code

    private static func scanCode(_ source: SourceText, _ range: Range<Int>, _ rules: CodeRules,
                                 initial: ScanState, tokens: inout [Token],
                                 lineEndStates: inout [ScanState]) -> ScanState {
        let chars = source.chars
        let limit = range.upperBound
        var index = range.lowerBound
        var state = initial
        // Longest opener first, so `"""` is never mistaken for `"` and `///` never for `//`.
        let stringRules = rules.strings.enumerated()
            .sorted { $0.element.open.count > $1.element.open.count }
        let lineCommentMarkers = (rules.docLineComments.map { ($0, TokenKind.docComment) }
                                  + rules.lineComments.map { ($0, TokenKind.comment) })
            .sorted { $0.0.count > $1.0.count }
        /// True at the very start of the scanned range only when that is also the file start.
        var atFileStart = range.lowerBound == 0

        while index < limit {
            switch state {

            case let .blockComment(depth, isDoc):
                let start = index
                var currentDepth = depth
                var done = false
                while index < limit {
                    if chars[index].isNewline {
                        emit(&tokens, source, start, index, isDoc ? .docComment : .comment)
                        lineEndStates.append(.blockComment(depth: currentDepth, doc: isDoc))
                        index += 1
                        state = .blockComment(depth: currentDepth, doc: isDoc)
                        done = true
                        break
                    }
                    if let close = rules.blockCommentClose, source.matches(close, at: index) {
                        currentDepth -= 1
                        index += close.count
                        if currentDepth <= 0 {
                            emit(&tokens, source, start, index, isDoc ? .docComment : .comment)
                            state = .normal
                            done = true
                            break
                        }
                        continue
                    }
                    if rules.nestedBlockComments, let open = rules.blockCommentOpen,
                       source.matches(open, at: index) {
                        currentDepth += 1
                        index += open.count
                        continue
                    }
                    index += 1
                }
                if !done {
                    emit(&tokens, source, start, index, isDoc ? .docComment : .comment)
                    state = .blockComment(depth: currentDepth, doc: isDoc)
                }

            case let .multilineString(ruleIndex):
                guard ruleIndex < rules.strings.count else { state = .normal; continue }
                index = scanStringBody(source, index, limit, rules, rules.strings[ruleIndex],
                                       ruleIndex, tokens: &tokens,
                                       lineEndStates: &lineEndStates, state: &state)

            default:
                let character = chars[index]

                if character.isNewline {
                    lineEndStates.append(.normal)
                    index += 1
                    atFileStart = false
                    continue
                }
                if character == " " || character == "\t" || character == "\r" {
                    index += 1
                    continue
                }

                // `#!/usr/bin/env python3`
                if atFileStart, rules.honorsShebang, source.matches("#!", at: index) {
                    let end = lineEnd(source, index, limit)
                    emit(&tokens, source, index, end, .comment)
                    index = end
                    atFileStart = false
                    continue
                }
                atFileStart = false

                // Comments before everything else — a `//` inside code is never a divide.
                var matchedComment = false
                for (marker, kind) in lineCommentMarkers where source.matches(marker, at: index) {
                    let end = lineEnd(source, index, limit)
                    emit(&tokens, source, index, end, kind)
                    index = end
                    matchedComment = true
                    break
                }
                if matchedComment { continue }

                if let open = rules.blockCommentOpen, source.matches(open, at: index) {
                    let isDoc = rules.docBlockOpen.map { source.matches($0, at: index) } ?? false
                    index += open.count
                    state = .blockComment(depth: 1, doc: isDoc)
                    // Re-enter the block-comment arm with the opener already consumed; the
                    // opener itself is coloured by the token the arm emits from `start`.
                    let openStart = index - open.count
                    tokens.append(Token(range: source.range(openStart, index),
                                        kind: isDoc ? .docComment : .comment))
                    continue
                }

                // Strings. A rule whose opener begins with a letter (r"…, f'…, b"…) only counts
                // when it is not the tail of a longer identifier.
                var matchedString = false
                for (ruleIndex, rule) in stringRules where source.matches(rule.open, at: index) {
                    if let first = rule.open.first, first.isLetter,
                       index > 0, isIdentifierPart(chars[index - 1], rules.identifierExtras) {
                        continue
                    }
                    emit(&tokens, source, index, index + rule.open.count, .string)
                    index += rule.open.count
                    if rule.multiline { state = .multilineString(rule: ruleIndex) }
                    index = scanStringBody(source, index, limit, rules, rule, ruleIndex,
                                           tokens: &tokens, lineEndStates: &lineEndStates,
                                           state: &state)
                    matchedString = true
                    break
                }
                if matchedString { continue }

                if character.isNumber {
                    let end = scanNumber(source, index, limit, rules)
                    emit(&tokens, source, index, end, .number)
                    index = end
                    continue
                }
                // `.5`
                if character == ".", index + 1 < limit, chars[index + 1].isNumber {
                    let end = scanNumber(source, index + 1, limit, rules)
                    emit(&tokens, source, index, end, .number)
                    index = end
                    continue
                }

                // @attribute / #[attribute]
                if rules.attributeStarts.contains(character), index + 1 < limit {
                    let next = chars[index + 1]
                    if isIdentifierStart(next, rules.identifierExtras) {
                        var end = index + 1
                        while end < limit,
                              isIdentifierPart(chars[end], rules.identifierExtras)
                                || chars[end] == "." { end += 1 }
                        emit(&tokens, source, index, end, .attribute)
                        index = end
                        continue
                    }
                    if next == "[" {
                        emit(&tokens, source, index, index + 2, .attribute)
                        index += 2
                        continue
                    }
                }

                // #directive, $variable
                if rules.directiveStarts.contains(character), index + 1 < limit {
                    let next = chars[index + 1]
                    if isIdentifierStart(next, rules.identifierExtras) || next.isNumber {
                        var end = index + 1
                        while end < limit,
                              isIdentifierPart(chars[end], rules.identifierExtras) { end += 1 }
                        emit(&tokens, source, index, end, .directive)
                        index = end
                        continue
                    }
                    if next == "{" || next == "(" {
                        emit(&tokens, source, index, index + 2, .directive)
                        index += 2
                        continue
                    }
                }

                if isIdentifierStart(character, rules.identifierExtras) {
                    var end = index + 1
                    while end < limit,
                          isIdentifierPart(chars[end], rules.identifierExtras) { end += 1 }
                    let word = source.text(index, end)
                    let lookup = rules.caseInsensitiveKeywords ? word.lowercased() : word
                    let kind: TokenKind
                    if rules.keywords.contains(lookup) {
                        kind = .keyword
                    } else if rules.types.contains(lookup) {
                        kind = .type
                    } else if rules.builtins.contains(lookup) {
                        kind = .builtin
                    } else if rules.marksFunctionCalls, end < limit, chars[end] == "(" {
                        kind = .function
                    } else {
                        kind = .plain
                    }
                    if kind != .plain { emit(&tokens, source, index, end, kind) }
                    index = end
                    continue
                }

                index += 1
            }
        }
        return state
    }

    /// Consume a string body from just past its opener up to and including its closer.
    /// Emits string, escape and interpolation tokens. Leaves `state` set to `.normal` once the
    /// string is closed, or to `.multilineString` if the range ran out first.
    private static func scanStringBody(_ source: SourceText, _ from: Int, _ limit: Int,
                                       _ rules: CodeRules, _ rule: StringRule, _ ruleIndex: Int,
                                       tokens: inout [Token], lineEndStates: inout [ScanState],
                                       state: inout ScanState) -> Int {
        let chars = source.chars
        var index = from
        var runStart = index

        func flush(_ end: Int) {
            emit(&tokens, source, runStart, end, rule.isRegex ? .regex : .string)
        }

        while index < limit {
            let character = chars[index]

            if character.isNewline {
                flush(index)
                if rule.multiline {
                    lineEndStates.append(.multilineString(rule: ruleIndex))
                    state = .multilineString(rule: ruleIndex)
                    index += 1
                    runStart = index
                    continue
                }
                // Unterminated single-line string: stop at the newline and recover.
                lineEndStates.append(.normal)
                state = .normal
                return index + 1
            }

            if let escape = rule.escape, character == escape, index + 1 < limit {
                flush(index)
                // Swift's interpolation opener is `\(`, which is also an escape. Interpolation
                // wins, or every `\(x)` would be coloured as a two-character escape.
                if let marker = rule.interpolation, source.matches(marker, at: index) {
                    // Capped at the newline: an interpolation that carried on to the next line
                    // would consume it without recording the line's end state, which shifts
                    // every line index after it and mis-colours the rest of the file.
                    index = scanInterpolation(source, index, lineEnd(source, index, limit),
                                              rules, marker, tokens: &tokens)
                    runStart = index
                    continue
                }
                emit(&tokens, source, index, index + 2, .escape)
                index += 2
                runStart = index
                continue
            }

            if let marker = rule.interpolation, source.matches(marker, at: index) {
                // `{{` in an f-string is a literal brace, not an interpolation.
                if marker == "{", index + 1 < limit, chars[index + 1] == "{" {
                    index += 2
                    continue
                }
                flush(index)
                index = scanInterpolation(source, index, lineEnd(source, index, limit),
                                          rules, marker, tokens: &tokens)
                runStart = index
                continue
            }

            if source.matches(rule.close, at: index) {
                index += rule.close.count
                flush(index)
                state = .normal
                return index
            }

            index += 1
        }
        flush(index)
        if rule.multiline { state = .multilineString(rule: ruleIndex) } else { state = .normal }
        return index
    }

    /// Scan `\(expr)`, `${expr}`, `#{expr}`, `{expr}` or Kotlin's bare `$name`, colouring the
    /// delimiters and tokenizing the interior as ordinary code.
    private static func scanInterpolation(_ source: SourceText, _ from: Int, _ limit: Int,
                                          _ rules: CodeRules, _ marker: String,
                                          tokens: inout [Token]) -> Int {
        let chars = source.chars
        var index = from + marker.count
        emit(&tokens, source, from, index, .interpolation)

        guard let last = marker.last else { return index }
        let closer: Character
        let opener: Character
        switch last {
        case "(": opener = "("; closer = ")"
        case "{": opener = "{"; closer = "}"
        default:
            // Bare `$` (Kotlin, shell): either `${…}` — handled above — or a plain identifier.
            if index < limit, chars[index] == "{" {
                var depth = 1
                let braceStart = index
                index += 1
                while index < limit, depth > 0 {
                    if chars[index] == "{" { depth += 1 }
                    if chars[index] == "}" { depth -= 1 }
                    index += 1
                }
                emit(&tokens, source, braceStart, index, .interpolation)
                return index
            }
            var end = index
            while end < limit, isIdentifierPart(chars[end], rules.identifierExtras) { end += 1 }
            emit(&tokens, source, index, end, .interpolation)
            return end
        }

        // Find the matching closer, ignoring ones inside nested strings.
        var depth = 1
        let bodyStart = index
        while index < limit, depth > 0 {
            let character = chars[index]
            if character == opener { depth += 1 }
            else if character == closer { depth -= 1; if depth == 0 { break } }
            else if character == "\"" || character == "'" {
                // Skip a nested string so a `)` inside it does not close the interpolation.
                let quote = character
                index += 1
                while index < limit, chars[index] != quote, !chars[index].isNewline {
                    // A trailing backslash must not step past the end of the range.
                    index = min(index + (chars[index] == "\\" ? 2 : 1), limit)
                }
            }
            index += 1
        }
        index = min(index, limit)
        // Tokenize the interior as code so `count` in "\(items.count)" still reads as code.
        if bodyStart < index {
            var inner: [Token] = []
            var innerStates: [ScanState] = []
            _ = scanCode(source, bodyStart..<index, rules, initial: .normal,
                         tokens: &inner, lineEndStates: &innerStates)
            tokens.append(contentsOf: inner)
        }
        if index < limit {
            emit(&tokens, source, index, index + 1, .interpolation)
            index += 1
        }
        return index
    }

    private static func scanNumber(_ source: SourceText, _ from: Int, _ limit: Int,
                                   _ rules: CodeRules) -> Int {
        let chars = source.chars
        var index = from
        // 0x / 0b / 0o
        if chars[index] == "0", index + 1 < limit {
            let marker = Character(String(chars[index + 1]).lowercased())
            if marker == "x" || marker == "b" || marker == "o" {
                index += 2
                while index < limit, chars[index].isHexDigit
                        || rules.digitSeparators.contains(chars[index]) { index += 1 }
                while index < limit, chars[index].isLetter || chars[index].isNumber { index += 1 }
                return index
            }
        }
        while index < limit, chars[index].isNumber
                || rules.digitSeparators.contains(chars[index]) { index += 1 }
        if index < limit, chars[index] == ".", index + 1 < limit, chars[index + 1].isNumber {
            index += 1
            while index < limit, chars[index].isNumber
                    || rules.digitSeparators.contains(chars[index]) { index += 1 }
        }
        if index < limit, chars[index] == "e" || chars[index] == "E" {
            var probe = index + 1
            if probe < limit, chars[probe] == "+" || chars[probe] == "-" { probe += 1 }
            if probe < limit, chars[probe].isNumber {
                index = probe
                while index < limit, chars[index].isNumber { index += 1 }
            }
        }
        // Suffixes: 10u32, 1.5f, 100L, 5_i64. The suffix must start with a letter, but may
        // then contain digits — otherwise `1u8` splits into the number `1u` and the number `8`.
        if index < limit, chars[index].isLetter || chars[index] == "_" {
            index += 1
            while index < limit, chars[index].isLetter || chars[index].isNumber
                    || chars[index] == "_" { index += 1 }
        }
        return index
    }

    // MARK: - JSON

    private static func scanJSON(_ source: SourceText, _ range: Range<Int>, initial: ScanState,
                                 tokens: inout [Token],
                                 lineEndStates: inout [ScanState]) -> ScanState {
        let chars = source.chars
        let limit = range.upperBound
        var index = range.lowerBound
        var state = initial

        while index < limit {
            if case .blockComment = state {
                let start = index
                var closed = false
                while index < limit {
                    if chars[index].isNewline {
                        emit(&tokens, source, start, index, .comment)
                        lineEndStates.append(state)
                        index += 1
                        closed = true
                        break
                    }
                    if source.matches("*/", at: index) {
                        index += 2
                        emit(&tokens, source, start, index, .comment)
                        state = .normal
                        closed = true
                        break
                    }
                    index += 1
                }
                if !closed { emit(&tokens, source, start, index, .comment) }
                continue
            }

            let character = chars[index]
            if character.isNewline { lineEndStates.append(.normal); index += 1; continue }
            if character == " " || character == "\t" || character == "\r" { index += 1; continue }

            if source.matches("//", at: index) {
                let end = lineEnd(source, index, limit)
                emit(&tokens, source, index, end, .comment)
                index = end
                continue
            }
            if source.matches("/*", at: index) {
                state = .blockComment(depth: 1, doc: false)
                continue
            }

            if character == "\"" {
                let start = index
                index += 1
                var escapes: [(Int, Int)] = []
                while index < limit, chars[index] != "\"", !chars[index].isNewline {
                    if chars[index] == "\\", index + 1 < limit {
                        escapes.append((index, index + 2))
                        index += 2
                        continue
                    }
                    index += 1
                }
                if index < limit, chars[index] == "\"" { index += 1 }
                // A string is a key when the next thing that is not whitespace is a colon.
                let probe = skipSpaces(source, index, limit)
                let isKey = probe < limit && chars[probe] == ":"
                emit(&tokens, source, start, index, isKey ? .key : .string)
                for (from, to) in escapes { emit(&tokens, source, from, min(to, index), .escape) }
                continue
            }

            if character.isNumber || (character == "-" && index + 1 < limit
                                      && chars[index + 1].isNumber) {
                var end = index + (character == "-" ? 1 : 0)
                while end < limit, chars[end].isNumber || chars[end] == "." || chars[end] == "e"
                        || chars[end] == "E" || chars[end] == "+" || chars[end] == "-" { end += 1 }
                emit(&tokens, source, index, end, .number)
                index = end
                continue
            }

            if character.isLetter {
                var end = index
                while end < limit, chars[end].isLetter { end += 1 }
                let word = source.text(index, end)
                emit(&tokens, source, index, end,
                     ["true", "false", "null"].contains(word) ? .builtin : .invalid)
                index = end
                continue
            }

            index += 1
        }
        return state
    }

    // MARK: - Markdown

    private static func scanMarkdown(_ source: SourceText, _ range: Range<Int>,
                                     initial: ScanState, tokens: inout [Token],
                                     lineEndStates: inout [ScanState]) -> ScanState {
        let limit = range.upperBound
        var index = range.lowerBound
        var state = initial

        while index < limit {
            let start = index
            let end = lineEnd(source, index, limit)

            if case let .markdownFence(info) = state {
                if isFenceLine(source, start, end) {
                    emit(&tokens, source, start, end, .keyword)
                    state = .normal
                } else if let language = Languages.byID(info) ?? languageForFenceInfo(info) {
                    var inner: [Token] = []
                    var innerStates: [ScanState] = []
                    _ = scan(source, start..<end, language, initial: .normal,
                             tokens: &inner, lineEndStates: &innerStates)
                    tokens.append(contentsOf: inner)
                } else {
                    emit(&tokens, source, start, end, .string)
                }
            } else if isFenceLine(source, start, end) {
                emit(&tokens, source, start, end, .keyword)
                let content = source.text(start, end)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`~ \t"))
                state = .markdownFence(info: content.lowercased())
            } else {
                scanMarkdownLine(source, start, end, tokens: &tokens)
            }

            if end < limit {
                lineEndStates.append(state)
                index = end + 1
            } else {
                index = end
            }
        }
        return state
    }

    private static func isFenceLine(_ source: SourceText, _ start: Int, _ end: Int) -> Bool {
        let first = skipSpaces(source, start, end)
        return source.matches("```", at: first) || source.matches("~~~", at: first)
    }

    private static func languageForFenceInfo(_ info: String) -> Language? {
        let alias: [String: Language] = [
            "sh": Languages.shell, "bash": Languages.shell, "zsh": Languages.shell,
            "shell": Languages.shell, "console": Languages.shell,
            "py": Languages.python, "python3": Languages.python,
            "js": Languages.javascript, "node": Languages.javascript,
            "ts": Languages.typescript, "jsonc": Languages.json,
            "yml": Languages.yaml, "objective-c": Languages.objc,
            "c++": Languages.cpp, "cplusplus": Languages.cpp, "golang": Languages.go,
            "html": Languages.html, "svg": Languages.xml,
        ]
        if let match = alias[info] { return match }
        return Languages.all.first { $0.extensions.contains(info) }
    }

    private static func scanMarkdownLine(_ source: SourceText, _ start: Int, _ end: Int,
                                         tokens: inout [Token]) {
        let chars = source.chars
        var index = skipSpaces(source, start, end)
        guard index < end else { return }

        // Heading
        if chars[index] == "#" {
            var probe = index
            while probe < end, chars[probe] == "#" { probe += 1 }
            if probe < end, chars[probe] == " " {
                emit(&tokens, source, start, end, .heading)
                return
            }
        }
        // Horizontal rule / setext underline
        let lineText = source.text(index, end).trimmingCharacters(in: .whitespaces)
        if lineText.count >= 3,
           lineText.allSatisfy({ $0 == "-" }) || lineText.allSatisfy({ $0 == "=" })
            || lineText.allSatisfy({ $0 == "*" }) || lineText.allSatisfy({ $0 == "_" }) {
            emit(&tokens, source, index, end, lineText.first == "=" ? .heading : .keyword)
            return
        }
        // Blockquote
        if chars[index] == ">" {
            emit(&tokens, source, index, end, .comment)
            return
        }
        // List marker or table row separator
        if chars[index] == "-" || chars[index] == "*" || chars[index] == "+" {
            if index + 1 < end, chars[index + 1] == " " {
                emit(&tokens, source, index, index + 1, .keyword)
                index += 2
            }
        } else if chars[index].isNumber {
            var probe = index
            while probe < end, chars[probe].isNumber { probe += 1 }
            if probe + 1 < end, chars[probe] == ".", chars[probe + 1] == " " {
                emit(&tokens, source, index, probe + 1, .keyword)
                index = probe + 2
            }
        }

        // Inline: `code`, **bold**, *em*, [text](url)
        while index < end {
            let character = chars[index]
            if character == "`" {
                var probe = index + 1
                while probe < end, chars[probe] != "`" { probe += 1 }
                if probe < end {
                    emit(&tokens, source, index, probe + 1, .string)
                    index = probe + 1
                    continue
                }
            }
            if character == "*" || character == "_" {
                let double = index + 1 < end && chars[index + 1] == character
                let markerLength = double ? 2 : 1
                var probe = index + markerLength
                while probe < end {
                    if chars[probe] == character,
                       !double || (probe + 1 < end && chars[probe + 1] == character) {
                        break
                    }
                    probe += 1
                }
                if probe < end {
                    let closeEnd = min(probe + markerLength, end)
                    emit(&tokens, source, index, closeEnd, .emphasis)
                    index = closeEnd
                    continue
                }
            }
            if character == "[" {
                var probe = index + 1
                while probe < end, chars[probe] != "]" { probe += 1 }
                if probe < end, probe + 1 < end, chars[probe + 1] == "(" {
                    var close = probe + 2
                    while close < end, chars[close] != ")" { close += 1 }
                    if close < end {
                        emit(&tokens, source, index, probe + 1, .link)
                        emit(&tokens, source, probe + 1, close + 1, .string)
                        index = close + 1
                        continue
                    }
                }
            }
            index += 1
        }
    }

    // MARK: - XML / HTML

    private static func scanXML(_ source: SourceText, _ range: Range<Int>, initial: ScanState,
                                tokens: inout [Token],
                                lineEndStates: inout [ScanState]) -> ScanState {
        let chars = source.chars
        let limit = range.upperBound
        var index = range.lowerBound
        var state = initial

        func isNameChar(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "-" || character == "_"
                || character == ":" || character == "." || character == "@"
        }

        while index < limit {
            switch state {

            case .xmlComment, .xmlCData:
                let closer = state == .xmlComment ? "-->" : "]]>"
                let start = index
                var handled = false
                while index < limit {
                    if chars[index].isNewline {
                        emit(&tokens, source, start, index, .comment)
                        lineEndStates.append(state)
                        index += 1
                        handled = true
                        break
                    }
                    if source.matches(closer, at: index) {
                        index += closer.count
                        emit(&tokens, source, start, index, .comment)
                        state = .normal
                        handled = true
                        break
                    }
                    index += 1
                }
                if !handled { emit(&tokens, source, start, index, .comment) }

            case let .xmlRaw(tag):
                // Body of <script> or <style>. Highlighted one line at a time with the embedded
                // language: a construct that spans lines there (a `/* */` comment) would need a
                // nested carry-over state, and a wrong one is worse than an uncoloured one.
                let language = tag == "style" ? Languages.css : Languages.javascript
                var closed = false
                while index < limit {
                    if source.matches("</\(tag)", at: index) { closed = true; break }
                    let stop = lineEnd(source, index, limit)
                    var bodyEnd = stop
                    var probe = index
                    while probe < stop {
                        if source.matches("</\(tag)", at: probe) { bodyEnd = probe; break }
                        probe += 1
                    }
                    if bodyEnd > index {
                        var inner: [Token] = []
                        var innerStates: [ScanState] = []
                        _ = scan(source, index..<bodyEnd, language, initial: .normal,
                                 tokens: &inner, lineEndStates: &innerStates)
                        tokens.append(contentsOf: inner)
                    }
                    index = bodyEnd
                    if bodyEnd < stop { closed = true; break }
                    if index < limit, chars[index].isNewline {
                        lineEndStates.append(.xmlRaw(tag: tag))
                        index += 1
                    } else {
                        break
                    }
                }
                if closed { state = .normal }

            case let .xmlTag(tag, closing):
                var left = false
                while index < limit, !left {
                    let character = chars[index]
                    if character.isNewline {
                        lineEndStates.append(.xmlTag(tag: tag, closing: closing))
                        index += 1
                        continue
                    }
                    if character == ">" {
                        emit(&tokens, source, index, index + 1, .tag)
                        index += 1
                        state = (!closing && (tag == "script" || tag == "style"))
                            ? .xmlRaw(tag: tag) : .normal
                        left = true
                        continue
                    }
                    if character == "/" {
                        emit(&tokens, source, index, index + 1, .tag)
                        index += 1
                        if index < limit, chars[index] == ">" {
                            emit(&tokens, source, index, index + 1, .tag)
                            index += 1
                            state = .normal
                            left = true
                        }
                        continue
                    }
                    if character == "\"" || character == "'" {
                        emit(&tokens, source, index, index + 1, .string)
                        index += 1
                        state = .xmlAttribute(tag: tag, closing: closing,
                                              quote: String(character))
                        left = true
                        continue
                    }
                    if isNameChar(character) {
                        var end = index
                        while end < limit, isNameChar(chars[end]) { end += 1 }
                        emit(&tokens, source, index, end, .key)
                        index = end
                        continue
                    }
                    index += 1
                }

            case let .xmlAttribute(tag, closing, quote):
                let quoteCharacter = Character(quote)
                let start = index
                var handled = false
                while index < limit {
                    if chars[index].isNewline {
                        emit(&tokens, source, start, index, .string)
                        lineEndStates.append(state)
                        index += 1
                        handled = true
                        break
                    }
                    if chars[index] == quoteCharacter {
                        index += 1
                        emit(&tokens, source, start, index, .string)
                        state = .xmlTag(tag: tag, closing: closing)
                        handled = true
                        break
                    }
                    index += 1
                }
                if !handled { emit(&tokens, source, start, index, .string) }

            default:
                let character = chars[index]
                if character.isNewline { lineEndStates.append(.normal); index += 1; continue }
                if source.matches("<!--", at: index) { state = .xmlComment; continue }
                if source.matches("<![CDATA[", at: index) { state = .xmlCData; continue }

                if character == "<" {
                    let tagStart = index
                    index += 1
                    var closing = false
                    if index < limit, chars[index] == "/" { closing = true; index += 1 }
                    // <!DOCTYPE …> and <?xml …?>. Bounded to this line so a stray one cannot
                    // swallow a newline whose state has to be recorded.
                    if index < limit, chars[index] == "!" || chars[index] == "?" {
                        let stop = lineEnd(source, index, limit)
                        while index < stop, chars[index] != ">" { index += 1 }
                        if index < stop { index += 1 }
                        emit(&tokens, source, tagStart, index, .directive)
                        continue
                    }
                    var nameEnd = index
                    while nameEnd < limit, isNameChar(chars[nameEnd]) { nameEnd += 1 }
                    let name = source.text(index, nameEnd).lowercased()
                    emit(&tokens, source, tagStart, nameEnd, .tag)
                    index = nameEnd
                    state = .xmlTag(tag: name, closing: closing)
                    continue
                }

                // Entities: &amp;
                if character == "&" {
                    var end = index + 1
                    while end < limit, chars[end].isLetter || chars[end].isNumber
                            || chars[end] == "#" { end += 1 }
                    if end < limit, chars[end] == ";" {
                        emit(&tokens, source, index, end + 1, .escape)
                        index = end + 1
                        continue
                    }
                }
                index += 1
            }
        }
        return state
    }

    // MARK: - YAML

    private static func scanYAML(_ source: SourceText, _ range: Range<Int>, initial: ScanState,
                                 tokens: inout [Token],
                                 lineEndStates: inout [ScanState]) -> ScanState {
        let chars = source.chars
        let limit = range.upperBound
        var index = range.lowerBound
        var state = initial

        while index < limit {
            let start = index
            let end = lineEnd(source, index, limit)
            let firstNonSpace = skipSpaces(source, start, end)
            let indent = firstNonSpace - start

            if case let .yamlBlockScalar(blockIndent) = state {
                if firstNonSpace == end || indent > blockIndent {
                    emit(&tokens, source, start, end, .string)
                    if end < limit { lineEndStates.append(state); index = end + 1 } else { index = end }
                    continue
                }
                state = .normal
            }

            if firstNonSpace < end, chars[firstNonSpace] == "#" {
                emit(&tokens, source, firstNonSpace, end, .comment)
            } else if source.matches("---", at: firstNonSpace) || source.matches("...", at: firstNonSpace) {
                emit(&tokens, source, firstNonSpace, end, .directive)
            } else if firstNonSpace < end {
                var cursor = firstNonSpace
                // A sequence entry can be followed by a key on the same line.
                if chars[cursor] == "-", cursor + 1 >= end || chars[cursor + 1] == " " {
                    emit(&tokens, source, cursor, cursor + 1, .keyword)
                    cursor = skipSpaces(source, cursor + 1, end)
                }
                // key:
                var keyEnd = cursor
                var sawColon = false
                while keyEnd < end {
                    if chars[keyEnd] == ":" ,
                       keyEnd + 1 >= end || chars[keyEnd + 1] == " " || chars[keyEnd + 1] == "\t" {
                        sawColon = true
                        break
                    }
                    if chars[keyEnd] == "#" { break }
                    keyEnd += 1
                }
                if sawColon, keyEnd > cursor {
                    emit(&tokens, source, cursor, keyEnd, .key)
                    cursor = skipSpaces(source, keyEnd + 1, end)
                }
                if cursor < end {
                    let rest = source.text(cursor, end).trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("|") || rest.hasPrefix(">") {
                        emit(&tokens, source, cursor, end, .keyword)
                        state = .yamlBlockScalar(indent: indent)
                    } else {
                        scanYAMLValue(source, cursor, end, tokens: &tokens)
                    }
                }
            }

            if end < limit { lineEndStates.append(state); index = end + 1 } else { index = end }
        }
        return state
    }

    private static func scanYAMLValue(_ source: SourceText, _ from: Int, _ to: Int,
                                      tokens: inout [Token]) {
        let chars = source.chars
        var index = from
        while index < to {
            let character = chars[index]
            if character == "#", index > from, chars[index - 1] == " " {
                emit(&tokens, source, index, to, .comment)
                return
            }
            if character == "\"" || character == "'" {
                let quote = character
                let start = index
                index += 1
                while index < to, chars[index] != quote {
                    if chars[index] == "\\" { index += 1 }
                    index += 1
                }
                if index < to { index += 1 }
                emit(&tokens, source, start, index, .string)
                continue
            }
            if character == "&" || character == "*" || character == "!" {
                var end = index + 1
                while end < to, chars[end].isLetter || chars[end].isNumber
                        || chars[end] == "_" || chars[end] == "-" || chars[end] == "!" { end += 1 }
                if end > index + 1 {
                    emit(&tokens, source, index, end, .attribute)
                    index = end
                    continue
                }
            }
            if character.isNumber || (character == "-" && index + 1 < to && chars[index + 1].isNumber) {
                var end = index + 1
                while end < to, chars[end].isNumber || chars[end] == "." { end += 1 }
                emit(&tokens, source, index, end, .number)
                index = end
                continue
            }
            if character.isLetter {
                var end = index
                while end < to, chars[end].isLetter { end += 1 }
                let word = source.text(index, end).lowercased()
                if ["true", "false", "null", "yes", "no", "on", "off", "~"].contains(word) {
                    emit(&tokens, source, index, end, .builtin)
                }
                index = end
                continue
            }
            index += 1
        }
    }

    // MARK: - INI / TOML

    private static func scanINI(_ source: SourceText, _ range: Range<Int>, initial: ScanState,
                                tokens: inout [Token],
                                lineEndStates: inout [ScanState]) -> ScanState {
        let chars = source.chars
        let limit = range.upperBound
        var index = range.lowerBound

        while index < limit {
            let start = index
            let end = lineEnd(source, index, limit)
            let firstNonSpace = skipSpaces(source, start, end)

            if firstNonSpace < end {
                let character = chars[firstNonSpace]
                if character == "#" || character == ";" {
                    emit(&tokens, source, firstNonSpace, end, .comment)
                } else if character == "[" {
                    emit(&tokens, source, firstNonSpace, end, .heading)
                } else {
                    var keyEnd = firstNonSpace
                    while keyEnd < end, chars[keyEnd] != "=" { keyEnd += 1 }
                    if keyEnd < end {
                        emit(&tokens, source, firstNonSpace, keyEnd, .key)
                        scanYAMLValue(source, keyEnd + 1, end, tokens: &tokens)
                    }
                }
            }

            if end < limit { lineEndStates.append(.normal); index = end + 1 } else { index = end }
        }
        return .normal
    }
}

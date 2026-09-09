import Foundation

/// A strict RFC 8259 validator with useful messages.
///
/// `JSONSerialization` is not usable for this. It accepts trailing commas — `{"a": 1,}` parses
/// clean — which every other JSON reader the user will feed the file to rejects, and its one
/// error message is "The data couldn't be read because it isn't in the correct format." An
/// editor that calls a broken file valid is worse than one with no checker at all.
enum JSONValidator {

    /// `.jsonc` and the config files that conventionally allow comments.
    static func allowsComments(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return url.pathExtension.lowercased() == "jsonc"
            || ["tsconfig.json", "jsconfig.json", ".eslintrc.json", "devcontainer.json"]
                .contains(name)
    }

    static func validate(_ text: String, url: URL) -> [Diagnostic] {
        var parser = Parser(text: Array(text), allowsComments: allowsComments(url))
        do {
            try parser.parseDocument()
        } catch let error as ParseError {
            return [Diagnostic(file: url, line: error.line, column: error.column,
                               severity: .error, message: error.message, source: "JSON")]
        } catch {
            return [Diagnostic(file: url, line: 1, column: 1, severity: .error,
                               message: "\(error)", source: "JSON")]
        }
        // Duplicate keys are legal JSON and almost always a mistake: readers keep one of them
        // and which one is not specified.
        return parser.duplicates.map {
            Diagnostic(file: url, line: $0.line, column: $0.column, severity: .warning,
                       message: "Duplicate key \"\($0.key)\" — readers keep only one of them.",
                       source: "JSON")
        }
    }

    struct ParseError: Error {
        let message: String
        let line: Int
        let column: Int
    }

    struct Duplicate {
        let key: String
        let line: Int
        let column: Int
    }

    private struct Parser {
        let text: [Character]
        let allowsComments: Bool
        var index = 0
        var line = 1
        var column = 1
        var duplicates: [Duplicate] = []
        /// Deeply nested input is machine-generated or malicious; recursing without a bound
        /// overflows the stack.
        var depth = 0
        static let maxDepth = 256

        init(text: [Character], allowsComments: Bool) {
            self.text = text
            self.allowsComments = allowsComments
        }

        var atEnd: Bool { index >= text.count }
        var current: Character? { atEnd ? nil : text[index] }

        mutating func advance() {
            guard !atEnd else { return }
            if text[index].isNewline { line += 1; column = 1 } else { column += 1 }
            index += 1
        }

        func fail(_ message: String) -> ParseError {
            ParseError(message: message, line: line, column: column)
        }

        mutating func skipTrivia() throws {
            while let character = current {
                if character == " " || character == "\t" || character == "\n"
                    || character == "\r" {
                    advance()
                    continue
                }
                guard allowsComments, character == "/", index + 1 < text.count else { break }
                let next = text[index + 1]
                if next == "/" {
                    while let inner = current, !inner.isNewline { advance() }
                } else if next == "*" {
                    advance(); advance()
                    var closed = false
                    while let inner = current {
                        if inner == "*", index + 1 < text.count, text[index + 1] == "/" {
                            advance(); advance(); closed = true; break
                        }
                        advance()
                    }
                    if !closed { throw fail("Unterminated /* comment.") }
                } else {
                    break
                }
            }
        }

        mutating func parseDocument() throws {
            try skipTrivia()
            // An empty file is not an error; it is a file nobody has written yet.
            if atEnd { return }
            try parseValue()
            try skipTrivia()
            if let character = current {
                throw fail("Unexpected \(describe(character)) after the end of the JSON value. "
                           + "A file holds exactly one value.")
            }
        }

        mutating func parseValue() throws {
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.maxDepth else {
                throw fail("Nested more than \(Self.maxDepth) levels deep.")
            }
            try skipTrivia()
            guard let character = current else {
                throw fail("Expected a value, found the end of the file.")
            }
            switch character {
            case "{": try parseObject()
            case "[": try parseArray()
            case "\"": _ = try parseString()
            case "t": try expect(word: "true")
            case "f": try expect(word: "false")
            case "n": try expect(word: "null")
            case "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9": try parseNumber()
            case "'": throw fail("JSON strings use double quotes, not single quotes.")
            default: throw fail("Expected a value, found \(describe(character)).")
            }
        }

        mutating func expect(word: String) throws {
            for expected in word {
                guard current == expected else { throw fail("Expected \(word).") }
                advance()
            }
        }

        mutating func parseObject() throws {
            advance()   // {
            var keys = Set<String>()
            try skipTrivia()
            if current == "}" { advance(); return }
            while true {
                try skipTrivia()
                guard current == "\"" else {
                    if current == "}" {
                        throw fail("Trailing comma before }. JSON does not allow one.")
                    }
                    if current == "'" {
                        throw fail("JSON strings use double quotes, not single quotes.")
                    }
                    throw fail(current.map { "Expected a quoted key, found \(describe($0))." }
                               ?? "Expected a quoted key, found the end of the file.")
                }
                let keyLine = line, keyColumn = column
                let key = try parseString()
                if !keys.insert(key).inserted {
                    duplicates.append(Duplicate(key: key, line: keyLine, column: keyColumn))
                }
                try skipTrivia()
                guard current == ":" else {
                    throw fail(current.map { "Expected : after the key, found \(describe($0))." }
                               ?? "Expected : after the key.")
                }
                advance()
                try parseValue()
                try skipTrivia()
                if current == "," { advance(); continue }
                if current == "}" { advance(); return }
                throw fail(current.map { "Expected , or } , found \(describe($0))." }
                           ?? "Expected , or } before the end of the file.")
            }
        }

        mutating func parseArray() throws {
            advance()   // [
            try skipTrivia()
            if current == "]" { advance(); return }
            while true {
                try skipTrivia()
                if current == "]" {
                    throw fail("Trailing comma before ]. JSON does not allow one.")
                }
                try parseValue()
                try skipTrivia()
                if current == "," { advance(); continue }
                if current == "]" { advance(); return }
                throw fail(current.map { "Expected , or ] , found \(describe($0))." }
                           ?? "Expected , or ] before the end of the file.")
            }
        }

        @discardableResult
        mutating func parseString() throws -> String {
            advance()   // opening quote
            var value = ""
            while true {
                guard let character = current else {
                    throw fail("Unterminated string — no closing quote before the end of the file.")
                }
                if character == "\"" { advance(); return value }
                if character.isNewline {
                    throw fail("Unterminated string — a newline inside a string must be "
                               + "written as \\n.")
                }
                if character == "\\" {
                    advance()
                    guard let escape = current else { throw fail("Unterminated escape.") }
                    switch escape {
                    case "\"", "\\", "/", "b", "f", "n", "r", "t":
                        value.append(escape)
                        advance()
                    case "u":
                        advance()
                        for _ in 0..<4 {
                            guard let digit = current, digit.isHexDigit else {
                                throw fail("\\u needs exactly four hex digits.")
                            }
                            advance()
                        }
                        value.append("?")
                    default:
                        throw fail("\\\(escape) is not a valid escape. JSON allows "
                                   + #"\" \\ \/ \b \f \n \r \t and \uXXXX."#)
                    }
                    continue
                }
                if let scalar = character.unicodeScalars.first, scalar.value < 0x20 {
                    throw fail("A raw control character (U+"
                               + String(format: "%04X", scalar.value)
                               + ") is not allowed inside a string.")
                }
                value.append(character)
                advance()
            }
        }

        mutating func parseNumber() throws {
            if current == "-" { advance() }
            guard let first = current, first.isNumber else {
                throw fail("Expected a digit after the minus sign.")
            }
            if first == "0" {
                advance()
                if let next = current, next.isNumber {
                    throw fail("Numbers may not have a leading zero.")
                }
            } else {
                while let digit = current, digit.isNumber { advance() }
            }
            if current == "." {
                advance()
                guard let digit = current, digit.isNumber else {
                    throw fail("Expected a digit after the decimal point.")
                }
                while let digit = current, digit.isNumber { advance() }
            }
            if current == "e" || current == "E" {
                advance()
                if current == "+" || current == "-" { advance() }
                guard let digit = current, digit.isNumber else {
                    throw fail("Expected a digit in the exponent.")
                }
                while let digit = current, digit.isNumber { advance() }
            }
            // `1abc` is two tokens to a lenient reader and a mistake to everyone else.
            if let trailing = current, trailing.isLetter {
                throw fail("\(describe(trailing)) is not valid in a number.")
            }
        }

        func describe(_ character: Character) -> String {
            if character == "\n" { return "a newline" }
            if character == "\t" { return "a tab" }
            if character == "'" { return "a single quote" }
            return "'\(character)'"
        }
    }
}

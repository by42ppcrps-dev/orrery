import Foundation

/// One problem reported about a file, from a compiler, a linter, or a language server.
/// Line and column are 1-based, matching what every one of those tools prints.
struct Diagnostic: Identifiable, Equatable, Hashable {
    enum Severity: String, Comparable, CaseIterable {
        case error, warning, info

        var rank: Int {
            switch self {
            case .error: return 0
            case .warning: return 1
            case .info: return 2
            }
        }
        static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }

        var symbol: String {
            switch self {
            case .error: return "xmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }

    var id: String { "\(file.path):\(line):\(column):\(severity.rawValue):\(message)" }
    var file: URL
    var line: Int
    var column: Int
    /// Characters to underline. 0 means "to the end of the line".
    var length: Int = 0
    var severity: Severity
    var message: String
    /// Which tool said so — shown in the problems list so a finding is always attributable.
    var source: String

    /// UTF-16 range in `text`, or nil when the position does not exist in this version of the
    /// file (the file changed since the tool ran).
    func range(in text: NSString) -> NSRange? {
        guard line >= 1 else { return nil }
        var currentLine = 1
        var index = 0
        while currentLine < line, index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            index = lineRange.location + lineRange.length
            currentLine += 1
        }
        guard currentLine == line, index <= text.length else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: min(index, text.length), length: 0))
        var contentsEnd = 0, end = 0, start = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                          for: NSRange(location: min(index, text.length), length: 0))
        let contentLength = max(0, contentsEnd - start)
        let column0 = max(0, column - 1)
        guard column0 <= contentLength else {
            return NSRange(location: start, length: contentLength)
        }
        let location = start + column0
        let available = max(0, contentsEnd - location)
        if length > 0 { return NSRange(location: location, length: min(length, available)) }
        // No length: underline to the end of the line, but never zero width.
        return NSRange(location: location, length: max(1, available)).clamped(to: lineRange)
    }
}

extension NSRange {
    func clamped(to bounds: NSRange) -> NSRange {
        let lower = Swift.max(location, bounds.location)
        let upper = Swift.min(location + length, bounds.location + bounds.length)
        return NSRange(location: lower, length: Swift.max(0, upper - lower))
    }
}

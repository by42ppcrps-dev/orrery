import Foundation

/// Checkers for the breadth languages. Each is a real tool with a syntax-only or parse-only
/// mode and a parser for its actual output format; a missing tool is named, never hidden.
extension Checkers {
    /// `Error in parse(...) : /path/file.R:2:3: unexpected symbol` and any `path:line:col: message`.
    static func parseLineColumnMessages(_ text: String, file: URL, source: String) -> [Diagnostic] {
        var results: [Diagnostic] = []
        let pattern = try! NSRegularExpression(pattern: #":(\d+):(\d+): ?(.+)$"#)
        for line in text.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = pattern.firstMatch(in: line, range: range),
                  let lineRange = Range(match.range(at: 1), in: line),
                  let columnRange = Range(match.range(at: 2), in: line),
                  let messageRange = Range(match.range(at: 3), in: line),
                  let lineNumber = Int(line[lineRange]), let column = Int(line[columnRange]) else { continue }
            let message = line[messageRange].trimmingCharacters(in: .whitespaces)
            guard !message.isEmpty else { continue }
            results.append(Diagnostic(file: file, line: lineNumber, column: column, severity: .error,
                                      message: message, source: source))
        }
        return results
    }

    static let php = Checker(
        name: "php -l",
        scope: "Syntax only, and it stops at the first error.",
        firstErrorOnly: true,
        locate: { Executables.find(["/opt/homebrew/bin/php", "/usr/local/bin/php"], orNamed: "php") },
        arguments: { url in ["-l", "-n", url.path] },
        parse: { result, url in
            // `PHP Parse error:  syntax error, unexpected token "}" in /path/file.php on line 3`
            var results: [Diagnostic] = []
            for line in result.combined.components(separatedBy: "\n") {
                guard let onLine = line.range(of: " on line "),
                      let lineNumber = Int(line[onLine.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)),
                      let errorMark = line.range(of: "error:") else { continue }
                var message = String(line[errorMark.upperBound..<onLine.lowerBound]).trimmingCharacters(in: .whitespaces)
                if let inMark = message.range(of: " in ", options: .backwards) { message = String(message[..<inMark.lowerBound]) }
                results.append(Diagnostic(file: url, line: lineNumber, column: 1, severity: .error,
                                          message: message, source: "php"))
            }
            return results
        })

    static let perl = Checker(
        name: "perl -c",
        scope: "Syntax only. `use` statements are executed to compile, so keep untrusted files out.",
        firstErrorOnly: true,
        locate: { Executables.find(["/usr/bin/perl", "/opt/homebrew/bin/perl"], orNamed: "perl") },
        arguments: { url in ["-c", url.path] },
        parse: { result, url in
            // `syntax error at /path/file.pl line 3, near "..."` / `... at file line 3.`
            var results: [Diagnostic] = []
            let pattern = try! NSRegularExpression(pattern: #"^(.*?) at .* line (\d+)[,.]?"#)
            for line in result.combined.components(separatedBy: "\n") where !line.hasSuffix("syntax OK") {
                let range = NSRange(line.startIndex..., in: line)
                guard let match = pattern.firstMatch(in: line, range: range),
                      let messageRange = Range(match.range(at: 1), in: line),
                      let lineRange = Range(match.range(at: 2), in: line),
                      let lineNumber = Int(line[lineRange]) else { continue }
                let message = line[messageRange].trimmingCharacters(in: .whitespaces)
                guard !message.isEmpty else { continue }
                results.append(Diagnostic(file: url, line: lineNumber, column: 1, severity: .error,
                                          message: message, source: "perl"))
            }
            return results
        })

    static let lua = Checker(
        name: "luac -p",
        scope: "Syntax only, and it stops at the first error.",
        firstErrorOnly: true,
        locate: { Executables.find(["/opt/homebrew/bin/luac", "/usr/local/bin/luac"], orNamed: "luac") },
        arguments: { url in ["-p", url.path] },
        parse: { result, url in
            // `luac: /path/file.lua:3: '=' expected near 'x'`
            var results: [Diagnostic] = []
            for line in result.combined.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: ":")
                guard let index = parts.indices.dropFirst().first(where: { Int(parts[$0].trimmingCharacters(in: .whitespaces)) != nil }),
                      let lineNumber = Int(parts[index].trimmingCharacters(in: .whitespaces)) else { continue }
                let message = parts[(index + 1)...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
                guard !message.isEmpty else { continue }
                results.append(Diagnostic(file: url, line: lineNumber, column: 1, severity: .error,
                                          message: message, source: "luac"))
            }
            return results
        })

    static let java = Checker(
        name: "javac",
        scope: "This file alone, compiled into a private temporary folder; other classes are not on the class path.",
        locate: { Executables.find(["/usr/bin/javac"], orNamed: "javac") },
        arguments: { url in
            let out = NSTemporaryDirectory() + "orrery-javac-" + UUID().uuidString
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            return ["-Xlint:none", "-proc:none", "-d", out, url.path]
        },
        parse: { result, url in parseGCCStyle(result.combined, file: url, source: "javac") })

    static let zig = Checker(
        name: "zig ast-check",
        scope: "Syntax and AST checks only; type errors need a build.",
        locate: { Executables.find(["/opt/homebrew/bin/zig", "/usr/local/bin/zig"], orNamed: "zig") },
        arguments: { url in ["ast-check", url.path] },
        parse: { result, url in parseGCCStyle(result.combined, file: url, source: "zig") })

    static let r = Checker(
        name: "Rscript parse",
        scope: "Parse only; nothing is evaluated.",
        firstErrorOnly: true,
        locate: { Executables.find(["/usr/local/bin/Rscript", "/opt/homebrew/bin/Rscript",
                                    "/Library/Frameworks/R.framework/Resources/bin/Rscript"], orNamed: "Rscript") },
        arguments: { url in ["--vanilla", "-e", "invisible(parse(file = commandArgs(trailingOnly = TRUE)[1]))", url.path] },
        parse: { result, url in parseLineColumnMessages(result.combined, file: url, source: "R") })

    static let dart = Checker(
        name: "dart analyze",
        scope: "The analyzer's own diagnostics for this file; package resolution follows the project.",
        locate: { Executables.find(["/opt/homebrew/bin/dart", "/usr/local/bin/dart"], orNamed: "dart") },
        arguments: { url in ["analyze", "--format=machine", url.path] },
        parse: { result, url in
            // `ERROR|SYNTACTIC_ERROR|EXPECTED_TOKEN|/path/file.dart|3|5|1|Expected to find ';'.`
            var results: [Diagnostic] = []
            for line in result.combined.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: "|")
                guard parts.count >= 8, let lineNumber = Int(parts[4]), let column = Int(parts[5]) else { continue }
                let severity: Diagnostic.Severity = parts[0] == "ERROR" ? .error : (parts[0] == "WARNING" ? .warning : .info)
                results.append(Diagnostic(file: url, line: lineNumber, column: column, severity: severity,
                                          message: parts[7...].joined(separator: "|"), source: "dart"))
            }
            return results
        })

    static let haskell = Checker(
        name: "ghc -fno-code",
        scope: "Type checks this module without generating code; imports must be resolvable.",
        locate: { Executables.find(["/opt/homebrew/bin/ghc", "/usr/local/bin/ghc", "\(NSHomeDirectory())/.ghcup/bin/ghc"], orNamed: "ghc") },
        arguments: { url in ["-fno-code", "-fno-diagnostics-show-caret", url.path] },
        parse: { result, url in
            // `file.hs:3:5: error: [GHC-58481]` followed by indented message lines.
            var results: [Diagnostic] = []
            let lines = result.combined.components(separatedBy: "\n")
            let pattern = try! NSRegularExpression(pattern: #":(\d+):(\d+)(?:-\d+)?: (error|warning)(?::)? ?(.*)$"#)
            var index = 0
            while index < lines.count {
                let line = lines[index]
                let range = NSRange(line.startIndex..., in: line)
                if let match = pattern.firstMatch(in: line, range: range),
                   let lineRange = Range(match.range(at: 1), in: line), let columnRange = Range(match.range(at: 2), in: line),
                   let kindRange = Range(match.range(at: 3), in: line), let restRange = Range(match.range(at: 4), in: line),
                   let lineNumber = Int(line[lineRange]), let column = Int(line[columnRange]) {
                    var message = line[restRange].trimmingCharacters(in: .whitespaces)
                    var next = index + 1
                    while next < lines.count, lines[next].hasPrefix(" "), !lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
                        message += (message.isEmpty ? "" : " ") + lines[next].trimmingCharacters(in: .whitespaces)
                        next += 1
                        if message.count > 300 { break }
                    }
                    results.append(Diagnostic(file: url, line: lineNumber, column: column,
                                              severity: line[kindRange] == "warning" ? .warning : .error,
                                              message: message.isEmpty ? "error" : message, source: "ghc"))
                    index = next
                } else { index += 1 }
            }
            return results
        })

    /// Preference order for the breadth languages; `candidates(for:)` consults this after its own table.
    static func additionalCandidates(for language: Language) -> [Checker] {
        switch language.id {
        case "php": return [php]
        case "perl": return [perl]
        case "lua": return [lua]
        case "java": return [java]
        case "zig": return [zig]
        case "r": return [r]
        case "dart": return [dart]
        case "haskell": return [haskell]
        default: return extraCandidates(for: language)
        }
    }
}

import Foundation

/// Checkers for the third language batch. Every one is a real tool in a syntax-only, parse-only
/// or no-codegen mode with a parser for its actual output; none executes the file being
/// checked, and a missing tool is named. Prolog has no such mode (loading runs directives), so
/// it deliberately has no checker.
extension Checkers {
    private static func brew(_ name: String) -> [String] { ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] }

    /// `path:LINE: [severity:] message` (no column). Severity words are optional.
    static func parseLineMessages(_ text: String, file: URL, source: String) -> [Diagnostic] {
        let pattern = try! NSRegularExpression(pattern: #":(\d+):\s*(?:(error|warning|fatal error|syntax error|note)\s*:?\s*)?(.+)$"#, options: [.caseInsensitive])
        var results: [Diagnostic] = []
        for line in text.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = pattern.firstMatch(in: line, range: range),
                  let lineRange = Range(match.range(at: 1), in: line),
                  let messageRange = Range(match.range(at: 3), in: line),
                  let lineNumber = Int(line[lineRange]) else { continue }
            let severityWord = Range(match.range(at: 2), in: line).map { line[$0].lowercased() } ?? "error"
            let message = line[messageRange].trimmingCharacters(in: .whitespaces)
            guard !message.isEmpty, !message.hasSuffix(":") else { continue }
            results.append(Diagnostic(file: file, line: lineNumber, column: 1,
                                      severity: severityWord.contains("warning") || severityWord == "note" ? .warning : .error,
                                      message: message, source: source))
        }
        return results
    }

    private static func temporaryDirectory(_ prefix: String) -> String {
        let path = NSTemporaryDirectory() + prefix + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// `file.f90:3:10:` on one line, the offending text, then `Error: message`.
    static let gfortran = Checker(
        name: "gfortran -fsyntax-only",
        scope: "Syntax and semantics of one file; modules it uses must already be compiled.",
        locate: { Executables.find(brew("gfortran"), orNamed: "gfortran") },
        arguments: { url in ["-fsyntax-only", "-Wall", url.path] },
        parse: { result, url in
            var results: [Diagnostic] = []
            var pending: (Int, Int)?
            let location = try! NSRegularExpression(pattern: #"^.+:(\d+):(\d+):\s*$"#)
            for line in result.combined.components(separatedBy: "\n") {
                let range = NSRange(line.startIndex..., in: line)
                if let match = location.firstMatch(in: line, range: range),
                   let l = Range(match.range(at: 1), in: line), let c = Range(match.range(at: 2), in: line) {
                    pending = (Int(line[l]) ?? 1, Int(line[c]) ?? 1)
                    continue
                }
                for (prefix, severity) in [("Error: ", Diagnostic.Severity.error), ("Fatal Error: ", .error), ("Warning: ", .warning)] where line.hasPrefix(prefix) {
                    let message = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    results.append(Diagnostic(file: url, line: pending?.0 ?? 1, column: pending?.1 ?? 1, severity: severity, message: message, source: "gfortran"))
                    pending = nil
                }
            }
            return results
        })

    /// `file.cob:5: error: syntax error, unexpected ...`
    static let cobc = Checker(
        name: "cobc -fsyntax-only",
        scope: "Syntax and semantic checks of one program without generating code.",
        locate: { Executables.find(brew("cobc"), orNamed: "cobc") },
        arguments: { url in ["-fsyntax-only", url.path] },
        parse: { result, url in parseLineMessages(result.combined, file: url, source: "cobc") })

    /// `file.adb:3:05: missing ";"` from GNAT's semantic-check-only mode.
    static let gnat = Checker(
        name: "gnatmake -gnatc",
        scope: "GNAT semantic check of one unit; no object code is written.",
        locate: { Executables.find(brew("gnatmake"), orNamed: "gnatmake") },
        arguments: { url in ["-q", "-gnatc", "-D", temporaryDirectory("orrery-gnat-"), url.path] },
        parse: { result, url in parseLineColumnMessages(result.combined, file: url, source: "gnat") })

    /// `file.pas(3,5) Error: Identifier not found "x"`; units and objects go to a temp folder.
    static let fpc = Checker(
        name: "fpc",
        scope: "Free Pascal compile of one unit with output redirected to a temporary folder.",
        locate: { Executables.find(brew("fpc"), orNamed: "fpc") },
        arguments: { url in
            let out = temporaryDirectory("orrery-fpc-")
            return ["-vew", "-FU" + out, "-FE" + out, url.path]
        },
        parse: { result, url in
            let pattern = try! NSRegularExpression(pattern: #"\((\d+),(\d+)\)\s+(Error|Fatal|Warning|Note):\s*(.+)$"#)
            var results: [Diagnostic] = []
            for line in result.combined.components(separatedBy: "\n") {
                let range = NSRange(line.startIndex..., in: line)
                guard let match = pattern.firstMatch(in: line, range: range),
                      let l = Range(match.range(at: 1), in: line), let c = Range(match.range(at: 2), in: line),
                      let kind = Range(match.range(at: 3), in: line), let m = Range(match.range(at: 4), in: line) else { continue }
                results.append(Diagnostic(file: url, line: Int(line[l]) ?? 1, column: Int(line[c]) ?? 1,
                                          severity: ["Warning", "Note"].contains(String(line[kind])) ? .warning : .error,
                                          message: String(line[m]), source: "fpc"))
            }
            return results
        })

    /// `file.nim(3, 5) Error: undeclared identifier: 'x'`
    static let nim = Checker(
        name: "nim check",
        scope: "Semantic check of one module without code generation.",
        locate: { Executables.find(brew("nim") + ["\(NSHomeDirectory())/.nimble/bin/nim"], orNamed: "nim") },
        arguments: { url in ["check", "--hints:off", "--colors:off", url.path] },
        parse: { result, url in
            let pattern = try! NSRegularExpression(pattern: #"\((\d+),\s*(\d+)\)\s+(Error|Warning|Hint):\s*(.+)$"#)
            var results: [Diagnostic] = []
            for line in result.combined.components(separatedBy: "\n") {
                let range = NSRange(line.startIndex..., in: line)
                guard let match = pattern.firstMatch(in: line, range: range),
                      let l = Range(match.range(at: 1), in: line), let c = Range(match.range(at: 2), in: line),
                      let kind = Range(match.range(at: 3), in: line), let m = Range(match.range(at: 4), in: line) else { continue }
                results.append(Diagnostic(file: url, line: Int(line[l]) ?? 1, column: Int(line[c]) ?? 1,
                                          severity: line[kind] == "Error" ? .error : .warning, message: String(line[m]), source: "nim"))
            }
            return results
        })

    /// Two shapes: `Syntax error in file.cr:2: unexpected token` and `Error: msg` followed by
    /// `In file.cr:2:1`.
    static let crystal = Checker(
        name: "crystal build --no-codegen",
        scope: "Full semantic analysis of one file without generating code.",
        locate: { Executables.find(brew("crystal"), orNamed: "crystal") },
        arguments: { url in ["build", "--no-codegen", "--no-color", url.path] },
        parse: { result, url in
            var results: [Diagnostic] = []
            let syntax = try! NSRegularExpression(pattern: #"^(?:Syntax error|Error) in .+:(\d+): (.+)$"#)
            let location = try! NSRegularExpression(pattern: #"^In .+:(\d+):(\d+)\s*$"#)
            var pendingMessage: String?
            for line in result.combined.components(separatedBy: "\n") {
                let range = NSRange(line.startIndex..., in: line)
                if let match = syntax.firstMatch(in: line, range: range), let l = Range(match.range(at: 1), in: line), let m = Range(match.range(at: 2), in: line) {
                    results.append(Diagnostic(file: url, line: Int(line[l]) ?? 1, column: 1, severity: .error, message: String(line[m]), source: "crystal"))
                } else if line.hasPrefix("Error: ") {
                    pendingMessage = String(line.dropFirst(7))
                } else if let message = pendingMessage, let match = location.firstMatch(in: line, range: range),
                          let l = Range(match.range(at: 1), in: line), let c = Range(match.range(at: 2), in: line) {
                    results.append(Diagnostic(file: url, line: Int(line[l]) ?? 1, column: Int(line[c]) ?? 1, severity: .error, message: message, source: "crystal"))
                    pendingMessage = nil
                }
            }
            return results
        })

    /// `file.v:3: syntax error` / `file.v:3: error: ...`
    static let iverilog = Checker(
        name: "iverilog -t null",
        scope: "Parses and elaborates one file with the null target; nothing is simulated.",
        locate: { Executables.find(brew("iverilog"), orNamed: "iverilog") },
        arguments: { url in ["-t", "null", "-g2012", url.path] },
        parse: { result, url in parseLineMessages(result.combined, file: url, source: "iverilog") })

    /// `file.vhd:3:5:error: ...` or `file.vhd:3:5: error: ...`
    static let ghdl = Checker(
        name: "ghdl -s",
        scope: "Syntax check of one VHDL file; no analysis into a library.",
        locate: { Executables.find(brew("ghdl"), orNamed: "ghdl") },
        arguments: { url in ["-s", "--std=08", url.path] },
        parse: { result, url in parseLineColumnMessages(result.combined, file: url, source: "ghdl") })

    /// chktex with a fixed one-line format: `file:line:col:message`.
    static let chktex = Checker(
        name: "chktex",
        scope: "LaTeX style and syntax warnings; it does not compile the document.",
        locate: { Executables.find(brew("chktex"), orNamed: "chktex") },
        arguments: { url in ["-q", "-f", "%f:%l:%c:%m\n", url.path] },
        parse: { result, url in parseLineColumnMessages(result.combined, file: url, source: "chktex").map { d in
            Diagnostic(file: d.file, line: d.line, column: d.column, severity: .warning, message: d.message, source: d.source) } })

    /// `file.asm:3: error: symbol 'x' undefined`
    static let nasm = Checker(
        name: "nasm -o /dev/null",
        scope: "Assembles one NASM-syntax file into nothing; GNU-syntax files are not covered.",
        locate: { Executables.find(brew("nasm"), orNamed: "nasm") },
        arguments: { url in ["-f", "bin", "-o", "/dev/null", url.path] },
        parse: { result, url in parseLineMessages(result.combined, file: url, source: "nasm") })

    /// `Error: Expected ';' but got 'x'` then ` --> file.sol:3:5:`
    static let solc = Checker(
        name: "solc --stop-after parsing",
        scope: "Parses one Solidity file; type checking and code generation are skipped.",
        locate: { Executables.find(brew("solc"), orNamed: "solc") },
        arguments: { url in ["--stop-after", "parsing", url.path] },
        parse: { result, url in
            var results: [Diagnostic] = []
            var pending: (String, Diagnostic.Severity)?
            let head = try! NSRegularExpression(pattern: #"^(Error|Warning|ParserError|SyntaxError|TypeError|DeclarationError)[^:]*:\s*(.+)$"#)
            let arrow = try! NSRegularExpression(pattern: #"^\s*-->\s*.+:(\d+):(\d+):?\s*$"#)
            for line in result.combined.components(separatedBy: "\n") {
                let range = NSRange(line.startIndex..., in: line)
                if let match = head.firstMatch(in: line, range: range), let k = Range(match.range(at: 1), in: line), let m = Range(match.range(at: 2), in: line) {
                    pending = (String(line[m]), line[k] == "Warning" ? .warning : .error)
                } else if let (message, severity) = pending, let match = arrow.firstMatch(in: line, range: range),
                          let l = Range(match.range(at: 1), in: line), let c = Range(match.range(at: 2), in: line) {
                    results.append(Diagnostic(file: url, line: Int(line[l]) ?? 1, column: Int(line[c]) ?? 1, severity: severity, message: message, source: "solc"))
                    pending = nil
                }
            }
            return results
        })

    /// Syntax errors as `file:3:5: ...`; lint findings as `file:3: rule: message`.
    static let buildifier = Checker(
        name: "buildifier -lint=warn",
        scope: "Starlark syntax and lint warnings; it never evaluates the file.",
        locate: { Executables.find(brew("buildifier"), orNamed: "buildifier") },
        arguments: { url in ["-mode=check", "-lint=warn", url.path] },
        parse: { result, url in
            let withColumns = parseLineColumnMessages(result.combined, file: url, source: "buildifier")
            let lines = withColumns.isEmpty ? parseLineMessages(result.combined, file: url, source: "buildifier") : []
            return withColumns + lines.map { Diagnostic(file: $0.file, line: $0.line, column: 1, severity: .warning, message: $0.message, source: $0.source) }
        })

    /// `file.rst:3: (ERROR/3) Unexpected indentation.`
    static let rst = Checker(
        name: "rst2html --exit-status=2",
        scope: "docutils parse of one document; the HTML is discarded.",
        locate: { Executables.find(brew("rst2html.py") + brew("rst2html"), orNamed: "rst2html") },
        arguments: { url in ["--halt=5", "--exit-status=2", "--report=2", url.path, "/dev/null"] },
        parse: { result, url in
            let pattern = try! NSRegularExpression(pattern: #":(\d+): \((ERROR|WARNING|SEVERE|INFO)/\d\)\s*(.+)$"#)
            var results: [Diagnostic] = []
            for line in result.combined.components(separatedBy: "\n") {
                let range = NSRange(line.startIndex..., in: line)
                guard let match = pattern.firstMatch(in: line, range: range),
                      let l = Range(match.range(at: 1), in: line), let k = Range(match.range(at: 2), in: line), let m = Range(match.range(at: 3), in: line) else { continue }
                results.append(Diagnostic(file: url, line: Int(line[l]) ?? 1, column: 1,
                                          severity: ["ERROR", "SEVERE"].contains(String(line[k])) ? .error : .warning,
                                          message: String(line[m]), source: "rst2html"))
            }
            return results
        })

    static func extraCandidates(for language: Language) -> [Checker] {
        switch language.id {
        case "fortran": return [gfortran]
        case "cobol": return [cobc]
        case "ada": return [gnat]
        case "pascal": return [fpc]
        case "nim": return [nim]
        case "crystal": return [crystal]
        case "verilog": return [iverilog]
        case "vhdl": return [ghdl]
        case "latex": return [chktex]
        case "asm": return [nasm]
        case "solidity": return [solc]
        case "starlark": return [buildifier]
        case "rst": return [rst]
        default: return []
        }
    }
}

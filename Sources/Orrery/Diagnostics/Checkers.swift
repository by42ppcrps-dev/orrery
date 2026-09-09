import Foundation

/// One language's way of being checked: which tool, how to invoke it, and how to read what it
/// prints. A language with no checker installed says so by name rather than reporting "no
/// problems", which would be a lie.
struct Checker: Sendable {
    /// Shown in the problems list and the status bar, e.g. `swiftc -parse`.
    let name: String
    /// What this actually catches. The UI shows it so nobody reads "no problems" as "correct".
    let scope: String
    let locate: @Sendable () -> String?
    let arguments: @Sendable (URL) -> [String]
    /// stdout+stderr, plus the path the tool was pointed at, to the diagnostics it describes.
    let parse: @Sendable (ProcessRunner.Result, URL) -> [Diagnostic]
    /// Some tools only ever report the first problem.
    let firstErrorOnly: Bool

    init(name: String, scope: String, firstErrorOnly: Bool = false,
         locate: @escaping @Sendable () -> String?,
         arguments: @escaping @Sendable (URL) -> [String],
         parse: @escaping @Sendable (ProcessRunner.Result, URL) -> [Diagnostic]) {
        self.name = name
        self.scope = scope
        self.firstErrorOnly = firstErrorOnly
        self.locate = locate
        self.arguments = arguments
        self.parse = parse
    }
}

enum Checkers {

    // MARK: Shared parsing

    /// `path:line:col: severity: message` — swiftc, clang, shellcheck -f gcc, and most others.
    static func parseGCCStyle(_ text: String, file: URL, source: String) -> [Diagnostic] {
        var results: [Diagnostic] = []
        var seen = Set<String>()
        for line in text.components(separatedBy: "\n") {
            // Split on the first three colons, but not the one in `C:\…` or a URL.
            let parts = line.components(separatedBy: ":")
            guard parts.count >= 4 else { continue }
            // Find the split where parts[i] is a line number and parts[i+1] a column.
            var index = 1
            while index < parts.count - 2 {
                if let lineNumber = Int(parts[index].trimmingCharacters(in: .whitespaces)),
                   lineNumber > 0 {
                    let columnText = parts[index + 1].trimmingCharacters(in: .whitespaces)
                    let column = Int(columnText)
                    let rest = parts[(column == nil ? index + 1 : index + 2)...]
                        .joined(separator: ":")
                    let severityWord = rest.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: ":").first?
                        .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                    let severity: Diagnostic.Severity
                    switch severityWord {
                    case "error", "fatal error": severity = .error
                    case "warning": severity = .warning
                    case "note", "remark", "info": severity = .info
                    default:
                        index += 1
                        continue
                    }
                    var message = rest
                    if let colon = rest.range(of: ":") {
                        message = String(rest[colon.upperBound...])
                    }
                    message = message.trimmingCharacters(in: .whitespaces)
                    guard !message.isEmpty else { break }
                    let diagnostic = Diagnostic(file: file, line: lineNumber,
                                                column: column ?? 1, severity: severity,
                                                message: message, source: source)
                    if seen.insert(diagnostic.id).inserted { results.append(diagnostic) }
                    break
                }
                index += 1
            }
        }
        return results
    }

    // MARK: Individual checkers

    static let swift = Checker(
        name: "swiftc -parse",
        scope: "Syntax only. Type errors need a full build of the package.",
        locate: { Executables.find(["/usr/bin/swiftc"], orNamed: "swiftc") },
        arguments: { url in ["-parse", "-suppress-warnings", url.path] },
        parse: { result, url in parseGCCStyle(result.combined, file: url, source: "swiftc") })

    static let python = Checker(
        name: "python3 ast",
        scope: "Syntax only, and it stops at the first error.",
        firstErrorOnly: true,
        locate: { Executables.find(["/opt/homebrew/bin/python3", "/usr/bin/python3"],
                                   orNamed: "python3") },
        arguments: { url in ["-c", pythonScript, url.path] },
        parse: { result, url in
            guard let data = result.standardOutput.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return [] }
            return rows.compactMap { row in
                guard let message = row["msg"] as? String else { return nil }
                return Diagnostic(file: url, line: row["line"] as? Int ?? 1,
                                  column: row["col"] as? Int ?? 1,
                                  severity: .error, message: message, source: "python")
            }
        })

    /// Kept as a literal rather than a temp script so there is nothing to install or clean up.
    private static let pythonScript = """
    import ast, json, sys
    path = sys.argv[1]
    try:
        source = open(path, encoding='utf-8').read()
    except Exception as error:
        print(json.dumps([{'line': 1, 'col': 1, 'msg': str(error)}])); raise SystemExit
    try:
        ast.parse(source, filename=path)
    except SyntaxError as error:
        print(json.dumps([{'line': error.lineno or 1, 'col': error.offset or 1,
                           'msg': error.msg}]))
    except Exception as error:
        print(json.dumps([{'line': 1, 'col': 1, 'msg': str(error)}]))
    else:
        print('[]')
    """

    static let ruff = Checker(
        name: "ruff",
        scope: "Lint and syntax.",
        locate: { Executables.find([], orNamed: "ruff") },
        arguments: { url in ["check", "--output-format", "json", "--force-exclude", url.path] },
        parse: { result, url in
            guard let data = result.standardOutput.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return [] }
            return rows.compactMap { row in
                let location = row["location"] as? [String: Any] ?? [:]
                let code = row["code"] as? String
                let message = row["message"] as? String ?? "issue"
                return Diagnostic(file: url, line: location["row"] as? Int ?? 1,
                                  column: location["column"] as? Int ?? 1,
                                  severity: .warning,
                                  message: code.map { "\($0): \(message)" } ?? message,
                                  source: "ruff")
            }
        })

    static let shell = Checker(
        name: "shellcheck",
        scope: "Syntax and the common shell mistakes.",
        locate: { Executables.find(["/opt/homebrew/bin/shellcheck", "/usr/local/bin/shellcheck"],
                                   orNamed: "shellcheck") },
        arguments: { url in ["-f", "gcc", url.path] },
        parse: { result, url in
            parseGCCStyle(result.combined, file: url, source: "shellcheck")
        })

    static let clang = Checker(
        name: "clang -fsyntax-only",
        scope: "Syntax and headers it can find. Project include paths are not applied.",
        locate: { Executables.find(["/usr/bin/clang"], orNamed: "clang") },
        arguments: { url in
            ["-fsyntax-only", "-fno-caret-diagnostics", "-fno-color-diagnostics",
             "-I", url.deletingLastPathComponent().path, url.path]
        },
        parse: { result, url in parseGCCStyle(result.combined, file: url, source: "clang") })

    static let node = Checker(
        name: "node --check",
        scope: "Syntax only, and it stops at the first error.",
        firstErrorOnly: true,
        locate: { Executables.find(["/opt/homebrew/bin/node", "/usr/local/bin/node"],
                                   orNamed: "node") },
        arguments: { url in ["--check", url.path] },
        parse: { result, url in parseNode(result.combined, file: url) })

    /// `node --check` prints `path:line`, the offending source, a caret, then `SyntaxError: …`.
    static func parseNode(_ text: String, file: URL) -> [Diagnostic] {
        let lines = text.components(separatedBy: "\n")
        var lineNumber: Int?
        var column = 1
        var message: String?
        for (index, line) in lines.enumerated() {
            if lineNumber == nil, let colon = line.lastIndex(of: ":"),
               let parsed = Int(line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)),
               line.hasPrefix("/") {
                lineNumber = parsed
                // The caret line, two below, gives the column.
                if index + 2 < lines.count, let caret = lines[index + 2].firstIndex(of: "^") {
                    column = lines[index + 2].distance(from: lines[index + 2].startIndex,
                                                       to: caret) + 1
                }
            }
            for marker in ["SyntaxError:", "ReferenceError:", "TypeError:"]
            where line.hasPrefix(marker) {
                message = line.replacingOccurrences(of: marker, with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        guard let message, let lineNumber else { return [] }
        return [Diagnostic(file: file, line: lineNumber, column: column, severity: .error,
                           message: message, source: "node")]
    }

    static let ruby = Checker(
        name: "ruby -c",
        scope: "Syntax only.",
        firstErrorOnly: true,
        locate: { Executables.find(["/usr/bin/ruby"], orNamed: "ruby") },
        arguments: { url in ["-c", url.path] },
        parse: { result, url in
            var results: [Diagnostic] = []
            for line in result.combined.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: ":")
                guard parts.count >= 3, let lineNumber = Int(parts[1]) else { continue }
                let message = parts[2...].joined(separator: ":")
                    .trimmingCharacters(in: .whitespaces)
                guard !message.isEmpty else { continue }
                results.append(Diagnostic(file: url, line: lineNumber, column: 1,
                                          severity: .error, message: message, source: "ruby"))
            }
            return results
        })

    static let go = Checker(
        name: "gofmt -e",
        scope: "Syntax only.",
        locate: { Executables.find([], orNamed: "gofmt") },
        arguments: { url in ["-e", url.path] },
        parse: { result, url in parseGCCStyle(result.standardError, file: url, source: "gofmt") })

    static let typescript = Checker(
        name: "tsc --noEmit",
        scope: "Types and syntax for this file alone; the project's tsconfig is not used.",
        locate: { Executables.find([], orNamed: "tsc") },
        arguments: { url in ["--noEmit", "--skipLibCheck", "--pretty", "false", url.path] },
        parse: { result, url in
            // tsc uses `path(line,col): error TSxxxx: message`.
            var results: [Diagnostic] = []
            for line in result.combined.components(separatedBy: "\n") {
                guard let open = line.firstIndex(of: "("),
                      let close = line.firstIndex(of: ")"), open < close else { continue }
                let coordinates = line[line.index(after: open)..<close]
                    .components(separatedBy: ",")
                guard coordinates.count == 2, let lineNumber = Int(coordinates[0]),
                      let column = Int(coordinates[1]) else { continue }
                let rest = String(line[line.index(after: close)...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                let severity: Diagnostic.Severity = rest.hasPrefix("warning") ? .warning : .error
                let message = rest.components(separatedBy: ": ").dropFirst()
                    .joined(separator: ": ")
                results.append(Diagnostic(file: url, line: lineNumber, column: column,
                                          severity: severity,
                                          message: message.isEmpty ? rest : message,
                                          source: "tsc"))
            }
            return results
        })

    // MARK: Registry

    /// Preference order per language: the better tool first, falling back to what is installed.
    static func candidates(for language: Language) -> [Checker] {
        RegistrySnapshot.shared.checkers[language.id, default: []] + builtInCandidates(for: language)
    }

    private static func builtInCandidates(for language: Language) -> [Checker] {
        switch language.id {
        case "swift": return [swift]
        case "python": return [ruff, python]
        case "shell": return [shell]
        case "c", "cpp", "objc": return [clang]
        case "javascript": return [node]
        case "typescript": return [typescript]
        case "ruby": return [ruby]
        case "go": return [go]
        default: return additionalCandidates(for: language)
        }
    }

    /// The checker that will actually run, or nil when none is installed.
    static func resolve(for language: Language) -> (Checker, String)? {
        for checker in candidates(for: language) {
            if let path = checker.locate() { return (checker, path) }
        }
        return nil
    }

    /// What to tell the user when nothing will run for this language.
    static func unavailableNote(for language: Language) -> String {
        let wanted = candidates(for: language)
        if wanted.isEmpty {
            return "No checker for \(language.name) — this pane stays empty for it."
        }
        let names = wanted.map(\.name).joined(separator: " or ")
        return "\(language.name) needs \(names), which is not installed. "
            + "Nothing is being checked, so an empty list here does not mean the file is clean."
    }
}

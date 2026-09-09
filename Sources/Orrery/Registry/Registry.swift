import Foundation

// MARK: - File format

/// A registry file adds languages, language servers, checkers and tasks as data. Two files are
/// read: `~/Library/Application Support/Orrery/registry.json` (yours, always on) and
/// `<project>/.orrery/registry.json` (the project's, only when the project is trusted and you
/// have allowed it in Agent settings → Tools). Loading never runs anything: commands run only
/// when you run a task or a checker checks a file. Unknown keys are ignored; every problem is
/// reported by entry, and a bad entry never takes the good ones down with it.
struct RegistryFile: Equatable {
    struct Language: Equatable {
        var id: String
        var name: String
        var extensions: [String] = []
        var filenames: [String] = []
        var lineComments: [String] = ["//"]
        var blockComment: [String]? = ["/*", "*/"]
        var strings: [StringForm] = [StringForm(open: "\"", close: "\"")]
        var keywords: [String] = []
        var types: [String] = []
        var builtins: [String] = []
        var caseInsensitive = false
        var indent = "    "
    }
    struct StringForm: Equatable {
        var open: String
        var close: String
        var escape: String? = "\\"
        var multiline = false
        var interpolation: String?
    }
    struct Server: Equatable {
        var language: String
        var command: String
        var arguments: [String] = []
        var name: String?
    }
    struct CheckerEntry: Equatable {
        var language: String
        var name: String
        var command: String
        var arguments: [String]
        var pattern: String
        var scope: String?
    }
    struct Task: Equatable {
        var id: String
        var title: String
        var command: String
        var arguments: [String] = []
        var kind = "run"
        var languages: [String] = []
        var fileExists: String?
    }

    var languages: [Language] = []
    var servers: [Server] = []
    var checkers: [CheckerEntry] = []
    var tasks: [Task] = []

    static let byteLimit = 256 * 1024
    static let entryLimit = 64
    static let taskLimit = 128
    static let placeholders = ["{file}", "{dir}", "{stem}", "{name}", "{project}"]

    /// Parses and validates. Problems name the entry; a file that cannot be parsed yields no entries.
    static func parse(_ data: Data, source: String) -> (file: RegistryFile, problems: [String]) {
        var problems: [String] = []
        guard data.count <= byteLimit else { return (RegistryFile(), ["\(source): larger than \(byteLimit / 1024) KB; ignored."]) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (RegistryFile(), ["\(source): not a JSON object."])
        }
        if let version = object["version"] as? Int, version != 1 { problems.append("\(source): version \(version) is newer than this app understands; reading it as version 1.") }
        var file = RegistryFile()
        let idPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,31}$")
        func validID(_ id: String) -> Bool { idPattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil }
        func strings(_ any: Any?, _ limit: Int = 64, each: Int = 128) -> [String]? {
            guard any != nil else { return [] }
            guard let list = any as? [String] else { return nil }
            return Array(list.prefix(limit)).filter { !$0.isEmpty && $0.count <= each }
        }
        for (index, raw) in ((object["languages"] as? [Any]) ?? []).prefix(entryLimit).enumerated() {
            guard let entry = raw as? [String: Any], let id = entry["id"] as? String, let name = entry["name"] as? String else {
                problems.append("\(source): languages[\(index)] needs \"id\" and \"name\"."); continue
            }
            guard validID(id) else { problems.append("\(source): language \"\(id)\": ids are lowercase letters, digits, - and _ (32 max)."); continue }
            guard let extensions = strings(entry["extensions"], 32, each: 16), let filenames = strings(entry["filenames"], 32),
                  let lineComments = strings(entry["lineComments"] ?? ["//"], 8, each: 8),
                  let keywords = strings(entry["keywords"], 512, each: 64), let types = strings(entry["types"], 512, each: 64),
                  let builtins = strings(entry["builtins"], 512, each: 64) else {
                problems.append("\(source): language \"\(id)\": list fields must be arrays of strings."); continue
            }
            guard !extensions.isEmpty || !filenames.isEmpty else { problems.append("\(source): language \"\(id)\" names no extension or filename, so nothing would use it."); continue }
            var language = Language(id: id, name: String(name.prefix(48)), extensions: extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) },
                                    filenames: filenames, lineComments: lineComments, keywords: keywords, types: types, builtins: builtins)
            if entry["blockComment"] is NSNull { language.blockComment = nil }
            else if let block = entry["blockComment"] as? [String] {
                guard block.count == 2, block.allSatisfy({ !$0.isEmpty && $0.count <= 8 }) else { problems.append("\(source): language \"\(id)\": blockComment must be [open, close]."); continue }
                language.blockComment = block
            }
            if let forms = entry["strings"] as? [[String: Any]] {
                var parsed: [StringForm] = []
                for form in forms.prefix(8) {
                    guard let open = form["open"] as? String, let close = form["close"] as? String, !open.isEmpty, !close.isEmpty, open.count <= 4, close.count <= 4 else {
                        problems.append("\(source): language \"\(id)\": each string form needs open and close (1–4 characters)."); continue
                    }
                    var stringForm = StringForm(open: open, close: close)
                    if form["escape"] is NSNull { stringForm.escape = nil } else if let escape = form["escape"] as? String { stringForm.escape = escape.isEmpty ? nil : String(escape.prefix(1)) }
                    stringForm.multiline = form["multiline"] as? Bool ?? false
                    stringForm.interpolation = (form["interpolation"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(2)) }
                    parsed.append(stringForm)
                }
                language.strings = parsed
            }
            language.caseInsensitive = entry["caseInsensitive"] as? Bool ?? false
            if let indent = entry["indent"] as? String, indent.count <= 8, indent.allSatisfy({ $0 == " " || $0 == "\t" }) { language.indent = indent }
            if file.languages.contains(where: { $0.id == id }) { problems.append("\(source): language \"\(id)\" is listed twice; the first one wins."); continue }
            file.languages.append(language)
        }
        for (index, raw) in ((object["servers"] as? [Any]) ?? []).prefix(entryLimit).enumerated() {
            guard let entry = raw as? [String: Any], let language = entry["language"] as? String, let command = entry["command"] as? String, !command.isEmpty, command.count <= 512 else {
                problems.append("\(source): servers[\(index)] needs \"language\" and \"command\"."); continue
            }
            guard let arguments = strings(entry["arguments"], 64, each: 512) else { problems.append("\(source): server for \"\(language)\": arguments must be strings."); continue }
            file.servers.append(Server(language: language, command: command, arguments: arguments, name: (entry["name"] as? String).map { String($0.prefix(64)) }))
        }
        for (index, raw) in ((object["checkers"] as? [Any]) ?? []).prefix(entryLimit).enumerated() {
            guard let entry = raw as? [String: Any], let language = entry["language"] as? String, let name = entry["name"] as? String,
                  let command = entry["command"] as? String, !command.isEmpty, command.count <= 512, let pattern = entry["pattern"] as? String else {
                problems.append("\(source): checkers[\(index)] needs \"language\", \"name\", \"command\", \"arguments\" and \"pattern\"."); continue
            }
            guard let arguments = strings(entry["arguments"], 64, each: 512),
                  arguments.contains(where: { $0.contains("{file}") }) || pattern.contains("(?<file>") else {
                problems.append("\(source): checker \"\(name)\": arguments must be strings, and either one of them contains {file} or the pattern has a (?<file>…) group so results can be matched to the file."); continue
            }
            guard pattern.count <= 1024, let regex = try? NSRegularExpression(pattern: pattern, options: []), regex.numberOfCaptureGroups >= 1,
                  pattern.contains("(?<line>"), pattern.contains("(?<message>") else {
                problems.append("\(source): checker \"\(name)\": pattern must be a valid regular expression with named groups (?<line>…) and (?<message>…), optionally (?<column>…) and (?<severity>…)."); continue
            }
            file.checkers.append(CheckerEntry(language: language, name: String(name.prefix(64)), command: command, arguments: arguments, pattern: pattern, scope: (entry["scope"] as? String).map { String($0.prefix(200)) }))
        }
        for (index, raw) in ((object["tasks"] as? [Any]) ?? []).prefix(taskLimit).enumerated() {
            guard let entry = raw as? [String: Any], let id = entry["id"] as? String, let title = entry["title"] as? String, let command = entry["command"] as? String,
                  !command.isEmpty, command.count <= 512, !title.isEmpty else {
                problems.append("\(source): tasks[\(index)] needs \"id\", \"title\" and \"command\"."); continue
            }
            guard validID(id) else { problems.append("\(source): task \"\(id)\": ids are lowercase letters, digits, - and _ (32 max)."); continue }
            guard let arguments = strings(entry["arguments"], 64, each: 512), let languages = strings(entry["languages"], 32) else {
                problems.append("\(source): task \"\(id)\": arguments and languages must be strings."); continue
            }
            let kind = (entry["kind"] as? String) ?? "run"
            guard RunTask.Kind(rawValue: kind) != nil else { problems.append("\(source): task \"\(id)\": kind must be build, run, test or script."); continue }
            let fileExists = (entry["fileExists"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let fileExists, fileExists.hasPrefix("/") || fileExists.contains("..") { problems.append("\(source): task \"\(id)\": fileExists must be a path inside the project."); continue }
            guard !languages.isEmpty || fileExists != nil else { problems.append("\(source): task \"\(id)\" needs \"languages\" (a file task) or \"fileExists\" (a project task)."); continue }
            if file.tasks.contains(where: { $0.id == id }) { problems.append("\(source): task \"\(id)\" is listed twice; the first one wins."); continue }
            file.tasks.append(Task(id: id, title: String(title.prefix(80)), command: command, arguments: arguments, kind: kind, languages: languages, fileExists: fileExists))
        }
        return (file, problems)
    }
}

// MARK: - Placeholders and command resolution

enum RegistryCommands {
    static func substitute(_ text: String, file: URL?, project: URL) -> String {
        var result = text.replacingOccurrences(of: "{project}", with: project.path)
        if let file {
            result = result.replacingOccurrences(of: "{file}", with: file.path)
                .replacingOccurrences(of: "{dir}", with: file.deletingLastPathComponent().path)
                .replacingOccurrences(of: "{stem}", with: file.deletingPathExtension().lastPathComponent)
                .replacingOccurrences(of: "{name}", with: file.lastPathComponent)
        }
        return result
    }

    /// An absolute path is used as is (if executable); a bare name is looked up on PATH.
    static func locate(_ command: String) -> String? {
        if command.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
        return Executables.find([], orNamed: command)
    }
}

// MARK: - The live snapshot the editor, checkers, tasks and language servers consult

/// Built once per load and read from any thread. Everything derived (Language values, Checker
/// values, server descriptions) is computed here so lookups are dictionary reads.
final class RegistrySnapshot: @unchecked Sendable {
    struct ServerDescription: Hashable {
        let name: String
        let command: String
        let arguments: [String]
    }

    static let empty = RegistrySnapshot(languages: [], checkers: [:], servers: [:], tasks: [], sources: [])
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: RegistrySnapshot = .empty

    static var shared: RegistrySnapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    static func install(_ snapshot: RegistrySnapshot) {
        lock.lock(); current = snapshot; lock.unlock()
    }

    let languages: [Language]
    let checkers: [String: [Checker]]
    let servers: [String: ServerDescription]
    let tasks: [RegistryFile.Task]
    let sources: [String]
    private let byExtension: [String: Language]
    private let byFilename: [String: Language]

    init(languages: [Language], checkers: [String: [Checker]], servers: [String: ServerDescription], tasks: [RegistryFile.Task], sources: [String]) {
        self.languages = languages
        self.checkers = checkers
        self.servers = servers
        self.tasks = tasks
        self.sources = sources
        var byExtension: [String: Language] = [:], byFilename: [String: Language] = [:]
        for language in languages {
            for ext in language.extensions where byExtension[ext] == nil { byExtension[ext] = language }
            for name in language.filenames { byFilename[name.lowercased()] = language }
        }
        self.byExtension = byExtension
        self.byFilename = byFilename
    }

    func language(forExtension ext: String) -> Language? { byExtension[ext] }
    func language(forFilename name: String) -> Language? { byFilename[name.lowercased()] }

    func tasks(project: URL?, activeFile: URL?, language: Language?) -> [RunTask] {
        var results: [RunTask] = []
        for task in tasks {
            let kind = RunTask.Kind(rawValue: task.kind) ?? .run
            if let fileExists = task.fileExists, let project {
                guard FileManager.default.fileExists(atPath: project.appendingPathComponent(fileExists).path) else { continue }
                let executable = RegistryCommands.locate(task.command)
                results.append(RunTask(id: "registry-" + task.id, title: task.title, executable: executable,
                                       arguments: task.arguments.map { RegistryCommands.substitute($0, file: nil, project: project) },
                                       directory: project, kind: kind, source: "registry (\(fileExists))",
                                       missingTool: executable == nil ? task.command : nil))
            } else if !task.languages.isEmpty, let activeFile, let language, task.languages.contains(language.id) {
                let root = project ?? activeFile.deletingLastPathComponent()
                let executable = RegistryCommands.locate(task.command)
                results.append(RunTask(id: "registry-" + task.id, title: RegistryCommands.substitute(task.title, file: activeFile, project: root),
                                       executable: executable,
                                       arguments: task.arguments.map { RegistryCommands.substitute($0, file: activeFile, project: root) },
                                       directory: root, kind: kind, source: "registry (current file)",
                                       missingTool: executable == nil ? task.command : nil))
            }
        }
        return results
    }

    /// Turns validated entries into runtime values. Ids that collide with built-in languages are
    /// refused; extension collisions are allowed because the registry expresses the user's choice.
    static func build(user: RegistryFile?, project: RegistryFile?, contributions: [(RegistryFile, String)] = [], sources: [String], builtInIDs: Set<String>) -> (RegistrySnapshot, [String]) {
        var problems: [String] = []
        var languages: [Language] = []
        var checkers: [String: [Checker]] = [:]
        var servers: [String: ServerDescription] = [:]
        var tasks: [RegistryFile.Task] = []
        let symbol = "puzzlepiece.extension"
        var files: [(RegistryFile?, String)] = [(user, "your registry"), (project, "the project registry")]
        files += contributions.map { ($0.0 as RegistryFile?, $0.1) }
        for (file, source) in files {
            guard let file else { continue }
            for entry in file.languages {
                guard !builtInIDs.contains(entry.id) else { problems.append("\(source): language \"\(entry.id)\" is built in and cannot be replaced."); continue }
                guard !languages.contains(where: { $0.id == entry.id }) else { problems.append("\(source): language \"\(entry.id)\" is already defined by your registry."); continue }
                var rules = CodeRules()
                rules.lineComments = entry.lineComments
                rules.blockCommentOpen = entry.blockComment?.first
                rules.blockCommentClose = entry.blockComment?.last
                rules.strings = entry.strings.map { StringRule(open: $0.open, close: $0.close, escape: $0.escape?.first, multiline: $0.multiline, interpolation: $0.interpolation) }
                rules.keywords = Set(entry.caseInsensitive ? entry.keywords.map { $0.lowercased() } : entry.keywords)
                rules.types = Set(entry.caseInsensitive ? entry.types.map { $0.lowercased() } : entry.types)
                rules.builtins = Set(entry.caseInsensitive ? entry.builtins.map { $0.lowercased() } : entry.builtins)
                rules.caseInsensitiveKeywords = entry.caseInsensitive
                var language = Language(id: entry.id, name: entry.name, extensions: entry.extensions, filenames: entry.filenames,
                                        grammar: .code(rules), lineComment: entry.lineComments.first, symbol: symbol)
                if let block = entry.blockComment, block.count == 2 { language.blockComment = (block[0], block[1]) }
                language.indentUnit = entry.indent
                languages.append(language)
            }
            for entry in file.servers {
                guard servers[entry.language] == nil else { problems.append("\(source): a server for \"\(entry.language)\" is already defined; the first one wins."); continue }
                servers[entry.language] = ServerDescription(name: entry.name ?? (entry.command as NSString).lastPathComponent, command: entry.command, arguments: entry.arguments)
            }
            for entry in file.checkers {
                guard let regex = try? NSRegularExpression(pattern: entry.pattern) else { continue }
                let command = entry.command, arguments = entry.arguments, name = entry.name
                let checker = Checker(
                    name: name,
                    scope: entry.scope ?? "From \(source): runs \(command) on the file and reads its output with your pattern.",
                    locate: { RegistryCommands.locate(command) },
                    arguments: { url in arguments.map { RegistryCommands.substitute($0, file: url, project: url.deletingLastPathComponent()) } },
                    parse: { result, url in
                        var results: [Diagnostic] = []
                        for line in result.combined.components(separatedBy: "\n") {
                            let range = NSRange(line.startIndex..., in: line)
                            guard let match = regex.firstMatch(in: line, range: range) else { continue }
                            func group(_ groupName: String) -> String? {
                                let r = match.range(withName: groupName)
                                guard r.location != NSNotFound, let swiftRange = Range(r, in: line) else { return nil }
                                return String(line[swiftRange])
                            }
                            guard let lineText = group("line"), let lineNumber = Int(lineText), let message = group("message"), !message.isEmpty else { continue }
                            // A project-wide tool reports every file; keep only lines about the one being checked.
                            if let reported = group("file"), !reported.isEmpty {
                                let reportedName = (reported as NSString).lastPathComponent
                                guard reportedName == url.lastPathComponent, url.path.hasSuffix(reported.hasPrefix("/") ? reported : "/" + reported) || reported == url.lastPathComponent else { continue }
                            }
                            let severityWord = group("severity")?.lowercased() ?? "error"
                            results.append(Diagnostic(file: url, line: lineNumber, column: group("column").flatMap(Int.init) ?? 1,
                                                      severity: severityWord.contains("warn") || severityWord.contains("note") || severityWord.contains("info") ? .warning : .error,
                                                      message: message, source: name))
                        }
                        return results
                    })
                checkers[entry.language, default: []].append(checker)
            }
            for entry in file.tasks {
                guard !tasks.contains(where: { $0.id == entry.id }) else { problems.append("\(source): task \"\(entry.id)\" is already defined; the first one wins."); continue }
                tasks.append(entry)
            }
        }
        return (RegistrySnapshot(languages: languages, checkers: checkers, servers: servers, tasks: tasks, sources: sources), problems)
    }
}

// MARK: - Loading and consent

/// Which projects may run their own registry's commands. Exact per directory, tied to the
/// directory's identity like project trust, so a replaced folder has to be allowed again.
enum RegistryConsent {
    static let key = "registry.projectAllowed.v1"

    static func isAllowed(_ root: URL, defaults: UserDefaults) -> Bool {
        guard let identity = identity(root) else { return false }
        return (defaults.dictionary(forKey: key) as? [String: String])?[root.resolvingSymlinksInPath().standardizedFileURL.path] == identity
    }

    static func setAllowed(_ root: URL, _ allowed: Bool, defaults: UserDefaults) {
        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
        var grants = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if allowed, let identity = identity(root) { grants[path] = identity } else { grants.removeValue(forKey: path) }
        defaults.set(grants, forKey: key)
    }

    private static func identity(_ root: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: root.resolvingSymlinksInPath().path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device):\(inode)"
    }
}

@MainActor @Observable
final class Registry {
    static let shared = Registry()
    static let projectRelativePath = ".orrery/registry.json"

    let userURL: URL
    private(set) var projectRoot: URL?
    private(set) var projectAllowed = false
    private(set) var userFile: RegistryFile?
    private(set) var projectFile: RegistryFile?
    private(set) var projectFileExists = false
    private(set) var problems: [String] = []
    private(set) var loadedAt: Date?

    init(userURL: URL? = nil) {
        self.userURL = userURL ?? PrivateProjectFile.defaultDirectory("").deletingLastPathComponent()
            .appendingPathComponent("Orrery", isDirectory: true).appendingPathComponent("registry.json")
    }

    var userFileExists: Bool { FileManager.default.fileExists(atPath: userURL.path) }
    var projectFileURL: URL? { projectRoot?.appendingPathComponent(Self.projectRelativePath) }

    func summary(of file: RegistryFile?) -> String {
        guard let file else { return "nothing loaded" }
        return "\(file.languages.count) language\(file.languages.count == 1 ? "" : "s"), \(file.servers.count) server\(file.servers.count == 1 ? "" : "s"), \(file.checkers.count) checker\(file.checkers.count == 1 ? "" : "s"), \(file.tasks.count) task\(file.tasks.count == 1 ? "" : "s")"
    }

    /// Reads the user file and, when allowed, the project file, then installs the snapshot.
    func load(project: URL?, projectAllowed: Bool, contributions: [(RegistryFile, String)] = []) {
        projectRoot = project
        self.projectAllowed = projectAllowed
        var problems: [String] = []
        var sources: [String] = []
        userFile = nil; projectFile = nil
        if let data = Self.read(userURL, problems: &problems, source: "your registry") {
            let parsed = RegistryFile.parse(data, source: "your registry")
            userFile = parsed.file; problems += parsed.problems; sources.append(userURL.path)
        }
        projectFileExists = false
        if let project {
            let url = project.appendingPathComponent(Self.projectRelativePath)
            projectFileExists = FileManager.default.fileExists(atPath: url.path)
            if projectFileExists {
                if projectAllowed, let data = Self.read(url, problems: &problems, source: "the project registry") {
                    let parsed = RegistryFile.parse(data, source: "the project registry")
                    projectFile = parsed.file; problems += parsed.problems; sources.append(url.path)
                } else if !projectAllowed {
                    problems.append("The project registry at \(Self.projectRelativePath) is not loaded: allow it in Agent settings → Tools once you have read it.")
                }
            }
        }
        let built = RegistrySnapshot.build(user: userFile, project: projectFile, contributions: contributions, sources: sources, builtInIDs: Set(Languages.builtIn.map(\.id)))
        problems += built.1
        RegistrySnapshot.install(built.0)
        self.problems = problems
        loadedAt = Date()
    }

    private static func read(_ url: URL, problems: inout [String], source: String) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            problems.append("\(source): \(url.lastPathComponent) is a symbolic link; refused."); return nil
        }
        guard let data = try? Data(contentsOf: url) else { problems.append("\(source): could not be read."); return nil }
        return data
    }

    /// The documented example, written only where no registry exists yet.
    static let example = """
    {
      "version": 1,
      "languages": [
        {"id": "gleam", "name": "Gleam", "extensions": ["gleam"],
         "lineComments": ["//"], "blockComment": null,
         "strings": [{"open": "\\"", "close": "\\""}],
         "keywords": ["fn", "let", "case", "pub", "import", "type", "if", "else", "use", "as", "assert", "const", "todo", "panic"],
         "types": ["Int", "Float", "String", "Bool", "List", "Result", "Option"]}
      ],
      "servers": [{"language": "gleam", "command": "gleam", "arguments": ["lsp"]}],
      "checkers": [{"language": "gleam", "name": "gleam check", "command": "gleam", "arguments": ["check"],
                    "pattern": "^(?<file>[^:]+):(?<line>\\\\d+):(?<column>\\\\d+):\\\\s*(?<severity>error|warning):\\\\s*(?<message>.+)$",
                    "scope": "Type-checks the project the file belongs to."}],
      "tasks": [
        {"id": "gleam-test", "title": "gleam test", "command": "gleam", "arguments": ["test"], "kind": "test", "fileExists": "gleam.toml"},
        {"id": "gleam-run-file", "title": "gleam run {name}", "command": "gleam", "arguments": ["run", "--module", "{stem}"], "languages": ["gleam"]}
      ]
    }

    """

    @discardableResult
    func writeExampleIfMissing() -> Bool {
        guard !userFileExists else { return false }
        do {
            try FileManager.default.createDirectory(at: userURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Self.example.write(to: userURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: userURL.path)
            return true
        } catch { problems.append("Could not write the example: \(error.localizedDescription)"); return false }
    }
}

extension AppModel {
    /// Whether this project's `.orrery/registry.json` may add commands. Requires trust.
    var projectRegistryAllowed: Bool {
        get { projectURL.map { isProjectTrusted && RegistryConsent.isAllowed($0, defaults: Self.preferences) } ?? false }
        set {
            guard let projectURL else { return }
            RegistryConsent.setAllowed(projectURL, newValue, defaults: Self.preferences)
            reloadRegistry()
        }
    }

    func reloadRegistry() { reloadExtensions() }
}

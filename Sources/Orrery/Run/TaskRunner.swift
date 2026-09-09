import Foundation
import Observation

// MARK: - Tasks

/// One thing this project can run, derived from its files — never hardcoded guesses. A task
/// whose tool is not installed still appears, with the missing tool named, because a silently
/// absent "swift test" reads as "there are no tests".
struct RunTask: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case build, run, test, script
    }

    let id: String
    let title: String
    let executable: String?
    let arguments: [String]
    let directory: URL
    let kind: Kind
    /// Where this task came from — Package.swift, package.json, Makefile, or the open file.
    let source: String
    /// Set when the needed tool is not installed; the UI shows the name instead of running.
    var missingTool: String?
}

enum TaskCatalog {

    /// Everything the project and the active file offer, in menu order.
    static func tasks(project: URL?, activeFile: URL?, language: Language?) -> [RunTask] {
        var tasks: [RunTask] = []
        if let project {
            tasks += packageSwiftTasks(project)
            tasks += packageJSONTasks(project)
            tasks += makefileTasks(project)
            tasks += cargoTasks(project)
            tasks += goTasks(project)
            tasks += moreProjectTasks(project)
        }
        if let activeFile, let language {
            tasks += fileTasks(activeFile, language: language,
                               project: project ?? activeFile.deletingLastPathComponent())
        }
        tasks += RegistrySnapshot.shared.tasks(project: project, activeFile: activeFile, language: language)
        return tasks
    }

    private static func exists(_ name: String, in project: URL) -> Bool {
        FileManager.default.fileExists(atPath: project.appendingPathComponent(name).path)
    }

    private static func packageSwiftTasks(_ project: URL) -> [RunTask] {
        guard exists("Package.swift", in: project) else { return [] }
        let swift = Executables.find(["/usr/bin/swift"], orNamed: "swift")
        func task(_ id: String, _ verb: String, _ kind: RunTask.Kind) -> RunTask {
            RunTask(id: "swift-\(id)", title: "swift \(verb)", executable: swift,
                    arguments: [verb], directory: project, kind: kind,
                    source: "Package.swift",
                    missingTool: swift == nil ? "swift" : nil)
        }
        return [task("build", "build", .build), task("test", "test", .test),
                task("run", "run", .run)]
    }

    private static func packageJSONTasks(_ project: URL) -> [RunTask] {
        let url = project.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String], !scripts.isEmpty
        else { return [] }
        let npm = Executables.find(["/opt/homebrew/bin/npm", "/usr/local/bin/npm"],
                                   orNamed: "npm")
        return scripts.keys.filter { !$0.hasPrefix("-") && !$0.contains("\n") }.sorted().map { name in
            let kind: RunTask.Kind = name.contains("test") ? .test
                : (name.contains("build") ? .build : (["start", "dev"].contains(name) ? .run : .script))
            return RunTask(id: "npm-\(name)", title: "npm run \(name)", executable: npm,
                           arguments: ["run", name], directory: project, kind: kind,
                           source: "package.json", missingTool: npm == nil ? "npm" : nil)
        }
    }

    private static func makefileTasks(_ project: URL) -> [RunTask] {
        let url = project.appendingPathComponent("Makefile")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let make = Executables.find(["/usr/bin/make"], orNamed: "make")
        var targets: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard !line.hasPrefix("\t"), !line.hasPrefix(" "), !line.hasPrefix("."),
                  let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("%"), !name.contains("="),
                  !name.contains(" "), !name.hasPrefix("-"), !targets.contains(name) else { continue }
            targets.append(name)
            if targets.count >= 20 { break }
        }
        return targets.map { target in
            // `["all","build",target].contains("build")` is always true — it classified
            // every non-test target as .build, so the acceptance gate ran `make clean`.
            let kind: RunTask.Kind = target.contains("test") ? .test
                : (target == "build" || target == "all" ? .build
                   : (["run", "dev", "start"].contains(target) ? .run : .script))
            return RunTask(id: "make-\(target)", title: "make \(target)", executable: make,
                           arguments: [target], directory: project, kind: kind,
                           source: "Makefile", missingTool: make == nil ? "make" : nil)
        }
    }

    private static func cargoTasks(_ project: URL) -> [RunTask] {
        guard exists("Cargo.toml", in: project) else { return [] }
        let cargo = Executables.find(["\(NSHomeDirectory())/.cargo/bin/cargo"], orNamed: "cargo")
        return [("build", RunTask.Kind.build), ("test", .test), ("run", .run)].map { verb, kind in
            RunTask(id: "cargo-\(verb)", title: "cargo \(verb)", executable: cargo,
                    arguments: [verb], directory: project, kind: kind, source: "Cargo.toml",
                    missingTool: cargo == nil ? "cargo" : nil)
        }
    }

    private static func goTasks(_ project: URL) -> [RunTask] {
        guard exists("go.mod", in: project) else { return [] }
        let go = Executables.find([], orNamed: "go")
        return [("build", ["build", "./..."], RunTask.Kind.build),
                ("test", ["test", "./..."], .test)].map { verb, arguments, kind in
            RunTask(id: "go-\(verb)", title: "go \(verb) ./...", executable: go,
                    arguments: arguments, directory: project, kind: kind, source: "go.mod",
                    missingTool: go == nil ? "go" : nil)
        }
    }

    /// Run/check the file in the front tab, for languages where a single file is runnable.
    private static func fileTasks(_ file: URL, language: Language, project: URL) -> [RunTask] {
        let name = file.lastPathComponent
        switch language.id {
        case "python":
            let python = Executables.find(["/opt/homebrew/bin/python3", "/usr/bin/python3"],
                                          orNamed: "python3")
            return [RunTask(id: "file-python", title: "python3 \(name)", executable: python,
                            arguments: [file.path], directory: project, kind: .run,
                            source: "current file", missingTool: python == nil ? "python3" : nil)]
        case "javascript":
            let node = Executables.find(["/opt/homebrew/bin/node", "/usr/local/bin/node"],
                                        orNamed: "node")
            return [RunTask(id: "file-node", title: "node \(name)", executable: node,
                            arguments: [file.path], directory: project, kind: .run,
                            source: "current file", missingTool: node == nil ? "node" : nil)]
        case "shell":
            return [RunTask(id: "file-shell", title: "bash \(name)", executable: "/bin/bash",
                            arguments: [file.path], directory: project, kind: .run,
                            source: "current file")]
        case "ruby":
            return [RunTask(id: "file-ruby", title: "ruby \(name)", executable: "/usr/bin/ruby",
                            arguments: [file.path], directory: project, kind: .run,
                            source: "current file")]
        case "swift" where !exists("Package.swift", in: project):
            let swift = Executables.find(["/usr/bin/swift"], orNamed: "swift")
            return [RunTask(id: "file-swift", title: "swift \(name)", executable: swift,
                            arguments: [file.path], directory: project, kind: .run,
                            source: "current file", missingTool: swift == nil ? "swift" : nil)]
        case "c", "cpp":
            let clang = Executables.find(["/usr/bin/clang"], orNamed: "clang")
            let out = NSTemporaryDirectory() + "orrery-cc-" + file.deletingPathExtension()
                .lastPathComponent
            return [RunTask(id: "file-clang", title: "clang \(name)", executable: clang,
                            arguments: (language.id == "cpp" ? ["-std=c++17"] : [])
                                + ["-fno-caret-diagnostics", "-fno-color-diagnostics",
                                   file.path, "-o", out],
                            directory: project, kind: .build, source: "current file",
                            missingTool: clang == nil ? "clang" : nil)]
        default:
            return moreFileTasks(file, language: language, project: project)
        }
    }
}

// MARK: - Output parsing

/// Finds source locations in build and run output, so an error line is a click, not a hunt.
enum TaskOutputParser {

    private static let gccPattern = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+)(?::(\d+))?:\s*(error|warning|note|fatal error)\s*:\s*(.+)$"#)
    private static let pythonPattern = try! NSRegularExpression(
        pattern: #"^\s*File "(.+?)", line (\d+)"#)
    private static let nodeHeaderPattern = try! NSRegularExpression(
        pattern: #"^(/.+?):(\d+)$"#)

    /// A diagnostic for this line, or nil. Only paths that exist become clickable — build tools
    /// print plenty of `something: value` lines that merely look like locations.
    static func diagnostic(for line: String, directory: URL) -> Diagnostic? {
        let range = NSRange(line.startIndex..., in: line)

        if let match = gccPattern.firstMatch(in: line, range: range),
           let diagnostic = fromGCC(match, line: line, directory: directory) {
            return diagnostic
        }
        if let match = pythonPattern.firstMatch(in: line, range: range),
           let path = string(match, 1, in: line), let lineNumber = int(match, 2, in: line),
           let url = resolve(path, against: directory) {
            return Diagnostic(file: url, line: lineNumber, column: 1, severity: .error,
                              message: "Python traceback frame", source: "python")
        }
        if let match = nodeHeaderPattern.firstMatch(in: line, range: range),
           let path = string(match, 1, in: line), let lineNumber = int(match, 2, in: line),
           let url = resolve(path, against: directory),
           ["js", "mjs", "cjs", "ts"].contains(url.pathExtension) {
            return Diagnostic(file: url, line: lineNumber, column: 1, severity: .error,
                              message: "Node error location", source: "node")
        }
        return nil
    }

    private static func fromGCC(_ match: NSTextCheckingResult, line: String,
                                directory: URL) -> Diagnostic? {
        guard let path = string(match, 1, in: line), let lineNumber = int(match, 2, in: line),
              let severityWord = string(match, 4, in: line),
              let message = string(match, 5, in: line),
              let url = resolve(path, against: directory) else { return nil }
        let severity: Diagnostic.Severity
        switch severityWord {
        case "error", "fatal error": severity = .error
        case "warning": severity = .warning
        default: severity = .info
        }
        return Diagnostic(file: url, line: lineNumber, column: int(match, 3, in: line) ?? 1,
                          severity: severity, message: message, source: "task")
    }

    private static func string(_ match: NSTextCheckingResult, _ index: Int,
                               in line: String) -> String? {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: line) else { return nil }
        return String(line[range])
    }

    private static func int(_ match: NSTextCheckingResult, _ index: Int,
                            in line: String) -> Int? {
        string(match, index, in: line).flatMap(Int.init)
    }

    private static func resolve(_ path: String, against directory: URL) -> URL? {
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : directory.appendingPathComponent(path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return url
    }
}

// MARK: - Run model

/// Runs one task at a time, streaming its output into the pane as lines with any recognized
/// source locations attached. Owned by `AppModel`.
@MainActor
@Observable
final class TaskRunModel {
    var canExecute: () -> Bool = { true }
    var onFinished: (() -> Void)?

    struct OutputLine: Identifiable, Equatable {
        let id: Int
        let text: String
        let diagnostic: Diagnostic?
    }

    private(set) var tasks: [RunTask] = []
    private(set) var activeTask: RunTask?
    private(set) var lines: [OutputLine] = []
    private(set) var isRunning = false
    private(set) var exitStatus: Int32?
    private(set) var duration: TimeInterval = 0
    /// The honesty channel: why nothing ran, or what was truncated.
    private(set) var note: String?

    var problemCount: Int { lines.lazy.filter { $0.diagnostic?.severity == .error }.count }

    private var process: Process?
    private var generation = UUID()
    private var partialLine = ""
    private var nextLineID = 0
    private var startedAt = Date()
    private static let maxLines = 5_000

    func refreshTasks(project: URL?, activeFile: URL?, language: Language?) {
        tasks = TaskCatalog.tasks(project: project, activeFile: activeFile, language: language)
    }

    /// The first task of this kind, the way ⌘R picks what "Run" means here.
    func defaultTask(_ kind: RunTask.Kind) -> RunTask? {
        tasks.first { $0.kind == kind }
    }

    /// Nothing to run is said out loud, not left as a pane that quietly does nothing.
    func reportNoTask(_ kind: RunTask.Kind, project: URL?) {
        guard !isRunning else { return }
        activeTask = nil
        lines = []
        exitStatus = nil
        note = project == nil
            ? "No project is open, so there is nothing to \(kind.rawValue)."
            : "No \(kind.rawValue) task found — nothing in \(project!.lastPathComponent) "
              + "declares one (looked for Package.swift, package.json scripts, a Makefile, "
              + "Cargo.toml, go.mod, or a runnable open file)."
    }

    func run(_ task: RunTask) {
        guard canExecute() else { note = "Trust this project before running its tasks."; return }
        guard !isRunning else {
            note = "A task is already running — stop it first."
            return
        }
        guard let executable = task.executable, task.missingTool == nil else {
            activeTask = task
            lines = []
            exitStatus = nil
            note = "\(task.title) needs \(task.missingTool ?? "a tool") — not installed, "
                + "so nothing was run."
            return
        }

        activeTask = task
        let generation = UUID()
        self.generation = generation
        lines = []
        partialLine = ""
        nextLineID = 0
        exitStatus = nil
        note = nil
        duration = 0
        startedAt = Date()
        appendLine("$ \(task.title)   (\(task.directory.path))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = task.arguments
        process.currentDirectoryURL = task.directory
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment["CLICOLOR"] = "0"
        environment["PATH"] = ProcessRunner.extendedPATH(environment["PATH"])
        process.environment = environment

        // stdout and stderr share one pipe so the output interleaves the way it would in a
        // terminal — and there is one reader, not two racing ones.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.ingest(text, directory: task.directory)
            }
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.finish(status: finished.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
            isRunning = true
        } catch {
            appendLine("could not start: \(error.localizedDescription)")
            exitStatus = -1
        }
    }

    private func ingest(_ text: String, directory: URL) {
        partialLine += text
        var pieces = partialLine.components(separatedBy: "\n")
        partialLine = pieces.removeLast()
        for piece in pieces {
            appendLine(String(piece.prefix(32_768)), directory: directory)
        }
        if partialLine.utf8.count > 32_768 {
            appendLine(String(partialLine.prefix(32_768)) + " … [line truncated]", directory: directory)
            partialLine = ""
        }
    }

    /// Text from a plugin command or save hook, shown in the Output pane under its name.
    func appendExternal(_ text: String, source: String) {
        appendLine("── \(source)")
        for line in text.components(separatedBy: "\n") where !line.isEmpty { appendLine(line) }
    }

    private func appendLine(_ text: String, directory: URL? = nil) {
        let diagnostic = directory.flatMap {
            TaskOutputParser.diagnostic(for: text, directory: $0)
        }
        lines.append(OutputLine(id: nextLineID, text: text, diagnostic: diagnostic))
        nextLineID += 1
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
            note = "Output exceeded \(Self.maxLines) lines — the oldest were dropped."
        }
    }

    private func finish(status: Int32) {
        if !partialLine.isEmpty {
            appendLine(partialLine, directory: activeTask?.directory)
            partialLine = ""
        }
        duration = Date().timeIntervalSince(startedAt)
        exitStatus = status
        isRunning = false
        process = nil
        appendLine(String(format: "— exited %d in %.1fs", status, duration))
        onFinished?()
    }

    func stop() {
        guard let process, isRunning else { return }
        process.terminate()
        appendLine("— stop requested")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.isRunning, self.process === process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

import CryptoKit
import Foundation

/// One named calibration: a single-item orchestration run in an isolated copy of
/// the project, recorded with `kind=calibration` so it cannot move real-world
/// seat stats.
struct CalibrationTask: Equatable, Sendable {
    var id: String
    var prompt: String
    /// Substrings that must appear in the copy's `--audit` output (the `── name`
    /// section headers `Auditor.section` prints).
    var requiredAuditSections: [String]
    /// When true, pass requires the item's acceptance gate to have actually passed.
    var requiresAcceptanceGate: Bool
}

/// Isolated, flag-driven calibration harness. Live `--calibrate` spends quota;
/// `--audit` drives the same code with `ScriptedBackend` and never does.
enum Calibration {

    static let tasks: [CalibrationTask] = [
        CalibrationTask(
            id: "calibration-jsonvalidator",
            prompt: "in the isolated copy, extend JSONValidator to reject unpaired UTF-16 "
                + "surrogate escapes (e.g. \\ud800 alone) with a precise line/column error, "
                + "and add matching checks to AuditDiagnostics",
            requiredAuditSections: ["Diagnostics — JSON (built in)"],
            requiresAcceptanceGate: true),
    ]

    static func task(id: String) -> CalibrationTask? {
        tasks.first { $0.id == id }
    }

    /// Package root of this source file. Isolation hashes and copies from here.
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Orchestrator
            .deletingLastPathComponent() // Orrery
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // package
            .standardizedFileURL
    }

    // MARK: Flag parsing

    struct Spec: Equatable {
        var task: CalibrationTask
        var author: Provider
        var model: String?
        var effort: String?

        /// `grok`, `grok:grok-4.6`, or `grok:grok-4.6:xhigh` — the token after `author=`.
        var authorToken: String {
            var token = author.rawValue
            if let model {
                token += ":" + model
                if let effort { token += ":" + effort }
            }
            return token
        }

        /// The one stdout line a successful parse prints (and `--audit` short-circuits to).
        var line: String { "calibrate: \(task.id) author=\(authorToken)" }
    }

    enum ParseError: Error, Equatable {
        case unknownTask(String)
        case malformedAuthor
        case unknownProvider(String)

        var line: String {
            switch self {
            case .unknownTask(let id):
                return "calibrate: unknown task id '\(id)'"
            case .malformedAuthor:
                return "calibrate: malformed author spec"
            case .unknownProvider(let name):
                return "calibrate: unknown provider '\(name)'"
            }
        }
    }

    static let missingValueLine =
        "calibrate: --calibrate needs \"<taskID> author=<provider>[:<model>[:<effort>]]\""

    static let noProjectLine =
        "calibrate: no project — pass a project path or open one"

    /// `"<taskID> author=<provider>[:<model>[:<effort>]]"`. Task id is checked first so
    /// an unknown task with a also-bad author spec still prints the unknown-task line.
    static func parse(_ raw: String) -> Result<Spec, ParseError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.split { $0.isWhitespace }.map(String.init)
        guard let taskID = tokens.first, !taskID.isEmpty else {
            return .failure(.malformedAuthor)
        }
        guard let task = task(id: taskID) else {
            return .failure(.unknownTask(taskID))
        }
        guard tokens.count == 2, tokens[1].hasPrefix("author=") else {
            return .failure(.malformedAuthor)
        }
        let spec = String(tokens[1].dropFirst("author=".count))
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard !spec.isEmpty, (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty }) else {
            return .failure(.malformedAuthor)
        }
        guard let provider = Provider(rawValue: parts[0]) else {
            return .failure(.unknownProvider(parts[0]))
        }
        let model = parts.count >= 2 ? parts[1] : nil
        let effort = parts.count == 3 ? parts[2] : nil
        return .success(Spec(task: task, author: provider, model: model, effort: effort))
    }

    /// First of claude, grok, codex that is not the author. Planner-assignment is
    /// not involved; reviewer ≠ author still holds.
    static func fixedReviewer(for author: Provider) -> Provider {
        for candidate in [Provider.claude, .grok, .codex] where candidate != author {
            return candidate
        }
        return .claude
    }

    // MARK: Isolated copy

    /// Names skipped when copying or hashing the working tree.
    ///
    /// `.build` is SwiftPM's product dir — copying it would ship a stale binary
    /// that can mask a red gate, and hashing it would flake while an audit
    /// compiles. `build/` is the `.app` bundle from `build-app.sh`. `.swiftpm`
    /// is workspace state. `scratchpad` is generated shots and run logs, not
    /// source. Hidden entries (`.DS_Store`) are skipped by the directory
    /// options. Sources, Tests, Package.swift, Resources, and docs come along,
    /// so the copy still `swift build`s and `--audit`s — otherwise the pass
    /// criteria would be a comment.
    static let copySkipNames: Set<String> = [
        ".build", "build", ".swiftpm", "scratchpad",
    ]

    static func copyProject(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try visit(source, root: source) { url, relative, isDirectory in
            let target = dest.appendingPathComponent(relative)
            if isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: target)
            }
        }
    }

    /// SHA-256 of every copied file (relative path + contents), sorted. Same
    /// skip set as the copy, so a `.build` write during `--audit` cannot look
    /// like an isolation failure.
    static func treeDigest(_ root: URL) -> String {
        var files: [(String, Data)] = []
        try? visit(root, root: root) { url, relative, isDirectory in
            guard !isDirectory, let data = try? Data(contentsOf: url) else { return }
            files.append((relative, data))
        }
        files.sort { $0.0 < $1.0 }
        var hasher = SHA256()
        for (relative, data) in files {
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: data)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func visit(_ dir: URL, root: URL,
                              body: (URL, String, Bool) throws -> Void) throws {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        for item in items {
            let name = item.lastPathComponent
            if copySkipNames.contains(name) { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            let relative = relativePath(item, from: root)
            if isDir.boolValue {
                try body(item, relative, true)
                try visit(item, root: root, body: body)
            } else {
                try body(item, relative, false)
            }
        }
    }

    private static func relativePath(_ url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return "" }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    // MARK: Launch dispatch

    /// `--audit` never starts a live (quota-spending) calibration. Parse errors
    /// and the canonical parsed line still go through this so FLAG PARSING can
    /// assert on `openLaunchArguments` without calling `parse` directly.
    @MainActor
    static func handleLaunch(_ raw: String, project: URL?,
                             makeBackend: @escaping (Provider) -> any AgentBackend)
        async -> String {
        switch parse(raw) {
        case .failure(let error):
            return error.line
        case .success(let spec):
            if CommandLine.arguments.contains("--audit") {
                return spec.line
            }
            guard let project else { return noProjectLine }
            let result = await run(
                spec: spec,
                sourceRoot: project,
                storeURL: TeamStats.storeURL,
                makeBackend: makeBackend,
                followGate: true,
                evaluatePassCriteria: true,
                turnTimeout: 300,
                leaveCopy: false,
                runTimeout: nil,
                includeCopyAudit: true)
            return result.line
        }
    }

    // MARK: Run

    struct RunResult {
        var line: String
        var copyRoot: URL
        var sourceDigestBefore: String
        var sourceDigestAfter: String
        var recordedKind: String?
        var authorProjectURL: URL?
        var copyDeleted: Bool
    }

    /// Copy `sourceRoot` to a temp dir and run a single prepared item there.
    /// The real tree is never opened for writing. `leaveCopy` keeps the temp
    /// tree so an isolation audit can inspect the agent's writes.
    @MainActor
    static func run(spec: Spec,
                    sourceRoot: URL,
                    storeURL: URL,
                    makeBackend: @escaping (Provider) -> any AgentBackend,
                    followGate: Bool,
                    evaluatePassCriteria: Bool,
                    turnTimeout: TimeInterval,
                    leaveCopy: Bool,
                    installedProviders: [Provider]? = nil,
                    runTimeout: TimeInterval? = nil,
                    includeCopyAudit: Bool = true) async -> RunResult {
        let reviewer = fixedReviewer(for: spec.author)
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-calibrate-\(UUID().uuidString)")
        let before = treeDigest(sourceRoot)
        do {
            try copyProject(from: sourceRoot, to: dest)
        } catch {
            return RunResult(line: "calibrate: could not isolate the project: \(error)",
                             copyRoot: dest, sourceDigestBefore: before,
                             sourceDigestAfter: treeDigest(sourceRoot),
                             recordedKind: nil, authorProjectURL: nil,
                             copyDeleted: false)
        }

        let engine = Orchestrator()
        let providers = installedProviders ?? Array(Set([spec.author, reviewer]))
        engine.installedProviders = Provider.allCases.filter { providers.contains($0) }
        if !engine.installedProviders.contains(spec.author) {
            engine.installedProviders.append(spec.author)
        }
        if !engine.installedProviders.contains(reviewer) {
            engine.installedProviders.append(reviewer)
        }
        engine.orchestratorProvider = reviewer
        engine.disabledWorkers = []
        engine.followGate = followGate
        engine.followEdits = false
        engine.turnTimeout = turnTimeout
        // Append ourselves after pass criteria so a printed failure cannot
        // land in the store as a clean accept. The engine's auto-record
        // fires as soon as phase becomes .done.
        engine.teamStatsURL = nil
        engine.teamStatsKind = TeamStats.kindCalibration
        engine.maxRounds = 2
        if let model = spec.model {
            engine.roleModelOverrides[.author, default: [:]][spec.author] = model
        }
        if let effort = spec.effort {
            engine.roleEffortOverrides[.author, default: [:]][spec.author] = effort
        }
        var created: [any AgentBackend] = []
        engine.makeBackend = { provider in
            let backend = makeBackend(provider)
            created.append(backend)
            return backend
        }

        engine.startPreparedItem(title: spec.task.id, brief: spec.task.prompt,
                                 author: spec.author, reviewer: reviewer,
                                 roundBudget: 2, project: dest)
        let finished = await waitWhileRunning(engine, timeout: runTimeout)
        if !finished {
            // A discarded timeout used to fall through into evaluate + delete
            // while the author was still streaming. Stop first; do not audit
            // or unlink the copy out from under a live agent.
            if engine.isRunning { engine.stop() }
            _ = await waitUntil(2) { !engine.isRunning }
        }
        let authorProject = created.compactMap { ($0 as? ScriptedBackend)?.projectURL }.first
        let after = treeDigest(sourceRoot)
        let item = engine.items.first

        var line = spec.line
        if !finished {
            line = spec.line + " fail: still running"
        } else if evaluatePassCriteria {
            let verdict = await evaluate(spec.task, copyRoot: dest, item: item,
                                         includeCopyAudit: includeCopyAudit)
            line = verdict.passed ? spec.line + " pass"
                : spec.line + " fail: " + verdict.detail
            if !verdict.passed {
                // Reviewer-accepted work that failed the calibration bar is
                // not a clean accept in the store.
                for work in engine.items where work.state == .accepted {
                    work.state = .failed
                }
            }
        } else if let item {
            line = spec.line + " " + item.state.rawValue
        } else if case let .failed(reason) = engine.phase {
            line = spec.line + " fail: " + reason
        }

        switch engine.phase {
        case .done, .cancelled, .failed:
            TeamStats.append(TeamStats.outcome(from: engine), to: storeURL)
        default:
            break
        }
        let recorded = TeamStats.load(from: storeURL).records.last

        var copyDeleted = false
        if !leaveCopy {
            try? FileManager.default.removeItem(at: dest)
            copyDeleted = true
        }
        return RunResult(line: line, copyRoot: dest, sourceDigestBefore: before,
                         sourceDigestAfter: after,
                         recordedKind: recorded?.kind,
                         authorProjectURL: authorProject,
                         copyDeleted: copyDeleted)
    }

    // MARK: Pass criteria

    struct Verdict {
        var passed: Bool
        var detail: String
    }

    /// Inspects the isolated copy — the source files and a real `--audit` run
    /// inside it. A comment claiming the work was done is not a pass.
    @MainActor
    static func evaluate(_ task: CalibrationTask, copyRoot: URL,
                         item: WorkItem?, includeCopyAudit: Bool = true) async -> Verdict {
        var reasons: [String] = []
        if task.requiresAcceptanceGate {
            if item?.gate?.passed != true {
                reasons.append("acceptance gate did not pass")
            }
        }
        if task.id == "calibration-jsonvalidator",
           !jsonValidatorWorkPresent(in: copyRoot) {
            reasons.append("copy does not reject unpaired surrogates with a line/column check "
                           + "and matching AuditDiagnostics assertions")
        }
        if includeCopyAudit {
            let audit = await runCopyAudit(copyRoot)
            for section in task.requiredAuditSections {
                if !audit.output.contains("── \(section)") {
                    reasons.append("missing audit section '\(section)'")
                }
            }
            if audit.exitCode != 0 || audit.output.contains("FAILED")
                || !audit.output.contains("checks passed") {
                reasons.append("copy audit was not green (exit \(audit.exitCode))")
            }
        }
        if reasons.isEmpty {
            return Verdict(passed: true, detail: "pass")
        }
        return Verdict(passed: false, detail: reasons.joined(separator: "; "))
    }

    /// Compiles the copy's `JSONValidator` and runs `checkJSON` on planted
    /// unpaired `\ud800` and `\udc00` fixtures (top-level, nested
    /// objects/arrays, start / middle / end) plus valid controls (plain JSON
    /// and a well-formed `\ud800\udc00` pair). Each unpaired hit must match
    /// the planted line **and** column exactly. "Something was detected
    /// somewhere" is not a pass. A validator that rejects only high surrogates
    /// does not pass. A validator that rejects a valid pair does not pass.
    /// AuditDiagnostics must invoke `checkJSON`/`expectJSON` on each planted
    /// fixture as that call's JSON-text argument and assert that fixture's
    /// exact line and column on that call (labeled arguments, a postfix
    /// on that call including a named closure parameter, or assertions on
    /// a local that stores that call's result). An `audit.check` that only
    /// names the fixture and assigns `line`/`column` is not a pass. A
    /// `checkJSON` of the fixture whose enclosing `audit.check` is always
    /// true and only constructs `Diagnostic(line:column:)`, assigns
    /// `.line`/`.column`, or compares an unrelated diagnostic's
    /// `.line`/`.column` is not a pass. Nested `checkJSON` calls do not
    /// inherit assertions from each other. A `checkJSON` of clean JSON that
    /// only names the fixture in `url:` or a nested closure is not a pass.
    static func jsonValidatorWorkPresent(in copyRoot: URL) -> Bool {
        guard let result = probeUnpairedSurrogate(in: copyRoot),
              result.validJSONErrorCount == 0 else { return false }
        guard unpairedHitsMatch(result.hits) else { return false }
        return auditDiagnosticsMatchesSurrogates(in: copyRoot)
    }

    /// One planted unpaired-surrogate JSON snippet and the 1-based line/column
    /// of the backslash that starts its `\uXXXX` escape.
    struct SurrogateFixture: Equatable {
        var name: String
        var json: String
        var line: Int
        var column: Int
    }

    struct SurrogateProbeHit: Equatable {
        var name: String
        var line: Int
        var column: Int
        var message: String
    }

    struct SurrogateProbeResult: Equatable {
        var validJSONErrorCount: Int
        var hits: [SurrogateProbeHit]
    }

    /// Lone high (`\ud800`) and lone low (`\udc00`) surrogates in multiple
    /// positions, including nested containers. Column is the backslash of
    /// the `\u` escape. High-only coverage is not enough.
    static let surrogateFixtures: [SurrogateFixture] = [
        SurrogateFixture(name: "top-value", json: #"{"x":"\ud800"}"#,
                         line: 1, column: 7),
        SurrogateFixture(name: "top-string-start", json: #""\ud800""#,
                         line: 1, column: 2),
        SurrogateFixture(name: "object-key", json: #"{"\ud800":1}"#,
                         line: 1, column: 3),
        SurrogateFixture(name: "nested-object", json: #"{"a":{"b":"\ud800"}}"#,
                         line: 1, column: 12),
        SurrogateFixture(name: "nested-array", json: #"{"a":["\ud800"]}"#,
                         line: 1, column: 8),
        SurrogateFixture(name: "array-in-object", json: #"{"a":[{"b":"\ud800"}]}"#,
                         line: 1, column: 13),
        SurrogateFixture(name: "object-in-array", json: #"[{"k":"\ud800"}]"#,
                         line: 1, column: 8),
        SurrogateFixture(name: "nested-multiline-middle",
                         json: "{\n  \"a\": [\n    {\"b\": \"\\ud800\"}\n  ]\n}",
                         line: 3, column: 12),
        SurrogateFixture(name: "nested-multiline-end",
                         json: "[\n  true,\n  {\"z\": \"\\ud800\"}\n]",
                         line: 3, column: 10),
        SurrogateFixture(name: "top-value-low", json: #"{"x":"\udc00"}"#,
                         line: 1, column: 7),
        SurrogateFixture(name: "top-string-start-low", json: #""\udc00""#,
                         line: 1, column: 2),
        SurrogateFixture(name: "object-key-low", json: #"{"\udc00":1}"#,
                         line: 1, column: 3),
        SurrogateFixture(name: "nested-object-low", json: #"{"a":{"b":"\udc00"}}"#,
                         line: 1, column: 12),
        SurrogateFixture(name: "nested-array-low", json: #"{"a":["\udc00"]}"#,
                         line: 1, column: 8),
        SurrogateFixture(name: "array-in-object-low", json: #"{"a":[{"b":"\udc00"}]}"#,
                         line: 1, column: 13),
        SurrogateFixture(name: "object-in-array-low", json: #"[{"k":"\udc00"}]"#,
                         line: 1, column: 8),
        SurrogateFixture(name: "nested-multiline-middle-low",
                         json: "{\n  \"a\": [\n    {\"b\": \"\\udc00\"}\n  ]\n}",
                         line: 3, column: 12),
        SurrogateFixture(name: "nested-multiline-end-low",
                         json: "[\n  true,\n  {\"z\": \"\\udc00\"}\n]",
                         line: 3, column: 10),
    ]

    /// JSON that must stay clean. `{"ok":true}` alone is not enough: a
    /// validator that rejects every surrogate escape — including a valid
    /// `\ud800\udc00` pair — would still leave that object error-free.
    static let validJSONControls: [String] = [
        #"{"ok":true}"#,
        #"{"ok":"\ud800\udc00"}"#,
    ]

    /// Run `checkJSON` on every planted fixture and on valid JSON. Exact line
    /// and exact column required; an off-by-one column is a miss. A valid
    /// paired surrogate must stay clean.
    @MainActor
    static func unpairedSurrogateReachability(
        checkJSON: (String, URL) -> [Diagnostic]
    ) -> Bool {
        let url = URL(fileURLWithPath: "/tmp/probe.json")
        for control in validJSONControls {
            let valid = checkJSON(control, url)
                .filter { $0.severity == .error }
            guard valid.isEmpty else { return false }
        }
        var hits: [SurrogateProbeHit] = []
        for fixture in surrogateFixtures {
            let found = checkJSON(fixture.json, url)
                .filter { $0.severity == .error }
            guard let diagnostic = found.first else { return false }
            hits.append(SurrogateProbeHit(name: fixture.name,
                                          line: diagnostic.line,
                                          column: diagnostic.column,
                                          message: diagnostic.message))
        }
        return unpairedHitsMatch(hits)
    }

    static func unpairedHitsMatch(_ hits: [SurrogateProbeHit]) -> Bool {
        guard hits.count == surrogateFixtures.count else { return false }
        for (hit, fixture) in zip(hits, surrogateFixtures) {
            guard hit.name == fixture.name,
                  hit.line == fixture.line,
                  hit.column == fixture.column else { return false }
            let msg = hit.message.lowercased()
            guard msg.contains("surrogate") || msg.contains("unpaired") else {
                return false
            }
        }
        return true
    }

    /// Compile the copy's validator (plus `Diagnostic.swift`) and execute
    /// `checkJSON` (a local wrapper around `JSONValidator.validate`) on every
    /// planted fixture. Returns nil when the probe cannot compile.
    static func probeUnpairedSurrogate(in copyRoot: URL) -> SurrogateProbeResult? {
        let validator = copyRoot
            .appendingPathComponent("Sources/Orrery/Diagnostics/JSONValidator.swift")
        guard FileManager.default.fileExists(atPath: validator.path) else { return nil }
        let copyDiag = copyRoot
            .appendingPathComponent("Sources/Orrery/Diagnostics/Diagnostic.swift")
        let diagnostic = FileManager.default.fileExists(atPath: copyDiag.path)
            ? copyDiag
            : packageRoot.appendingPathComponent("Sources/Orrery/Diagnostics/Diagnostic.swift")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-surr-probe-" + String(UUID().uuidString.prefix(8)))
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let vDest = tmp.appendingPathComponent("JSONValidator.swift")
        let dDest = tmp.appendingPathComponent("Diagnostic.swift")
        let mainDest = tmp.appendingPathComponent("main.swift")
        let exe = tmp.appendingPathComponent("probe")
        do {
            try FileManager.default.copyItem(at: validator, to: vDest)
            try FileManager.default.copyItem(at: diagnostic, to: dDest)
            try probeMainSource.write(to: mainDest, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        compile.arguments = ["-swift-version", "5", "-o", exe.path,
                             dDest.path, vDest.path, mainDest.path]
        compile.currentDirectoryURL = tmp
        compile.standardOutput = FileHandle.nullDevice
        compile.standardError = FileHandle.nullDevice
        do { try compile.run() } catch { return nil }
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else { return nil }
        let run = Process()
        run.executableURL = exe
        let pipe = Pipe()
        run.standardOutput = pipe
        run.standardError = FileHandle.nullDevice
        do { try run.run() } catch { return nil }
        run.waitUntilExit()
        guard run.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        return parseProbeOutput(out)
    }

    /// Driver compiled against the copy's validator. Calls `checkJSON` — the
    /// same function `DiagnosticsEngine.checkJSON` is — on every planted
    /// fixture. Valid controls (plain JSON and a paired surrogate) must stay
    /// clean.
    private static var probeMainSource: String {
        var lines: [String] = [
            "import Foundation",
            "let url = URL(fileURLWithPath: \"/tmp/probe.json\")",
            "func checkJSON(_ text: String, url: URL) -> [Diagnostic] {",
            "    JSONValidator.validate(text, url: url)",
            "}",
            "var validErrors = 0",
        ]
        for control in validJSONControls {
            lines.append("do {")
            lines.append("    let text = " + swiftRawStringLiteral(control))
            lines.append("    let good = checkJSON(text, url: url)")
            lines.append("        .filter { $0.severity == Diagnostic.Severity.error }")
            lines.append("    validErrors += good.count")
            lines.append("}")
        }
        lines.append("print(\"VALID_ERRORS=\\(validErrors)\")")
        for fixture in surrogateFixtures {
            lines.append("do {")
            lines.append("    let text = " + swiftRawStringLiteral(fixture.json))
            lines.append("    let bad = checkJSON(text, url: url)")
            lines.append("        .filter { $0.severity == Diagnostic.Severity.error }")
            lines.append("    print(\"FIXTURE=\(fixture.name)\")")
            lines.append("    if let d = bad.first {")
            lines.append("        print(\"LINE=\\(d.line)\")")
            lines.append("        print(\"COLUMN=\\(d.column)\")")
            lines.append("        print(\"MSG=\\(d.message)\")")
            lines.append("    } else { print(\"NONE\") }")
            lines.append("}")
        }
        return lines.joined(separator: "\n")
    }

    /// Embed `text` as a Swift raw string literal in generated probe source.
    private static func swiftRawStringLiteral(_ text: String) -> String {
        var hashes = "#"
        while text.contains("\"" + hashes) || text.contains(hashes + "\"") {
            hashes += "#"
        }
        return hashes + "\"\"\"\n" + text + "\n\"\"\"" + hashes
    }

    private static func parseProbeOutput(_ out: String) -> SurrogateProbeResult? {
        var validErrors: Int?
        var hits: [SurrogateProbeHit] = []
        var currentName: String?
        var line: Int?
        var column: Int?
        var message: String?

        func flushHit() {
            if let name = currentName, let line, let column, let message {
                hits.append(SurrogateProbeHit(name: name, line: line,
                                              column: column, message: message))
            }
            currentName = nil
            line = nil
            column = nil
            message = nil
        }

        for raw in out.split(whereSeparator: \.isNewline) {
            let row = String(raw)
            if row.hasPrefix("VALID_ERRORS="),
               let n = Int(row.dropFirst("VALID_ERRORS=".count)) {
                validErrors = n
            } else if row.hasPrefix("FIXTURE=") {
                flushHit()
                currentName = String(row.dropFirst("FIXTURE=".count))
            } else if row == "NONE" {
                currentName = nil
                line = nil
                column = nil
                message = nil
            } else if row.hasPrefix("LINE="),
                      let n = Int(row.dropFirst("LINE=".count)) {
                line = n
            } else if row.hasPrefix("COLUMN="),
                      let n = Int(row.dropFirst("COLUMN=".count)) {
                column = n
            } else if row.hasPrefix("MSG=") {
                message = String(row.dropFirst("MSG=".count))
            }
        }
        flushHit()
        guard let validErrors else { return nil }
        return SurrogateProbeResult(validJSONErrorCount: validErrors, hits: hits)
    }

    /// True when the copy's AuditDiagnostics.swift invokes `checkJSON` or
    /// `expectJSON` on every planted unpaired fixture and asserts that
    /// fixture's exact line and column on that call. The fixture literal
    /// must be the JSON-text argument of the checker (first unlabeled
    /// argument of `checkJSON`, second of `expectJSON`, or `text:`) — not a
    /// string in `url:`, a nested closure, or merely nearby in an outer
    /// `audit.check`. Location is taken from that call's labeled
    /// `line:`/`column:` arguments, from a postfix on that call
    /// (`.first.map { $0.line == N && $0.column == M }`, a named closure
    /// parameter `{ diag in diag.line == N }`, `.first?.line, N`), and from
    /// later comparisons on a local that stores the result
    /// (`let found = checkJSON(...); found.first?.line, N`). Comparisons in
    /// an enclosing `audit.check` are not shared across nested checkers;
    /// `other.line == N` next to an uninspected `checkJSON` is not a pass.
    static func auditDiagnosticsMatchesSurrogates(in copyRoot: URL) -> Bool {
        let url = copyRoot
            .appendingPathComponent("Sources/Orrery/Audit/AuditDiagnostics.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let regions = checkerCallRegions(in: source)
        return surrogateFixtures.allSatisfy { fixture in
            regions.contains { feed in
                feed.isJSONFeed && feed.jsonText == fixture.json && feed.asserts(fixture)
            }
        }
    }

    /// AuditDiagnostics source used by honesty checks; not the live tree.
    /// Default: each fixture is the JSON-text argument of `checkJSON`, with
    /// `$0.line` and `$0.column` asserted in a postfix on that call.
    /// `invokeJSONChecker: false` writes an always-true `audit.check` that
    /// only names the fixture and assigns `line`/`column`.
    /// `jsonCheckerArgument` feeds that string to `checkJSON` instead of the
    /// fixture (the fixture literal is still present, unused).
    /// `placeFixtureInURL` validates clean JSON and puts the fixture in `url:`.
    /// `placeFixtureInNestedClosure` validates clean JSON and names the fixture
    /// inside a closure that is the JSON-text argument.
    /// `placeUnrelatedDiagnostic` calls `checkJSON` on the fixture but never
    /// inspects the result; an always-true `audit.check` constructs
    /// `Diagnostic(line:column:)` and assigns `.line`/`.column`.
    /// `placeUnrelatedComparison` calls `checkJSON` on the fixture and
    /// compares `unrelated.line`/`unrelated.column` in the enclosing check.
    /// `shareEnclosingAssertions` puts every fixture `checkJSON` in one
    /// `audit.check` and compares an unrelated diagnostic at every planted
    /// line/column.
    /// `storeCheckerResult` assigns the `checkJSON` result to a local and
    /// asserts that local's `.line`/`.column`.
    /// `namedClosureParameter` uses `{ diag in diag.line == N }` instead of `$0`.
    /// `placeUnrelatedNamedClosure` uses a named parameter but compares
    /// `unrelated.line`/`unrelated.column`.
    static func surrogateAuditDiagnosticsSource(
        covering fixtures: [SurrogateFixture] = surrogateFixtures,
        columnOffset: Int = 0,
        invokeJSONChecker: Bool = true,
        jsonCheckerArgument: String? = nil,
        placeFixtureInURL: Bool = false,
        placeFixtureInNestedClosure: Bool = false,
        placeUnrelatedDiagnostic: Bool = false,
        placeUnrelatedComparison: Bool = false,
        shareEnclosingAssertions: Bool = false,
        storeCheckerResult: Bool = false,
        namedClosureParameter: Bool = false,
        placeUnrelatedNamedClosure: Bool = false
    ) -> String {
        var lines = [
            "import Foundation",
            "enum AuditDiagnostics {",
            "    static func run(_ audit: Auditor) {",
            "        let jsonURL = URL(fileURLWithPath: \"/tmp/audit.json\")",
        ]
        if shareEnclosingAssertions {
            lines.append("        audit.check(\"all planted surrogates\", {")
            for fixture in fixtures {
                let jsonLit = swiftRawStringLiteral(fixture.json)
                lines.append("            _ = DiagnosticsEngine.checkJSON(\(jsonLit), url: jsonURL)")
            }
            if let first = fixtures.first {
                let column = first.column + columnOffset
                lines.append("            return unrelated.line == \(first.line) && unrelated.column == \(column)")
                for fixture in fixtures.dropFirst() {
                    let column = fixture.column + columnOffset
                    lines.append("                && unrelated.line == \(fixture.line) && unrelated.column == \(column)")
                }
            } else {
                lines.append("            return true")
            }
            lines.append("        }())")
        } else {
        for fixture in fixtures {
            let jsonLit = swiftRawStringLiteral(fixture.json)
            let column = fixture.column + columnOffset
            if invokeJSONChecker, placeFixtureInURL {
                let cleanLit = swiftRawStringLiteral(jsonCheckerArgument ?? #"{"ok":true}"#)
                lines.append("        audit.check(\"\(fixture.name)\", DiagnosticsEngine.checkJSON(")
                lines.append("            \(cleanLit), url: URL(fileURLWithPath: \(jsonLit))).first.map {")
                lines.append("            $0.line == \(fixture.line) && $0.column == \(column)")
                lines.append("        } ?? false)")
            } else if invokeJSONChecker, placeFixtureInNestedClosure {
                let cleanLit = swiftRawStringLiteral(jsonCheckerArgument ?? #"{"ok":true}"#)
                lines.append("        audit.check(\"\(fixture.name)\", DiagnosticsEngine.checkJSON({")
                lines.append("            _ = \(jsonLit)")
                lines.append("            return \(cleanLit)")
                lines.append("        }(), url: jsonURL).first.map {")
                lines.append("            $0.line == \(fixture.line) && $0.column == \(column)")
                lines.append("        } ?? false)")
            } else if invokeJSONChecker, placeUnrelatedDiagnostic {
                lines.append("        audit.check(\"\(fixture.name)\", {")
                lines.append("            _ = DiagnosticsEngine.checkJSON(\(jsonLit), url: jsonURL)")
                lines.append("            var dummy = Diagnostic(file: jsonURL, line: \(fixture.line), column: \(column),")
                lines.append("                                   severity: .error, message: \"unused\", source: \"JSON\")")
                lines.append("            dummy.line = \(fixture.line)")
                lines.append("            dummy.column = \(column)")
                lines.append("            return true")
                lines.append("        }())")
            } else if invokeJSONChecker, placeUnrelatedComparison {
                lines.append("        audit.check(\"\(fixture.name)\", {")
                lines.append("            _ = DiagnosticsEngine.checkJSON(\(jsonLit), url: jsonURL)")
                lines.append("            return unrelated.line == \(fixture.line)")
                lines.append("                && unrelated.column == \(column)")
                lines.append("        }())")
            } else if invokeJSONChecker, storeCheckerResult {
                lines.append("        do {")
                lines.append("            let found = DiagnosticsEngine.checkJSON(\(jsonLit), url: jsonURL)")
                lines.append("            audit.equal(\"\(fixture.name) line\", found.first?.line, \(fixture.line))")
                lines.append("            audit.equal(\"\(fixture.name) column\", found.first?.column, \(column))")
                lines.append("        }")
            } else if invokeJSONChecker, namedClosureParameter {
                lines.append("        audit.check(\"\(fixture.name)\", DiagnosticsEngine.checkJSON(")
                lines.append("            \(jsonLit), url: jsonURL).first.map { diag in")
                lines.append("            diag.line == \(fixture.line) && diag.column == \(column)")
                lines.append("        } ?? false)")
            } else if invokeJSONChecker, placeUnrelatedNamedClosure {
                lines.append("        audit.check(\"\(fixture.name)\", DiagnosticsEngine.checkJSON(")
                lines.append("            \(jsonLit), url: jsonURL).first.map { diag in")
                lines.append("            unrelated.line == \(fixture.line) && unrelated.column == \(column)")
                lines.append("        } ?? false)")
            } else if invokeJSONChecker, jsonCheckerArgument == nil {
                lines.append("        audit.check(\"\(fixture.name)\", DiagnosticsEngine.checkJSON(")
                lines.append("            \(jsonLit), url: jsonURL).first.map {")
                lines.append("            $0.line == \(fixture.line) && $0.column == \(column)")
                lines.append("        } ?? false)")
            } else if invokeJSONChecker, let argument = jsonCheckerArgument {
                let fedLit = swiftRawStringLiteral(argument)
                lines.append("        audit.check(\"\(fixture.name)\", {")
                lines.append("            _ = DiagnosticsEngine.checkJSON(\(fedLit), url: jsonURL)")
                lines.append("            let unused = \(jsonLit)")
                lines.append("            return dummy.line == \(fixture.line)")
                lines.append("                && dummy.column == \(column)")
                lines.append("        }())")
            } else {
                lines.append("        audit.check(\"\(fixture.name)\", {")
                lines.append("            let json = \(jsonLit)")
                lines.append("            let line = \(fixture.line)")
                lines.append("            let column = \(column)")
                lines.append("            return true")
                lines.append("        }())")
            }
        }
        }
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    static var exactSurrogateAuditDiagnosticsSource: String {
        surrogateAuditDiagnosticsSource()
    }

    private struct CallRegion {
        var names: [String]
        var start: Int
        var end: Int
        var jsonText: String?
        /// `.line == N` / `.column == N` comparisons, or `audit.equal` arguments.
        var lines: [Int]
        var columns: [Int]
        /// `line: N` / `column: N` labeled arguments or initializers.
        var labeledLines: [Int]
        var labeledColumns: [Int]

        var isJSONFeed: Bool {
            names == ["checkJSON"] || names == ["expectJSON"]
        }

        func asserts(_ fixture: SurrogateFixture) -> Bool {
            var lines = self.lines
            var columns = self.columns
            if isJSONFeed {
                lines.append(contentsOf: labeledLines)
                columns.append(contentsOf: labeledColumns)
            }
            return lines.contains(fixture.line) && columns.contains(fixture.column)
        }
    }

    private struct CallArgument {
        var label: String?
        var text: String
    }

    private static let checkerCallNames: [[String]] = [
        ["audit", "check"],
        ["audit", "equal"],
        ["expectJSON"],
        ["checkJSON"],
    ]

    /// Every `checkJSON`/`expectJSON`/`audit.check`/`audit.equal` call, including
    /// nested ones. Inner JSON checkers are not skipped when an outer
    /// `audit.check` wraps them.
    private static func checkerCallRegions(in source: String) -> [CallRegion] {
        let chars = Array(source)
        var i = 0
        var regions: [CallRegion] = []
        while i < chars.count {
            if skipStringOrComment(chars, &i) { continue }
            for parts in checkerCallNames {
                guard let nameEnd = matchQualifiedName(parts, chars, at: i) else { continue }
                var j = nameEnd
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                guard j < chars.count, chars[j] == "(" else { continue }
                guard let close = matchingParen(chars, open: j) else { continue }
                let callSource = String(chars[i...close])
                let isFeed = parts == ["checkJSON"] || parts == ["expectJSON"]
                let assertionEnd = isFeed ? assertionSpanEnd(chars, callClose: close) : close
                let assertionSource = String(chars[i...assertionEnd])
                let callParsed = parseCallRegion(callSource)
                let asserted = parseCallRegion(assertionSource)
                var lines = asserted.lines
                var columns = asserted.columns
                if isFeed, let binding = resultBindingName(chars, before: i) {
                    let extra = assertionsOnBinding(chars, name: binding, after: assertionEnd)
                    lines.append(contentsOf: extra.lines)
                    columns.append(contentsOf: extra.columns)
                }
                regions.append(CallRegion(names: parts, start: i, end: assertionEnd,
                                          jsonText: jsonTextLiteral(in: callSource, names: parts),
                                          lines: lines,
                                          columns: columns,
                                          labeledLines: callParsed.labeledLines,
                                          labeledColumns: callParsed.labeledColumns))
                break
            }
            i += 1
        }
        return regions
    }

    private enum AssertionOp { case colon, comma, assign, compare }

    private static func parseCallRegion(_ region: String) -> (
        lines: [Int], columns: [Int], labeledLines: [Int], labeledColumns: [Int]
    ) {
        let chars = Array(region)
        var i = 0
        var lines: [Int] = []
        var columns: [Int] = []
        var labeledLines: [Int] = []
        var labeledColumns: [Int] = []
        var braceParams: [Set<String>] = []
        while i < chars.count {
            if skipComment(chars, &i) { continue }
            if let decoded = decodeStringLiteral(chars, at: i) {
                i = decoded.end
                continue
            }
            if chars[i] == "{" {
                braceParams.append(closureParameterNames(chars, openBrace: i))
                i += 1
                continue
            }
            if chars[i] == "}" {
                if !braceParams.isEmpty { braceParams.removeLast() }
                i += 1
                continue
            }
            if let ident = readIdent(chars, at: i) {
                let identStart = i
                i = ident.end
                if ident.name == "line" || ident.name == "column",
                   let asserted = readAssertedInteger(chars, at: &i) {
                    let property = isPropertyAccess(chars, before: identStart)
                    if property, asserted.op == .compare || asserted.op == .comma {
                        if !braceParams.isEmpty {
                            let allowed = braceParams.reduce(into: Set<String>()) {
                                $0.formUnion($1)
                            }
                            let root = propertyChainRoot(chars, identStart: identStart)
                                ?? propertyReceiver(chars, before: identStart)
                            guard let root, allowed.contains(root)
                                    || isClosureShorthand(root) else { continue }
                        }
                        if ident.name == "line" { lines.append(asserted.value) }
                        else { columns.append(asserted.value) }
                    } else if !property, asserted.op == .colon {
                        if ident.name == "line" { labeledLines.append(asserted.value) }
                        else { labeledColumns.append(asserted.value) }
                    }
                }
                continue
            }
            i += 1
        }
        return (lines, columns, labeledLines, labeledColumns)
    }

    /// Postfix on a JSON checker: `.first.map { $0.line == N }`, then an
    /// `audit.equal` trailing `, N` after `.line`/`.column`.
    private static func assertionSpanEnd(_ chars: [Character], callClose: Int) -> Int {
        let end = postfixChainEnd(chars, after: callClose)
        return trailingCommaIntegerEnd(chars, after: end)
    }

    private static func postfixChainEnd(_ chars: [Character], after close: Int) -> Int {
        var i = close + 1
        var end = close
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            if i >= chars.count { break }
            if chars[i] == "?" {
                if i + 1 < chars.count, chars[i + 1] == "?" { break }
                i += 1
                continue
            }
            if chars[i] == "." {
                i += 1
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                guard let ident = readIdent(chars, at: i) else { break }
                i = ident.end
                end = i - 1
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                if i < chars.count, chars[i] == "(" {
                    guard let close = matchingParen(chars, open: i) else { break }
                    i = close + 1
                    end = close
                    continue
                }
                if i < chars.count, chars[i] == "{" {
                    guard let close = matchingBrace(chars, open: i) else { break }
                    i = close + 1
                    end = close
                    continue
                }
                continue
            }
            if chars[i] == "{" {
                guard let close = matchingBrace(chars, open: i) else { break }
                i = close + 1
                end = close
                continue
            }
            break
        }
        return end
    }

    private static func trailingCommaIntegerEnd(_ chars: [Character], after end: Int) -> Int {
        var i = end + 1
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        guard i < chars.count, chars[i] == "," else { return end }
        i += 1
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
        guard i < chars.count, chars[i].isNumber else { return end }
        while i < chars.count, chars[i].isNumber { i += 1 }
        return i - 1
    }

    /// Decoded JSON-text argument of a `checkJSON`/`expectJSON` call, if that
    /// argument is a single string literal. Nested closures, concatenations,
    /// and strings in `url:` or other arguments are ignored.
    private static func jsonTextLiteral(in callSource: String, names: [String]) -> String? {
        guard names == ["checkJSON"] || names == ["expectJSON"] else { return nil }
        let args = parseCallArguments(in: callSource)
        let textArg: String?
        if let labeled = args.first(where: { $0.label == "text" }) {
            textArg = labeled.text
        } else if names == ["checkJSON"] {
            textArg = args.first(where: { $0.label == nil })?.text
        } else {
            let unlabeled = args.filter { $0.label == nil }
            textArg = unlabeled.count >= 2 ? unlabeled[1].text : nil
        }
        guard let textArg else { return nil }
        return soleStringLiteral(in: textArg)
    }

    private static func parseCallArguments(in region: String) -> [CallArgument] {
        let chars = Array(region)
        var i = 0
        while i < chars.count {
            if skipStringOrComment(chars, &i) { continue }
            if chars[i] == "(" { break }
            i += 1
        }
        guard i < chars.count, chars[i] == "(" else { return [] }
        guard let close = matchingParen(chars, open: i) else { return [] }
        return splitTopLevelArguments(chars, start: i + 1, end: close)
    }

    private static func splitTopLevelArguments(_ chars: [Character], start: Int, end: Int)
        -> [CallArgument] {
        var args: [CallArgument] = []
        var i = start
        while i < end {
            skipTrivia(chars, &i, limit: end)
            if i >= end { break }
            if chars[i] == "," { i += 1; continue }

            var label: String?
            if let ident = readIdent(chars, at: i) {
                var j = ident.end
                while j < end, chars[j].isWhitespace { j += 1 }
                if j < end, chars[j] == ":" {
                    label = ident.name
                    i = j + 1
                    skipTrivia(chars, &i, limit: end)
                }
            }

            let valueStart = i
            var depthParen = 0
            var depthBrace = 0
            var depthBracket = 0
            while i < end {
                if skipStringOrComment(chars, &i) { continue }
                let character = chars[i]
                if character == "(" { depthParen += 1; i += 1; continue }
                if character == ")" {
                    if depthParen == 0 { break }
                    depthParen -= 1
                    i += 1
                    continue
                }
                if character == "{" { depthBrace += 1; i += 1; continue }
                if character == "}" {
                    if depthBrace > 0 { depthBrace -= 1 }
                    i += 1
                    continue
                }
                if character == "[" { depthBracket += 1; i += 1; continue }
                if character == "]" {
                    if depthBracket > 0 { depthBracket -= 1 }
                    i += 1
                    continue
                }
                if character == ",", depthParen == 0, depthBrace == 0, depthBracket == 0 {
                    break
                }
                i += 1
            }
            let value = String(chars[valueStart..<i])
            if label != nil || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                args.append(CallArgument(label: label, text: value))
            }
            if i < end, chars[i] == "," { i += 1 }
        }
        return args
    }

    /// A lone string literal, possibly surrounded by whitespace or comments.
    /// Concatenation, wrappers, and closures do not count.
    private static func soleStringLiteral(in argument: String) -> String? {
        let chars = Array(argument)
        var i = 0
        skipTrivia(chars, &i, limit: chars.count)
        guard let decoded = decodeStringLiteral(chars, at: i) else { return nil }
        i = decoded.end
        skipTrivia(chars, &i, limit: chars.count)
        guard i == chars.count else { return nil }
        return decoded.value
    }

    private static func skipTrivia(_ chars: [Character], _ i: inout Int, limit: Int) {
        while i < limit {
            if chars[i].isWhitespace { i += 1; continue }
            let saved = i
            if skipComment(chars, &i) {
                if i > limit { i = limit }
                continue
            }
            i = saved
            break
        }
    }

    /// `let found = checkJSON(...)` / `let found = DiagnosticsEngine.checkJSON(...)`.
    /// `_ = checkJSON(...)` is not a binding.
    private static func resultBindingName(_ chars: [Character], before callStart: Int) -> String? {
        var j = callStart
        skipQualifiedNameLeft(chars, from: &j)
        while j > 0, chars[j - 1].isWhitespace { j -= 1 }
        guard j > 0, chars[j - 1] == "=" else { return nil }
        j -= 1
        while j > 0, chars[j - 1].isWhitespace { j -= 1 }
        let end = j
        while j > 0, isIdentContinue(chars[j - 1]) { j -= 1 }
        guard j < end, isIdentStart(chars[j]) else { return nil }
        let name = String(chars[j..<end])
        if name == "_" { return nil }
        while j > 0, chars[j - 1].isWhitespace { j -= 1 }
        let keywordEnd = j
        while j > 0, isIdentContinue(chars[j - 1]) { j -= 1 }
        guard j < keywordEnd else { return nil }
        let keyword = String(chars[j..<keywordEnd])
        if keyword == "let" || keyword == "var" { return name }
        return nil
    }

    private static func skipQualifiedNameLeft(_ chars: [Character], from j: inout Int) {
        while true {
            var k = j
            while k > 0, chars[k - 1].isWhitespace { k -= 1 }
            guard k > 0, chars[k - 1] == "." else { return }
            k -= 1
            while k > 0, chars[k - 1].isWhitespace { k -= 1 }
            let end = k
            while k > 0, isIdentContinue(chars[k - 1]) { k -= 1 }
            guard k < end, isIdentStart(chars[k]) else { return }
            j = k
        }
    }

    /// `.line` / `.column` comparisons whose receiver chain roots at `name`
    /// (or an alias `let first = name.first`) until `name` is rebound.
    private static func assertionsOnBinding(_ chars: [Character], name: String, after start: Int)
        -> (lines: [Int], columns: [Int]) {
        var i = start + 1
        var lines: [Int] = []
        var columns: [Int] = []
        var roots: Set<String> = [name]
        while i < chars.count {
            if skipStringOrComment(chars, &i) { continue }
            guard let ident = readIdent(chars, at: i) else {
                i += 1
                continue
            }
            if ident.name == "let" || ident.name == "var" {
                var j = ident.end
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                guard let bound = readIdent(chars, at: j) else {
                    i = ident.end
                    continue
                }
                if bound.name == name { return (lines, columns) }
                var k = bound.end
                while k < chars.count, chars[k].isWhitespace { k += 1 }
                if k < chars.count, chars[k] == "=" {
                    k += 1
                    while k < chars.count, chars[k].isWhitespace { k += 1 }
                    if let rhs = readIdent(chars, at: k), roots.contains(rhs.name) {
                        roots.insert(bound.name)
                    }
                }
                i = bound.end
                continue
            }
            if ident.name == name {
                var j = ident.end
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "=",
                   !(j + 1 < chars.count && chars[j + 1] == "=") {
                    return (lines, columns)
                }
            }
            if ident.name == "line" || ident.name == "column" {
                let identStart = i
                var cursor = ident.end
                if let asserted = readAssertedInteger(chars, at: &cursor),
                   isPropertyAccess(chars, before: identStart),
                   asserted.op == .compare || asserted.op == .comma,
                   let root = propertyChainRoot(chars, identStart: identStart)
                    ?? propertyReceiver(chars, before: identStart),
                   roots.contains(root) {
                    if ident.name == "line" { lines.append(asserted.value) }
                    else { columns.append(asserted.value) }
                    i = cursor
                    continue
                }
            }
            i = ident.end
        }
        return (lines, columns)
    }

    private static let closureSignatureKeywords: Set<String> = [
        "for", "if", "guard", "while", "switch", "return", "let", "var", "repeat",
        "do", "defer", "break", "continue", "throw", "try", "await", "where",
        "func", "enum", "struct", "class", "actor", "protocol", "typealias",
        "in", "is", "as", "catch", "case", "default", "else", "import",
    ]

    /// `{ diag in ... }`, `{ (diag: Diagnostic) in ... }`, or implicit `$0`.
    private static func closureParameterNames(_ chars: [Character], openBrace: Int) -> Set<String> {
        var i = openBrace + 1
        skipTrivia(chars, &i, limit: chars.count)
        if i < chars.count, chars[i] == "[" {
            guard let close = matchingPair(chars, open: i, openChar: "[", closeChar: "]") else {
                return ["$0"]
            }
            i = close + 1
            skipTrivia(chars, &i, limit: chars.count)
        }
        guard let inPos = findClosureInKeyword(chars, from: i) else { return ["$0"] }
        var names: [String] = []
        if i < chars.count, chars[i] == "(" {
            guard let close = matchingParen(chars, open: i), close < inPos else { return ["$0"] }
            for arg in splitTopLevelArguments(chars, start: i + 1, end: close) {
                if let label = arg.label, label != "_" {
                    names.append(label)
                } else if let ident = firstIdent(in: arg.text), ident != "_" {
                    names.append(ident)
                }
            }
        } else {
            var j = i
            while j < inPos {
                skipTrivia(chars, &j, limit: inPos)
                if j >= inPos { break }
                if chars[j] == "," { j += 1; continue }
                guard let ident = readIdent(chars, at: j) else { return ["$0"] }
                if ident.name != "_" { names.append(ident.name) }
                j = ident.end
            }
        }
        if names.contains(where: { closureSignatureKeywords.contains($0) }) {
            return ["$0"]
        }
        return Set(names + ["$0"])
    }

    private static func firstIdent(in text: String) -> String? {
        let chars = Array(text)
        var i = 0
        skipTrivia(chars, &i, limit: chars.count)
        return readIdent(chars, at: i)?.name
    }

    private static func findClosureInKeyword(_ chars: [Character], from start: Int) -> Int? {
        var j = start
        var paren = 0
        var bracket = 0
        while j < chars.count {
            if skipStringOrComment(chars, &j) { continue }
            let c = chars[j]
            if c == "(" { paren += 1; j += 1; continue }
            if c == ")" {
                if paren == 0 { return nil }
                paren -= 1
                j += 1
                continue
            }
            if c == "[" { bracket += 1; j += 1; continue }
            if c == "]" {
                if bracket > 0 { bracket -= 1 }
                j += 1
                continue
            }
            if c == "{" || c == "}" { return nil }
            if paren == 0, bracket == 0,
               let ident = readIdent(chars, at: j), ident.name == "in" {
                return j
            }
            j += 1
        }
        return nil
    }

    private static func isClosureShorthand(_ name: String) -> Bool {
        guard name.first == "$" else { return false }
        let rest = name.dropFirst()
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }

    /// `.line`, `?.line`, `first?.line` — not `let line =`.
    private static func isPropertyAccess(_ chars: [Character], before i: Int) -> Bool {
        var j = i
        while j > 0, chars[j - 1].isWhitespace { j -= 1 }
        if j > 0, chars[j - 1] == "?" { j -= 1 }
        while j > 0, chars[j - 1].isWhitespace { j -= 1 }
        return j > 0 && chars[j - 1] == "."
    }

    /// Leftmost identifier of a `.line` / `.column` chain (`found` in
    /// `found.first?.line`, `$0` in `$0.line`).
    private static func propertyChainRoot(_ chars: [Character], identStart: Int) -> String? {
        var j = identStart
        var root: String?
        while true {
            while j > 0, chars[j - 1].isWhitespace { j -= 1 }
            if j > 0, chars[j - 1] == "?" || chars[j - 1] == "!" { j -= 1 }
            while j > 0, chars[j - 1].isWhitespace { j -= 1 }
            guard j > 0, chars[j - 1] == "." else { break }
            j -= 1
            while j > 0, chars[j - 1].isWhitespace { j -= 1 }
            if j > 0, chars[j - 1] == "?" || chars[j - 1] == "!" { j -= 1 }
            while j > 0, chars[j - 1].isWhitespace { j -= 1 }
            let end = j
            while j > 0, isIdentContinue(chars[j - 1]) { j -= 1 }
            guard j < end, isIdentStart(chars[j]) else { return root }
            root = String(chars[j..<end])
        }
        return root
    }

    /// Receiver of `.line` / `.column` (`$0` in ` $0.line == 3`).
    private static func propertyReceiver(_ chars: [Character], before i: Int) -> String? {
        var j = i
        while j > 0, chars[j - 1].isWhitespace { j -= 1 }
        if j > 0, chars[j - 1] == "?" { j -= 1 }
        while j > 0, chars[j - 1].isWhitespace { j -= 1 }
        guard j > 0, chars[j - 1] == "." else { return nil }
        j -= 1
        while j > 0, chars[j - 1].isWhitespace { j -= 1 }
        let end = j
        while j > 0, isIdentContinue(chars[j - 1]) { j -= 1 }
        guard j < end, isIdentStart(chars[j]) else { return nil }
        return String(chars[j..<end])
    }

    private static func matchQualifiedName(_ parts: [String], _ chars: [Character],
                                           at i: Int) -> Int? {
        if i > 0, isIdentContinue(chars[i - 1]) { return nil }
        var pos = i
        for (index, part) in parts.enumerated() {
            if index > 0 {
                while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
                guard pos < chars.count, chars[pos] == "." else { return nil }
                pos += 1
                while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
            }
            guard let ident = readIdent(chars, at: pos), ident.name == part else { return nil }
            pos = ident.end
        }
        return pos
    }

    private static func readIdent(_ chars: [Character], at i: Int) -> (name: String, end: Int)? {
        guard i < chars.count, isIdentStart(chars[i]) else { return nil }
        var j = i + 1
        while j < chars.count, isIdentContinue(chars[j]) { j += 1 }
        return (String(chars[i..<j]), j)
    }

    private static func isIdentStart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter
    }

    private static func isIdentContinue(_ character: Character) -> Bool {
        isIdentStart(character) || character.isNumber
    }

    /// After `line`/`column`, parse `: 3`, `= 3`, `== 3`, or `, 3`.
    /// Only `==` and `,` on a property, plus `:` labeled args on a JSON
    /// checker, count as location assertions.
    private static func readAssertedInteger(_ chars: [Character], at i: inout Int)
        -> (value: Int, op: AssertionOp)? {
        var j = i
        while j < chars.count, chars[j].isWhitespace { j += 1 }
        if j < chars.count, chars[j] == "?" { j += 1 }
        while j < chars.count, chars[j].isWhitespace { j += 1 }
        guard j < chars.count else { return nil }
        let op: AssertionOp
        if chars[j] == "=" {
            j += 1
            if j < chars.count, chars[j] == "=" {
                j += 1
                op = .compare
            } else {
                op = .assign
            }
        } else if chars[j] == ":" {
            j += 1
            op = .colon
        } else if chars[j] == "," {
            j += 1
            op = .comma
        } else {
            return nil
        }
        while j < chars.count, chars[j].isWhitespace { j += 1 }
        guard j < chars.count else { return nil }
        var sign = 1
        if chars[j] == "-" { sign = -1; j += 1 }
        else if chars[j] == "+" { j += 1 }
        guard j < chars.count, chars[j].isNumber else { return nil }
        var value = 0
        while j < chars.count, let digit = chars[j].wholeNumberValue {
            value = value * 10 + digit
            j += 1
        }
        i = j
        return (value * sign, op)
    }

    private static func matchingParen(_ chars: [Character], open: Int) -> Int? {
        matchingPair(chars, open: open, openChar: "(", closeChar: ")")
    }

    private static func matchingBrace(_ chars: [Character], open: Int) -> Int? {
        matchingPair(chars, open: open, openChar: "{", closeChar: "}")
    }

    private static func matchingPair(_ chars: [Character], open: Int,
                                     openChar: Character, closeChar: Character) -> Int? {
        guard open < chars.count, chars[open] == openChar else { return nil }
        var i = open + 1
        var depth = 1
        while i < chars.count {
            if skipStringOrComment(chars, &i) { continue }
            if chars[i] == openChar { depth += 1 }
            else if chars[i] == closeChar {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    @discardableResult
    private static func skipStringOrComment(_ chars: [Character], _ i: inout Int) -> Bool {
        if skipComment(chars, &i) { return true }
        if let decoded = decodeStringLiteral(chars, at: i) {
            i = decoded.end
            return true
        }
        return false
    }

    @discardableResult
    private static func skipComment(_ chars: [Character], _ i: inout Int) -> Bool {
        guard i < chars.count else { return false }
        if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
            i += 2
            while i < chars.count, !chars[i].isNewline { i += 1 }
            return true
        }
        if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
            i += 2
            while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
            i = min(i + 2, chars.count)
            return true
        }
        return false
    }

    private static func decodeStringLiteral(_ chars: [Character], at i: Int)
        -> (value: String, end: Int)? {
        guard i < chars.count else { return nil }
        var pos = i
        var hashes = 0
        while pos < chars.count, chars[pos] == "#" {
            hashes += 1
            pos += 1
        }
        guard pos < chars.count, chars[pos] == "\"" else { return nil }
        let multiline = pos + 2 < chars.count && chars[pos + 1] == "\"" && chars[pos + 2] == "\""
        if multiline {
            return decodeMultilineString(chars, hashes: hashes, afterOpener: pos + 3)
        }
        pos += 1
        if hashes > 0 {
            var value = ""
            while pos < chars.count {
                if chars[pos] == "\"", rawHashesMatch(chars, at: pos + 1, hashes: hashes) {
                    return (value, pos + 1 + hashes)
                }
                value.append(chars[pos])
                pos += 1
            }
            return nil
        }
        var value = ""
        while pos < chars.count {
            if chars[pos].isNewline { return nil }
            if chars[pos] == "\\" {
                guard pos + 1 < chars.count else { return nil }
                if chars[pos + 1] == "(" {
                    guard let close = matchingParen(chars, open: pos + 1) else { return nil }
                    pos = close + 1
                    continue
                }
                value.append(unescape(chars[pos + 1]))
                pos += 2
                continue
            }
            if chars[pos] == "\"" { return (value, pos + 1) }
            value.append(chars[pos])
            pos += 1
        }
        return nil
    }

    private static func decodeMultilineString(_ chars: [Character], hashes: Int,
                                              afterOpener pos: Int)
        -> (value: String, end: Int)? {
        var i = pos
        if i < chars.count, chars[i] == "\r" { i += 1 }
        if i < chars.count, chars[i] == "\n" { i += 1 }
        let bodyStart = i
        while i < chars.count {
            if chars[i] == "\"",
               i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"",
               rawHashesMatch(chars, at: i + 3, hashes: hashes) {
                var lineStart = i
                while lineStart > bodyStart, !chars[lineStart - 1].isNewline {
                    lineStart -= 1
                }
                let indent = String(chars[lineStart..<i])
                guard indent.allSatisfy({ $0 == " " || $0 == "\t" }) else {
                    i += 1
                    continue
                }
                var bodyEnd = lineStart
                if bodyEnd > bodyStart {
                    bodyEnd -= 1
                    if bodyEnd >= bodyStart, chars[bodyEnd] == "\n" {
                        if bodyEnd > bodyStart, chars[bodyEnd - 1] == "\r" { bodyEnd -= 1 }
                    }
                }
                let body = bodyEnd >= bodyStart ? String(chars[bodyStart..<bodyEnd]) : ""
                let stripped = stripMultilineIndent(body, indent: indent)
                return (stripped, i + 3 + hashes)
            }
            i += 1
        }
        return nil
    }

    private static func rawHashesMatch(_ chars: [Character], at i: Int, hashes: Int) -> Bool {
        guard i + hashes <= chars.count else { return false }
        for offset in 0..<hashes {
            if chars[i + offset] != "#" { return false }
        }
        return true
    }

    private static func stripMultilineIndent(_ body: String, indent: String) -> String {
        guard !indent.isEmpty else { return body }
        return body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var line = String(line)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.hasPrefix(indent) { return String(line.dropFirst(indent.count)) }
            return line
        }.joined(separator: "\n")
    }

    private static func unescape(_ character: Character) -> Character {
        switch character {
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "0": return "\0"
        default: return character
        }
    }

    /// A validator that reports the exact planted line and column of each
    /// unpaired high or low surrogate. Used by honesty checks; not the live tree.
    static let exactSurrogateValidatorSource = #"""
    import Foundation
    enum JSONValidator {
        static func allowsComments(_ url: URL) -> Bool { return false }
        static func validate(_ text: String, url: URL) -> [Diagnostic] {
            var line = 1
            var column = 1
            let chars = Array(text)
            var i = 0
            while i < chars.count {
                if chars[i] == "\\" && i + 5 < chars.count && chars[i + 1] == "u" {
                    let hex = String(chars[(i + 2)..<(i + 6)])
                    if let value = Int(hex, radix: 16) {
                        if (0xD800...0xDBFF).contains(value) {
                            var paired = false
                            if i + 11 < chars.count, chars[i + 6] == "\\", chars[i + 7] == "u" {
                                let low = String(chars[(i + 8)..<(i + 12)])
                                if let lv = Int(low, radix: 16), (0xDC00...0xDFFF).contains(lv) {
                                    paired = true
                                }
                            }
                            if !paired {
                                return [Diagnostic(file: url, line: line, column: column,
                                                   severity: .error,
                                                   message: "unpaired UTF-16 surrogate",
                                                   source: "JSON")]
                            }
                            for _ in 0..<12 {
                                if chars[i].isNewline { line += 1; column = 1 } else { column += 1 }
                                i += 1
                            }
                            continue
                        } else if (0xDC00...0xDFFF).contains(value) {
                            return [Diagnostic(file: url, line: line, column: column,
                                               severity: .error,
                                               message: "unpaired UTF-16 surrogate",
                                               source: "JSON")]
                        }
                    }
                }
                if chars[i].isNewline { line += 1; column = 1 } else { column += 1 }
                i += 1
            }
            return []
        }
    }
    """#

    /// Full `swift build && Orrery --audit` in the copy. Not called from
    /// `--audit` itself (that would nest the suite and spend minutes per check).
    private static func runCopyAudit(_ copyRoot: URL) async -> (exitCode: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.currentDirectoryURL = copyRoot
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-lc", "swift build -c debug && ./.build/debug/Orrery --audit"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let drain = PipeDrain()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    drain.append(data)
                }
            }
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                drain.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: (proc.terminationStatus, drain.text()))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, "could not start copy audit: \(error)"))
            }
        }
    }

    /// Drains a child's stdout/stderr without blocking on Darwin's 64 KiB pipe.
    /// Live-only: `--audit` never calls `runCopyAudit`.
    private final class PipeDrain: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); storage.append(data); lock.unlock()
        }
        func text() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(data: storage, encoding: .utf8) ?? ""
        }
    }

    /// Wait until the engine is idle. `timeout` nil means wait as long as the
    /// per-turn stall watchdog needs — a multi-turn streaming run is not capped
    /// at one `turnTimeout`. A finite timeout that expires must be honoured by
    /// the caller (stop, do not evaluate, do not delete under a live agent).
    @MainActor
    static func waitWhileRunning(_ engine: Orchestrator,
                                 timeout: TimeInterval?) async -> Bool {
        if let timeout {
            return await waitUntil(timeout) { !engine.isRunning }
        }
        while engine.isRunning {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    @MainActor
    @discardableResult
    static func waitUntil(_ timeout: TimeInterval,
                          _ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }
}

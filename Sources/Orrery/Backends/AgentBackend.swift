import Foundation

enum Provider: String, CaseIterable, Identifiable, Hashable, Codable {
    case grok, claude, codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .grok: return "Grok"
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .grok: return "bolt"
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Everything a backend can tell the UI. Each provider speaks a different wire protocol;
/// they all normalize down to these.
enum BackendEvent {
    case status(String)
    case connected(sessionID: String)
    case disconnected(reason: String)
    case assistantDelta(String)
    case thoughtDelta(String)
    case toolStarted(id: String, title: String, kind: String, input: String)
    case toolUpdated(id: String, status: String?, output: String?, diff: FileDiff?)
    case plan([String])
    case models([ModelOption], current: String?)
    case permission(PermissionRequest)
    case turnFinished(stopReason: String?, costUSD: Double?)
    case failure(String)
    case note(String)
    case log(String)
    /// The saved conversation could not be resumed and a fresh one replaced it; the app must
    /// forget the old id or it would retry the dead resume at every launch.
    case sessionDropped(reason: String)
}

@MainActor
protocol AgentBackend: AnyObject {
    var computerConnection: ComputerConnection? { get set }
    var sessionSettings: AgentSessionSettings { get set }
    var provider: Provider { get }
    var isRunning: Bool { get }
    var models: [ModelOption] { get }
    /// Explicit model ids this app knows the CLI accepts, for providers whose live catalog
    /// reports only aliases. Shown as a separate menu section and never counted as reported.
    var knownVersions: [ModelOption] { get }
    var currentModel: String { get }
    var supportsEffort: Bool { get }
    var supportsSteering: Bool { get }
    var efforts: [String] { get }
    var currentEffort: String { get set }
    /// When false, model/effort choices apply to this session only and are never written to
    /// the user's saved defaults. Orchestrator sessions turn this off, so a run configured
    /// for max effort cannot silently become tomorrow's chat default.
    var persistsSelection: Bool { get set }
    /// Configure a session that has not started yet. A protocol requirement — not just an
    /// extension method — because calls go through `any AgentBackend`, and an extension-only
    /// method would statically bind to the default and silently skip every override.
    /// The audit caught exactly that.
    func preconfigure(model: String?, effort: String?)
    var onEvent: ((BackendEvent) -> Void)? { get set }

    /// Executable path, or nil when this provider is not installed on the machine.
    static func locate() -> String?

    func start(project: URL, autoApprove: Bool) async
    func stop()
    func send(_ text: String) async
    func send(_ text: String, attachments: [MessageAttachment]) async
    func cancel()
    /// Returns true only when the provider acknowledges delivery to the active turn.
    /// A false result leaves the caller's follow-up intact for queuing or retry.
    func steer(_ text: String) async -> Bool
    func setModel(_ id: String) async
    func setEffort(_ effort: String) async
}

extension AgentBackend {
    var knownVersions: [ModelOption] { [] }
    var computerConnection: ComputerConnection? { get { nil } set {} }
    var sessionSettings: AgentSessionSettings { get { AgentSessionSettings() } set {} }
    func send(_ text: String, attachments: [MessageAttachment]) async { await send(text) }
    var supportsEffort: Bool { false }
    var supportsSteering: Bool { false }
    func steer(_ text: String) async -> Bool { false }
    var efforts: [String] { [] }
    func setEffort(_ effort: String) async { currentEffort = effort }
    func emit(_ event: BackendEvent) { onEvent?(event) }

    /// Configure a session that has not started yet. The default covers effort (every backend
    /// takes it as spawn or per-turn state); backends whose model is a spawn or set-model
    /// concern override this.
    func preconfigure(model: String?, effort: String?) {
        if let effort, !effort.isEmpty { currentEffort = effort }
    }
}

/// Line-delimited JSON child process. Shared by the Claude and Codex backends;
/// `ACPClient` keeps its own copy because it also answers agent→client requests.
@MainActor
final class LineProcess {
    private var process: Process?
    private var executionLease: AgentExecutionLease?
    private var stdinPipe: Pipe?
    private var buffer = Data()
    private var generation = UUID()

    var onLine: ((JSON) -> Void)?
    var onRawLine: ((String) -> Void)?
    var onStderr: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onWriteForTest: (([String: Any]) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    func start(executable: String, arguments: [String], cwd: URL?,
               environment extra: [String: String] = [:], execution: AgentExecutionRequest? = nil) throws {
        stop()
        let generation = self.generation
        let proc = Process()
        if let cwd { proc.currentDirectoryURL = cwd }

        var env = AgentEnvironment.sanitized(ProcessInfo.processInfo.environment)
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        for (key, value) in extra { env[key] = value }
        let launch = try AgentExecutionBoundary.prepare(executable: executable, arguments: arguments,
                                                        environment: env, execution: execution)
        proc.executableURL = URL(fileURLWithPath: launch.executable)
        proc.arguments = launch.arguments
        proc.environment = launch.environment

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // A pipe at EOF stays "readable" forever, so the handler must remove itself or
            // it spins a core until the app quits.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in
                guard self?.generation == generation else { return }
                self?.ingest(data)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            Task { @MainActor in
                guard self?.generation == generation else { return }
                self?.onStderr?(trimmed)
            }
        }
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard self?.generation == generation else { return }
                self?.executionLease = nil
                self?.onExit?(p.terminationStatus)
            }
        }

        try proc.run()
        executionLease = launch.lease
        process = proc
        stdinPipe = inPipe
    }

    func stop() {
        generation = UUID()
        if let process, process.isRunning {
            process.terminate()
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        executionLease = nil
        stdinPipe = nil
        buffer.removeAll()
    }

    func write(_ object: [String: Any]) {
        onWriteForTest?(object)
        guard let stdinPipe,
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }


    /// A single protocol message should never be this large. If one is, the stream is broken —
    /// keeping it in memory is worse than dropping it.
    private static let maxBufferedLine = 64 * 1024 * 1024

    private func onStderrOrLog(_ text: String) { onStderr?(text) }

    private func ingest(_ data: Data) {
        buffer.append(data)
        if buffer.count > Self.maxBufferedLine {
            buffer.removeAll(keepingCapacity: false)
            onStderrOrLog("dropped an oversized protocol message")
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            if let json = JSON(line: line) {
                onLine?(json)
            } else {
                onRawLine?(line)
            }
        }
    }
}

/// Finds an executable by absolute path, then by PATH lookup.
enum Executables {
    static func find(_ candidates: [String], orNamed name: String? = nil) -> String? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        guard let name else { return nil }
        // Lookup runs from view/model setup too. Never spawn and synchronously wait for `which`
        // on the main thread. Ignore relative PATH components (including the current project).
        guard !name.contains("/"), !name.isEmpty else { return nil }
        let searchPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            + ":/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
        for directory in searchPath.split(separator: ":") where directory.hasPrefix("/") {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

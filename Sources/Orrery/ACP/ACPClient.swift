import Foundation

/// Events surfaced to the UI layer.
enum ACPEvent {
    case sessionUpdate(sessionId: String, update: JSON)
    case notification(method: String, params: JSON)
    case log(String)
    case exited(Int32)
}

/// Speaks ACP (JSON-RPC 2.0 over NDJSON) to a `grok agent stdio` child process.
///
/// Isolation guarantees, so this app can never disturb another Grok client on the machine:
///   * spawned with `--no-leader`, so it never attaches to or creates `~/.grok/leader.sock`
///   * owns exactly one child process and only ever signals that PID
///   * never writes to `~/.grok/config.toml` or any shared Grok state
@MainActor
final class ACPClient {
    enum ClientError: LocalizedError {
        case notRunning
        case rpc(code: Int, message: String, data: String?)

        var errorDescription: String? {
            switch self {
            case .notRunning: return "The Grok agent is not running."
            case let .rpc(code, message, data):
                return data.map { "\(message) (\(code)): \($0)" } ?? "\(message) (\(code))"
            }
        }
    }

    private var process: Process?
    private var executionLease: AgentExecutionLease?
    private var stdinPipe: Pipe?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var readBuffer = Data()
    /// Mirrors the session's approval mode. Grok has its own gated file tools and does not use the
    /// client-side write in practice, but if it ever did, an ungated write would sidestep the
    /// approval the user asked for.
    private var allowClientWrites = false
    private var workspace: WorkspaceFileAccess?
    private var generation = UUID()
    private var timeouts: [Int: Task<Void, Never>] = [:]

    var onEvent: ((ACPEvent) -> Void)?
    /// Called for `session/request_permission`. Reply with the chosen optionId, or nil to cancel.
    var onPermission: ((JSON, @escaping (String?) -> Void) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Lifecycle

    func start(executable: String, alwaysApprove: Bool, model: String?,
               effort: String? = nil, project: URL? = nil, environment extra: [String: String] = [:],
               extraArguments: [String] = [], execution: AgentExecutionRequest? = nil) throws {
        stop()
        let generation = self.generation
        allowClientWrites = alwaysApprove
        workspace = project.map { WorkspaceFileAccess(root: $0) }

        let proc = Process()
        var args = ["agent", "--no-leader"]
        if alwaysApprove { args.append("--always-approve") }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let effort, !effort.isEmpty { args += ["--reasoning-effort", effort] }
        args += extraArguments
        args.append("stdio")

        proc.currentDirectoryURL = project
        var env = AgentEnvironment.sanitized(ProcessInfo.processInfo.environment)
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        // Agent mode has no --subagents flag, and without this the session gets no tool for
        // spawning one — which silently breaks any skill that delegates (e.g. /ultra-review).
        // Set per-process only; no config file is touched.
        env["GROK_SUBAGENTS"] = "1"
        env.merge(extra) { _, new in new }
        let launch = try AgentExecutionBoundary.prepare(executable: executable, arguments: args,
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
            guard let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            Task { @MainActor in
                guard self?.generation == generation else { return }
                self?.onEvent?(.log(text))
            }
        }
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard self?.generation == generation else { return }
                self?.executionLease = nil
                self?.failAllPending(with: ClientError.notRunning)
                self?.onEvent?(.exited(p.terminationStatus))
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
        failAllPending(with: ClientError.notRunning)
        process = nil
        executionLease = nil
        stdinPipe = nil
        readBuffer.removeAll()
    }

    // MARK: - Sending

    @discardableResult
    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> JSON {
        guard isRunning, let stdinPipe else { throw ClientError.notRunning }
        let id = nextID
        nextID += 1
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            // Prompts use the orchestrator's activity deadline; setup RPCs must not hang UI.
            if method != "session/prompt" {
                timeouts[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard !Task.isCancelled, let self,
                          let pending = self.pending.removeValue(forKey: id) else { return }
                    self.timeouts.removeValue(forKey: id)
                    pending.resume(throwing: ClientError.rpc(code: -32000, message: "\(method) timed out", data: nil))
                }
            }
            do {
                try write(message, to: stdinPipe)
            } catch {
                pending[id] = nil
                timeouts.removeValue(forKey: id)?.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    func notify(_ method: String, _ params: [String: Any] = [:]) {
        guard let stdinPipe else { return }
        try? write(["jsonrpc": "2.0", "method": method, "params": params], to: stdinPipe)
    }

    private func respond(id: Any, result: [String: Any]) {
        guard let stdinPipe else { return }
        try? write(["jsonrpc": "2.0", "id": id, "result": result], to: stdinPipe)
    }

    private func respond(id: Any, errorCode: Int, message: String) {
        guard let stdinPipe else { return }
        try? write(["jsonrpc": "2.0", "id": id,
                    "error": ["code": errorCode, "message": message]], to: stdinPipe)
    }

    private func write(_ object: [String: Any], to pipe: Pipe) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        try pipe.fileHandleForWriting.write(contentsOf: data)
    }

    // MARK: - Receiving


    /// A single protocol message should never be this large. If one is, the stream is broken —
    /// keeping it in memory is worse than dropping it.
    private static let maxBufferedLine = 64 * 1024 * 1024

    private func onStderrOrLog(_ text: String) { onEvent?(.log(text)) }

    private func ingest(_ data: Data) {
        readBuffer.append(data)
        if readBuffer.count > Self.maxBufferedLine {
            readBuffer.removeAll(keepingCapacity: false)
            onStderrOrLog("dropped an oversized protocol message")
            return
        }
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[readBuffer.startIndex..<newline]
            readBuffer.removeSubrange(readBuffer.startIndex...newline)
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8) else { continue }
            handle(line: line)
        }
    }

    private func handle(line: String) {
        guard let message = JSON(line: line) else {
            onEvent?(.log(line))
            return
        }

        // Response to one of our requests.
        if let id = message["id"].int, message["result"].exists || message["error"].exists {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            timeouts.removeValue(forKey: id)?.cancel()
            if message["error"].exists {
                let error = message["error"]
                continuation.resume(throwing: ClientError.rpc(
                    code: error["code"].int ?? -1,
                    message: error["message"].string ?? "RPC error",
                    data: error["data"].exists ? error["data"]["message"].string
                        ?? error["data"].compact : nil))
            } else {
                continuation.resume(returning: message["result"])
            }
            return
        }

        guard let method = message["method"].string else { return }
        let params = message["params"]

        // Agent -> client request (has an id we must answer).
        if let id = message["id"].raw {
            handleAgentRequest(method: method, id: id, params: params)
            return
        }

        // Notification.
        if method == "session/update" {
            onEvent?(.sessionUpdate(sessionId: params["sessionId"].string ?? "",
                                    update: params["update"]))
        } else {
            onEvent?(.notification(method: method, params: params))
        }
    }

    /// Grok's bundled skills live under `~/.grok/bundled`; the agent reads them through this
    /// client, so that read-only folder is allowed beside the project. Everything else outside
    /// the workspace is still refused.
    nonisolated(unsafe) static var bundledSkillsRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/bundled", isDirectory: true)

    nonisolated static func readForAgent(_ path: String, workspace: WorkspaceFileAccess) throws -> Data {
        let bundled = WorkspaceFileAccess.canonicalURL(bundledSkillsRoot).path
        let requested = WorkspaceFileAccess.canonicalURL(URL(fileURLWithPath: path)).path
        if requested.hasPrefix(bundled + "/") {
            return try WorkspaceFileAccess(root: bundledSkillsRoot).read(path)
        }
        return try workspace.read(path)
    }

    private func handleAgentRequest(method: String, id: Any, params: JSON) {
        switch method {
        case "session/request_permission":
            guard let onPermission else {
                respond(id: id, result: ["outcome": ["outcome": "cancelled"]])
                return
            }
            onPermission(params) { [weak self] optionID in
                guard let self else { return }
                if let optionID {
                    self.respond(id: id, result: ["outcome": ["outcome": "selected",
                                                              "optionId": optionID]])
                } else {
                    self.respond(id: id, result: ["outcome": ["outcome": "cancelled"]])
                }
            }

        case "fs/read_text_file":
            onEvent?(.log("fs/read_text_file ← \(params["path"].string ?? "?")"))
            guard let path = params["path"].string else {
                respond(id: id, errorCode: -32602, message: "missing path"); return
            }
            do {
                guard let workspace else { throw ClientError.rpc(code: -32602, message: "No workspace configured", data: nil) }
                guard let textData = String(data: try Self.readForAgent(path, workspace: workspace), encoding: .utf8), !textData.contains("\0") else {
                    throw ClientError.rpc(code: -32602, message: "Not a UTF-8 text file", data: nil)
                }
                var text = textData
                if let start = params["line"].int, start < 1 { throw ClientError.rpc(code: -32602, message: "line must be positive", data: nil) }
                if let limit = params["limit"].int, limit < 0 { throw ClientError.rpc(code: -32602, message: "limit cannot be negative", data: nil) }
                if let start = params["line"].int {
                    var lines = text.components(separatedBy: "\n")
                    let from = max(0, start - 1)
                    lines = from < lines.count ? Array(lines[from...]) : []
                    text = lines.joined(separator: "\n")
                }
                if let limit = params["limit"].int { text = text.components(separatedBy: "\n").prefix(limit).joined(separator: "\n") }
                respond(id: id, result: ["content": text])
            } catch {
                respond(id: id, errorCode: -32603, message: error.localizedDescription)
            }

        case "fs/write_text_file":
            onEvent?(.log("fs/write_text_file → \(params["path"].string ?? "?")"))
            guard allowClientWrites else {
                respond(id: id, errorCode: -32603,
                        message: "Client-side writes are disabled while approvals are on. "
                               + "Use your own file tool so the write goes through permissions.")
                return
            }
            guard let path = params["path"].string, let content = params["content"].string else {
                respond(id: id, errorCode: -32602, message: "missing path or content"); return
            }
            do {
                guard let workspace else { throw ClientError.rpc(code: -32602, message: "No workspace configured", data: nil) }
                try workspace.write(Data(content.utf8), to: path)
                respond(id: id, result: [:])
            } catch {
                respond(id: id, errorCode: -32603, message: error.localizedDescription)
            }

        default:
            respond(id: id, errorCode: -32601, message: "Method not found: \(method)")
        }
    }

    private func failAllPending(with error: Error) {
        timeouts.values.forEach { $0.cancel() }
        timeouts.removeAll()
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }
}

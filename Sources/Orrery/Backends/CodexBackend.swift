import Foundation

/// Codex through `codex app-server` — the JSON-RPC surface the ChatGPT desktop app uses.
///
/// Isolation rules, so a `codex` CLI run elsewhere is never disturbed:
///   * bare `app-server` only. Never `app-server daemon`, never `app-server proxy`, never
///     `remote-control` — those attach to the shared local daemon.
///   * no writes to `~/.codex/config.toml`; model and effort are passed per turn.
///   * no `thread/archive`, `thread/delete`, or config mutation calls are ever sent.
@MainActor
final class CodexBackend: AgentBackend {
    var computerConnection: ComputerConnection?
    var sessionSettings = AgentSessionSettings()
    let provider = Provider.codex
    var models: [ModelOption] = []
    var currentModel: String = UserDefaults.standard.string(forKey: "codexModel") ?? ""
    var currentEffort: String = UserDefaults.standard.string(forKey: "codexEffort") ?? "medium" {
        didSet { if persistsSelection { UserDefaults.standard.set(currentEffort, forKey: "codexEffort") } }
    }
    var persistsSelection = true
    var supportsEffort: Bool { true }
    var efforts: [String] { effortsByModel[currentModel] ?? ["low", "medium", "high"] }
    var onEvent: ((BackendEvent) -> Void)?

    private let child = LineProcess()
    private var nextID = 1
    private var pending: [Int: (JSON) -> Void] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var threadID: String?
    private var turnID: String?
    private var project: URL?
    private var autoApprove = true
    private var effortsByModel: [String: [String]] = [:]
    private var itemTitles: [String: String] = [:]
    private var turnInFlight = false
    private var generation = UUID()
    /// Test seam: a scripted executable stands in for the installed CLI.
    var executableForTest: String?

    var isRunning: Bool { child.isRunning }

    static func locate() -> String? {
        Executables.find([
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.codex/bin/codex",
        ], orNamed: "codex") ?? Executables.find([
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/Applications/ChatGPT.app/Contents/Resources/codex",
        ])
    }

    init() {
        child.onLine = { [weak self] json in self?.handle(json) }
        child.onStderr = { [weak self] text in self?.emit(.log(text)) }
        child.onExit = { [weak self] code in
            guard let self else { return }
            self.threadID = nil
            self.failPending("Codex app-server exited (\(code))")
            self.emit(.disconnected(reason: "Codex app-server exited (\(code)) — ⌘N to restart"))
            if self.turnInFlight {
                self.turnInFlight = false
                self.emit(.failure("Codex app-server exited (\(code)) mid-turn."))
                self.emit(.turnFinished(stopReason: "process exited", costUSD: nil))
            }
        }
    }

    // MARK: - Lifecycle

    func start(project: URL, autoApprove: Bool) async {
        stop()
        let generation = self.generation
        self.project = project
        self.autoApprove = autoApprove
        guard let executable = executableForTest ?? Self.locate() else {
            emit(.failure("codex not found. Install the Codex CLI, or ChatGPT.app which bundles it."))
            return
        }
        if sessionSettings.nativeComputerControl, executableForTest == nil, AppModel.persistsPreferences {
            do { try await NativeComputerControl.prepareCodexService() }
            catch { emit(.note("Codex native computer control could not start: \(error.localizedDescription) Ordinary coding can continue; reconnect after resolving the helper setup.")) }
            guard generation == self.generation else { return }
        }
        do {
            emit(.status("Starting Codex app-server…"))
            // Bare `app-server`: its own process, not the shared daemon.
            try child.start(executable: executable,
                            arguments: ["app-server"] + (computerConnection?.codexArguments ?? []), cwd: project,
                            environment: ProviderAccounts.shared.childEnvironment(for: .codex),
                            execution: AgentExecutionRequest(policy: sessionSettings.executionPolicy, workspace: project, provider: .codex,
                                                             readOnlyWorkspace: sessionSettings.planMode,
                                                             additionalDirectories: sessionSettings.additionalDirectoryURLs))
        } catch {
            emit(.failure("Could not start Codex: \(error.localizedDescription)"))
            return
        }

        let initialization = await request("initialize", ["clientInfo": [
            "name": "Orrery", "title": "Orrery", "version": "1.0",
        ]])
        guard generation == self.generation, !initialization["error"].exists, child.isRunning else {
            emit(.failure(initialization["error"]["message"].string ?? "Codex initialization was interrupted"))
            return
        }
        child.write(["jsonrpc": "2.0", "method": "initialized", "params": [:]])

        await loadModels()
        guard generation == self.generation, child.isRunning else { return }

        var params: [String: Any] = ["cwd": project.path]
        if !currentModel.isEmpty { params["model"] = currentModel }
        params["approvalPolicy"] = autoApprove ? "never" : "untrusted"
        params["sandbox"] = Self.sandboxParameter(policy: sessionSettings.executionPolicy, confinementAvailable: AgentExecutionBoundary.isAvailable,
                                                  planMode: sessionSettings.planMode, setting: sessionSettings.sandbox)
        params["config"] = sessionSettings.codexConfiguration(adding: computerConnection)
        if !sessionSettings.instructions.isEmpty { params["developerInstructions"] = sessionSettings.instructions }
        var result: JSON
        if !sessionSettings.resumeSession.isEmpty {
            var resumeParams = params
            resumeParams["threadId"] = sessionSettings.resumeSession
            result = await request("thread/resume", resumeParams)
            guard generation == self.generation, child.isRunning else { return }
            if result["thread"]["id"].string == nil {
                emit(.note("The saved Codex thread could not be resumed: \(result["error"]["message"].string ?? "no thread returned"). Starting a new conversation."))
                emit(.sessionDropped(reason: result["error"]["message"].string ?? "no thread returned"))
                result = await request("thread/start", params)
            }
        } else { result = await request("thread/start", params) }
        if let id = result["thread"]["id"].string {
            threadID = id
            emit(.connected(sessionID: id))
            if sessionSettings.nativeComputerControl {
                Task { [weak self] in
                guard let self, generation == self.generation else { return }
                let inventory = await self.request("mcpServerStatus/list", ["threadId": id, "limit": 100], timeoutSeconds: 8)
                guard generation == self.generation, self.child.isRunning else { return }
                self.emit(.note(inventory["error"].exists
                    ? "Codex native tool availability could not be checked. Verify the Computer Use plugin before relying on desktop access."
                    : NativeComputerControl.hasCodexTools(inventory)
                    ? "Codex native computer tools are loaded. Desktop actions use the provider's own access controls."
                    : "Codex native computer tools were not found in this session. Set up Computer Use in the Codex desktop app; shared desktop control is a separate choice in Tools settings."))
                }
            }
        } else {
            emit(.failure("Codex did not return a thread: \(result.compact.prefix(200))"))
        }
        await refreshRateLimits()
    }

    /// Codex's own sandbox cannot start inside the IDE's write confinement: macOS refuses a
    /// nested profile (`sandbox_apply: Operation not permitted`), which made every Codex
    /// command and patch fail there. Under confinement the IDE boundary is the sandbox —
    /// project writes, or a read-only project in plan mode — and Codex's own setting applies
    /// with Full Access only.
    static func sandboxParameter(policy: AgentExecutionPolicy, confinementAvailable: Bool, planMode: Bool, setting: String) -> String {
        if policy == .confinedWrites && confinementAvailable { return "danger-full-access" }
        return planMode ? "read-only" : setting
    }

    func stop() {
        generation = UUID()
        child.stop()
        threadID = nil
        turnID = nil
        turnInFlight = false
        itemTitles.removeAll()
        failPending("Codex session stopped")
    }

    private func failPending(_ message: String) {
        // Resume in-flight RPCs. Dropping the handlers leaks the caller:
        // `start()` parks on a checked continuation, and task cancellation
        // cannot unwind that.
        let handlers = Array(pending.values)
        pending.removeAll()
        timeouts.values.forEach { $0.cancel() }
        timeouts.removeAll()
        for handler in handlers {
            handler(Self.rpcFailure(message))
        }
    }

    func send(_ text: String) async { await send(text, attachments: []) }

    var supportsSteering: Bool { true }

    func steer(_ text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, turnInFlight, let threadID, let expectedTurnID = turnID else {
            emit(.note("Codex has no active turn ready for steering. Your follow-up has not been sent."))
            return false
        }
        let generation = self.generation
        // Installed app-server schema requires the expected active turn ID. A stale request
        // cannot accidentally steer the next turn when completion races with this action.
        let result = await request("turn/steer", ["threadId": threadID, "expectedTurnId": expectedTurnID,
                                                  "input": [["type": "text", "text": text]]])
        guard self.generation == generation, !result["error"].exists,
              result["turnId"].string == expectedTurnID else {
            emit(.note("Codex did not acknowledge steering: \(result["error"]["message"].string ?? "the active session changed or returned an unexpected turn ID"). Your follow-up has not been marked as sent."))
            return false
        }
        return true
    }

    func send(_ text: String, attachments: [MessageAttachment]) async {
        guard !turnInFlight else {
            emit(.failure("Codex is already working. Wait for the current turn or press Stop."))
            emit(.turnFinished(stopReason: "busy", costUSD: nil))
            return
        }
        guard let threadID else {
            emit(.failure("No Codex thread."))
            emit(.turnFinished(stopReason: "error", costUSD: nil))
            return
        }
        turnInFlight = true
        var params: [String: Any] = [
            "threadId": threadID,
            "input": [["type": "text", "text": text]] + attachments.map { $0.content(for: .codex) },
        ]
        if !currentModel.isEmpty { params["model"] = currentModel }
        if !currentEffort.isEmpty { params["effort"] = currentEffort }
        params["cwd"] = project?.path
        let result = await request("turn/start", params)
        if result["error"].exists || (!result["turn"]["id"].exists && !result["turnId"].exists) {
            turnInFlight = false
            emit(.failure(result["error"]["message"].string ?? "turn/start failed"))
            emit(.turnFinished(stopReason: "error", costUSD: nil))
        } else {
            turnID = result["turn"]["id"].string ?? result["turnId"].string
        }
    }

    func cancel() {
        guard let threadID, let turnID else { return }
        Task { _ = await request("turn/interrupt", ["threadId": threadID, "turnId": turnID]) }
    }

    /// Codex takes effort per turn, so a change needs no restart.
    func setEffort(_ effort: String) async {
        guard effort != currentEffort else { return }
        currentEffort = effort
        emit(.models(models, current: currentModel))
        emit(.note("Effort set to \(effort)."))
    }

    /// Model and effort ride on every turn, so plain assignment is enough at any time.
    func preconfigure(model: String?, effort: String?) {
        if let model, !model.isEmpty { currentModel = model }
        if let effort, !effort.isEmpty { currentEffort = effort }
    }

    func setModel(_ id: String) async {
        currentModel = id
        if persistsSelection { UserDefaults.standard.set(id, forKey: "codexModel") }
        if let allowed = effortsByModel[id], !allowed.contains(currentEffort) {
            currentEffort = allowed.contains("medium") ? "medium" : (allowed.first ?? "medium")
        }
        emit(.models(models, current: id))
        emit(.note("Codex will use \(id) from the next turn."))
    }

    private func loadModels() async {
        let result = await request("model/list", ["limit": 30])
        var options: [ModelOption] = []
        for model in result["data"].array {
            guard let id = model["id"].string ?? model["model"].string else { continue }
            if model["hidden"].bool == true { continue }
            options.append(ModelOption(id: id, name: model["displayName"].string ?? id))
            let levels = model["supportedReasoningEfforts"].array
                .compactMap { $0["reasoningEffort"].string ?? $0["effort"].string }
            if !levels.isEmpty { effortsByModel[id] = levels }
        }
        if !options.isEmpty {
            models = options
            if currentModel.isEmpty || !options.contains(where: { $0.id == currentModel }) {
                currentModel = options[0].id
            }
            emit(.models(models, current: currentModel))
        }
    }

    /// Read-only: shows how much of the subscription window is left, so a session here does not
    /// quietly eat quota another Codex CLI run is depending on.
    private func refreshRateLimits() async {
        let result = await request("account/rateLimits/read", [:])
        let primary = result["rateLimits"]["primary"]
        if let used = primary["usedPercent"].double ?? primary["used_percent"].double {
            emit(.note(String(format: "Codex usage: %.0f%% of the current window used", used)))
        }
    }

    // MARK: - JSON-RPC

    @discardableResult
    private func request(_ method: String, _ params: [String: Any], timeoutSeconds: UInt64 = 120) async -> JSON {
        guard child.isRunning else { return Self.rpcFailure("Codex is not running") }
        let id = nextID
        nextID += 1
        return await withCheckedContinuation { continuation in
            var resumed = false
            pending[id] = { json in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: json)
            }
            child.write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            // Guards against a dropped reply hanging a turn. Cancelled as soon as the reply lands,
            // so a busy session does not accumulate sleeping tasks.
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.timeouts[id] = nil
                guard let handler = self.pending.removeValue(forKey: id) else { return }
                handler(Self.rpcFailure("\(method) timed out"))
            }
        }
    }

    private func respond(id: Any, result: [String: Any]) {
        child.write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func rpcFailure(_ message: String) -> JSON {
        JSON(["error": ["code": -32000, "message": message]])
    }

    func handleJSONForTest(_ json: JSON) { handle(json) }
    /// Test seam: speak the app-server protocol to a scripted local process with a live thread
    /// and turn, so steering can be audited without the installed CLI or any quota.
    func startScriptedForTest(executable: String, arguments: [String], environment: [String: String] = [:],
                              threadID: String, turnID: String?) throws {
        try child.start(executable: executable, arguments: arguments, cwd: nil, environment: environment)
        self.threadID = threadID
        self.turnID = turnID
        self.turnInFlight = turnID != nil
    }
    func observeProtocolForTest(_ observer: @escaping ([String: Any]) -> Void) {
        child.onWriteForTest = observer
    }

    private func handle(_ json: JSON) {
        if let id = json["id"].int, json["result"].exists || json["error"].exists {
            timeouts.removeValue(forKey: id)?.cancel()
            let handler = pending.removeValue(forKey: id)
            handler?(json["error"].exists ? JSON(["error": json["error"].raw as Any]) : json["result"])
            return
        }
        guard let method = json["method"].string else { return }
        if let id = json["id"].raw {
            handleServerRequest(method: method, id: id, params: json["params"])
        } else {
            handleNotification(method: method, params: json["params"])
        }
    }

    // MARK: - Approvals

    private func handleServerRequest(method: String, id: Any, params: JSON) {
        switch method {

        // Current item-scoped approvals. Vocabulary: accept / acceptForSession / decline / cancel.
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            let isCommand = method.contains("command")
            approve(id: id, params: params, isCommand: isCommand,
                    allow: "accept", allowSession: "acceptForSession",
                    reject: "decline", dismiss: "cancel")

        // Legacy names, and a different enum: ReviewDecision. Replying "accept" here is invalid.
        case "execCommandApproval", "applyPatchApproval":
            let isCommand = method == "execCommandApproval"
            approve(id: id, params: params, isCommand: isCommand,
                    allow: "approved", allowSession: "approved_for_session",
                    reject: "denied", dismiss: "abort")

        // Not a decision at all: the reply is the permission profile being granted, so the only
        // sound answer is to grant exactly what was asked for, or grant nothing.
        case "item/permissions/requestApproval":
            let requested = params["permissions"].raw ?? [:]
            if autoApprove {
                respond(id: id, result: ["permissions": requested, "scope": "turn"])
                return
            }
            emit(.permission(PermissionRequest(
                title: "Grant the permissions Codex is asking for?",
                detail: [params["reason"].string, params["permissions"].pretty]
                    .compactMap { $0 }.joined(separator: "\n\n"),
                options: [
                    PermissionOption(id: "grant", name: "Grant", kind: "allow_once"),
                    PermissionOption(id: "deny", name: "Deny", kind: "reject_once"),
                ],
                reply: { [weak self] choice in
                    self?.respond(id: id, result: [
                        "permissions": choice == "grant" ? requested : [:],
                        "scope": "turn",
                    ])
                })))

        // Answers are a map of question id to answer; there is no decision field.
        case "item/tool/requestUserInput":
            let questions = params["questions"].array.compactMap { question -> AgentQuestion? in
                guard let id = question["id"].string, let title = question["question"].string else { return nil }
                return AgentQuestion(id: id, title: title,
                    options: question["options"].array.compactMap { $0["label"].string },
                    isSecret: question["isSecret"].bool ?? false)
            }
            guard !questions.isEmpty else { respond(id: id, result: ["answers": [:]]); return }
            let generation = self.generation
            emit(.permission(PermissionRequest(title: "A decision is needed", detail: "", options: [],
                questions: questions,
                answer: { [weak self] answers in
                    guard let self, generation == self.generation else { return }
                    self.respond(id: id, result: ["answers": answers.mapValues { ["answers": [$0]] }])
                },
                reply: { [weak self] _ in
                    guard let self, generation == self.generation else { return }
                    self.respond(id: id, result: ["answers": [:]])
                })))

        case "mcpServer/elicitation/request":
            respond(id: id, result: ["action": "decline"])

        default:
            child.write(["jsonrpc": "2.0", "id": id,
                         "error": ["code": -32601, "message": "Unsupported request: \(method)"]])
        }
    }

    /// Shared approval flow for the two request families that do take a decision string.
    private func approve(id: Any, params: JSON, isCommand: Bool,
                         allow: String, allowSession: String, reject: String, dismiss: String) {
        if autoApprove {
            respond(id: id, result: ["decision": allow])
            return
        }
        let detail = isCommand
            ? [params["command"].string, params["reason"].string]
                .compactMap { $0 }.joined(separator: "\n\n")
            : params["fileUpdates"].pretty.ifEmpty(params.pretty)
        emit(.permission(PermissionRequest(
            title: isCommand ? "Run this command?" : "Apply these file changes?",
            detail: detail,
            options: [
                PermissionOption(id: allow, name: "Allow once", kind: "allow_once"),
                PermissionOption(id: allowSession, name: "Allow for session", kind: "allow_always"),
                PermissionOption(id: reject, name: "Reject", kind: "reject_once"),
            ],
            reply: { [weak self] choice in
                self?.respond(id: id, result: ["decision": choice ?? dismiss])
            })))
    }

    // MARK: - Notifications

    private func handleNotification(method: String, params: JSON) {
        switch method {
        case "item/agentMessage/delta":
            emit(.assistantDelta(params["delta"].string ?? ""))

        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            emit(.thoughtDelta(params["delta"].string ?? ""))

        case "item/started":
            let item = params["item"]
            guard let id = item["id"].string else { return }
            let type = item["type"].string ?? ""
            guard let (title, kind, input) = describe(item: item, type: type) else { return }
            itemTitles[id] = title
            emit(.toolStarted(id: id, title: title, kind: kind, input: input))
            emit(.toolUpdated(id: id, status: "in_progress", output: nil, diff: nil))

        case "item/completed":
            let item = params["item"]
            guard let id = item["id"].string else { return }
            let type = item["type"].string ?? ""
            switch type {
            case "agentMessage", "reasoning":
                break   // already streamed
            case "fileChange":
                for change in item["changes"].array {
                    let diff = FileDiff(path: change["path"].string ?? "?",
                                        oldText: change["oldContent"].string ?? "",
                                        newText: change["newContent"].string
                                            ?? change["unifiedDiff"].string ?? "")
                    emit(.toolUpdated(id: id, status: "completed", output: nil, diff: diff))
                }
                emit(.toolUpdated(id: id, status: "completed", output: nil, diff: nil))
            default:
                let output = item["output"].string
                    ?? item["aggregatedOutput"].string
                    ?? item["result"].string
                let failed = (item["exitCode"].int ?? 0) != 0 || item["status"].string == "failed"
                emit(.toolUpdated(id: id, status: failed ? "failed" : "completed",
                                  output: output, diff: nil))
            }

        case "item/commandExecution/outputDelta", "command/exec/outputDelta":
            let id = params["itemId"].string ?? ""
            let chunk = params["chunk"].string ?? params["delta"].string ?? ""
            if !chunk.isEmpty && !id.isEmpty {
                emit(.toolUpdated(id: id, status: nil, output: chunk, diff: nil))
            }

        case "turn/plan/updated", "item/plan/delta":
            let steps = params["plan"].array.map { step -> String in
                let status = step["status"].string ?? ""
                let mark = status == "completed" ? "✓" : (status == "in_progress" ? "→" : "•")
                return "\(mark) \(step["step"].string ?? step["content"].string ?? "")"
            }
            if !steps.isEmpty { emit(.plan(steps)) }

        case "turn/completed":
            turnID = nil
            turnInFlight = false
            let usage = params["turn"]["usage"]
            emit(.turnFinished(stopReason: params["turn"]["status"].string ?? "completed",
                               costUSD: usage["costUsd"].double))

        case "turn/started":
            turnID = params["turn"]["id"].string ?? params["turnId"].string

        case "error":
            turnInFlight = false
            emit(.failure(params["message"].string ?? params.compact))
            emit(.turnFinished(stopReason: "error", costUSD: nil))

        case "warning", "guardianWarning", "configWarning":
            emit(.note(params["message"].string ?? params.compact))

        case "account/rateLimits/updated":
            let primary = params["rateLimits"]["primary"]
            if let used = primary["usedPercent"].double {
                emit(.status(String(format: "Codex · %.0f%% of window used", used)))
            }

        case "mcpServer/startupStatus/updated":
            if params["status"].string == "failed" {
                emit(.log("MCP \(params["name"].string ?? "?"): \(params["error"].string ?? "failed")"))
            }

        case "thread/tokenUsage/updated":
            break

        default:
            break
        }
    }

    private func describe(item: JSON, type: String) -> (String, String, String)? {
        switch type {
        case "commandExecution":
            let command = item["command"].string ?? item["parsedCmd"].compact
            return ("Shell · \(command.prefix(80))", "execute", command)
        case "fileChange":
            let paths = item["changes"].array.compactMap { $0["path"].string }
            let name = paths.first.map { ($0 as NSString).lastPathComponent } ?? "files"
            return ("Edit · \(name)\(paths.count > 1 ? " +\(paths.count - 1)" : "")",
                    "edit", paths.joined(separator: "\n"))
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            let name = item["toolName"].string ?? item["name"].string ?? "tool"
            return ("MCP · \(name)", "other", item["arguments"].pretty)
        case "webSearch":
            return ("Web search · \(item["query"].string ?? "")", "fetch", item["query"].string ?? "")
        case "subAgentActivity":
            return ("Subagent · \(item["description"].string ?? "")", "think", "")
        case "contextCompaction":
            return ("Compacting context", "think", "")
        case "imageGeneration":
            return ("Image generation", "other", "")
        default:
            return nil
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

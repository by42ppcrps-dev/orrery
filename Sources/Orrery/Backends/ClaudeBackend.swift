import Foundation

/// Claude Code driven through its streaming JSON interface:
/// `claude -p --input-format stream-json --output-format stream-json`.
///
/// The child owns one conversation. Model switches and cancel-recovery restart the child with
/// `--resume <session_id>`, so history survives.
@MainActor
final class ClaudeBackend: AgentBackend {
    var computerConnection: ComputerConnection?
    var sessionSettings = AgentSessionSettings()
    let provider = Provider.claude
    var currentModel: String = UserDefaults.standard.string(forKey: "claudeModel") ?? "claude-opus-5"
    var currentEffort: String = UserDefaults.standard.string(forKey: "claudeEffort") ?? "high" {
        didSet { if persistsSelection { UserDefaults.standard.set(currentEffort, forKey: "claudeEffort") } }
    }
    var persistsSelection = true
    var supportsEffort: Bool { true }
    var efforts: [String] { ["low", "medium", "high", "xhigh", "max"] }
    var onEvent: ((BackendEvent) -> Void)?

    /// Claude Code takes a model alias or a full ID. The handshake reports aliases only
    /// ("Opus", "Sonnet", …), so these explicit ids stay available as "specific versions".
    static let knownVersions = [
        ModelOption(id: "claude-fable-5-1", name: "Fable 5.1"),
        ModelOption(id: "claude-fable-5", name: "Fable 5"),
        ModelOption(id: "claude-opus-5", name: "Opus 5"),
        ModelOption(id: "claude-sonnet-5", name: "Sonnet 5"),
        ModelOption(id: "claude-haiku-4-5", name: "Haiku 4.5"),
        ModelOption(id: "claude-opus-4-8", name: "Opus 4.8"),
        ModelOption(id: "claude-sonnet-4-6", name: "Sonnet 4.6"),
        ModelOption(id: "opusplan", name: "Opus Plan Mode"),
    ]
    var knownVersions: [ModelOption] { Self.knownVersions }
    var models: [ModelOption] = ClaudeBackend.knownVersions

    private let child = LineProcess()
    private var sessionID: String?
    private var project: URL?
    private var autoApprove = false
    private var generation = UUID()
    private var initializationID: String?
    private var initialized = false
    private var pendingControls: Set<String> = []
    private var toolNames: [String: String] = [:]      // tool_use_id -> tool name
    private var pendingInterrupt = 0
    private var turnInFlight = false
    /// Set while the child is being replaced on purpose (model or effort change), so an
    /// intentional restart is not reported as a crash.
    private var restarting = false
    /// Whether the current assistant message arrived as stream deltas. When it did not — because
    /// `--include-partial-messages` is unavailable — the complete message is used instead, so the
    /// reply is never silently blank.
    private var sawTextDelta = false
    private var sawThinkingDelta = false
    /// A `result` that arrives before the initialize handshake completes describes a startup
    /// failure (for example a session id that cannot be resumed), not a turn.
    private var startupFailure: String?
    /// True while a `--resume` launch has not completed its handshake: an exit in that window is
    /// the resume failing, which `launch` reports and retries, not a crash to announce.
    private var resumingSession = false
    /// Test seam: a scripted executable stands in for the installed CLI.
    var executableForTest: String?

    var isRunning: Bool { child.isRunning }

    static func locate() -> String? {
        Executables.find(["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(NSHomeDirectory())/.claude/local/claude"], orNamed: "claude")
    }

    init() {
        child.onLine = { [weak self] json in self?.handle(json) }
        child.onRawLine = { [weak self] line in self?.emit(.log(line)) }
        child.onStderr = { [weak self] text in self?.emit(.log(text)) }
        child.onExit = { [weak self] code in
            guard let self else { return }
            if self.restarting { return }
            if self.resumingSession && !self.initialized { return }
            self.emit(.disconnected(reason: "Claude exited (\(code)) — ⌘N to restart"))
            if self.turnInFlight {
                self.turnInFlight = false
                self.emit(.failure("Claude exited (\(code)) mid-turn."))
                self.emit(.turnFinished(stopReason: "process exited", costUSD: nil))
            }
        }
    }

    func start(project: URL, autoApprove: Bool) async {
        stop()
        sessionID = nil
        self.project = project
        self.autoApprove = autoApprove
        await launch(resume: sessionSettings.resumeSession.isEmpty ? nil : sessionSettings.resumeSession)
    }

    private func launch(resume: String?) async {
        guard let executable = executableForTest ?? Self.locate() else {
            emit(.failure("claude not found. Install with: npm i -g @anthropic-ai/claude-code"))
            return
        }
        guard let project else { return }

        var args = ["-p",
                    "--input-format", "stream-json",
                    "--output-format", "stream-json",
                    "--verbose",
                    "--include-partial-messages",
                    "--model", currentModel,
                    "--effort", currentEffort,
                    "--permission-mode", sessionSettings.planMode ? "plan" : (autoApprove ? "bypassPermissions" : "default")]
        args += sessionSettings.claudeArguments(adding: computerConnection)
        if !autoApprove { args += ["--permission-prompt-tool", "stdio"] }
        if let resume { args += ["--resume", resume] }
        var environment = ProviderAccounts.shared.childEnvironment(for: .claude)
        args = MCPLaunchCredentials.claude(arguments: args, environment: &environment)

        do {
            emit(.status("Starting Claude Code…"))
            resumingSession = resume != nil
            try child.start(executable: executable, arguments: args, cwd: project,
                            environment: environment,
                            execution: AgentExecutionRequest(policy: sessionSettings.executionPolicy, workspace: project, provider: .claude,
                                                             additionalDirectories: sessionSettings.additionalDirectoryURLs))
            let requestID = UUID().uuidString
            initializationID = requestID
            child.write(["type": "control_request", "request_id": requestID,
                         "request": ["subtype": "initialize"]])
            let generation = self.generation
            let deadline = Date().addingTimeInterval(30)
            while initializationID == requestID, child.isRunning,
                  generation == self.generation, Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard generation == self.generation else { return }
            guard initialized else {
                let reason = startupFailure
                startupFailure = nil
                if resume != nil {
                    // The saved conversation is gone or unreadable; a fresh session beats a dead task.
                    restarting = true
                    stop()
                    emit(.note("The saved Claude session could not be resumed" + (reason.map { ": \($0)" } ?? "") + ". Starting a new conversation."))
                    emit(.sessionDropped(reason: reason ?? "resume failed"))
                    await launch(resume: nil)
                    restarting = false
                    return
                }
                stop()
                emit(.failure("Claude did not complete its startup handshake" + (reason.map { ": \($0)" } ?? ".")))
                emit(.disconnected(reason: "Claude startup failed"))
                return
            }
            if !autoApprove {
                emit(.note("Claude uses its default permission rules. Tools needing approval appear in this window."))
            }
        } catch {
            emit(.failure("Could not start Claude: \(error.localizedDescription)"))
        }
    }

    /// The CLI's own words for a failed start: its result text, an error string, or the
    /// `errors` list newer versions send, before falling back to the bare subtype.
    static func startupReason(_ json: JSON) -> String? {
        let errors = json["errors"].array.compactMap(\.string).filter { !$0.isEmpty }
        return json["result"].string ?? json["error"].string
            ?? (errors.isEmpty ? nil : errors.joined(separator: "; ")) ?? json["subtype"].string
    }

    func stop() {
        generation = UUID()
        pendingInterrupt += 1
        pendingControls.removeAll()
        initializationID = nil
        initialized = false
        turnInFlight = false
        child.stop()
    }

    func send(_ text: String) async { await send(text, attachments: []) }

    func send(_ text: String, attachments: [MessageAttachment]) async {
        guard child.isRunning, initialized else {
            emit(.failure("Claude is not running."))
            emit(.turnFinished(stopReason: "error", costUSD: nil))
            return
        }
        guard !turnInFlight else {
            emit(.failure("Claude already has a turn running."))
            emit(.turnFinished(stopReason: "busy", costUSD: nil))
            return
        }
        turnInFlight = true
        sawTextDelta = false
        sawThinkingDelta = false
        child.write(["type": "user",
                     "message": ["role": "user",
                                 "content": [["type": "text", "text": text]] + attachments.map { $0.content(for: .claude) }]])
    }

    func cancel() {
        guard child.isRunning else { return }
        pendingInterrupt += 1
        child.write(["type": "control_request",
                     "request_id": UUID().uuidString,
                     "request": ["subtype": "interrupt"]])
        // If the interrupt is not honored, restart the child and resume the same conversation.
        let attempt = pendingInterrupt
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.pendingInterrupt == attempt else { return }
            self.emit(.note("Interrupt not acknowledged — restarting Claude and resuming the session."))
            let resume = self.sessionID
            self.restarting = true
            self.stop()
            await self.launch(resume: resume)
            self.restarting = false
            self.emit(.turnFinished(stopReason: "cancelled", costUSD: nil))
        }
    }

    /// `--effort` is per-invocation, so a change restarts the child and resumes the same
    /// conversation with `--resume`.
    func setEffort(_ effort: String) async {
        guard !turnInFlight else { emit(.note("Stop the current turn before changing effort.")); return }
        guard effort != currentEffort else { return }
        currentEffort = effort
        emitCatalogIfConfirmed()
        guard child.isRunning || sessionID != nil else { return }
        let resume = sessionID
        restarting = true
        stop()
        await launch(resume: resume)
        restarting = false
        emit(.note("Effort set to \(effort)\(resume != nil ? " (conversation resumed)" : "")."))
    }

    /// Model and effort are spawn arguments, so before `start` a plain assignment is enough.
    func preconfigure(model: String?, effort: String?) {
        if let model, !model.isEmpty { currentModel = model }
        if let effort, !effort.isEmpty { currentEffort = effort }
    }

    func setModel(_ id: String) async {
        guard !turnInFlight else { emit(.note("Stop the current turn before changing models.")); return }
        guard id != currentModel else { return }
        currentModel = id
        if persistsSelection { UserDefaults.standard.set(id, forKey: "claudeModel") }
        emitCatalogIfConfirmed()
        guard child.isRunning || sessionID != nil else { return }
        let resume = sessionID
        restarting = true
        stop()
        await launch(resume: resume)
        restarting = false
        emit(.note("Switched to \(models.first { $0.id == id }?.name ?? id)"
                   + (resume != nil ? " (conversation resumed)" : "")))
    }

    /// Constructor IDs become a models event only after `system/init`. Changing
    /// effort or model during initialization must not mark them reported.
    private func emitCatalogIfConfirmed() {
        guard sessionID != nil else { return }
        emit(.models(models, current: currentModel))
    }

    // MARK: - Event mapping

    /// Test seam so `--audit` can inject `system/init` without spawning Claude.
    func handleJSONForTest(_ json: JSON) { handle(json) }

    private func handle(_ json: JSON) {
        switch json["type"].string ?? "" {
        case "control_request":
            handleControlRequest(json)

        case "control_cancel_request":
            if let id = json["request_id"].string { pendingControls.remove(id) }

        case "control_response":
            let response = json["response"]
            guard response["request_id"].string == initializationID else { break }
            initializationID = nil
            if response["subtype"].string == "error" {
                emit(.failure(response["error"].string ?? "Claude initialization failed"))
                stop()
                emit(.disconnected(reason: "Claude initialization failed"))
                break
            }
            let reported = response["response"]["models"].array.compactMap { item -> ModelOption? in
                guard let id = item["value"].string else { return nil }
                return ModelOption(id: id, name: item["displayName"].string ?? id)
            }
            if !reported.isEmpty {
                models = reported
                // Keep an explicitly selected full model ID visible even when the CLI lists aliases.
                if !models.contains(where: { $0.id == currentModel }) {
                    models.append(Self.knownVersions.first { $0.id == currentModel }
                                  ?? ModelOption(id: currentModel, name: currentModel))
                }
                emit(.models(models, current: currentModel))
            }
            initialized = true
            resumingSession = false
            emit(.connected(sessionID: sessionID ?? "ready"))
        case "system":
            switch json["subtype"].string ?? "" {
            case "init":
                if let id = json["session_id"].string {
                    sessionID = id
                    emit(.connected(sessionID: id))
                }
                // Constructor IDs become a confirmed report only after init.
                emit(.models(models, current: currentModel))
                let commands = json["slash_commands"].array.compactMap { $0.string }
                if !commands.isEmpty {
                    SlashCommandStore.shared.set(commands.sorted(), for: .claude)
                }
            default:
                break
            }

        case "stream_event":
            handleStreamEvent(json["event"])

        case "assistant":
            for block in json["message"]["content"].array {
                switch block["type"].string ?? "" {
                case "text" where !sawTextDelta:
                    emit(.assistantDelta(block["text"].string ?? ""))
                case "thinking" where !sawThinkingDelta:
                    emit(.thoughtDelta(block["thinking"].string ?? ""))
                default:
                    break
                }
            }
            // Tool calls only arrive as complete blocks.
            for block in json["message"]["content"].array where block["type"].string == "tool_use" {
                let id = block["id"].string ?? UUID().uuidString
                let name = block["name"].string ?? "tool"
                toolNames[id] = name
                emit(.toolStarted(id: id, title: title(for: name, input: block["input"]),
                                  kind: kind(for: name), input: block["input"].pretty))
                emit(.toolUpdated(id: id, status: "in_progress", output: nil, diff: nil))
            }

        case "user":
            for block in json["message"]["content"].array
            where block["type"].string == "tool_result" {
                let id = block["tool_use_id"].string ?? ""
                let failed = block["is_error"].bool ?? false
                var text = block["content"].string ?? ""
                if text.isEmpty {
                    text = block["content"].array
                        .compactMap { $0["text"].string }
                        .joined(separator: "\n")
                }
                emit(.toolUpdated(id: id, status: failed ? "failed" : "completed",
                                  output: text.isEmpty ? nil : text, diff: nil))
            }

        case "result":
            guard initialized else {
                startupFailure = Self.startupReason(json)
                break
            }
            pendingInterrupt += 1     // any pending interrupt watchdog is now moot
            turnInFlight = false
            if json["is_error"].bool == true {
                emit(.failure(json["result"].string ?? json["error"].compact.ifEmpty("Turn failed")))
            }
            emit(.turnFinished(stopReason: json["stop_reason"].string ?? json["subtype"].string,
                               costUSD: json["total_cost_usd"].double))

        case "rate_limit_event":
            let info = json["rate_limit_info"]
            if info["status"].string != "allowed" {
                emit(.note("Rate limit: \(info["status"].string ?? "?") "
                           + "(\(info["rateLimitType"].string ?? "window"))"))
            }

        default:
            break
        }
    }

    func observeProtocolForTest(_ observer: @escaping ([String: Any]) -> Void) {
        child.onWriteForTest = observer
    }

    private func handleControlRequest(_ json: JSON) {
        guard let id = json["request_id"].string else { return }
        guard json["request"]["subtype"].string == "can_use_tool" else {
            child.write(["type": "control_response", "response": ["subtype": "error",
                         "request_id": id, "error": "Unsupported control request"]])
            return
        }
        pendingControls.insert(id)
        let input = json["request"]["input"].raw as? [String: Any] ?? [:]
        let tool = json["request"]["tool_name"].string ?? "Tool"
        let generation = self.generation
        emit(.permission(PermissionRequest(title: "Allow \(tool)?", detail: JSON(input).pretty,
            options: [PermissionOption(id: "allow", name: "Allow once", kind: "allow_once"),
                      PermissionOption(id: "deny", name: "Deny", kind: "reject_once")],
            reply: { [weak self] choice in
                guard let self, generation == self.generation, self.pendingControls.remove(id) != nil else { return }
                let response: [String: Any] = choice == "allow"
                    ? ["behavior": "allow", "updatedInput": input]
                    : ["behavior": "deny", "message": "The user declined this tool request."]
                self.child.write(["type": "control_response", "response": [
                    "subtype": "success", "request_id": id, "response": response]])
            })))
    }

    private func handleStreamEvent(_ event: JSON) {
        switch event["type"].string ?? "" {
        case "message_start":
            sawTextDelta = false
            sawThinkingDelta = false
        case "content_block_delta":
            let delta = event["delta"]
            switch delta["type"].string ?? "" {
            case "text_delta":
                sawTextDelta = true
                emit(.assistantDelta(delta["text"].string ?? ""))
            case "thinking_delta":
                sawThinkingDelta = true
                emit(.thoughtDelta(delta["thinking"].string ?? ""))
            default:
                break
            }
        default:
            break
        }
    }

    private func title(for name: String, input: JSON) -> String {
        switch name {
        case "Bash":
            return input["command"].string.map { "Bash · \($0.prefix(70))" } ?? "Bash"
        case "Read", "Edit", "Write", "NotebookEdit":
            let path = input["file_path"].string ?? input["path"].string ?? ""
            return "\(name) · \((path as NSString).lastPathComponent)"
        case "Grep":
            return "Grep · \(input["pattern"].string ?? "")"
        case "Glob":
            return "Glob · \(input["pattern"].string ?? "")"
        case "Task":
            return "Agent · \(input["description"].string ?? "")"
        case "WebFetch", "WebSearch":
            return "\(name) · \(input["url"].string ?? input["query"].string ?? "")"
        default:
            return name
        }
    }

    private func kind(for name: String) -> String {
        switch name {
        case "Read", "NotebookRead": return "read"
        case "Edit", "Write", "NotebookEdit": return "edit"
        case "Grep", "Glob": return "search"
        case "Bash", "BashOutput", "KillShell": return "execute"
        case "WebFetch", "WebSearch": return "fetch"
        case "Task": return "think"
        default: return "other"
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

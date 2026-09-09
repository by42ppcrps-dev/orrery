import Foundation

/// Grok Build over ACP (`grok agent --no-leader stdio`).
///
/// `--no-leader` is deliberate: it keeps this app off `~/.grok/leader.sock` so a TUI session or
/// automation running elsewhere on the machine is never touched.
@MainActor
final class GrokBackend: AgentBackend {
    var computerConnection: ComputerConnection?
    var sessionSettings = AgentSessionSettings()
    let provider = Provider.grok
    var models: [ModelOption] = []
    var currentModel: String = ""
    var currentEffort: String = UserDefaults.standard.string(forKey: "grokEffort") ?? "high" {
        didSet { if persistsSelection { UserDefaults.standard.set(currentEffort, forKey: "grokEffort") } }
    }
    var persistsSelection = true
    /// A model requested before the session existed; applied over `session/set_model` as soon
    /// as the agent reports in.
    private var pendingModel: String?
    var supportsEffort: Bool { true }
    var efforts: [String] { effortsByModel[currentModel] ?? ["low", "medium", "high"] }
    var onEvent: ((BackendEvent) -> Void)?

    private let client = ACPClient()
    private var sessionID: String?
    private var effortsByModel: [String: [String]] = [:]
    private var project: URL?
    private var autoApprove = true
    /// Grok persists a session's effort, and that persisted value wins over the spawn flag on
    /// `session/load` — so an effort change can only take on a session that has no history yet.
    private var hasHistory = false
    /// Test seam: a scripted executable stands in for the installed CLI.
    var executableForTest: String?

    var isRunning: Bool { client.isRunning }

    static func locate() -> String? {
        Executables.find(["\(NSHomeDirectory())/.grok/bin/grok",
                          "/opt/homebrew/bin/grok", "/usr/local/bin/grok"], orNamed: "grok")
    }

    init() {
        client.onEvent = { [weak self] event in self?.handle(event) }
        client.onPermission = { [weak self] params, reply in
            guard let self else { reply(nil); return }
            let call = params["toolCall"]
            let options = params["options"].array.compactMap { option -> PermissionOption? in
                guard let id = option["optionId"].string else { return nil }
                return PermissionOption(id: id, name: option["name"].string ?? id,
                                        kind: option["kind"].string ?? "")
            }
            self.emit(.permission(PermissionRequest(
                title: call["title"].string ?? "Allow this action?",
                detail: call["rawInput"].exists ? call["rawInput"].pretty : call["kind"].compact,
                options: options,
                reply: reply)))
        }
    }

    func start(project: URL, autoApprove: Bool) async {
        self.project = project
        self.autoApprove = autoApprove
        hasHistory = false
        guard let executable = executableForTest ?? Self.locate() else {
            emit(.failure("grok not found. Install it with: curl -fsSL https://x.ai/cli/install.sh | bash"))
            return
        }
        do {
            emit(.status("Starting Grok agent…"))
            try client.start(executable: executable, alwaysApprove: autoApprove && !sessionSettings.planMode, model: nil,
                             effort: currentEffort, project: project,
                             environment: sessionSettings.grokEnvironment.merging(ProviderAccounts.shared.childEnvironment(for: .grok)) { _, new in new },
                             extraArguments: sessionSettings.grokAgentArguments,
                             execution: AgentExecutionRequest(policy: sessionSettings.executionPolicy, workspace: project, provider: .grok))
            _ = try await client.request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": true,
                                             "writeTextFile": autoApprove],
                                       "terminal": false],
            ])
            let parameters: [String: Any] = [
                "cwd": project.path,
                "mcpServers": sessionSettings.acpMCPServers + (computerConnection.map { [$0.acp] } ?? []),
                "_meta": sessionSettings.grokMetadata(autoApprove: autoApprove)
            ]
            var resumed = false
            var result: JSON
            if !sessionSettings.resumeSession.isEmpty {
                var loadParameters = parameters
                loadParameters["sessionId"] = sessionSettings.resumeSession
                // ACP replays the conversation as session/update notifications before the load
                // result. The app restores its own transcript, so the replay is dropped.
                replayingHistory = true
                defer { replayingHistory = false }
                do {
                    result = try await client.request("session/load", loadParameters)
                    resumed = true
                } catch {
                    emit(.note("The saved Grok session could not be resumed: \(error.localizedDescription). Starting a new conversation."))
                    emit(.sessionDropped(reason: error.localizedDescription))
                    result = try await client.request("session/new", parameters)
                }
            } else { result = try await client.request("session/new", parameters) }
            guard let id = result["sessionId"].string ?? (resumed ? sessionSettings.resumeSession : nil), !id.isEmpty else {
                throw ACPClient.ClientError.rpc(code: -32603, message: "Grok did not return a session", data: nil)
            }
            sessionID = id
            // A model chosen before the session existed is applied here, before anyone can
            // send a prompt: a detached switch used to race the first turn, which then ran on
            // the agent's default model while the transcript claimed otherwise.
            if let wanted = applyModels(result["models"]) { await setModel(wanted) }
            emit(.connected(sessionID: sessionID ?? "?"))
        } catch {
            emit(.failure(error.localizedDescription))
            client.stop()
        }
    }

    func stop() {
        client.stop()
        sessionID = nil
    }

    /// True while `session/load` is in flight; replayed history updates are dropped then.
    private var replayingHistory = false
    /// How many replayed updates were dropped, for the audit.
    private(set) var droppedReplayUpdates = 0

    func send(_ text: String) async { await send(text, attachments: []) }

    func send(_ text: String, attachments: [MessageAttachment]) async {
        guard let sessionID else {
            emit(.failure("No Grok session."))
            emit(.turnFinished(stopReason: "error", costUSD: nil))
            return
        }
        hasHistory = true
        do {
            let result = try await client.request("session/prompt", [
                "sessionId": sessionID,
                "prompt": [["type": "text", "text": text]] + attachments.map { $0.content(for: .grok) },
            ])
            emit(.turnFinished(stopReason: result["stopReason"].string, costUSD: nil))
        } catch {
            emit(.failure(error.localizedDescription))
            emit(.turnFinished(stopReason: "error", costUSD: nil))
        }
    }

    func cancel() {
        guard let sessionID else { return }
        client.notify("session/cancel", ["sessionId": sessionID])   // ACP cancel is a notification
    }

    /// Effort is a spawn-time flag for Grok (`grok agent --reasoning-effort`), and a resumed
    /// session restores its own persisted effort. So: apply it now on an untouched session,
    /// otherwise hold it for the next one rather than silently doing nothing.
    func setEffort(_ effort: String) async {
        guard effort != currentEffort else { return }
        currentEffort = effort
        emit(.models(models, current: currentModel))
        guard let project else { return }
        if isRunning && hasHistory {
            emit(.note("Effort set to \(effort). Grok applies it when a session starts — "
                       + "press ⌘N for a new session at this effort."))
            return
        }
        client.stop()
        sessionID = nil
        await start(project: project, autoApprove: autoApprove)
        emit(.note("Effort set to \(effort)."))
    }

    /// Effort is a spawn flag, so it applies directly. The model can only be set on a live
    /// session, so it is parked until the agent reports its models.
    func preconfigure(model: String?, effort: String?) {
        if let effort, !effort.isEmpty { currentEffort = effort }
        if let model, !model.isEmpty { pendingModel = model }
    }

    func setModel(_ id: String) async {
        guard let sessionID else { return }
        do {
            _ = try await client.request("session/set_model", ["sessionId": sessionID, "modelId": id])
            currentModel = id
            emit(.models(models, current: id))
        } catch {
            emit(.failure("Could not switch model: \(error.localizedDescription)"))
        }
    }

    // MARK: - Event mapping

    private func handle(_ event: ACPEvent) {
        switch event {
        case let .sessionUpdate(_, update):
            if replayingHistory { droppedReplayUpdates += 1; return }
            map(update)
        case let .notification(method, params):
            mapNotification(method: method, params: params)
        case let .log(text):
            emit(.log(text))
        case let .exited(code):
            sessionID = nil
            emit(.disconnected(reason: "Grok agent exited (\(code)) — ⌘N to restart"))
        }
    }

    private func map(_ update: JSON) {
        switch update["sessionUpdate"].string ?? "" {
        case "agent_message_chunk":
            emit(.assistantDelta(update["content"]["text"].string ?? ""))

        case "agent_thought_chunk":
            emit(.thoughtDelta(update["content"]["text"].string ?? ""))

        case "tool_call":
            let id = update["toolCallId"].string ?? UUID().uuidString
            let name = update["title"].string ?? "Tool call"
            let input = update["rawInput"].exists ? update["rawInput"] : update["input"]
            let reported = update["kind"].string ?? ""
            emit(.toolStarted(id: id,
                              title: Self.title(name: name, input: input),
                              kind: reported.isEmpty || reported == "other"
                                ? Self.kind(for: name) : reported,
                              input: input.compact))
            emitContent(update["content"], toolID: id, status: update["status"].string)

        case "tool_call_update":
            let id = update["toolCallId"].string ?? ""
            emitContent(update["content"], toolID: id, status: update["status"].string)

        case "plan":
            emit(.plan(update["entries"].array.map { step in
                let status = step["status"].string ?? ""
                let mark = status == "completed" ? "✓" : (status == "in_progress" ? "→" : "•")
                return "\(mark) \(step["content"].string ?? "")"
            }))

        case "available_commands_update":
            let names = update["availableCommands"].array.compactMap { $0["name"].string }
            SlashCommandStore.shared.set(names.sorted(), for: .grok)

        default:
            break
        }
    }


    /// Grok reports the tool name as `title` and often leaves `kind` unset, so the icon and a
    /// useful one-line label are derived from the name and arguments.
    static func kind(for name: String) -> String {
        switch name {
        case "read_file", "read": return "read"
        case "search_replace", "edit_file", "write_file", "create_file", "write": return "edit"
        case "grep", "grep_search", "codebase_search", "glob", "list_dir": return "search"
        case "bash", "run_terminal_cmd", "run_terminal_command": return "execute"
        case "web_search", "web_fetch", "open_page", "open_page_with_find",
             "x_user_search", "x_semantic_search", "x_keyword_search", "x_thread_fetch":
            return "fetch"
        case "spawn_subagent", "task", "workflow", "enter_plan_mode", "exit_plan_mode",
             "monitor", "memory_search", "memory_get":
            return "think"
        case "delete_file": return "delete"
        default: return "other"
        }
    }

    static func title(name: String, input: JSON) -> String {
        let detail: String?
        switch name {
        case "read_file", "search_replace", "edit_file", "write_file", "write", "delete_file":
            let path = input["target_file"].string ?? input["path"].string
                ?? input["file_path"].string ?? ""
            detail = path.isEmpty ? nil : (path as NSString).lastPathComponent
        case "list_dir":
            let path = input["target_directory"].string ?? input["path"].string ?? ""
            detail = path.isEmpty ? nil : (path as NSString).lastPathComponent
        case "grep", "grep_search", "codebase_search":
            detail = input["pattern"].string ?? input["query"].string
        case "bash", "run_terminal_cmd", "run_terminal_command":
            detail = input["command"].string.map { String($0.prefix(70)) }
        case "web_search", "web_fetch", "open_page", "open_page_with_find":
            detail = input["query"].string ?? input["url"].string
        case "memory_search":
            detail = input["query"].string
        case "todo_write":
            detail = "\(input["todos"].array.count) item(s)"
        case "spawn_subagent":
            detail = input["description"].string ?? input["subagent_type"].string
        default:
            detail = nil
        }
        guard let detail, !detail.isEmpty else { return name }
        return "\(name) · \(detail)"
    }

    private func emitContent(_ content: JSON, toolID: String, status: String?) {
        var text = ""
        var diff: FileDiff?
        for block in content.array {
            switch block["type"].string ?? "" {
            case "diff":
                diff = FileDiff(path: block["path"].string ?? "?",
                                oldText: block["oldText"].string ?? "",
                                newText: block["newText"].string ?? "")
            case "content":
                let chunk = block["content"]["type"].string == "image"
                    ? "[Image returned by tool]" : (block["content"]["text"].string ?? block["content"].compact)
                if !chunk.isEmpty { text += (text.isEmpty ? "" : "\n") + chunk }
            default:
                if let chunk = block["text"].string, !chunk.isEmpty {
                    text += (text.isEmpty ? "" : "\n") + chunk
                }
            }
        }
        if status != nil || !text.isEmpty || diff != nil {
            emit(.toolUpdated(id: toolID, status: status,
                              output: text.isEmpty ? nil : text, diff: diff))
        }
    }

    private func mapNotification(method: String, params: JSON) {
        switch method {
        case "_x.ai/models/update":
            if let wanted = applyModels(params) { Task { await self.setModel(wanted) } }

        case "_x.ai/session/prompt_complete":
            if params["stopReason"].string == "error" {
                emit(.failure(params["agentResult"].string ?? "Turn failed"))
            }

        case "_x.ai/session_notification":
            let update = params["update"]
            switch update["sessionUpdate"].string ?? "" {
            case "retry_state" where update["type"].string == "failed":
                emit(.failure(update["message"].string ?? "Request failed"))
            case "model_changed":
                if let id = update["model_id"].string {
                    currentModel = id
                    emit(.models(models, current: id))
                }
            default:
                break
            }

        default:
            break
        }
    }

    /// Records the agent's catalog and current model; returns a parked model that still has to
    /// be switched to, so the caller decides whether to wait for the switch.
    @discardableResult
    private func applyModels(_ payload: JSON) -> String? {
        let list = payload["availableModels"].array.compactMap { model -> ModelOption? in
            guard let id = model["modelId"].string else { return nil }
            let levels = model["_meta"]["reasoningEfforts"].array.compactMap {
                $0["id"].string ?? $0["value"].string
            }
            if !levels.isEmpty { effortsByModel[id] = levels }
            return ModelOption(id: id, name: model["name"].string ?? id)
        }
        if !list.isEmpty { models = list }
        var wanted: String?
        if let pending = pendingModel {
            pendingModel = nil
            if pending != payload["currentModelId"].string { wanted = pending }
        }
        if let current = payload["currentModelId"].string {
            currentModel = current
            // Trust the agent's own report of the running session's effort.
            if let reported = payload["availableModels"].array
                .first(where: { $0["modelId"].string == current })?["_meta"]["reasoningEffort"].string,
               !reported.isEmpty {
                currentEffort = reported
            }
        }
        emit(.models(models, current: currentModel))
        return wanted
    }
}

/// Slash commands each provider advertises, so the composer can autocomplete them.
/// Multiple windows subscribe; a second AppModel must not unhook the first.
@MainActor
final class SlashCommandStore {
    static let shared = SlashCommandStore()
    private var commands: [Provider: [String]] = [:]
    private var subscribers: [UUID: () -> Void] = [:]

    var subscriberCount: Int { subscribers.count }

    @discardableResult
    func addSubscriber(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        return id
    }

    func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    func set(_ names: [String], for provider: Provider) {
        commands[provider] = names
        for handler in Array(subscribers.values) {
            handler()
        }
    }

    func names(for provider: Provider) -> [String] { commands[provider] ?? [] }
}

/// Drops a slash-command subscription when the owning window model is released.
final class SlashCommandToken {
    let id: UUID
    init(id: UUID) { self.id = id }
    deinit {
        let id = self.id
        Task { @MainActor in
            SlashCommandStore.shared.removeSubscriber(id)
        }
    }
}

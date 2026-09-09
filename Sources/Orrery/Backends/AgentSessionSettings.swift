import Foundation
import CryptoKit

/// Explicit project settings. The provider's ordinary user/project configuration still loads;
/// these values are session overlays, never edits to the global CLI configuration.
struct AgentSessionSettings: Codable, Equatable {
    var executionPolicy: AgentExecutionPolicy = .confinedWrites
    var model = ""
    var effort = ""
    var planMode = false
    var instructions = ""
    var systemPrompt = ""
    var resumeSession = ""
    var agentProfile = ""
    var subagents = true
    var chrome = false
    var nativeComputerControl = true
    var sandbox = "workspace-write"
    var networkAccess = false
    var webSearch = "cached"
    var allowedTools = ""
    var deniedTools = ""
    var additionalDirectories = ""
    /// The additional writable folders as URLs, for the execution boundary.
    var additionalDirectoryURLs: [URL] {
        Self.lines(additionalDirectories).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }
    var pluginDirectories = ""
    var maxBudget = ""
    var outputSchema = ""
    var providerConfiguration = ""
    var mcpConfiguration = ""
    /// Set by the model when it hands these settings to a backend, so connectors limited to one
    /// agent only reach that agent. Not saved: it is the session's provider, not a preference.
    var connectorProvider: Provider? = nil

    init() {}

    /// Saved settings created before host confinement preserve their previous execution mode.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        executionPolicy = try values.decodeIfPresent(AgentExecutionPolicy.self, forKey: .executionPolicy) ?? .fullAccess
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        effort = try values.decodeIfPresent(String.self, forKey: .effort) ?? ""
        planMode = try values.decodeIfPresent(Bool.self, forKey: .planMode) ?? false
        instructions = try values.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        systemPrompt = try values.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        resumeSession = try values.decodeIfPresent(String.self, forKey: .resumeSession) ?? ""
        agentProfile = try values.decodeIfPresent(String.self, forKey: .agentProfile) ?? ""
        subagents = try values.decodeIfPresent(Bool.self, forKey: .subagents) ?? true
        chrome = try values.decodeIfPresent(Bool.self, forKey: .chrome) ?? false
        nativeComputerControl = try values.decodeIfPresent(Bool.self, forKey: .nativeComputerControl) ?? true
        sandbox = try values.decodeIfPresent(String.self, forKey: .sandbox) ?? "workspace-write"
        networkAccess = try values.decodeIfPresent(Bool.self, forKey: .networkAccess) ?? false
        webSearch = try values.decodeIfPresent(String.self, forKey: .webSearch) ?? "cached"
        allowedTools = try values.decodeIfPresent(String.self, forKey: .allowedTools) ?? ""
        deniedTools = try values.decodeIfPresent(String.self, forKey: .deniedTools) ?? ""
        additionalDirectories = try values.decodeIfPresent(String.self, forKey: .additionalDirectories) ?? ""
        pluginDirectories = try values.decodeIfPresent(String.self, forKey: .pluginDirectories) ?? ""
        maxBudget = try values.decodeIfPresent(String.self, forKey: .maxBudget) ?? ""
        outputSchema = try values.decodeIfPresent(String.self, forKey: .outputSchema) ?? ""
        providerConfiguration = try values.decodeIfPresent(String.self, forKey: .providerConfiguration) ?? ""
        mcpConfiguration = try values.decodeIfPresent(String.self, forKey: .mcpConfiguration) ?? ""
    }
    private enum CodingKeys: String, CodingKey {
        case executionPolicy, model, effort, planMode, instructions, systemPrompt, resumeSession, agentProfile, subagents, chrome, nativeComputerControl, sandbox, networkAccess, webSearch, allowedTools, deniedTools, additionalDirectories, pluginDirectories, maxBudget, outputSchema, providerConfiguration, mcpConfiguration
    }

    static func object(_ text: String) throws -> [String: Any] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard text.utf8.count <= 65_536,
              let data = text.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ComputerError("Enter a JSON object, up to 64 KB.")
        }
        return result
    }
    func validate() throws {
        _ = try Self.object(providerConfiguration)
        _ = try Self.object(outputSchema)
        let servers = try Self.object(mcpConfiguration)
        for (name, value) in servers {
            guard name != "studio_computer", let server = value as? [String: Any],
                  server["command"] is String || server["url"] is String else {
                throw ComputerError("Each MCP server needs a command or URL. studio_computer is reserved for the IDE.")
            }
            if let args = server["args"], !(args is [String]) { throw ComputerError("MCP args must be a list of strings.") }
        }
        if !maxBudget.isEmpty, Double(maxBudget).map({ $0.isFinite && $0 > 0 }) != true {
            throw ComputerError("Budget must be a positive number.")
        }
        guard ["read-only", "workspace-write", "danger-full-access"].contains(sandbox),
              ["disabled", "cached", "live"].contains(webSearch) else { throw ComputerError("Unsupported sandbox or web-search setting.") }
    }
    var configuration: [String: Any] { (try? Self.object(providerConfiguration)) ?? [:] }
    /// Plugin-provided servers first, then the shared connectors for this session's provider, then
    /// this project's explicit list; later ones win by name.
    var mcpServers: [String: Any] {
        PluginSnapshot.shared.mcpServers
            .merging(ConnectorSnapshot.shared.servers(for: connectorProvider)) { _, connector in connector }
            .merging((try? Self.object(mcpConfiguration)) ?? [:]) { _, explicit in explicit }
    }
    static func lines(_ text: String) -> [String] { text.components(separatedBy: .newlines).filter { !$0.isEmpty } }
    var grokEnvironment: [String: String] {
        var overlay = configuration
        if !effort.isEmpty {
            var models = overlay["models"] as? [String: Any] ?? [:]
            models["default_reasoning_effort"] = effort; overlay["models"] = models
        }
        var environment = ["GROK_SUBAGENTS": subagents ? "1" : "0"]
        if !overlay.isEmpty { environment["GROK_CONFIG"] = JSON(overlay).compact }
        return environment
    }
    var grokAgentArguments: [String] {
        Self.lines(pluginDirectories).flatMap { ["--plugin-dir", $0] }
    }
    func grokMetadata(autoApprove: Bool) -> [String: Any] {
        var meta: [String: Any] = ["yoloMode": autoApprove && !planMode]
        if !instructions.isEmpty { meta["rules"] = instructions }
        if !systemPrompt.isEmpty { meta["systemPromptOverride"] = systemPrompt }
        if planMode { meta["agentProfile"] = "plan" }
        else if !agentProfile.isEmpty { meta["agentProfile"] = agentProfile }
        return meta
    }
    var acpMCPServers: [[String: Any]] {
        mcpServers.compactMap { name, raw in
            guard let server = raw as? [String: Any] else { return nil }
            if let command = server["command"] as? String {
                return ["name": name, "command": command, "args": server["args"] as? [String] ?? [],
                        "env": (server["env"] as? [String: String] ?? [:]).map { ["name": $0.key, "value": $0.value] }]
            }
            if let url = server["url"] as? String {
                return ["name": name, "url": url, "type": server["type"] as? String ?? "http",
                        "headers": (server["headers"] as? [String: String] ?? [:]).map { ["name": $0.key, "value": $0.value] }]
            }
            return nil
        }
    }
    var claudeArguments: [String] {
        var args: [String] = []
        for (flag, value) in [("--append-system-prompt", instructions), ("--system-prompt", systemPrompt),
                              ("--agent", agentProfile), ("--allowedTools", allowedTools),
                              ("--disallowedTools", deniedTools), ("--max-budget-usd", maxBudget),
                              ("--json-schema", outputSchema), ("--settings", providerConfiguration)] where !value.isEmpty {
            args += [flag, value]
        }
        for path in Self.lines(additionalDirectories) { args += ["--add-dir", path] }
        for path in Self.lines(pluginDirectories) { args += ["--plugin-dir", path] }
        if chrome { args.append("--chrome") }
        if !mcpServers.isEmpty { args += ["--mcp-config", JSON(["mcpServers": mcpServers]).compact] }
        return args
    }
    func claudeArguments(adding computer: ComputerConnection?) -> [String] {
        guard let computer else { return claudeArguments }
        var args = claudeArguments
        if let index = args.firstIndex(of: "--mcp-config") { args.removeSubrange(index...index + 1) }
        var servers = mcpServers
        servers["studio_computer"] = computer.mcp
        args += ["--mcp-config", JSON(["mcpServers": servers]).compact]
        return args
    }
    var codexConfiguration: [String: Any] { codexConfiguration(adding: nil) }

    /// Thread overrides replace the MCP table from app-server launch flags. Include the
    /// IDE bridge in that same table so shared connectors cannot erase it for Codex.
    func codexConfiguration(adding computer: ComputerConnection?) -> [String: Any] {
        var config = configuration
        config["sandbox_workspace_write.network_access"] = networkAccess
        config["web_search"] = webSearch
        var servers = config["mcp_servers"] as? [String: Any] ?? [:]
        servers.merge(MCPLaunchCredentials.codexServers(mcpServers)) { _, managed in managed }
        if let computer {
            var bridge = computer.mcp
            bridge["default_tools_approval_mode"] = "approve"
            bridge["tool_timeout_sec"] = 125
            servers["studio_computer"] = bridge
        }
        if !servers.isEmpty { config["mcp_servers"] = servers }
        if !additionalDirectories.isEmpty { config["sandbox_workspace_write.writable_roots"] = Self.lines(additionalDirectories) }
        return config
    }
    func nativeArguments(for provider: Provider, autoApprove: Bool) -> [String] {
        var args: [String] = []
        if !model.isEmpty { args += ["--model", model] }
        if !effort.isEmpty { args += provider == .codex ? ["-c", "model_reasoning_effort=\(TOMLArgument.value(effort))"] : ["--effort", effort] }
        switch provider {
        case .grok:
            if planMode { args += ["--permission-mode", "plan"] }
            else if autoApprove { args.append("--always-approve") }
            if !instructions.isEmpty { args += ["--rules", instructions] }
            if !systemPrompt.isEmpty { args += ["--system-prompt-override", systemPrompt] }
            if !agentProfile.isEmpty { args += ["--agent", agentProfile] }
            if !resumeSession.isEmpty { args += ["--resume", resumeSession] }
            if !subagents { args.append("--no-subagents") }
        case .claude:
            args += claudeArguments
            if planMode { args += ["--permission-mode", "plan"] }
            else if autoApprove { args += ["--permission-mode", "bypassPermissions"] }
            if !resumeSession.isEmpty { args += ["--resume", resumeSession] }
        case .codex:
            args += ["--sandbox", planMode ? "read-only" : sandbox, "--ask-for-approval", autoApprove ? "never" : "on-request"]
            for key in codexConfiguration.keys.sorted() { args += ["-c", "\(key)=\(TOMLArgument.value(codexConfiguration[key]!))"] }
            if !instructions.isEmpty { args += ["-c", "developer_instructions=\(TOMLArgument.value(instructions))"] }
            if !resumeSession.isEmpty { args += ["resume", resumeSession] }
        }
        return args
    }
}

@MainActor
enum AgentSettingsStore {
    static func location(_ project: URL) -> URL {
        let digest = SHA256.hash(data: Data((WorkspaceFileAccess.canonicalPath(project) ?? project.path).utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Orrery/ProjectSettings/\(digest).json")
    }
    static func load(_ project: URL) -> [Provider: AgentSessionSettings] {
        guard let data = try? Data(contentsOf: location(project)), data.count <= 512 * 1024,
              let values = try? JSONDecoder().decode([Provider: AgentSessionSettings].self, from: data) else { return [:] }
        return values.filter { (try? $0.value.validate()) != nil }
    }
    static func save(_ values: [Provider: AgentSessionSettings], project: URL) throws {
        let url = location(project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(values)
        guard data.count <= 512 * 1024 else { throw ComputerError("Project settings are too large.") }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// `-c` takes TOML, not JSON. In particular objects use `=` and strings must remain quoted.
enum TOMLArgument {
    static func value(_ object: Any) -> String {
        if let dictionary = object as? [String: Any] {
            return "{" + dictionary.keys.sorted().map { quote($0) + " = " + value(dictionary[$0]!) }.joined(separator: ", ") + "}"
        }
        if let array = object as? [Any] { return "[" + array.map(value).joined(separator: ", ") + "]" }
        if let string = object as? String { return quote(string) }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return quote("")
    }
    private static func quote(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
        return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
    }
}

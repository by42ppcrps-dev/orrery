import Foundation
import AppKit
import SwiftUI

/// Connectors: the shared MCP list every agent gets. The store keeps secrets out of its file,
/// filters by agent, feeds the three CLIs' own argument shapes, and imports what the Claude
/// Code and Codex configs already hold — all against fixtures in a temporary folder.
@MainActor
enum AuditConnectors {
    private static func connectionLayout(_ audit: Auditor) async {
        audit.section("Connections — large lists create only visible native controls")
        await Auditor.withTemporaryDirectory { root in
            let store = ConnectorStore(directory: root, secrets: .memory())
            for index in 0..<100 {
                store.upsert(Connector(name: "connection-\(index)", command: "npx", arguments: ["fixture-server"]))
            }
            let model = AppModel()
            let view = NSHostingView(rootView: ScrollView {
                ConnectorsSection(model: model, store: store).padding(20)
            })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            let start = Date()
            window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
            // Let SwiftUI finish its first layout transaction without showing the audit window.
            try? await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            func buttonCount(_ view: NSView) -> Int {
                (view is NSButton ? 1 : 0) + view.subviews.reduce(0) { $0 + buttonCount($1) }
            }
            let buttons = buttonCount(view)
            audit.check("100 connections mount visible controls without creating all 300 agent checkboxes", buttons > 0 && buttons < 100, "\(buttons) native buttons")
            audit.check("connection list layout stays below the watchdog deadline", Date().timeIntervalSince(start) < 6)
            window.contentView = nil
            model.shutdown()
        }
    }

    static func run(_ audit: Auditor) async {
        await connectionLayout(audit)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orrery-connectors-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); ConnectorSnapshot.install(.empty) }
        let secrets = ConnectorSecretStore.memory()

        audit.section("Connectors — secrets stay in the Keychain, never in the file")
        let store = ConnectorStore(directory: root.appendingPathComponent("store"), secrets: secrets)
        audit.check("a fresh store is empty", store.connectors.isEmpty)
        let github = Connector(name: "github", command: "npx", arguments: ["-y", "@modelcontextprotocol/server-github"],
                               environment: ["HOST": "api.github.com"], secretKeys: ["GITHUB_PERSONAL_ACCESS_TOKEN"])
        store.upsert(github, secretValues: ["GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_audit_secret_value"])
        let saved = (try? String(contentsOf: store.fileURL, encoding: .utf8)) ?? ""
        audit.check("the connector is written", saved.contains("\"github\"") && saved.contains("GITHUB_PERSONAL_ACCESS_TOKEN"))
        audit.check("the secret value is not in the file", !saved.contains("ghp_audit_secret_value"))
        let mode = (try? FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int) ?? 0
        audit.check("the file is owner-only", mode & 0o777 == 0o600, String(mode, radix: 8))
        let config = store.serverConfig(store.connectors[0])
        let env = config["env"] as? [String: String] ?? [:]
        audit.check("a session gets the secret resolved with the plain environment", env["GITHUB_PERSONAL_ACCESS_TOKEN"] == "ghp_audit_secret_value" && env["HOST"] == "api.github.com" && config["command"] as? String == "npx")
        audit.check("the store knows the secret is present", store.hasSecret(github.id, key: "GITHUB_PERSONAL_ACCESS_TOKEN"))
        var edited = store.connectors[0]
        edited.environment["GITHUB_PERSONAL_ACCESS_TOKEN"] = "pasted-into-the-plain-box"
        store.upsert(edited)
        audit.check("a secret key pasted into the plain environment is dropped", (store.connectors[0].environment["GITHUB_PERSONAL_ACCESS_TOKEN"]) == nil)
        audit.check("an edit without a new value keeps the stored secret", (store.serverConfig(store.connectors[0])["env"] as? [String: String])?["GITHUB_PERSONAL_ACCESS_TOKEN"] == "ghp_audit_secret_value")
        let reloaded = ConnectorStore(directory: root.appendingPathComponent("store"), secrets: secrets)
        audit.check("a reload reads the same connector", reloaded.connectors.count == 1 && reloaded.connectors[0].name == "github" && reloaded.connectors[0].secretKeys == ["GITHUB_PERSONAL_ACCESS_TOKEN"])
        store.remove(github.id)
        audit.check("removing a connector removes its secret", store.connectors.isEmpty && !store.hasSecret(github.id, key: "GITHUB_PERSONAL_ACCESS_TOKEN"))

        audit.section("Connectors — names and transports are checked")
        audit.check("an empty name is refused", Connector(name: " ").problem != nil)
        audit.check("studio_computer is reserved", Connector(name: "studio_computer", command: "x").problem != nil)
        audit.check("odd characters are refused", Connector(name: "bad name!", command: "x").problem != nil)
        audit.check("a command connector needs a command", Connector(name: "a").problem != nil && Connector(name: "a", command: "npx").problem == nil)
        audit.check("a remote connector needs an http(s) URL", Connector(name: "r", transport: .http).problem != nil && Connector(name: "r", transport: .http, url: "ftp://x").problem != nil
                    && Connector(name: "r", transport: .sse, url: "https://example.com/sse").problem == nil)
        audit.check("credential-looking keys are recognised", ["GITHUB_PERSONAL_ACCESS_TOKEN", "WORKSPACE_MCP_API_KEY", "DB_PASSWORD", "CLIENT_SECRET", "AUTH_HEADER", "X-Api-Key", "KEY"].allSatisfy(Connector.looksSecret))
        audit.check("ordinary keys are not", !["HOST", "PORT", "CODEX_HOME", "NODE_ENV"].contains(where: Connector.looksSecret))

        audit.section("Connectors — opening Orrery never touches the Keychain")
        // Publishing the list must not read a single secret: with an ad-hoc rebuild the Keychain
        // would ask for the login password before the first window appeared.
        final class Counter: @unchecked Sendable { let lock = NSLock(); var reads = 0 }
        let counter = Counter()
        var counting = ConnectorSecretStore.memory()
        let inner = counting.read
        counting.read = { account in counter.lock.lock(); counter.reads += 1; counter.lock.unlock(); return inner(account) }
        let counted = ConnectorStore(directory: root.appendingPathComponent("counted"), secrets: counting)
        counted.upsert(Connector(name: "with-secret", command: "npx", arguments: ["x"], secretKeys: ["API_TOKEN"]), secretValues: ["API_TOKEN": "value-1"])
        counted.installSnapshot()
        let afterPublish = counter.reads
        audit.equal("publishing the list reads no secret", afterPublish, 0)
        let names = ConnectorSnapshot.shared.names(for: .claude)
        audit.check("the names are known without reading one", names == ["with-secret"] && counter.reads == afterPublish,
                    "\(names) after \(counter.reads) reads")
        let resolved = ConnectorSnapshot.shared.servers(for: .claude)["with-secret"] as? [String: Any]
        audit.check("a session starting reads it and gets the value", counter.reads > afterPublish
                    && (resolved?["env"] as? [String: String]) == ["API_TOKEN": "value-1"])
        let afterFirstSession = counter.reads
        _ = ConnectorSnapshot.shared.servers(for: .claude)
        _ = ConnectorSnapshot.shared.servers(for: .codex)
        audit.equal("later sessions reuse what was read, so the Keychain asks once per launch", counter.reads, afterFirstSession)
        counted.upsert(Connector(id: "second", name: "another", command: "npx", secretKeys: ["API_TOKEN"]), secretValues: ["API_TOKEN": "value-2"])
        let afterChange = counter.reads
        _ = ConnectorSnapshot.shared.servers(for: .claude)
        audit.check("a changed list is read again", counter.reads > afterChange
                    && ((ConnectorSnapshot.shared.servers(for: .claude)["another"] as? [String: Any])?["env"] as? [String: String]) == ["API_TOKEN": "value-2"])
        let beforeReopen = counter.reads
        let loaded = ConnectorStore(directory: root.appendingPathComponent("counted"), secrets: counting)
        audit.equal("reopening the list reads no secret either", counter.reads, beforeReopen)
        audit.equal("…and still knows the connectors", loaded.connectors.map(\.name).sorted(), ["another", "with-secret"])
        // A Keychain question must never hold the app still: the read is given a deadline, and a
        // session that hits it starts without that secret instead of freezing.
        let slow = ConnectorStore(directory: root.appendingPathComponent("slow"), secrets: ConnectorSecretStore(
            read: { _ in Thread.sleep(forTimeInterval: 1.0); return "eventually" }, write: { _, _ in }, delete: { _ in }))
        slow.upsert(Connector(id: "slow-one", name: "slow", command: "npx", secretKeys: ["API_TOKEN"]))
        ConnectorSnapshot.secretDeadline = 0.2
        let started = Date()
        let slowServers = ConnectorSnapshot.shared.servers(for: .claude)
        let waited = Date().timeIntervalSince(started)
        audit.check("a secret that keeps the app waiting is given up on", waited < 0.9, "waited \(String(format: "%.2f", waited))s")
        audit.check("…and the session starts without launching a connector with missing credentials", slowServers["slow"] == nil)
        let retryStart = Date()
        _ = ConnectorSnapshot.shared.servers(for: .grok)
        audit.check("an in-flight credential read is not duplicated or waited on by another agent", Date().timeIntervalSince(retryStart) < 0.1)
        try? await Task.sleep(for: .milliseconds(1100))
        ConnectorSnapshot.secretDeadline = 5
        audit.check("…and the value is not remembered as missing, so the next session gets it",
                    ((ConnectorSnapshot.shared.servers(for: .claude)["slow"] as? [String: Any])?["env"] as? [String: String]) == ["API_TOKEN": "eventually"])
        ConnectorSnapshot.secretDeadline = 3
        counted.installSnapshot()

        let missingReads = Counter()
        let missingStore = ConnectorSecretStore(read: { _ in
            missingReads.lock.lock(); missingReads.reads += 1; missingReads.lock.unlock(); return nil
        }, write: { _, _ in }, delete: { _ in })
        let missingConnector = Connector(name: "locked", command: "npx", secretKeys: ["API_TOKEN"])
        let missingSnapshot = ConnectorSnapshot(byProvider: [.grok: [missingConnector], .claude: [missingConnector]], secrets: missingStore)
        _ = missingSnapshot.servers(for: .grok); _ = missingSnapshot.servers(for: .claude)
        audit.check("a locked or missing credential is read once across agent launches, including nil results", missingReads.reads == 1)
        let failing = ConnectorStore(directory: root.appendingPathComponent("failed-keychain"), secrets: ConnectorSecretStore(
            read: { _ in nil }, write: { _, _ in throw ComputerError("locked") }, delete: { _ in }))
        audit.check("a Keychain write failure is reported without saving a broken connector", !failing.upsert(missingConnector, secretValues: ["API_TOKEN": "secret"]) && failing.connectors.isEmpty && failing.lastError != nil)
        let header = Connector(name: "remote-secret", transport: .http, url: "https://example.com/mcp", secretKeys: ["Authorization"], headers: ["Authorization": "must-not-be-persisted"])
        counted.upsert(header, secretValues: ["Authorization": "Bearer protected"])
        let disk = (try? String(contentsOf: counted.fileURL)) ?? ""
        audit.check("secret HTTP headers cannot leak into the saved connector JSON", !disk.contains("must-not-be-persisted") && !disk.contains("Bearer protected"))
        let pasted = try? ConnectorImport.pasted("{\"mcpServers\":{\"service\":{\"url\":\"https://example.com/mcp\",\"headers\":{\"Authorization\":\"Bearer pasted-secret\"}}}}")
        audit.check("paste setup separates credentials and defaults to all agents", pasted?.first?.0.headers.isEmpty == true && pasted?.first?.1["Authorization"] == "Bearer pasted-secret" && pasted?.first?.0.providers == Set(Provider.allCases))
        audit.check("paste setup rejects invalid argument types without silently dropping a server", (try? ConnectorImport.pasted("{\"broken\":{\"command\":\"npx\",\"args\":\"oops\"}}")) == nil)
        let secretServers: [String: Any] = ["private": ["command": "node", "env": ["API_TOKEN": "launch-canary"]], "remote": ["url": "https://example.com/mcp", "headers": ["Authorization": "Bearer header-canary"]]]
        var claudeEnvironment: [String: String] = [:]
        let protectedArgs = MCPLaunchCredentials.claude(arguments: ["--mcp-config", JSON(["mcpServers": secretServers]).compact], environment: &claudeEnvironment)
        audit.check("Claude launch arguments contain references rather than credential values", !protectedArgs.joined().contains("launch-canary") && !protectedArgs.joined().contains("header-canary") && Set(claudeEnvironment.values) == Set(["launch-canary", "Bearer header-canary"]))
        var codexEnvironment: [String: String] = [:]
        let codexProtected = try? MCPLaunchCredentials.codexNative(secretServers, environment: &codexEnvironment)
        audit.check("Codex native launch config keeps credentials in the child environment", codexProtected != nil && !JSON(codexProtected).compact.contains("canary") && codexEnvironment["API_TOKEN"] == "launch-canary" && codexEnvironment.values.contains("Bearer header-canary"))
        audit.check("Codex HTTP connections use the provider's http_headers key", (MCPLaunchCredentials.codexServers(secretServers)["remote"] as? [String: Any])?["http_headers"] != nil)
        var conflicting = ["API_TOKEN": "different"]
        audit.check("conflicting native connector environments fail before launching with the wrong credential", (try? MCPLaunchCredentials.codexNative(secretServers, environment: &conflicting)) == nil)

        audit.check("a secret that cannot be read is left out rather than sent empty",
                    (Connector(name: "x", command: "c", secretKeys: ["K"]).serverConfig { _ in nil }["env"] as? [String: String]) == nil)

        audit.section("Connectors — every agent gets them, filtered per agent")
        let shared = Connector(name: "shared", command: "uvx", arguments: ["mcp-server-fetch"], environment: ["A": "1"], secretKeys: ["API_TOKEN"])
        let codexOnly = Connector(name: "codex-only", command: "/Applications/ChatGPT.app/x", providers: [.codex])
        let off = Connector(name: "off", command: "x", enabled: false)
        let remote = Connector(name: "docs", transport: .http, url: "https://docs.mcp.cloudflare.com/mcp", secretKeys: ["Authorization"], headers: ["X-Client": "orrery"])
        store.upsert(shared, secretValues: ["API_TOKEN": "tok-123"])
        store.upsert(codexOnly); store.upsert(off)
        store.upsert(remote, secretValues: ["Authorization": "Bearer abc"])
        let forClaude = ConnectorSnapshot.shared.servers(for: .claude)
        let forCodex = ConnectorSnapshot.shared.servers(for: .codex)
        audit.equal("Claude gets the shared ones only", forClaude.keys.sorted(), ["docs", "shared"])
        audit.equal("Codex gets its own one too", forCodex.keys.sorted(), ["codex-only", "docs", "shared"])
        audit.check("a disabled connector reaches nobody", ConnectorSnapshot.shared.servers(for: .grok)["off"] == nil)
        audit.check("settings not bound to a provider add nothing", ConnectorSnapshot.shared.servers(for: nil).isEmpty)
        var settings = AgentSessionSettings()
        audit.check("plain settings carry no connectors", settings.mcpServers.isEmpty)
        settings.connectorProvider = .claude
        let sharedServer = settings.mcpServers["shared"] as? [String: Any]
        audit.check("bound settings carry the connector with its secret resolved", (sharedServer?["env"] as? [String: String]) == ["A": "1", "API_TOKEN": "tok-123"])
        audit.check("Claude receives it in --mcp-config", settings.claudeArguments(adding: nil).joined(separator: " ").contains("\"shared\":{") && settings.claudeArguments(adding: nil).contains("--mcp-config"))
        let docsServer = settings.mcpServers["docs"] as? [String: Any]
        audit.check("a remote connector carries type, url and headers", docsServer?["type"] as? String == "http" && docsServer?["url"] as? String == "https://docs.mcp.cloudflare.com/mcp"
                    && (docsServer?["headers"] as? [String: String]) == ["X-Client": "orrery", "Authorization": "Bearer abc"])
        settings.connectorProvider = .codex
        let codexServers = settings.codexConfiguration["mcp_servers"] as? [String: Any]
        audit.equal("Codex receives them under mcp_servers", codexServers?.keys.sorted() ?? [], ["codex-only", "docs", "shared"])
        settings.connectorProvider = .grok
        let acp = settings.acpMCPServers
        audit.check("Grok receives them as ACP servers with env pairs", acp.count == 2 && acp.contains { server in
            server["name"] as? String == "shared" && (server["env"] as? [[String: String]])?.contains { $0["name"] == "API_TOKEN" && $0["value"] == "tok-123" } == true })
        settings.connectorProvider = .claude
        settings.mcpConfiguration = #"{"shared": {"command": "explicit-wins"}}"#
        audit.check("this project's explicit list still wins by name", (settings.mcpServers["shared"] as? [String: Any])?["command"] as? String == "explicit-wins")
        settings.mcpConfiguration = ""
        let previousPlugins = PluginSnapshot.shared
        PluginSnapshot.install(PluginSnapshot(commands: [], saveHooks: [], mcpServers: ["shared": ["command": "plugin"], "plugin-only": ["command": "p"]]))
        audit.check("a connector wins over a plugin server of the same name, other plugin servers stay",
                    (settings.mcpServers["shared"] as? [String: Any])?["command"] as? String == "uvx" && settings.mcpServers["plugin-only"] != nil)
        PluginSnapshot.install(previousPlugins)
        store.setProviders([.grok], id: shared.id)
        audit.check("changing a connector's agents takes effect at once", ConnectorSnapshot.shared.servers(for: .claude)["shared"] == nil && ConnectorSnapshot.shared.servers(for: .grok)["shared"] != nil)
        store.setEnabled(false, id: remote.id)
        audit.check("switching a connector off takes effect at once", ConnectorSnapshot.shared.servers(for: .claude)["docs"] == nil)

        audit.section("Connectors — import reads the CLIs' own configs")
        let toml = """
        model = "gpt-6"

        [mcp_servers.workspace-tools]
        command = "node"
        args = ["/Users/someone/workspace-tools/mcp.js", "--stdio"]

        [mcp_servers.workspace-tools.env]
        WORKSPACE_MCP_API_KEY = "workspace-tools-secret-123"
        WORKSPACE_URL = "http://127.0.0.1:9000"

        [mcp_servers.node_repl]
        command = "/Applications/ChatGPT.app/Contents/Resources/node"
        args = ["repl.js"]
        startup_timeout_sec = 30

        [mcp_servers.node_repl.env]
        CODEX_HOME = "/Users/someone/.codex"

        [mcp_servers.computer-use]
        command = "./computer-use"
        args = []
        cwd = "/tmp"
        enabled = false

        [mcp_servers.cloudflare-docs]
        url = "https://docs.mcp.cloudflare.com/mcp"

        [mcp_servers.cloudflare]
        url = "https://mcp.cloudflare.com/mcp"
        """
        let tables = TOMLTables.parse(toml)
        audit.check("the TOML reader sees tables, strings, arrays, numbers and booleans",
                    tables[["mcp_servers", "workspace-tools"]]?["args"] as? [String] == ["/Users/someone/workspace-tools/mcp.js", "--stdio"]
                    && tables[["mcp_servers", "node_repl"]]?["startup_timeout_sec"] as? Int == 30
                    && tables[["mcp_servers", "computer-use"]]?["enabled"] as? Bool == false
                    && tables[[]]?["model"] as? String == "gpt-6")
        let codex = ConnectorImport.fromCodex(toml)
        let byName = Dictionary(uniqueKeysWithValues: codex.map { ($0.0.name, $0) })
        audit.equal("Codex servers are imported, the disabled one skipped", byName.keys.sorted(), ["cloudflare", "cloudflare-docs", "node_repl", "workspace-tools"])
        audit.check("the API key goes to the secret list, the plain value stays", byName["workspace-tools"]?.0.secretKeys == ["WORKSPACE_MCP_API_KEY"] && byName["workspace-tools"]?.1["WORKSPACE_MCP_API_KEY"] == "workspace-tools-secret-123"
                    && byName["workspace-tools"]?.0.environment == ["WORKSPACE_URL": "http://127.0.0.1:9000"])
        audit.check("an imported command connector keeps its command and arguments",
                    byName["workspace-tools"]?.0.command == "node" && byName["workspace-tools"]?.0.arguments == ["/Users/someone/workspace-tools/mcp.js", "--stdio"])
        audit.check("a shared server is offered to every agent", byName["workspace-tools"]?.0.providers == Set(Provider.allCases) && byName["cloudflare-docs"]?.0.providers == Set(Provider.allCases))
        audit.check("url servers become http connectors", byName["cloudflare-docs"]?.0.transport == .http && byName["cloudflare-docs"]?.0.url == "https://docs.mcp.cloudflare.com/mcp")
        audit.check("a server that belongs to the Codex app stays Codex-only", byName["node_repl"]?.0.providers == [.codex] && byName["node_repl"]?.0.note.contains("Codex only") == true)
        let claudeJSON = JSON([
            "mcpServers": ["memory": ["command": "npx", "args": ["-y", "@modelcontextprotocol/server-memory"]],
                           "linear": ["type": "sse", "url": "https://mcp.linear.app/sse", "headers": ["Authorization": "Bearer lin-1"]]],
            "projects": [root.path: ["mcpServers": ["local-tool": ["command": "./tool"]]],
                         "/somewhere/else": ["mcpServers": ["other-project": ["command": "x"]]]],
        ])
        let claude = ConnectorImport.fromClaude(claudeJSON, project: root)
        let claudeByName = Dictionary(uniqueKeysWithValues: claude.map { ($0.0.name, $0) })
        audit.equal("Claude Code's user servers and this project's are imported, other projects' are not", claudeByName.keys.sorted(), ["linear", "local-tool", "memory"])
        audit.check("an SSE server with a bearer header keeps the header secret", claudeByName["linear"]?.0.transport == .sse && claudeByName["linear"]?.0.secretKeys == ["Authorization"] && claudeByName["linear"]?.1["Authorization"] == "Bearer lin-1" && claudeByName["linear"]?.0.headers.isEmpty == true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try? claudeJSON.compact.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try? toml.write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        try? #"{"mcpServers": {"project-mcp": {"command": "npx", "args": ["x"]}}}"#.write(to: root.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        let fresh = ConnectorStore(directory: root.appendingPathComponent("import"), secrets: ConnectorSecretStore.memory())
        let report = fresh.importFromCLIs(project: root, home: home)
        audit.check("import reports what it added", report.contains("Imported 8 connectors"), report)
        audit.equal("everything from both CLIs and the project's .mcp.json is in the store", fresh.connectors.map(\.name).sorted(), ["cloudflare", "cloudflare-docs", "linear", "local-tool", "memory", "node_repl", "project-mcp", "workspace-tools"])
        let workspaceTools = fresh.connectors.first { $0.name == "workspace-tools" }!
        audit.check("the imported key is in the secret store and resolved for sessions", fresh.hasSecret(workspaceTools.id, key: "WORKSPACE_MCP_API_KEY") && (fresh.serverConfig(workspaceTools)["env"] as? [String: String])?["WORKSPACE_MCP_API_KEY"] == "workspace-tools-secret-123")
        let onDisk = (try? String(contentsOf: fresh.fileURL, encoding: .utf8)) ?? ""
        audit.check("imported secrets are not written to the connectors file", !onDisk.contains("workspace-tools-secret-123") && !onDisk.contains("lin-1"))
        fresh.setProviders([.codex], id: workspaceTools.id)
        fresh.setEnabled(false, id: workspaceTools.id)
        let again = fresh.importFromCLIs(project: root, home: home)
        audit.check("importing again refreshes instead of duplicating", again.contains("refreshed 8") && fresh.connectors.count == 8, again)
        let workspaceToolsAgain = fresh.connectors.first { $0.name == "workspace-tools" }!
        audit.check("a refresh keeps your agent choice and on/off switch", workspaceToolsAgain.providers == [.codex] && !workspaceToolsAgain.enabled && workspaceToolsAgain.id == workspaceTools.id)
        let empty = ConnectorStore(directory: root.appendingPathComponent("empty"), secrets: ConnectorSecretStore.memory())
        audit.check("import with nothing to read says so", empty.importFromCLIs(project: nil, home: root.appendingPathComponent("nohome")).hasPrefix("Nothing to import"))
        audit.check("the catalog entries are valid connectors", !ConnectorImport.catalog.isEmpty && ConnectorImport.catalog.allSatisfy { $0.connector.problem == nil })

        audit.section("Connectors — the CLI panes get them too")
        // The checks above left `shared` on Grok only and `docs` switched off; put them back so
        // this section reads a normal, everything-on list.
        store.setProviders(Set(Provider.allCases), id: shared.id)
        store.setEnabled(true, id: remote.id)
        var native = AgentSessionSettings()
        native.connectorProvider = .claude
        let claudeNative = native.nativeArguments(for: .claude, autoApprove: false)
        audit.check("the Claude CLI pane is launched with the connectors",
                    claudeNative.contains("--mcp-config") && claudeNative.joined(separator: " ").contains("\"shared\":{"),
                    claudeNative.joined(separator: " "))
        native.connectorProvider = .codex
        let codexNative = native.nativeArguments(for: .codex, autoApprove: false)
        let mcpArgument = codexNative.enumerated().first { $0.element.hasPrefix("mcp_servers=") }?.element ?? ""
        audit.check("the Codex CLI pane is launched with the connectors as inline TOML",
                    codexNative.contains("-c") && mcpArgument.contains("\"shared\" = {") && mcpArgument.contains("\"command\" = \"uvx\"")
                    && mcpArgument.contains("[\"mcp-server-fetch\"]") && mcpArgument.contains("\"API_TOKEN\" = \"tok-123\""), mcpArgument)
        native.connectorProvider = .grok
        audit.check("the Grok CLI pane takes no MCP arguments, as before", !native.nativeArguments(for: .grok, autoApprove: false).contains("--mcp-config"))

        audit.section("Connectors — the app binds every session to its agent")
        let app = AppModel(trust: .forAudit)
        for provider in Provider.allCases {
            audit.check("\(provider.displayName) settings are stamped with their agent", app.sessionSettings(for: provider).connectorProvider == provider)
            audit.check("a \(provider.displayName) chat backend carries the stamp", app.configuredBackend(provider).sessionSettings.connectorProvider == provider)
            audit.check("a \(provider.displayName) Team backend carries the stamp", app.configuredBackend(provider, forTeam: true).sessionSettings.connectorProvider == provider)
            audit.check("a \(provider.displayName) one-shot backend carries the stamp", app.makeOneShotBackend(provider).sessionSettings.connectorProvider == provider)
        }
        audit.check("the stamp is not saved with the project's settings",
                    !(String(data: (try? JSONEncoder().encode(app.sessionSettings(for: .claude))) ?? Data(), encoding: .utf8) ?? "").contains("connectorProvider"))
    }
}

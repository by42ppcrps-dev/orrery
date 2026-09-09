import Foundation

/// Accounts: each provider signs in either through its own CLI (subscription) or with an API
/// key that lives in the Keychain and reaches only that provider's processes; the usage record
/// is local, owner-only, bounded, and survives a restart. Audits use an in-memory key store and
/// a private preferences suite so they never touch the user's Keychain or defaults.
@MainActor
enum AuditAccounts {
    static func run(_ audit: Auditor) async {
        audit.section("Accounts — subscription sign-in or API credits, keys only in the Keychain")
        let suiteName = "app.orrery.studio.audit-accounts-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = KeychainStore.memory()
        let accounts = ProviderAccounts(store: store, preferences: suite)
        for provider in Provider.allCases {
            audit.equal("\(provider.displayName) starts in subscription mode", accounts.mode(for: provider), .subscription)
            audit.check("\(provider.displayName) has no stored key at first", !accounts.hasKey(for: provider))
            audit.check("\(provider.displayName) children get no key in subscription mode", accounts.childEnvironment(for: provider).isEmpty)
        }
        audit.equal("Grok's key variable is XAI_API_KEY", ProviderAccounts.environmentVariable(for: .grok), "XAI_API_KEY")
        audit.equal("Claude's key variable is ANTHROPIC_API_KEY", ProviderAccounts.environmentVariable(for: .claude), "ANTHROPIC_API_KEY")
        audit.equal("Codex's key variable is OPENAI_API_KEY", ProviderAccounts.environmentVariable(for: .codex), "OPENAI_API_KEY")
        audit.equal("Claude signs in with `claude auth login`", ProviderAccounts.loginArguments(for: .claude), ["auth", "login"])
        audit.equal("Codex signs in with `codex login`", ProviderAccounts.loginArguments(for: .codex), ["login"])
        audit.equal("Grok signs in with `grok login`", ProviderAccounts.loginArguments(for: .grok), ["login"])
        let model = AppModel(trust: .forAudit)
        defer { model.shutdown() }
        model.presetNativeCLI(ProviderAccounts.loginArguments(for: .claude), for: .claude)
        audit.equal("Sign In with the CLI presets one argument per line, as the CLI pane parses them", model.nativeArguments[.claude], "auth\nlogin")
        audit.equal("…which the pane splits into the two words `auth` `login`, not one argument",
                    (model.nativeArguments[.claude] ?? "").components(separatedBy: .newlines).filter { !$0.isEmpty }, ["auth", "login"])
        audit.check("…and shows the CLI pane for that provider without launching", model.assistantMode == .cli && model.provider == .claude && model.nativeSessions.isEmpty)

        for bad in ["", "   ", "sk-ant\nsecond line", "sk ant space", "sk\tant", String(repeating: "k", count: ProviderAccounts.keyByteLimit + 1)] {
            var refused = false
            do { try accounts.storeKey(bad, for: .claude) } catch { refused = true }
            audit.check("a malformed key (\(bad.debugDescription.prefix(24))…) is refused before it reaches the store", refused && !accounts.hasKey(for: .claude))
        }
        do {
            try accounts.storeKey("  sk-ant-audit-0123456789  ", for: .claude)
            audit.check("a valid key is stored", accounts.hasKey(for: .claude))
            audit.equal("the stored key is trimmed", store.read(.claude), "sk-ant-audit-0123456789")
            audit.check("a stored key stays out of the environment until API credits are chosen", accounts.childEnvironment(for: .claude).isEmpty)
            accounts.setMode(.apiKey, for: .claude)
            audit.equal("API-credit mode hands Claude's children exactly its own variable",
                        accounts.childEnvironment(for: .claude), ["ANTHROPIC_API_KEY": "sk-ant-audit-0123456789"])
            audit.check("Codex children never see Claude's key", accounts.childEnvironment(for: .codex).isEmpty)
            audit.check("Grok children never see Claude's key", accounts.childEnvironment(for: .grok).isEmpty)
            accounts.setMode(.apiKey, for: .codex)
            audit.check("API-credit mode without a stored key sends nothing", accounts.childEnvironment(for: .codex).isEmpty)
            let reloaded = ProviderAccounts(store: store, preferences: suite)
            audit.equal("the mode choice persists in preferences", reloaded.mode(for: .claude), .apiKey)
            audit.check("a fresh instance sees the key's presence without reading it", reloaded.hasKey(for: .claude))
            let inherited = AgentEnvironment.sanitized(["ANTHROPIC_API_KEY": "from-the-shell", "HOME": "/tmp/h"])
            audit.check("the sanitizer still strips a key inherited from the shell", inherited["ANTHROPIC_API_KEY"] == nil)
            let merged = inherited.merging(accounts.childEnvironment(for: .claude)) { _, new in new }
            audit.equal("the account key is merged after sanitizing, so it survives", merged["ANTHROPIC_API_KEY"], "sk-ant-audit-0123456789")
            try accounts.removeKey(for: .claude)
            audit.check("removing the key clears presence and the environment", !accounts.hasKey(for: .claude) && accounts.childEnvironment(for: .claude).isEmpty)
            try accounts.removeKey(for: .claude)
            audit.check("removing an absent key is not an error", true)
        } catch { audit.check("key round trip", false, "\(error)") }
        audit.check("headless runs keep the shared accounts out of the user's Keychain (nothing stored, nothing injected)",
                    !AppModel.persistsPreferences && Provider.allCases.allSatisfy { ProviderAccounts.shared.childEnvironment(for: $0).isEmpty })

        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orrery-audit-home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        audit.check("Grok reports not signed in without ~/.grok/auth.json", ProviderAccounts.subscriptionStatus(for: .grok, home: home).hasPrefix("Not signed in"))
        audit.check("Codex reports not signed in without ~/.codex/auth.json", ProviderAccounts.subscriptionStatus(for: .codex, home: home).hasPrefix("Not signed in"))
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".grok"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try? "{}".write(to: home.appendingPathComponent(".grok/auth.json"), atomically: true, encoding: .utf8)
        try? "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"never-read\"}}".write(to: home.appendingPathComponent(".codex/auth.json"), atomically: true, encoding: .utf8)
        try? "{}".write(to: home.appendingPathComponent(".claude/.credentials.json"), atomically: true, encoding: .utf8)
        audit.check("Grok reports signed in by file presence", ProviderAccounts.subscriptionStatus(for: .grok, home: home).hasPrefix("Signed in"))
        let codex = ProviderAccounts.subscriptionStatus(for: .codex, home: home)
        audit.check("Codex reports its ChatGPT sign-in mode without echoing tokens", codex.contains("ChatGPT") && !codex.contains("never-read"), codex)
        audit.check("Claude reports a credentials file when one exists", ProviderAccounts.subscriptionStatus(for: .claude, home: home).hasPrefix("Signed in"))

        audit.section("Accounts — the usage record is local, bounded and survives a restart")
        let ledgerDir = home.appendingPathComponent("Usage")
        let ledgerURL = ledgerDir.appendingPathComponent("usage.json")
        let ledger = UsageLedger(fileURL: ledgerURL)
        audit.equal("an unused provider reads as unused", ledger.summary(for: .grok), "No turns recorded yet.")
        ledger.record(turn: .claude, costUSD: 0.0125)
        ledger.record(turn: .claude, costUSD: 0.0075)
        ledger.record(turn: .claude, costUSD: nil)
        ledger.record(quota: .codex, text: "Codex usage: 5-hour window 100% used, resets 2026-09-10 21:36")
        let summary = ledger.summary(for: .claude)
        audit.check("the summary totals turns, cost and unpriced turns", summary.contains("Today $0.0200") && summary.contains("3 turns") && summary.contains("1 reported no cost"), summary)
        audit.equal("turns land in today's bucket", ledger.usage[.claude]?.days.count, 1)
        ledger.record(turn: .codex, costUSD: 0.5)
        audit.check("a single turn is not pluralized", ledger.summary(for: .codex).contains("over 1 turn ") || ledger.summary(for: .codex).hasSuffix("over 1 turn"), ledger.summary(for: .codex))
        audit.check("the last quota message is kept for the provider that sent it", ledger.usage[.codex]?.lastQuota?.contains("100% used") == true && ledger.usage[.claude]?.lastQuota == nil)
        audit.check("the record saves", ledger.saveNow())
        let mode = (try? FileManager.default.attributesOfItem(atPath: ledgerURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        audit.equal("the record file is owner-only", mode & 0o777, 0o600)
        let dirMode = (try? FileManager.default.attributesOfItem(atPath: ledgerDir.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        audit.equal("the record directory is owner-only", dirMode & 0o777, 0o700)
        let text = (try? String(contentsOf: ledgerURL, encoding: .utf8)) ?? ""
        audit.check("the record holds counts and costs only, no prompts or keys", text.contains("\"turns\"") && !text.contains("sk-") && !text.contains("prompt"))
        let reloaded = UsageLedger(fileURL: ledgerURL)
        audit.equal("a restart reads the same totals back", reloaded.usage, ledger.usage)
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        for offset in 0..<(UsageLedger.dayLimit + 10) {
            reloaded.record(turn: .grok, costUSD: nil, on: calendar.date(byAdding: .day, value: -offset, to: Date())!)
        }
        audit.equal("day buckets are capped", reloaded.usage[.grok]?.days.count, UsageLedger.dayLimit)
        audit.equal("capping keeps the totals", reloaded.usage[.grok]?.turns, UsageLedger.dayLimit + 10)
        try? "not json".write(to: ledgerURL, atomically: true, encoding: .utf8)
        let broken = UsageLedger(fileURL: ledgerURL)
        audit.check("a corrupt record is reported, not trusted", broken.usage.isEmpty && broken.lastError?.contains("could not be read") == true)
        let missing = UsageLedger(fileURL: home.appendingPathComponent("nothing/usage.json"))
        audit.check("a missing record is simply empty", missing.usage.isEmpty && missing.lastError == nil)
        audit.check("headless runs keep the shared record in a temporary file",
                    !AppModel.persistsPreferences && UsageLedger.shared.fileURL.path.hasPrefix(NSTemporaryDirectory()))

        audit.section("Accounts — the CLI sign-in launch is not decorated with tool-server flags")
        let claudeConnection = ComputerConnection(socketPath: "/tmp/orrery-audit.sock", token: "audit-token", provider: .claude)
        let codexConnection = ComputerConnection(socketPath: "/tmp/orrery-audit.sock", token: "audit-token", provider: .codex)
        audit.equal("claude auth login is launched exactly as typed",
                    NativeLaunch.arguments(provider: .claude, explicit: ["auth", "login"], defaults: ["--permission-mode", "default"], mcpServers: [:], connection: claudeConnection), ["auth", "login"])
        let interactive = NativeLaunch.arguments(provider: .claude, explicit: [], defaults: ["--permission-mode", "default"], mcpServers: ["other": ["command": "x"]], connection: claudeConnection)
        audit.check("an interactive Claude launch gets the studio tool server beside the configured servers",
                    interactive.contains("--mcp-config") && (interactive.last ?? "").contains("studio_computer") && (interactive.last ?? "").contains("\"other\""), interactive.joined(separator: " "))
        let flags = NativeLaunch.arguments(provider: .claude, explicit: ["--resume", "abc"], defaults: [], mcpServers: [:], connection: claudeConnection)
        audit.check("flag-only launch options keep the tool server", Array(flags.prefix(2)) == ["--resume", "abc"] && flags.contains("--mcp-config"), flags.joined(separator: " "))
        audit.equal("codex login is launched exactly as typed",
                    NativeLaunch.arguments(provider: .codex, explicit: ["login"], defaults: [], mcpServers: [:], connection: codexConnection), ["login"])
        audit.check("an interactive Codex launch gets the studio tool server",
                    NativeLaunch.arguments(provider: .codex, explicit: [], defaults: ["--full-auto"], mcpServers: [:], connection: codexConnection).contains { $0.hasPrefix("mcp_servers.studio_computer.command=") })
        audit.equal("without a tool server the defaults are launched as they are",
                    NativeLaunch.arguments(provider: .claude, explicit: [], defaults: ["--permission-mode", "default"], mcpServers: [:], connection: nil), ["--permission-mode", "default"])
        audit.equal("the sign-in launch runs outside the write confinement (it needs the browser and the credential store)",
                    NativeLaunch.executionPolicy(configured: .confinedWrites, explicit: ["auth", "login"]), .fullAccess)
        audit.equal("logout runs outside the write confinement too", NativeLaunch.executionPolicy(configured: .confinedWrites, explicit: ["logout"]), .fullAccess)
        audit.equal("an interactive launch keeps the configured confinement", NativeLaunch.executionPolicy(configured: .confinedWrites, explicit: []), .confinedWrites)
        audit.equal("a resumed interactive launch keeps the configured confinement", NativeLaunch.executionPolicy(configured: .confinedWrites, explicit: ["--resume", "abc"]), .confinedWrites)
        audit.equal("other subcommands keep the configured confinement", NativeLaunch.executionPolicy(configured: .confinedWrites, explicit: ["update"]), .confinedWrites)

        audit.section("Accounts — every child launcher and both turn paths are wired")
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/" && !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) { root.deleteLastPathComponent() }
        func source(_ path: String) -> String { (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "" }
        for (path, provider) in [("Sources/Orrery/Backends/ClaudeBackend.swift", ".claude"), ("Sources/Orrery/Backends/CodexBackend.swift", ".codex"),
                                 ("Sources/Orrery/Backends/GrokBackend.swift", ".grok"), ("Sources/Orrery/Views/NativeAgentView.swift", "provider")] {
            audit.check("\(path.split(separator: "/").last ?? "") merges the account key for \(provider)",
                        source(path).contains("ProviderAccounts.shared.childEnvironment(for: \(provider))"))
        }
        audit.check("Solo turns record usage", source("Sources/Orrery/AppModel.swift").contains("UsageLedger.shared.record(turn: source, costUSD: cost)"))
        audit.check("Team turns record usage", source("Sources/Orrery/Orchestrator/Orchestrator.swift").contains("UsageLedger.shared.record(turn: provider, costUSD: cost)"))
        let sheet = source("Sources/Orrery/Views/AgentSettingsSheet.swift")
        audit.check("the settings sheet has an Account tab with a SecureField and a CLI sign-in button",
                    sheet.contains("\"Account\"") && sheet.contains("SecureField(\"Paste an API key\"") && sheet.contains("Sign In with the CLI…"))
        audit.check("the sheet never shows or logs the key", !sheet.contains("print(apiKeyDraft") && !sheet.contains("Text(apiKeyDraft"))

        audit.section("Accounts — an expired login is flagged with a one-click sign-in, not a red line")
        audit.check("the CLIs' sign-out messages are recognized",
                    ["Failed to authenticate. API Error: 401 OAuth access token has expired. Re-authenticate to continue.",
                     "Not logged in · Please run /login", "OAuth session expired and could not be refreshed",
                     "Request failed: unauthorized", "Invalid API key provided"].allSatisfy(AppModel.looksLikeAuthFailure))
        audit.check("ordinary failures are not taken for sign-outs",
                    !AppModel.looksLikeAuthFailure("quota exhausted") && !AppModel.looksLikeAuthFailure("Turn failed: the agent went silent") && !AppModel.looksLikeAuthFailure("Could not switch model"))
        await Auditor.withTemporaryDirectory { dir in
            let model = AppModel(trust: .forAudit)
            defer { model.shutdown() }
            model.installed = [.grok: true, .claude: true, .codex: true]
            model.openProject(dir)
            model.provider = .claude
            model.handle(.connected(sessionID: "real-session"), from: .claude)
            model.update(.claude) { $0.sessionUsed = true }
            model.handle(.failure("Failed to authenticate. API Error: 401 OAuth access token has expired. Re-authenticate to continue."), from: .claude)
            model.handle(.turnFinished(stopReason: "stop_sequence", costUSD: nil), from: .claude)
            audit.equal("a 401 turn flags Claude as signed out", model.needsSignIn, [.claude])
            audit.check("…and forgets the session that answered 401, so no resume loop follows", model.states[.claude]?.sessionID == nil)
            model.handle(.failure("quota exhausted"), from: .codex)
            audit.check("an ordinary failure flags nothing", !model.needsSignIn.contains(.codex))
            model.handle(.note("The saved Grok session could not be resumed: not authenticated. Starting a new conversation."), from: .grok)
            audit.check("a failed resume with a sign-out reason flags that provider too", model.needsSignIn.contains(.grok))
            model.dismissSignIn(.grok)
            audit.check("Dismiss clears a flag", !model.needsSignIn.contains(.grok))
            model.signIn(.claude)
            audit.check("Sign In presets the provider's own login in the CLI pane and shows it",
                        model.nativeArguments[.claude] == "auth\nlogin" && model.assistantMode == .cli && model.provider == .claude)
            audit.check("the login runs outside the write confinement", NativeLaunch.executionPolicy(configured: .confinedWrites, explicit: ["auth", "login"]) == .fullAccess)
            model.handle(.assistantDelta("READY"), from: .claude)
            model.handle(.turnFinished(stopReason: "end_turn", costUSD: 0.01), from: .claude)
            audit.check("the next successful turn clears the flag", !model.needsSignIn.contains(.claude))
        }
        let pane = source("Sources/Orrery/Views/WorkspacePresentation.swift")
        audit.check("the assistant pane shows a sign-out banner with a Sign In button in every mode",
                    pane.contains("needsSignIn.contains") && pane.contains("Sign In with the CLI") && pane.contains("model.signIn(provider)"))
        let chat = source("Sources/Orrery/Views/ChatView.swift")
        audit.check("the approval switches sit on the page: the Solo status line is a menu with both toggles",
                    chat.contains("struct ApprovalMenu") && chat.contains("Bypass every approval, everywhere") && chat.contains("isOn: $model.blanketApproval"))
        audit.check("…and the Roundtable and Team panes carry them too",
                    source("Sources/Orrery/Views/RoundtableView.swift").contains("ApprovalMenu(model: model)") && source("Sources/Orrery/Views/OrchestratorView.swift").contains("ApprovalMenu(model: model)"))
    }
}

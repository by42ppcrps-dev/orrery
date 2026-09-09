import SwiftUI
import AppKit

struct AgentSettingsSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentSessionSettings
    @State private var error: String?
    @State private var verificationStatus: String?
    @State private var section = "Session"
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    @State private var accessibilityAllowed = AXIsProcessTrusted()
    @State private var apiKeyDraft = ""
    @State private var accountStatus: String?
    @State private var customModel = false
    @State private var unlocking = false
    @State private var showLegacyUnlock = false
    private let provider: Provider

    init(model: AppModel) {
        self.model = model
        provider = model.provider
        _draft = State(initialValue: model.agentSettings[model.provider] ?? AgentSessionSettings())
        if let requested = model.requestedSettingsSection { _section = State(initialValue: requested) }
    }
    private var busy: Bool {
        model.states.values.contains(where: \.isBusy) || model.orchestrator.isRunning || model.roundtable.isRunning
            || model.nativeSessions.values.contains(where: \.isRunning)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(section == "Connectors" ? "Connections & plugins" : "\(provider.displayName) settings").font(.title2.weight(.semibold))
                    Text(model.projectURL?.lastPathComponent ?? "Choose a project first")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Picker("Settings section", selection: $section) {
                ForEach(["Session", "Tools", "Advanced", "Computer", "Account", "Connectors", "Remote"], id: \.self) { Text($0).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    switch section {
                    case "Session": session
                    case "Tools": tools
                    case "Advanced": advanced
                    case "Account": account
                    case "Connectors":
                        ConnectorsSection(model: model)
                        plugins
                    case "Remote": RemoteSettingsView(model: model)
                    default: computer
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let verificationStatus { Text(verificationStatus).foregroundStyle(.green).font(.callout) }
                if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                if section == "Account" {
                    Text("Account choices apply to every project. Keys never leave the Keychain except to reach this provider's own processes when API credits are selected; nothing is written to disk in plain text.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if section == "Connectors" {
                    Text("Connectors and plugins apply to every project; project plugins only to this one and only once allowed. Nothing runs until you use a command, save a file with a hook, or start an agent session that gets a plugin's tool server.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if section == "Remote" {
                    Text("Remote control applies to every project and window on this Mac. The Mac's key and the paired devices live in Application Support/Orrery/Remote, owner-only.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if section != "Computer" {
                    Text("Saved for this project and provider. Apply starts a new chat session; your draft and files stay open. Stop running agents or CLIs before applying.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Reset Form") { draft = AgentSessionSettings() }
                        Spacer()
                        Button("Apply Settings") { apply() }.buttonStyle(.borderedProminent)
                            .disabled(busy || model.projectURL == nil)
                    }
                } else {
                    Text("Orrery's shared grant lasts one hour unless persistent blanket access is on. It ends when disabled, the project closes or trust is revoked. Native provider permissions are managed separately.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .frame(width: 680, height: 560)
        .onAppear { model.requestedSettingsSection = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenAllowed = CGPreflightScreenCaptureAccess()
            accessibilityAllowed = AXIsProcessTrusted()
        }
    }

    private var session: some View {
        Group {
            Text("Model and behavior").font(.headline)
            Picker("Available model", selection: $draft.model) {
                Text("Provider default").tag("")
                ForEach(model.models) { option in Text(option.name).tag(option.id) }
                if !draft.model.isEmpty, !model.models.contains(where: { $0.id == draft.model }) {
                    Text(draft.model).tag(draft.model)
                }
            }
            DisclosureGroup("Use a custom model ID", isExpanded: $customModel) {
                field("Model ID", placeholder: "Exact ID from the provider", text: $draft.model)
            }
            Picker("Reasoning effort", selection: $draft.effort) {
                Text("Provider default").tag("")
                ForEach(model.availableEfforts.isEmpty ? ["low", "medium", "high"] : model.availableEfforts, id: \.self) { Text($0.capitalized).tag($0) }
                if !draft.effort.isEmpty, !(model.availableEfforts.isEmpty ? ["low", "medium", "high"] : model.availableEfforts).contains(draft.effort) {
                    Text(draft.effort).tag(draft.effort)
                }
            }
            Toggle("Plan before making changes", isOn: $draft.planMode)
            Text(provider == .codex ? "Uses the read-only sandbox for investigation and planning." : "Starts the provider’s planning mode or plan agent.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Run tools without asking each time", isOn: $model.autoApprove)
                .disabled(busy || model.blanketApproval)
            Text("Applies to Chat, Team and new CLI sessions in this project. Trusted tools can act with the permissions of your macOS account; provider restrictions still apply.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Bypass every tool approval everywhere", isOn: $model.blanketApproval)
                .disabled(busy)
            Text(model.blanketApproval
                 ? "On: every agent runs every tool without asking, in every project and mode — Solo, Team, Roundtable Work, the native CLI — the browser, the iPhone simulator and computer control are on for every agent, and every computer and browser action once computer control is on. Switch it off to get approvals back."
                 : "A global switch. Off: each project decides with the toggle above, and computer actions follow the Computer tab.")
                .font(.caption).foregroundStyle(.secondary)
            field("Resume session ID", placeholder: "Leave empty for a new conversation", text: $draft.resumeSession)
            if provider != .codex { field("Agent profile", placeholder: "Use the default agent", text: $draft.agentProfile) }
            editor("Additional instructions", text: $draft.instructions, height: 100)
            if provider != .codex { editor("Replace system prompt (optional)", text: $draft.systemPrompt, height: 80) }
        }
    }
    private var tools: some View {
        Group {
            Text("Execution boundary").font(.headline)
            Picker("Local file access", selection: $draft.executionPolicy) {
                ForEach(AgentExecutionPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            if draft.executionPolicy == .confinedWrites {
                Text("macOS limits the agent and its child processes to writing in the execution folder, a private temporary folder, and the provider’s session storage. Automatic tools still work within those limits. File reads and network access remain available; connected services and computer control have their own access.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Global settings, plugin installation and some account-management commands may require full access. A blocked launch never retries with full access. Additional writable folders below do not expand this host boundary.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Common SSH, cloud and browser credential folders are blocked, as are the other providers’ standard authentication files. Your selected provider can still use its own sign-in. This does not protect every possible secret or restrict connected services.")
                    .font(.caption).foregroundStyle(.secondary)
                if !AgentExecutionBoundary.isAvailable {
                    Label("Confinement is unavailable on this Mac. Agents will not start with this setting.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else {
                Text("The agent and its tools run with your macOS account’s access. Project trust and approval settings do not create an operating-system boundary. Provider-native restrictions still apply.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Text("Tools and access").font(.headline)
            if provider != .grok {
                Toggle("Prefer native computer control", isOn: $draft.nativeComputerControl)
                Text(provider == .claude
                     ? "Claude's native desktop tools require the interactive CLI pane, /mcp setup and Full macOS account access above. File confinement blocks its native helper. Solo, Team and Roundtable cannot use these tools through Claude's non-interactive connection. Turn this off to use Orrery's shared desktop tools there."
                     : "Codex uses its installed Computer Use plugin. If unavailable, it reports the setup issue instead of silently switching to Orrery's desktop tools. Turn this off to choose Orrery's shared controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if provider == .grok {
                Toggle("Enable subagents", isOn: $draft.subagents)
            }
            if provider == .claude {
                Toggle("Enable Claude in Chrome", isOn: $draft.chrome)
                field("Allowed tools", placeholder: "Provider permission rules", text: $draft.allowedTools)
                field("Denied tools", placeholder: "Tool names or permission rules", text: $draft.deniedTools)
                field("Maximum budget in USD", placeholder: "No session override", text: $draft.maxBudget)
            }
            if provider == .codex {
                Picker("Command sandbox", selection: $draft.sandbox) {
                    Text("Read only").tag("read-only")
                    Text("Project writes").tag("workspace-write")
                    Text("Full machine access").tag("danger-full-access")
                }
                Toggle("Allow network in the command sandbox", isOn: $draft.networkAccess)
                Text("With “Confine local writes”, Orrery’s own boundary is the sandbox — project writes, or a read-only project in plan mode — because Codex’s sandbox cannot start inside it. The two choices above apply with full macOS account access.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Web search", selection: $draft.webSearch) {
                    Text("Off").tag("disabled"); Text("Cached").tag("cached"); Text("Live").tag("live")
                }
            }
            if provider != .grok { editor("Additional writable folders (one per line)", text: $draft.additionalDirectories, height: 70) }
            if provider != .codex { editor("Plugin folders (one per line)", text: $draft.pluginDirectories, height: 70) }
            editor("Additional MCP servers", text: $draft.mcpConfiguration, height: 150)
            Text("JSON object keyed by server name, with command/args/env or URL/headers. Your provider’s existing MCP configuration still loads. Add only tools you trust.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            registry
        }
    }

    @ViewBuilder private var registry: some View {
        let registry = Registry.shared
        Text("Registry").font(.headline)
        Text("Your registry: \(registry.userURL.path) — \(registry.userFileExists ? registry.summary(of: registry.userFile) : "no file yet").")
            .font(.callout).textSelection(.enabled)
        if registry.projectFileURL != nil {
            Text("Project registry: \(Registry.projectRelativePath) — \(registry.projectFileExists ? (model.projectRegistryAllowed ? registry.summary(of: registry.projectFile) : "present, not loaded") : "no file").")
                .font(.callout)
            Toggle("Run this project’s registry and plugins", isOn: Binding(get: { model.projectRegistryAllowed }, set: { model.projectRegistryAllowed = $0 }))
                .disabled(!model.isProjectTrusted)
            Text("A project registry or plugin can name any command. Read \(Registry.projectRelativePath) and \(PluginManager.projectRelativePath) before allowing them; the choice is tied to this folder like project trust.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(registry.problems, id: \.self) { problem in Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        HStack {
            Button("Reload Registry") { model.reloadRegistry() }
            if !registry.userFileExists {
                Button("Write Example Registry") { registry.writeExampleIfMissing(); model.reloadRegistry() }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([registry.userURL]) }.disabled(!registry.userFileExists)
        }
        Text("Define languages, language servers, checkers and tasks as JSON. Write an example registry to see the supported format. Loading a registry never runs anything.")
            .font(.caption).foregroundStyle(.secondary)
    }
    private var advanced: some View {
        Group {
            Text("Provider configuration").font(.headline)
            Text(provider == .grok
                 ? "Grok’s JSON configuration overlay supports its documented soft settings, including models, features and toolset. Organization policy and Grok’s allowlist still apply. Security and discovery settings belong in the provider’s configuration file."
                 : "Enter a JSON object using the provider’s configuration keys. These settings apply to this project session alongside your normal CLI configuration.")
                .font(.callout).foregroundStyle(.secondary)
            editor("Configuration JSON", text: $draft.providerConfiguration, height: 180)
            if provider == .claude { editor("Structured output JSON schema", text: $draft.outputSchema, height: 100) }
            Text("Native CLI and configuration files").font(.headline)
            Button("Browse every installed CLI option…") {
                model.assistantMode = .cli
                model.showNativeOptions = true
                dismiss()
            }
            Text("Use CLI launch options for terminal presentation, login, remote sessions and other interactive commands. The CLI view preserves the provider’s full interface. Global settings can also be edited in the IDE.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Provider Configuration") {
                let path: String
                switch provider {
                case .grok: path = ".grok/config.toml"
                case .claude: path = ".claude/settings.json"
                case .codex: path = ".codex/config.toml"
                }
                let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: url.path) else { error = "No provider configuration file exists yet at \(url.path)."; return }
                model.open(file: url); model.workspaceLayout = .editor; dismiss()
            }
        }
    }
    private var computer: some View {
        Group {
            Label("Provider-native controls", systemImage: "cpu").font(.headline)
            Text("Codex uses its installed Computer Use plugin in chat and Roundtable. Claude's built-in desktop control requires its interactive CLI. Grok uses Orrery's shared controls. Choose the preference separately for Claude and Codex in Tools.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Claude's native CLI") {
                model.provider = .claude
                model.assistantMode = .cli
                dismiss()
            }.disabled(!model.isProjectTrusted)
            Text("In Claude CLI, open /mcp and enable computer-use. Its native helper requires Full macOS account access in Claude's Tools settings; confinement can make it report missing OS permissions. The provider handles eligibility and permissions. Native controls have their own access settings; stopping Orrery's shared service does not revoke them.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Codex Computer Use setup", destination: URL(string: "https://learn.chatgpt.com/docs/computer-use")!)
            Divider()
            Label("Orrery shared computer control", systemImage: "desktopcomputer").font(.headline)
            DesktopPermissionsView()
            Text("Shared desktop tools for Grok, and for Claude or Codex when you choose shared control in Tools. They inspect the main display, click, type and scroll. Each agent gets its own connection; none can approve its own actions or operate Orrery's own permission controls.")
                .font(.callout).foregroundStyle(.secondary)
            if let control = model.computerControl, control.isEnabled, control.desktopEnabled {
                Label("Enabled for this session", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Toggle("Ask before each computer action", isOn: Bindable(control).askBeforeEachAction)
                    .disabled(model.blanketApproval)
                    .help(model.blanketApproval ? "Blanket bypass is on: no computer action asks." : "")
                Button("Stop Computer Control", role: .destructive) { model.disableComputerControl() }
                Text("Recent actions").font(.headline)
                if control.activity.isEmpty { Text("No computer actions yet.").foregroundStyle(.secondary) }
                ForEach(Array(control.activity.suffix(12).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).textSelection(.enabled)
                }
            } else {
                Button("Enable Computer Control for All Agents This Session") {
                    do { try model.enableComputerControl() } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).disabled(!model.isProjectTrusted || busy)
                if !model.isProjectTrusted { Text("Trust the project first.").font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
            Text("IDE tools").font(.headline)
            Text(model.isProjectTrusted
                 ? "On for this trusted project: agents can list and run its tasks, read problems, search, and open files in the editor (ide_* and preview_* tools). They cannot approve their own actions."
                 : "Trust the project to give agents the IDE tools.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("Browser for agents").font(.headline)
            Text(model.blanketApproval ? "Bypass is on: you and your agents may browse any HTTP or HTTPS website. Turning bypass off restores the allowed sites below." : "The Browser pane (View → Browser) is yours: sign in to sites there once and they stay signed in inside Orrery only. Name the sites agents may use, then switch them on; on those sites an agent acts as you, so keep the list short.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Allowed sites, comma separated (for example grok.com)", text: Binding(
                get: { model.browserAllowedHosts.joined(separator: ", ") },
                set: { model.browserAllowedHosts = $0.split(separator: ",").map(String.init) }))
                .textFieldStyle(.roundedBorder).accessibilityLabel("Allowed sites")
            Toggle(model.blanketApproval ? "Agents may use all websites (bypass on)" : "Agents may use the browser on those sites", isOn: Binding(get: { model.agentsMayUseBrowser }, set: { model.browserAgentsAllowed = $0 }))
                .disabled(model.blanketApproval || model.browserAllowedHosts.isEmpty || !model.isProjectTrusted)
            if model.browserAgentsAllowed, let control = model.computerControl, control.isEnabled {
                Toggle("Ask before each browser action", isOn: Bindable(control).askBeforeEachAction)
            }
            Divider()
            Text("macOS permissions").font(.headline)
            LabeledContent("Screen Recording", value: screenAllowed ? "Allowed" : "Not enabled")
            LabeledContent("Accessibility", value: accessibilityAllowed ? "Allowed" : "Not enabled")
            HStack {
                Button("Screen Recording…") {
                    screenAllowed = CGRequestScreenCaptureAccess()
                    if !screenAllowed { openPrivacySettings("Privacy_ScreenCapture") }
                }
                Button("Accessibility…") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    accessibilityAllowed = AXIsProcessTrustedWithOptions(options)
                    if !accessibilityAllowed { openPrivacySettings("Privacy_Accessibility") }
                }
            }
            Text("macOS requires these permissions once. Computer tools cannot change permission settings or operate this IDE’s approval controls. Screen images are sent to the agent only when it requests a screenshot.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Verify Local Tool Connection") {
                Task {
                    guard let control = model.computerControl else { error = "Enable computer control first."; return }
                    let c = control.connection(for: provider)
                    let result = await Task.detached {
                        try? ComputerMCPBridge.call(path: c.socketPath, payload: ["token": c.token, "provider": c.provider.rawValue,
                            "request": ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]])
                    }.value
                    let count = JSON(result)["result"]["tools"].array.count
                    // Compare with the server's own catalog so adding a tool cannot turn a working
                    // connection into a reported failure.
                    if count == control.enabledTools.count, count > 0 {
                        error = nil; verificationStatus = "Local tool connection verified: \(count) tools available."
                    } else {
                        verificationStatus = nil
                        error = "Local connection check failed (\(count) of \(control.enabledTools.count) tools reported)."
                    }
                }
            }.disabled(model.computerControl == nil)
        }
    }
    @ViewBuilder private var account: some View {
        let accounts = ProviderAccounts.shared
        let ledger = UsageLedger.shared
        VStack(alignment: .leading, spacing: 8) {
            Text("How \(provider.displayName) signs in").font(.headline)
            Picker("Authentication", selection: Binding(
                get: { accounts.mode(for: provider) },
                set: { accounts.setMode($0, for: provider); accountStatus = "\(provider.displayName) now uses \($0 == .apiKey ? "API credits" : "the CLI's own sign-in"). Restart its session to pick that up." })) {
                ForEach(ProviderAuthMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.radioGroup).labelsHidden().accessibilityLabel("Authentication")
            Text("Subscription mode leaves credentials entirely to the \(provider.rawValue) command line, which keeps them in its own store. API-credit mode hands the stored key to \(provider.displayName)'s processes as \(ProviderAccounts.environmentVariable(for: provider)) and to nothing else.")
                .font(.caption).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Subscription sign-in").font(.headline)
            Text(ProviderAccounts.subscriptionStatus(for: provider)).font(.callout).textSelection(.enabled)
            HStack {
                Button("Sign In with the CLI…") {
                    model.presetNativeCLI(ProviderAccounts.loginArguments(for: provider), for: provider)
                    dismiss()
                }.disabled(model.installed[provider] != true)
                Text("Opens the CLI pane with `\(provider.rawValue) \(ProviderAccounts.loginArguments(for: provider).joined(separator: " "))` ready to launch; the browser or device flow runs there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("API credits").font(.headline)
            Button(unlocking ? "Unlocking…" : CredentialUnlock.buttonTitle) {
                unlocking = true
                Task {
                    let result = await CredentialUnlock.unlock([.init(service: KeychainStore.service, account: provider.rawValue)])
                    accountStatus = result.message
                    switch result { case .needsKeychainPermission, .unavailable: showLegacyUnlock = true; default: showLegacyUnlock = false }
                    unlocking = false
                }
            }.disabled(unlocking || !accounts.hasKey(for: provider))
            if showLegacyUnlock {
                Button("Allow existing Keychain access…") {
                    unlocking = true
                    Task {
                        let selected = provider
                        let available = await Task.detached { KeychainAccess.read(service: KeychainStore.service, account: selected.rawValue, interactive: true) != nil }.value
                        accountStatus = available ? "Key available for this app session." : "Access cancelled or key unavailable. The saved key was kept."
                        unlocking = false
                    }
                }.disabled(unlocking)
            }
            Text(accounts.hasKey(for: provider)
                 ? "A \(provider.displayName) key is stored in the macOS Keychain (this device only)."
                 : "No \(provider.displayName) key is stored.").font(.callout)
            HStack {
                SecureField("Paste an API key", text: $apiKeyDraft).textFieldStyle(.roundedBorder).accessibilityLabel("API key")
                Button("Save to Keychain") {
                    do {
                        try accounts.storeKey(apiKeyDraft, for: provider)
                        apiKeyDraft = ""
                        accountStatus = "Key stored. Choose API credits above and restart the session to use it."
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }.disabled(apiKeyDraft.isEmpty)
                Button("Remove") {
                    do { try accounts.removeKey(for: provider); accountStatus = "Key removed from the Keychain."; error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(!accounts.hasKey(for: provider))
            }
            if let accountStatus { Text(accountStatus).font(.callout).foregroundStyle(.green) }
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage recorded on this Mac").font(.headline)
            Text(ledger.summary(for: provider)).font(.callout).textSelection(.enabled)
            if let quota = ledger.usage[provider]?.lastQuota {
                Text("Last quota message: \(quota)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let ledgerError = ledger.lastError { Text(ledgerError).font(.caption).foregroundStyle(.red) }
            Text("Costs are what the provider reports per turn (Claude reports dollars; Grok and Codex usually report none). The record is an owner-only file in this app's Application Support folder and is never sent anywhere.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var plugins: some View {
        let manager = PluginManager.shared
        Text("Plugins").font(.headline)
        Text("A plugin is a folder with plugin.json and its own scripts. It can add commands to the Plugins menu (acting on the selection, the whole file or nothing), run something after you save, give every agent session extra tools (MCP servers), and add languages, checkers and tasks. Plugins run as separate programs, never inside Orrery.")
            .font(.callout).foregroundStyle(.secondary)
        if manager.plugins.isEmpty {
            Text("No plugins installed. Write Example Plugin adds three small commands you can look at and change.").font(.callout)
        }
        ForEach(manager.plugins) { plugin in
            HStack(alignment: .top, spacing: 10) {
                Toggle("Enabled", isOn: Binding(get: { plugin.enabled }, set: { manager.setEnabled($0, pluginID: plugin.id); model.reloadExtensions() }))
                    .labelsHidden().toggleStyle(.switch).accessibilityLabel("Enable \(plugin.manifest.name)")
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(plugin.manifest.name) \(plugin.manifest.version)\(plugin.source == .project ? " · from this project" : "")").font(.callout.weight(.medium))
                    if !plugin.manifest.description.isEmpty { Text(plugin.manifest.description).font(.caption).foregroundStyle(.secondary) }
                    Text(plugin.summary + (plugin.enabled ? "" : " · off")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if plugin.source == .user {
                    Button("Remove") {
                        do { try manager.remove(plugin); model.reloadExtensions(); accountStatus = "Moved \(plugin.manifest.name) to the Trash." }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
        ForEach(manager.problems, id: \.self) { problem in Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        HStack {
            Button("Install Plugin Folder…") { installPlugin() }
            Button("Write Example Plugin") { manager.writeExampleIfMissing(); model.reloadExtensions(); accountStatus = "Example Tools installed; see the Plugins menu." }
                .disabled(FileManager.default.fileExists(atPath: manager.userDirectory.appendingPathComponent(PluginManager.exampleID).path))
            Button("Open Plugins Folder") {
                try? FileManager.default.createDirectory(at: manager.userDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                NSWorkspace.shared.open(manager.userDirectory)
            }
            Button("Reload") { model.reloadExtensions() }
        }
        if let accountStatus, section == "Connectors" { Text(accountStatus).font(.callout).foregroundStyle(.green) }
        if model.projectURL != nil {
            Toggle("Run this project’s registry and plugins", isOn: Binding(get: { model.projectRegistryAllowed }, set: { model.projectRegistryAllowed = $0 }))
                .disabled(!model.isProjectTrusted)
            Text("Project plugins live in \(PluginManager.projectRelativePath). They can run any command, so read them first; the choice is tied to this folder like project trust.\(model.isProjectTrusted ? "" : " Trust the project to enable this.")")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text("Plugins folder: \(manager.userDirectory.path). The README's Plugins section documents plugin.json.")
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }

    private func installPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Install"
        panel.message = "Choose a folder that contains plugin.json. It is copied into your plugins folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let manifest = try PluginManager.shared.install(from: url)
            model.reloadExtensions()
            accountStatus = "Installed \(manifest.name)."
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
    private func editor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            TextEditor(text: text).font(.system(.callout, design: .monospaced))
                .padding(8).frame(height: height).background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary)).accessibilityLabel(title)
        }
    }
    private func apply() {
        do {
            try draft.validate()
            guard let project = model.projectURL else { return }
            var settings = model.agentSettings; settings[provider] = draft
            try AgentSettingsStore.save(settings, project: project)
            model.agentSettings = settings
            Task { await model.restartAll() }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

extension AppModel {
    func enableComputerControl() throws {
        guard !isShutDown, isProjectTrusted, projectURL != nil else { throw ComputerError("Trust the project before enabling computer control.") }
        ensureStudioTools()
        guard let control = computerControl else { throw ComputerError("The IDE tool server could not start.") }
        control.setGroups(baseToolGroups.union([.desktop]))
        Task { await restartAll() }
    }
    func disableComputerControl() {
        computerControl?.setGroups(baseToolGroups)
        Task { await restartAll() }
    }
}

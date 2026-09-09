import SwiftUI

/// Launch the actual provider TUI, with its own PTY, without translating or filtering its
/// commands. This retains features that a provider does not expose through its chat protocol.
struct NativeAgentView: View {
    @Bindable var model: AppModel
    @State private var draftArguments = ""
    private var session: TerminalSession? { model.nativeSessions[model.provider] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("\(model.provider.displayName) CLI", systemImage: "terminal").font(.callout.weight(.medium))
                Spacer()
                if session?.isRunning == true {
                    Button("Stop") { session?.terminate() }
                        .help("Stop this CLI; your chat and other projects continue")
                } else {
                    Button(session == nil ? "Start" : "Start Again") { model.startNativeCLI() }
                        .disabled(!model.isProjectTrusted || model.installed[model.provider] != true)
                }
                PaneIconButton(title: "CLI launch options", symbol: "slider.horizontal.3") { model.showNativeOptions = true }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            if model.provider == .claude {
                VStack(alignment: .leading, spacing: 6) {
                    Text("After signing in, enter /mcp and enable computer-use. Claude handles native desktop availability and app permissions. This requires an interactive session.")
                        .font(.caption).foregroundStyle(.secondary)
                    if (model.agentSettings[.claude] ?? AgentSessionSettings()).executionPolicy == .confinedWrites {
                        Text("File confinement blocks Claude's native desktop helper and can make it report missing macOS permissions. Native desktop use requires Full macOS account access in Tools; ordinary CLI work can stay confined.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Review Claude's access settings") {
                            model.requestedSettingsSection = "Tools"
                            model.showAgentSettings = true
                        }.font(.caption)
                    }
                }.padding(.horizontal, 14).padding(.bottom, 8)
            }
            Text(model.currentTaskWorkspace != nil
                 ? "Runs directly in the project folder, not in the Chat task’s working copy. CLI edits are not captured in task Changes."
                 : "Runs directly in the project folder. CLI edits are not isolated or captured in task Changes.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 8)
            Divider()
            if let notice = model.taskNotice {
                Text(notice).font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled).padding(12)
            }
            if let session {
                if let failure = session.startFailure {
                    Text(failure).foregroundStyle(.red).textSelection(.enabled).padding(14)
                }
                TerminalHostView(session: session).id(ObjectIdentifier(session))
                if let status = session.exitStatus {
                    Text("CLI ended (exit \(status)). Start again to open a new session.")
                        .font(.caption).foregroundStyle(.secondary).padding(10)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "terminal").font(.system(size: 30)).foregroundStyle(.secondary)
                        Text("The complete \(model.provider.displayName) CLI").font(.title2.weight(.semibold))
                        Text("Use the provider’s own commands, session history, skills, plugins, MCP tools and configuration here. This session stays open when you switch projects or views.")
                            .foregroundStyle(.secondary)
                        Text("Chat and CLI are separate conversations. Launch options let you resume a saved CLI session or use any supported flag.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("The CLI works in the project folder itself. Chat and Team tasks use separate working copies with a Changes review; the CLI does not.")
                            .font(.callout).foregroundStyle(.secondary)
                        if !model.isProjectTrusted {
                            Label("Trust this project to start a CLI.", systemImage: "lock.shield")
                                .font(.callout)
                        } else if model.installed[model.provider] != true {
                            Label("Install \(model.provider.displayName) to continue.", systemImage: "exclamationmark.triangle")
                        }
                        Button("Launch Options…") { model.showNativeOptions = true }
                    }
                    .frame(maxWidth: 560, alignment: .leading).padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $model.showNativeOptions) { options }
        .onChange(of: model.showNativeOptions, initial: true) { _, shown in
            if shown { draftArguments = model.nativeArguments[model.provider] ?? "" }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(model.provider.displayName) CLI options").font(.title2.weight(.semibold))
            CLIOptionsBrowser(provider: model.provider, arguments: arguments)
            Text("One argument per line. Values containing spaces stay together; no shell quoting is needed. Leave empty for the standard interactive session.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("New Session") { arguments.wrappedValue = "" }
                Button("Resume Latest") {
                    arguments.wrappedValue = model.provider == .codex ? "resume\n--last" : "--continue"
                }
                Button("Session Picker") {
                    arguments.wrappedValue = model.provider == .codex ? "resume" : "--resume"
                }
                Button("Help") { arguments.wrappedValue = "--help" }
            }
            TextEditor(text: arguments)
                .font(.system(.body, design: .monospaced))
                .padding(8).frame(height: 80)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel("CLI arguments, one per line")
            Text("Runs in \(model.projectURL?.path ?? "the selected project"). The CLI reads your existing provider settings and handles its own permissions. Saved session settings apply when no custom arguments are supplied.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Cancel") { model.showNativeOptions = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Options") { model.nativeArguments[model.provider] = draftArguments; model.showNativeOptions = false }
                Button("Launch") { model.nativeArguments[model.provider] = draftArguments; model.startNativeCLI(); model.showNativeOptions = false }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isProjectTrusted || model.installed[model.provider] != true || session?.isRunning == true)
            }
            if session?.isRunning == true {
                Text("Stop the running CLI before launching with different options.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24).frame(width: 610)
    }

    private var arguments: Binding<String> {
        $draftArguments
    }
}

extension AppModel {
    func stopNativeSessions() {
        for session in nativeSessions.values { session.terminate() }
        nativeSessions.removeAll()
    }

    func startNativeCLI(waitForView: Bool = true) {
        guard !isShutDown, isProjectTrusted, !taskMutationBusy, let projectURL,
              nativeSessions[provider]?.isRunning != true else { return }
        let executable: String?
        switch provider {
        case .grok: executable = GrokBackend.locate()
        case .claude: executable = ClaudeBackend.locate()
        case .codex: executable = CodexBackend.locate()
        }
        guard let executable else { return }
        let session = TerminalSession(directory: projectURL)
        nativeSessions[provider] = session
        var environment = AgentEnvironment.sanitized(ProcessInfo.processInfo.environment)
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/.grok/bin"
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment.removeValue(forKey: "NO_COLOR")
        let settings = sessionSettings(for: provider)
        if provider == .grok { environment.merge(settings.grokEnvironment) { _, new in new } }
        environment.merge(ProviderAccounts.shared.childEnvironment(for: provider)) { _, new in new }
        let explicit = (nativeArguments[provider] ?? "").components(separatedBy: .newlines).filter { !$0.isEmpty }
        let connection = computerControl.flatMap { $0.isEnabled ? $0.connection(for: provider) : nil }
        var args = NativeLaunch.arguments(provider: provider, explicit: explicit,
                                          defaults: settings.nativeArguments(for: provider, autoApprove: autoApprove),
                                          mcpServers: settings.mcpServers, connection: connection)
        if provider == .claude { args = MCPLaunchCredentials.claude(arguments: args, environment: &environment) }
        if provider == .codex, explicit.isEmpty {
            do {
                let servers = try MCPLaunchCredentials.codexNative(settings.mcpServers, environment: &environment)
                if let index = args.indices.first(where: { args[$0].hasPrefix("mcp_servers=") }) {
                    args[index] = "mcp_servers=" + TOMLArgument.value(servers)
                }
            } catch {
                taskNotice = error.localizedDescription
                nativeSessions.removeValue(forKey: provider)
                return
            }
        }
        let target = provider
        Task { @MainActor [weak self] in
            guard let self else { return }
            if target == .codex, settings.nativeComputerControl, AppModel.persistsPreferences {
                do { try await NativeComputerControl.prepareCodexService() }
                catch { self.taskNotice = "Codex native computer control could not start: \(error.localizedDescription)" }
            }
            guard !self.isShutDown, self.isProjectTrusted, self.nativeSessions[target] === session else { return }
            session.start(executable: executable, arguments: args, environment: environment, whenVisible: waitForView,
                          execution: AgentExecutionRequest(policy: NativeLaunch.executionPolicy(configured: settings.executionPolicy, explicit: explicit),
                                                           workspace: projectURL, provider: target,
                                                           additionalDirectories: settings.additionalDirectoryURLs))
        }
    }
}

import SwiftUI
import AppKit

/// Shared visual hierarchy: a quiet canvas, distinct work surfaces and one accent.
enum StudioStyle {
    static let accent = Color(red: 0.36, green: 0.64, blue: 0.98)
    static let canvas = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let border = Color.primary.opacity(0.085)
}

struct OrbitMark: View {
    var size: CGFloat = 60
    var body: some View {
        ZStack {
            Ellipse().stroke(StudioStyle.accent.opacity(0.45), lineWidth: 1).rotationEffect(.degrees(-35))
            Ellipse().stroke(StudioStyle.accent.opacity(0.45), lineWidth: 1).rotationEffect(.degrees(35))
            Circle().fill(StudioStyle.accent).frame(width: size * 0.2, height: size * 0.2)
            Circle().fill(Color.primary.opacity(0.85)).frame(width: 5, height: 5).offset(x: size * 0.4, y: -size * 0.23)
        }.frame(width: size, height: size * 0.65).accessibilityHidden(true)
    }
}

struct ProjectWelcomeView: View {
    @Bindable var model: AppModel
    @State private var error: String?
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 12) {
                        OrbitMark(size: 38)
                        Text("ORRERY").font(.system(size: 12, weight: .bold, design: .rounded)).tracking(4)
                        Spacer()
                        Button("Set up your agents") { model.showSetup = true }.buttonStyle(.bordered)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Your next idea.\nAlready in motion.")
                            .font(.system(size: geometry.size.width < 800 ? 38 : 52, weight: .semibold, design: .rounded)).tracking(-1.5)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Describe what you want. Build with your AI team. See it come to life in one workspace.")
                            .font(.title3).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading)
                    }.padding(.vertical, 14)
                    HStack(spacing: 12) {
                        Button { createProject() } label: { Label("Create a project", systemImage: "plus") }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        Button { model.chooseProject() } label: { Label("Open a folder", systemImage: "folder") }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                    HStack(alignment: .top, spacing: 24) {
                        step("01", "Start with an idea", "No code required. A project keeps your conversations and files together.")
                        step("02", "Choose your AI", "Use Grok, Claude or Codex. One account is enough; add more whenever you want.")
                        step("03", "Make it yours", "Preview the result, ask for changes, and review the files your agents create.")
                    }.padding(.top, 20)
                    Label("Your accounts, projects and credentials stay on your Mac. Your chosen AI provider receives the context you send.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                }
                .frame(maxWidth: 850, alignment: .leading)
                .padding(.horizontal, geometry.size.width < 800 ? 28 : 56).padding(.vertical, 44)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
            .background(StudioStyle.canvas)
            .background(alignment: .topTrailing) { Circle().fill(StudioStyle.accent.opacity(0.07)).frame(width: 420).blur(radius: 90).allowsHitTesting(false) }
        }
    }
    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(number).font(.caption.monospaced()).foregroundStyle(StudioStyle.accent)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func createProject() {
        let panel = NSSavePanel()
        panel.title = "Create a project"
        panel.prompt = "Create Project"
        panel.nameFieldStringValue = "My project"
        panel.message = "Choose where your new project folder will live."
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectSetup.createEmptyFolder(at: url)
            if let open = model.openProjectInWindow { open(url) }
            else { _ = model.openProject(url) }
        } catch { self.error = error.localizedDescription }
    }
}

enum ProjectSetup {
    static func canUseAgent(installed: Bool, needsSignIn: Bool) -> Bool {
        installed && !needsSignIn
    }
    static func agentStatus(installed: Bool, connected: Bool, needsSignIn: Bool) -> String {
        if !installed { return "Install this agent to get started" }
        if needsSignIn { return "Sign in again to reconnect your account" }
        if connected { return "Connected · ready to use" }
        return "Installed · sign in or use your saved account"
    }
    static func createEmptyFolder(at url: URL) throws {
        guard url.isFileURL, !FileManager.default.fileExists(atPath: url.path) else {
            throw ComputerError("That folder already exists. Use Open a folder to keep working in it.")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    static func installationURL(for provider: Provider) -> URL {
        switch provider {
        case .grok: return URL(string: "https://x.ai/build")!
        case .claude: return URL(string: "https://code.claude.com/docs/en/quickstart")!
        case .codex: return URL(string: "https://developers.openai.com/codex/cli/")!
        }
    }
}

struct StudioSetupView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAccount = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Make this workspace yours").font(.title2.weight(.semibold))
                    Text("Start with one agent. Add your other accounts and tools at any time.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label("1  Choose your project", systemImage: "folder").font(.headline)
                    if let project = model.projectURL {
                        HStack {
                            Text(project.lastPathComponent).font(.callout.weight(.medium))
                            Spacer()
                            if model.isProjectTrusted { Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                            else { Button("Trust this project") { model.setProjectTrusted(true) }.buttonStyle(.borderedProminent) }
                        }
                        if !model.isProjectTrusted { Text("Review an unfamiliar folder before trusting it. Trust lets your agents run this project's tools.").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Button("Open a project folder") { model.chooseProject() }.buttonStyle(.borderedProminent)
                        Text("Choose the folder you want to work in, then connect one agent below.").font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        Label("2  Connect an agent", systemImage: "sparkles").font(.headline)
                        Spacer()
                        Button("Check again") { refresh() }.controlSize(.small)
                    }
                    ForEach(Provider.allCases) { provider in
                        HStack(spacing: 14) {
                            Image(systemName: provider.symbol).font(.title3).foregroundStyle(StudioStyle.accent)
                                .frame(width: 40, height: 40).background(StudioStyle.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider.displayName).font(.headline)
                                Text(ProjectSetup.agentStatus(installed: model.installed[provider] == true,
                                      connected: model.states[provider]?.isConnected == true, needsSignIn: model.needsSignIn.contains(provider)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.installed[provider] == true {
                                if ProjectSetup.canUseAgent(installed: model.installed[provider] == true, needsSignIn: model.needsSignIn.contains(provider)) {
                                    Button("Use \(provider.displayName)") {
                                        model.provider = provider; model.assistantMode = .chat; dismiss()
                                    }.buttonStyle(.borderedProminent).disabled(!model.isProjectTrusted || model.projectURL == nil)
                                } else {
                                    Button("Sign in") {
                                        model.signIn(provider)
                                        dismiss()
                                    }.buttonStyle(.borderedProminent).disabled(!model.isProjectTrusted || model.projectURL == nil)
                                }
                                Menu("Account") {
                                    Button("Sign in with the CLI") { model.signIn(provider); dismiss() }
                                        .disabled(!model.isProjectTrusted || model.projectURL == nil)
                                    Button("API key & settings") {
                                        model.provider = provider; model.requestedSettingsSection = "Account"; showAccount = true
                                    }.disabled(model.projectURL == nil)
                                }.controlSize(.small)
                            } else {
                                Link("Install \(provider.displayName)", destination: ProjectSetup.installationURL(for: provider))
                            }
                        }.padding(14).background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioStyle.border))
                    }
                    Text("Installation is detected automatically. Sign in with your own subscription or save an API key in Keychain. No Orrery account is required.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Label("3  Add your tools — optional", systemImage: "puzzlepiece.extension").font(.headline)
                    Text("Connections supports MCP servers and plugins. Import existing settings or paste a setup, then choose which agents can use it.").font(.callout).foregroundStyle(.secondary)
                    Button("Set up connections") {
                        model.requestedSettingsSection = "Connectors"; showAccount = true
                    }
                }.padding(24)
            }
        }.frame(width: 660, height: 670)
        .background(StudioStyle.canvas)
        .sheet(isPresented: $showAccount) { AgentSettingsSheet(model: model) }
        .onChange(of: model.assistantMode) { _, mode in if mode == .cli { dismiss() } }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }
    private func refresh() {
        model.installed = [.grok: GrokBackend.locate() != nil, .claude: ClaudeBackend.locate() != nil, .codex: CodexBackend.locate() != nil]
        if !model.orchestrator.isRunning {
            model.orchestrator.installedProviders = Provider.allCases.filter { model.installed[$0] == true }
            model.orchestrator.adoptInstalledOrchestrator()
        }
    }
}

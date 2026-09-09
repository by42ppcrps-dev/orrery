import SwiftUI
import AppKit

@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--computer-mcp") {
            ComputerMCPBridge.run()
        } else if CommandLine.arguments.contains("--audit") {
            SelfTest.audit()
        } else if CommandLine.arguments.contains("--probe") {
            SelfTest.probe()
        } else if CommandLine.arguments.contains("--keychain-probe") {
            SelfTest.keychainProbe()
        } else if let index = CommandLine.arguments.firstIndex(of: "--print-profile"), index + 2 < CommandLine.arguments.count {
            // Diagnostic: the exact sandbox profile a confined launch would get.
            // usage: Orrery --print-profile <grok|claude|codex> <workspace>
            let provider = Provider(rawValue: CommandLine.arguments[index + 1]) ?? .claude
            let workspace = URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true)
            do {
                let launch = try AgentExecutionBoundary.prepare(executable: "/bin/sh", arguments: [], environment: [:],
                    execution: AgentExecutionRequest(policy: .confinedWrites, workspace: workspace, provider: provider))
                print(launch.arguments.count > 1 ? launch.arguments[1] : "(no profile)")
            } catch { print("error: \(error.localizedDescription)") }
            exit(0)
        } else if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        } else {
            LegacyMigration.runAtLaunch()
            PluginManager.shared.load(project: nil, projectAllowed: false)
            MainActor.assumeIsolated { ConnectorStore.shared.installSnapshot() }
            Registry.shared.load(project: nil, projectAllowed: false, contributions: PluginManager.shared.registryContributions)
            MainThreadWatchdog.shared.start()
            if let index = CommandLine.arguments.firstIndex(of: "--hang-test"), index + 1 < CommandLine.arguments.count,
               let seconds = TimeInterval(CommandLine.arguments[index + 1]) {
                // Proves the watchdog on a real build: block the main thread on purpose after the
                // window is up. Only when asked for on the command line.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Thread.sleep(forTimeInterval: seconds) }
            }
            OrreryApp.main()
        }
    }
}

struct StudioModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var studioModel: AppModel? {
        get { self[StudioModelKey.self] }
        set { self[StudioModelKey.self] = newValue }
    }
}

/// Extra windows with their own AppModel. A second SwiftUI WindowGroup would open itself
/// at launch; these are created only when asked.
@MainActor
final class ExtraWindowSupport: NSObject, NSWindowDelegate {
    static let shared = ExtraWindowSupport()

    private struct Item {
        let window: NSWindow
        let model: AppModel
    }
    private var items: [Item] = []

    func open(project: URL?, model: AppModel? = nil) {
        let model = model ?? AppModel()
        if let project { model.openProject(project) }
        let root = WorkspaceWindowView(model: model, restoreLastProject: false)
            .frame(minWidth: 900, minHeight: 620)
        let window = NSWindow(
            contentRect: NSRect(x: 80 + CGFloat(items.count) * 28,
                                y: 60 + CGFloat(items.count) * 28,
                                width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Orrery"
        window.contentView = NSHostingView(rootView: root)
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if NSApplication.shared.activationPolicy() != .prohibited {
            window.makeKeyAndOrderFront(nil)
        }
        items.append(Item(window: window, model: model))
    }

    /// Production close path: `NSWindow.close()` delivers `windowWillClose`.
    func closeAll() {
        for window in items.map(\.window) {
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if let item = items.first(where: { $0.window === closing }) {
            item.model.shutdown()
        }
        items.removeAll { $0.window === closing }
    }
}

struct OrreryApp: App {
    @NSApplicationDelegateAdaptor(StudioApplicationDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            WorkspaceWindowView()
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            StudioCommands()
        }
    }
}

@MainActor
final class StudioApplicationDelegate: NSObject, NSApplicationDelegate {
    private final class WindowModel {
        weak var value: AppModel?
        init(_ value: AppModel) { self.value = value }
    }
    private static var windows: [WindowModel] = []

    static func register(_ model: AppModel) {
        windows.removeAll { $0.value == nil || $0.value?.isShutDown == true }
        guard !model.isShutDown else { return }
        if !windows.contains(where: { $0.value === model }) { windows.append(WindowModel(model)) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for window in Self.windows {
            guard let model = window.value, !model.isShutDown else { continue }
            if !model.documents.approveClosing() { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        for window in Self.windows { window.value?.shutdown() }
    }
}

/// Menu commands act on the key window's model. No focused window ⇒ disabled, never a
/// silent action against some other window. Zoom is app-wide by design.

/// Navigate → Jump to Definition. Lives on the focused `AppModel`, not the first responder,
/// so the command still works when the sidebar or another pane has focus.
enum StudioNavigate {
    @MainActor
    static func jumpToDefinition(_ model: AppModel?) async {
        await model?.jumpToDefinition()
    }
}

struct StudioCommands: Commands {
    @FocusedValue(\.studioModel) private var model
    @FocusedValue(\.projectWorkspaces) private var workspaces

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(OrreryUpdates.shared.checking ? "Checking for Updates…" : "Check for Orrery Updates…") {
                Task { await OrreryUpdates.shared.check() }
            }.disabled(OrreryUpdates.shared.checking)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Session") { Task { await model?.newSession() } }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model == nil)
            Button("New Project Window") {
                ExtraWindowSupport.shared.open(project: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Add Project to Window…") { workspaces?.chooseProject() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model == nil)
            Divider()
            Button("Next Project") { workspaces?.cycle(1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(workspaces == nil)
            Button("Previous Project") { workspaces?.cycle(-1) }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(workspaces == nil)
            Button("Close Project") {
                if let id = workspaces?.active?.id { workspaces?.close(id) }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(workspaces == nil)
            Divider()
            ForEach(Provider.allCases) { provider in
                Button("Switch to \(provider.displayName)") { model?.provider = provider }
                    .disabled(model == nil || model?.installed[provider] != true)
            }
        }
        CommandGroup(after: .saveItem) {
            Button("Save") { model?.saveActiveFile() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model == nil || model?.documents.active == nil)
            Button("Save All") { model?.saveAllFiles() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model == nil || model?.documents.hasUnsavedChanges != true)
            Button("Revert to Saved") { model?.reloadActiveFile() }
                .disabled(model == nil || model?.documents.active == nil)
            Divider()
            Button("Refresh File Tree") { model?.refreshTree() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Activity Across Devices…") { ActivityWindowSupport.shared.open() }
            Divider()
            Button("Actual Size") { setFontSize(13) }
                .keyboardShortcut("0", modifiers: .command)
            Button("Zoom In") { setFontSize(EditorTheme.fontSize + 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { setFontSize(EditorTheme.fontSize - 1) }
                .keyboardShortcut("-", modifiers: .command)
            Divider()
            Picker("Workspace Layout", selection: Binding(
                get: { model?.workspaceLayout ?? .workspace },
                set: { model?.workspaceLayout = $0 })) {
                ForEach(WorkspaceLayout.allCases) { layout in Text(layout.title).tag(layout) }
            }
            Button("Native CLI") { model?.assistantMode = .cli; model?.workspaceLayout = .assistant }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Button("Commands…") { model?.showCommandPalette = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Keyboard Shortcuts") { model?.showShortcuts = true }
                .keyboardShortcut("/", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Solo") { AppCommands.switchMode(model, to: .chat) }.keyboardShortcut("1", modifiers: .command).disabled(model == nil)
            Button("Team") { AppCommands.switchMode(model, to: .team) }.keyboardShortcut("2", modifiers: .command).disabled(model == nil)
            Button("Roundtable") { AppCommands.switchMode(model, to: .roundtable) }.keyboardShortcut("3", modifiers: .command).disabled(model == nil)
            Button("CLI") { AppCommands.switchMode(model, to: .cli) }.keyboardShortcut("4", modifiers: .command).disabled(model == nil)
            Divider()
            Button("Browser") { model?.showBrowser() }
            Button("iPhone Simulator") { model?.showSimulator() }
            Button("Source Control") { model?.showGit() }.keyboardShortcut("g", modifiers: [.command, .control])
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Problems") { model?.bottomPane = .problems }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Hide Bottom Pane") { model?.bottomPane = .hidden }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(model == nil)
        }
        CommandMenu("Navigate") {
            Button("Go to File…") { model?.showQuickOpen = true }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(model == nil)
            Button("Find in Project…") { model?.bottomPane = .search }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Go to Line…") { model?.showGoToLine = true }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(model == nil || model?.documents.active == nil)
            Button("Jump to Definition") {
                Task { await StudioNavigate.jumpToDefinition(model) }
            }
            .keyboardShortcut("j", modifiers: [.control, .command])
            .disabled(model == nil)
            Divider()
            Button("Next Tab") { model?.documents.selectNext(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Previous Tab") { model?.documents.selectNext(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Close Tab") {
                if let document = model?.documents.active { model?.documents.close(document) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(model == nil || model?.documents.active == nil)
        }
        CommandMenu("Run") {
            Button("Run") { model?.runTask(kind: .run) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model == nil)
            Button("Build") { model?.runTask(kind: .build) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Test") { model?.runTask(kind: .test) }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(model == nil)
            Button("Stop Task") { model?.taskRun.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model == nil || model?.taskRun.isRunning != true)
            Divider()
            Button("Terminal") { model?.showTerminal() }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(model == nil)
            Button("Output") { model?.bottomPane = .output }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(model == nil)
        }
        CommandMenu("Plugins") {
            let commands = model?.pluginMenuCommands ?? []
            if commands.isEmpty {
                Text("No plugin commands for this file").disabled(true)
            } else {
                ForEach(commands) { reference in
                    Button(reference.menuTitle) { model?.runPluginCommand(reference) }
                }
            }
            Divider()
            Button("Reload Plugins and Registry") { model?.reloadExtensions() }.disabled(model == nil)
            Button("Connectors…") { model?.requestedSettingsSection = "Connectors"; model?.showAgentSettings = true }.disabled(model == nil)
            Button("Plugin Settings…") { model?.requestedSettingsSection = "Connectors"; model?.showAgentSettings = true }.disabled(model == nil)
        }
        CommandMenu("Source") {
            Button("Edit Selection with Agent…") {
                if !NSApp.sendAction(#selector(CodeTextView.editSelectionWithAgent(_:)), to: nil, from: nil) {
                    model?.editActiveSelectionWithAgent()
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(model == nil)
            Divider()
            Button("Commit…") { model?.showGit() }.disabled(model?.git.status.isRepo != true)
            Button("Push") { if let git = model?.git { Task { await git.push() } } }.disabled(model?.git.status.isRepo != true || model?.git.remote.isEmpty != false)
            Button("Pull") { if let git = model?.git { Task { await git.pull() } } }.disabled(model?.git.status.isRepo != true || model?.git.remote.isEmpty != false)
            Button("Fetch") { if let git = model?.git { Task { await git.fetch() } } }.disabled(model?.git.status.isRepo != true || model?.git.remote.isEmpty != false)
            Button("Initialize Git Repository") { if let git = model?.git { Task { await git.initialize() } } }.disabled(model?.projectURL == nil || model?.git.status.isRepo == true)
            Button("Clone Repository…") { model?.showGit() }
            Divider()
            Button("Toggle Comment") {
                NSApp.sendAction(#selector(CodeTextView.toggleLineComment(_:)),
                                 to: nil, from: nil)
            }
            .keyboardShortcut("/", modifiers: .command)
            .disabled(model == nil)
            Button("Duplicate Line") {
                NSApp.sendAction(#selector(CodeTextView.duplicateLine(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model == nil)
            Button("Delete Line") {
                NSApp.sendAction(#selector(CodeTextView.deleteCurrentLine(_:)),
                                 to: nil, from: nil)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(model == nil)
        }
    }
}

/// Zooming the editor re-lays out every open document, so it goes through the theme rather
/// than any one view.
@MainActor
private func setFontSize(_ size: CGFloat) {
    EditorTheme.fontSize = max(8, min(32, size))
    NotificationCenter.default.post(name: .editorFontChanged, object: nil)
}

extension Notification.Name {
    static let editorFontChanged = Notification.Name("Orrery.editorFontChanged")
}

extension AppModel {
    /// Folder picker. Lives here because it needs AppKit.
    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        if panel.runModal() == .OK, let url = panel.url {
            if let openProjectInWindow { openProjectInWindow(url); return }
            guard openProject(url) else { return }
            Task { await restartAll() }
        }
    }
}

extension SelfTest {
    /// `Orrery --audit` — every headless regression check, in sections.
    /// Touches only temporary directories and spends no subscription quota.
    static func audit() {
        // The editor checks build real NSTextViews, so AppKit has to be initialized — with a
        // prohibited activation policy, which gives no dock icon and no window.
        //
        // The main thread also has to stay alive. `dispatchMain()` parks it by calling
        // `pthread_exit`, and CoreAnimation's thread-cleanup handler then tries to run a display
        // pass and asserts. Draining the run loop keeps the thread — and AppKit — intact.
        NSApplication.shared.setActivationPolicy(.prohibited)
        final class Outcome { var code: Int32 = 1; var done = false }
        let outcome = Outcome()
        Task { @MainActor in
            let audit = Auditor()
            if CommandLine.arguments.contains("--recovery-only") {
                await AuditTaskHistory.run(audit)
                outcome.code = audit.summary(); outcome.done = true; return
            }
            if CommandLine.arguments.contains("--tasks-only") {
                await AuditTaskHistory.run(audit)
                await AuditTaskWorkspaces.run(audit)
                outcome.code = audit.summary(); outcome.done = true; return
            }
            if CommandLine.arguments.contains("--workspace-only") {
                await AuditWorkspace.run(audit)
                await AuditLSP.run(audit)
                await AuditLSPEditor.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--experience-only") {
                await AuditStudioExperience.run(audit)
                outcome.code = audit.summary(); outcome.done = true; return
            }
            if CommandLine.arguments.contains("--studio-only") {
                await AuditStudioFeatures.run(audit)
                await AuditUIVerification.run(audit)
                await AuditAccounts.run(audit)
                await AuditInlineEdit.run(audit)
                await AuditMigration.run(audit)
                await AuditRegistry.run(audit)
                await AuditPlugins.run(audit)
                await AuditRelease.run(audit)
                await AuditTeamSingle.run(audit)
                await AuditRoundtable.run(audit)
                await AuditStudioExperience.run(audit)
                await AuditUpdates.run(audit)
                await AuditImagine.run(audit)
                await AuditStudioTools.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--windows-only") {
                await AuditWindows.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--studio-tools-only") {
                await AuditStudioTools.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--updates-only") {
                await AuditUpdates.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--imagine-only") {
                await AuditImagine.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--roundtable-only") {
                await AuditRoundtable.run(audit)
                await AuditStudioExperience.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--commands-only") {
                await AuditCommands.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--skills-only") {
                await AuditSkills.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--simulator-only") {
                await AuditSimulator.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--watchdog-only") {
                await AuditWatchdog.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--connectors-only") {
                await AuditConnectors.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--activity-only") {
                await AuditActivity.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--remote-only") {
                await AuditRemote.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--git-only") {
                await AuditGit.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--team-single-only") {
                await AuditTeamSingle.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--plugins-only") {
                await AuditPlugins.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--registry-only") {
                await AuditRegistry.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--inline-only") {
                await AuditInlineEdit.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--accounts-only") {
                await AuditAccounts.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--languages-only") {
                await AuditLanguages.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--verification-only") {
                await AuditUIVerification.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            if CommandLine.arguments.contains("--security-only") {
                await AuditSecurity.run(audit)
                await AuditExecutionPolicy.run(audit)
                outcome.code = audit.summary()
                outcome.done = true
                return
            }
            AuditTokenizer.run(audit)
            AuditHighlighter.run(audit)
            AuditEditor.run(audit)
            AuditRendering.run(audit)
            AuditPolyglot.run(audit)
            await AuditWorkspace.run(audit)
            await AuditMedia.run(audit)
            await AuditDiagnostics.run(audit)
            await AuditLSP.run(audit)
            await AuditLSPEditor.run(audit)
            await AuditTerminal.run(audit)
            await AuditRun.run(audit)
            await AuditOrchestrator.run(audit)
            await AuditTeamStats.run(audit)
            await AuditCalibration.run(audit)
            await AuditToolchain.run(audit)
            await AuditApp.run(audit)
            await AuditWindows.run(audit)
            await AuditSecurity.run(audit)
            await AuditStudioFeatures.run(audit)
            await AuditTaskHistory.run(audit)
            await AuditTaskWorkspaces.run(audit)
            await AuditExecutionPolicy.run(audit)
            await AuditUIVerification.run(audit)
            await AuditLanguages.run(audit)
            await AuditAccounts.run(audit)
            await AuditInlineEdit.run(audit)
            await AuditMigration.run(audit)
            await AuditRegistry.run(audit)
            await AuditPlugins.run(audit)
            await AuditConnectors.run(audit)
            await AuditWatchdog.run(audit)
            await AuditSimulator.run(audit)
            await AuditSkills.run(audit)
            await AuditCommands.run(audit)
            await AuditRelease.run(audit)
            await AuditTeamSingle.run(audit)
            await AuditRoundtable.run(audit)
                await AuditStudioExperience.run(audit)
            await AuditGit.run(audit)
            await AuditRemote.run(audit)
            await AuditUpdates.run(audit)
            await AuditImagine.run(audit)
            await AuditStudioTools.run(audit)
            outcome.code = audit.summary()
            outcome.done = true
        }
        while !outcome.done {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        exit(outcome.code)
    }

    /// `Orrery --probe <grok|claude|codex> <project> "<prompt>"` — sends one real turn through
    /// the same backend and event mapping the window uses, printing the normalized event stream.
    /// This one DOES spend subscription quota, so it is never run automatically.
    static func probe() {
        let all = Array(CommandLine.arguments.dropFirst())
        let ask = all.contains("--ask")
        func value(_ flag: String) -> String? {
            guard let i = all.firstIndex(of: flag), i + 1 < all.count else { return nil }
            return all[i + 1]
        }
        let wantModel = value("--model")
        let wantEffort = value("--effort")
        let cancelAfter = value("--cancel-after").flatMap(Double.init)
        var skip = Set(["--probe", "--ask"])
        for flag in ["--model", "--effort", "--cancel-after"] {
            if let v = value(flag) { skip.insert(flag); skip.insert(v) }
        }
        let args = all.filter { !skip.contains($0) }
        guard args.count >= 3,
              let provider = Provider(rawValue: args[0].lowercased()) else {
            print("usage: Orrery --probe <grok|claude|codex> <project-path> \"<prompt>\"")
            exit(2)
        }
        let project = URL(fileURLWithPath: args[1])
        let prompt = args[2...].joined(separator: " ")

        Task { @MainActor in
            let backend: any AgentBackend
            switch provider {
            case .grok:   backend = GrokBackend()
            case .claude: backend = ClaudeBackend()
            case .codex:  backend = CodexBackend()
            }
            backend.persistsSelection = false
            print("── \(provider.displayName) · \(project.lastPathComponent)")
            print("── prompt: \(prompt)\n")

            var assistant = "", thinking = ""
            var tools: [String: String] = [:]
            var finished = false
            var failed = false

            backend.onEvent = { event in
                switch event {
                case let .connected(id):
                    print("[connected] \(id)")
                case let .disconnected(reason):
                    print("[disconnected] \(reason)")
                case let .status(text):
                    print("[status] \(text)")
                case let .note(text):
                    print("[note] \(text)")
                case let .sessionDropped(reason):
                    print("[session dropped] \(reason)")
                case let .assistantDelta(text):
                    assistant += text
                    FileHandle.standardOutput.write(Data(text.utf8))
                case let .thoughtDelta(text):
                    thinking += text
                case let .toolStarted(id, title, kind, input):
                    tools[id] = title
                    print("\n[tool \(kind)] \(title)")
                    if !input.isEmpty {
                        print("          input: \(input.prefix(160).replacingOccurrences(of: "\n", with: " "))")
                    }
                case let .toolUpdated(id, status, output, diff):
                    if let status, status != "in_progress" {
                        print("[tool \(status)] \(tools[id] ?? id)")
                    }
                    if let output, !output.isEmpty {
                        print("          output: \(output.prefix(160).replacingOccurrences(of: "\n", with: " "))")
                    }
                    if let diff { print("          diff: \(diff.path)") }
                case let .plan(steps):
                    print("\n[plan]\n  " + steps.joined(separator: "\n  "))
                case let .failure(message):
                    failed = true
                    print("\n[FAILURE] \(message)")
                case let .turnFinished(stop, cost):
                    finished = true
                    print("\n\n── turn finished: \(stop ?? "?")"
                          + (cost.map { String(format: " · $%.4f", $0) } ?? ""))
                    print("── streamed: \(assistant.count) chars of reply, "
                          + "\(thinking.count) chars of thinking, \(tools.count) tool call(s)")
                    backend.stop()
                    let unsuccessful = ["error", "failed", "process exited", "busy"].contains(stop ?? "")
                    exit(failed || unsuccessful || (assistant.isEmpty && tools.isEmpty) ? 1 : 0)
                case let .permission(request):
                    print("\n[approval requested] \(request.title)")
                    print("          detail: \(request.detail.prefix(200).replacingOccurrences(of: "\n", with: " "))")
                    for o in request.options {
                        print("          option: id=\(o.id) name=\"\(o.name)\" kind=\(o.kind)")
                    }
                    let allow = (request.options.first { $0.kind == "allow_once" }
                                 ?? request.options.first { $0.kind.hasPrefix("allow") })?.id
                    print("          replying: \(allow ?? "cancel")")
                    request.reply(allow)
                case .models, .log:
                    break
                }
            }

            await backend.start(project: project, autoApprove: !ask)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let wantEffort {
                await backend.setEffort(wantEffort)
                print("[effort set] \(backend.currentEffort)")
            }
            if let wantModel {
                await backend.setModel(wantModel)
                print("[model set] \(backend.currentModel)")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            if let cancelAfter {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(cancelAfter * 1_000_000_000))
                    print("\n[cancelling after \(cancelAfter)s]")
                    backend.cancel()
                }
            }
            await backend.send(prompt)

            try? await Task.sleep(nanoseconds: 300_000_000_000)
            if !finished { print("\n[timeout] no turn completion after 300s"); backend.stop(); exit(1) }
        }
        dispatchMain()
    }
}

/// A backend that accepts a prompt and never answers — stands in for a killed CLI, a broken
/// pipe, or a dropped protocol message.
@MainActor
final class StubBackend: AgentBackend {
    let provider = Provider.grok
    var models: [ModelOption] = []
    var currentModel = ""
    var currentEffort = ""
    var persistsSelection = true
    var onEvent: ((BackendEvent) -> Void)?
    var isRunning: Bool { true }
    var cancelled = false
    var stopped = false

    static func locate() -> String? { "/bin/true" }
    func start(project: URL, autoApprove: Bool) async {}
    func stop() { stopped = true }
    func send(_ text: String) async {}          // deliberately silent
    func cancel() { cancelled = true }          // and ignores the cancel
    func setModel(_ id: String) async {}
}

/// `Orrery --selftest [path]` — starts every installed backend, reports what connected and
/// which models it offers, then exits. Sends no prompt, so it costs nothing against any
/// subscription.
enum SelfTest {
    /// One provider's free handshake: start, await connected/models, stop. No prompt.
    struct HandshakeResult: Equatable, Sendable {
        var provider: Provider
        var locatedPath: String?
        var sessionID: String?
        var failure: String?
        var modelNames: [String]
        var effortInfo: String?

        var ok: Bool { locatedPath != nil && failure == nil }
    }

    /// Test seam. Production is nil, which means the real provider backend.
    static var backendFactory: ((Provider) -> (located: String?, backend: any AgentBackend))?

    /// A still-running backend with no session (Claude until the first turn) is ok.
    /// Disconnect or process exit — even after a session id — is a failed handshake.
    static func failureAfterWait(connected: String?, failure: String?,
                                 disconnected: String?, isRunning: Bool) -> String? {
        if let failure { return failure }
        if let disconnected, !disconnected.isEmpty { return disconnected }
        if !isRunning {
            return connected == nil
                ? "exited before a session was reported"
                : "exited after connecting"
        }
        return nil
    }

    /// Shared by `--selftest` printing and the toolchain watchdog. Never sends a prompt.
    @MainActor
    static func handshake(provider: Provider, project: URL,
                          waitSeconds: TimeInterval = 3) async -> HandshakeResult {
        let located: String?
        let backend: any AgentBackend
        if let backendFactory {
            (located, backend) = backendFactory(provider)
        } else {
            switch provider {
            case .grok:   located = GrokBackend.locate();   backend = GrokBackend()
            case .claude: located = ClaudeBackend.locate(); backend = ClaudeBackend()
            case .codex:  located = CodexBackend.locate();  backend = CodexBackend()
            }
        }
        guard let located else {
            return HandshakeResult(provider: provider, locatedPath: nil, sessionID: nil,
                                   failure: "not installed", modelNames: [], effortInfo: nil)
        }
        var connected: String?
        var failure: String?
        var disconnected: String?
        backend.onEvent = { event in
            switch event {
            case let .connected(sessionID): connected = sessionID
            case let .failure(message): failure = failure ?? message
            case let .disconnected(reason): disconnected = disconnected ?? reason
            default: break
            }
        }
        // Deadline covers start() itself. A stalled initialize RPC must not
        // block the launch sweep or Check now for minutes.
        let deadline = Date().addingTimeInterval(waitSeconds)
        var startDone = false
        let startTask = Task { @MainActor in
            await backend.start(project: project, autoApprove: true)
            startDone = true
        }
        while Date() < deadline, connected == nil, failure == nil, disconnected == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        failure = failureAfterWait(connected: connected, failure: failure,
                                   disconnected: disconnected, isRunning: backend.isRunning)
        // A still-running backend whose start() returned (Claude) is ok with
        // no session. A start() that never returns is a timeout.
        if failure == nil, connected == nil, Date() >= deadline, !startDone {
            failure = "handshake timed out"
        }
        let names = backend.models.map(\.name)
        let effort: String?
        if backend.supportsEffort {
            effort = "\(backend.efforts.joined(separator: ", ")) (now: \(backend.currentEffort))"
        } else {
            effort = nil
        }
        // Snapshot before stop(): Codex start() may emit a follow-on failure
        // as in-flight RPCs are resumed with nil.
        let result = HandshakeResult(provider: provider, locatedPath: located,
                                     sessionID: connected, failure: failure,
                                     modelNames: names, effortInfo: effort)
        // stop() must resume any parked RPC. cancel() alone cannot unwind a
        // checked continuation, so join start() after stop rather than leak it.
        backend.stop()
        startTask.cancel()
        await startTask.value
        return result
    }

    static func run() {
        let path = CommandLine.arguments.dropFirst()
            .first { !$0.hasPrefix("--") } ?? FileManager.default.currentDirectoryPath
        let project = URL(fileURLWithPath: path)
        print("Orrery self-test — project: \(project.path)\n")

        // The work runs on the main queue, so the main thread must not block waiting for it.
        Task { @MainActor in
            for provider in Provider.allCases {
                print("── \(provider.displayName)")
                let result = await handshake(provider: provider, project: project)
                guard let located = result.locatedPath else {
                    print("   not installed\n")
                    continue
                }
                print("   binary:  \(located)")
                if let connected = result.sessionID {
                    print("   session: \(connected)")
                } else if let failure = result.failure {
                    print("   FAILED:  \(failure)")
                } else {
                    print("   started, no session id reported yet (normal for Claude until the first turn)")
                }
                let names = result.modelNames.joined(separator: ", ")
                print("   models:  \(names.isEmpty ? "—" : names)")
                if let effort = result.effortInfo {
                    print("   effort:  \(effort)")
                }
                print("")
            }
            print("No prompts were sent; no subscription quota was used.")
            exit(0)
        }
        dispatchMain()
    }
}

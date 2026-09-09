import Foundation
import Observation
import SwiftUI

// MARK: - Transcript

enum EntryKind: String, Codable {
    case user, assistant, thought, tool, plan, system, failure
}

struct ToolDetail: Equatable, Codable {
    var status: String = "pending"
    var kind: String = "other"
    var rawInput: String = ""
    var output: String = ""
    var diffs: [FileDiff] = []
    var locations: [String] = []
}

struct FileDiff: Equatable, Identifiable, Codable {
    var id: String { path }
    var path: String
    var oldText: String
    var newText: String
}

struct Entry: Identifiable, Equatable, Codable {
    let id: String
    var kind: EntryKind
    var text: String = ""
    var title: String = ""
    var tool: ToolDetail? = nil
    var isOpen: Bool = true

    static func == (a: Entry, b: Entry) -> Bool {
        a.id == b.id && a.text == b.text && a.title == b.title
            && a.tool == b.tool && a.isOpen == b.isOpen
    }
}

struct PermissionOption: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String
}

/// Own the callback across queue removal and repeated/stale UI invocations. Optimized Swift
/// can prematurely release a borrowed closure stored in a copied value-type request.
final class PermissionRequest: Identifiable {
    let id: UUID
    let title: String
    let detail: String
    let options: [PermissionOption]
    let questions: [AgentQuestion]
    let answer: (([String: String]) -> Void)?
    let reply: (String?) -> Void

    init(id: UUID = UUID(), title: String, detail: String, options: [PermissionOption],
         questions: [AgentQuestion] = [], answer: (([String: String]) -> Void)? = nil,
         reply: @escaping (String?) -> Void) {
        self.id = id
        self.title = title
        self.detail = detail
        self.options = options
        self.questions = questions
        self.answer = answer
        self.reply = reply
    }
}

struct AgentQuestion: Identifiable {
    let id: String
    let title: String
    var options: [String] = []
    var isSecret = false
}

struct ModelOption: Identifiable, Hashable {
    let id: String
    let name: String
}

struct SessionSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let cwd: String
    let updatedAt: String
}

/// Everything that is per-provider: its own conversation, its own status, its own busy flag.
/// Switching providers in the toolbar does not throw away what the others were doing.
struct ProviderState {
    var entries: [Entry] = []
    var status: String = "Not started"
    /// Grok queues prompts, so more than one turn can be in flight. A boolean would let the first
    /// completion clear the busy state — and hide the Stop button — while work is still running.
    var inFlight = 0
    var isBusy: Bool { inFlight > 0 }
    var isConnected = false
    var sessionID: String?
    /// Whether the current session has content worth resuming: a prompt was sent into it, or a
    /// turn finished in it. A session that only connected is started fresh next time instead of
    /// being resumed, because Claude and Codex have nothing on disk for it yet.
    var sessionUsed = false
    var title: String = "New session"
    var openAssistantID: String?
    var openThoughtID: String?
    var log: [String] = []
    /// Set only when this provider's backend actually emitted a `.models` event.
    /// A constructor-populated catalogue is not a report.
    var hasReportedModels = false
    var lastReportedModels: [ModelOption] = []
    var lastReportedEfforts: [String] = []
    var lastSelectedModel = ""
    var lastSelectedEffort = ""
}

// MARK: - Recent projects

struct RecentProject: Identifiable, Equatable, Hashable {
    let path: String
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

/// Most-recent-first list of projects, persisted separately from `lastProject`.
@MainActor
@Observable
final class RecentProjects {
    static let shared = RecentProjects()
    static let defaultsKey = "recentProjects"
    static let cap = 8

    private let defaults: UserDefaults
    /// Injectable so the audit can record temp directories without writing the user's defaults,
    /// and can still exercise the real scratch-path guard.
    var isScratchPath: (String) -> Bool = { AppModel.isScratchPath($0) }
    private(set) var entries: [RecentProject] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        entries = paths.map { RecentProject(path: $0) }
    }

    func record(_ url: URL) {
        let standardized = url.resolvingSymlinksInPath().standardizedFileURL
        let path = standardized.path
        guard !isScratchPath(url.path), !isScratchPath(path) else { return }
        entries.removeAll { $0.path == path }
        entries.insert(RecentProject(path: path), at: 0)
        if entries.count > Self.cap {
            entries = Array(entries.prefix(Self.cap))
        }
        defaults.set(entries.map(\.path), forKey: Self.defaultsKey)
    }
}

// MARK: - Model

@MainActor
@Observable
final class AppModel {
    /// Headless runs share the app bundle's preference domain when launched from the installed
    /// bundle. They must neither read the user's choices (deterministic checks) nor write them
    /// (an audit once switched the user's selected provider), so they get a private suite that
    /// is wiped at process start. Audits exercise persistence against that suite.
    static let persistsPreferences = !CommandLine.arguments.contains(where: {
        ["--audit", "--probe", "--selftest"].contains($0)
    })
    static let preferences: UserDefaults = {
        let name = "app.orrery.studio.headless"
        guard !persistsPreferences, let suite = UserDefaults(suiteName: name) else { return .standard }
        suite.removePersistentDomain(forName: name)
        return suite
    }()

    // Providers
    var provider: Provider = {
        let saved = preferences.string(forKey: "provider") ?? Provider.grok.rawValue
        return Provider(rawValue: saved) ?? .grok
    }() {
        didSet {
            Self.preferences.set(provider.rawValue, forKey: "provider")
            Task { await startIfNeeded() }
        }
    }
    var states: [Provider: ProviderState] = [:]
    var installed: [Provider: Bool] = [:]

    /// This project's rule: run tools without asking each time. Saved per project.
    var projectAutoApprove = false {
        didSet {
            roundtable.autoApprove = autoApprove
            guard projectAutoApprove != oldValue, !loadingProjectSettings else { return }
            if let projectURL {
                Self.preferences.set(projectAutoApprove, forKey: "studio.automaticTools." + AgentSettingsStore.location(projectURL).lastPathComponent)
            }
            // Under the blanket bypass the effective rule did not change.
            if blanketApproval { return }
            restartForApprovalChange()
        }
    }
    /// The blanket bypass: every project, every mode (Solo, Team, Roundtable Work, the native
    /// CLI) and every computer and browser action, until it is switched off. A global preference,
    /// shared with every other window through a notification.
    var blanketApproval = AppModel.preferences.bool(forKey: AppModel.blanketApprovalKey) {
        didSet {
            roundtable.autoApprove = autoApprove
            browser?.bypassHostRestrictions = blanketApproval
            guard blanketApproval != oldValue else { return }
            Self.preferences.set(blanketApproval, forKey: Self.blanketApprovalKey)
            NotificationCenter.default.post(name: Self.blanketApprovalChanged, object: self, userInfo: ["on": blanketApproval])
            // The blanket also decides the browser, simulator and desktop groups: apply before the
            // sessions restart so they start with the right tools.
            refreshToolGroups()
            if projectAutoApprove { orchestrator.autoApprove = autoApprove; Task { await restartAll() }; return }
            restartForApprovalChange()
        }
    }
    static let blanketApprovalKey = "studio.blanketApproval.v1"
    static let blanketApprovalChanged = Notification.Name("app.orrery.studio.blanketApprovalChanged")
    /// What every agent session actually gets: the blanket bypass, or this project's rule.
    var autoApprove: Bool {
        get { blanketApproval || projectAutoApprove }
        set { projectAutoApprove = newValue }
    }
    private func restartForApprovalChange() {
        // Revoke the old child immediately; a toolbar that says approvals are on must
        // never leave a bypass-permissions child running behind it.
        if orchestrator.isRunning { orchestrator.stop() }
        orchestrator.autoApprove = autoApprove
        stopNativeSessions()
        stopChatSessions()
        Task { await startIfNeeded() }
    }
    /// Other windows share the blanket switch: follow a change made anywhere.
    func observeBlanketApproval() {
        NotificationCenter.default.addObserver(forName: Self.blanketApprovalChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, let on = note.userInfo?["on"] as? Bool, (note.object as AnyObject?) !== self else { return }
            MainActor.assumeIsolated { if self.blanketApproval != on { self.blanketApproval = on } }
        }
    }
    /// After an agent's turn, silently re-read any open tab it changed that you had not edited.
    /// Tabs with unsaved edits are never touched.
    var autoReloadAfterTurns: Bool =
        preferences.object(forKey: "autoReloadAfterTurns") as? Bool ?? true {
        didSet { Self.preferences.set(autoReloadAfterTurns, forKey: "autoReloadAfterTurns") }
    }

    // Workspace
    var projectURL: URL?
    var openProjectInWindow: ((URL) -> Void)?
    var chatAttachments: [Provider: [MessageAttachment]] = [:]
    var chatDrafts: [Provider: String] = [:] { didSet { scheduleTaskSave() } }
    var taskRecords: [TaskRecord] = []
    var activeTaskIDs: [Provider: UUID] = [:]
    var taskQueues: [Provider: [QueuedTaskPrompt]] = [:]
    var queuePaused: Set<Provider> = []
    var taskPreparing: Set<Provider> = []
    var taskWorkspaces: [UUID: TaskWorkspace] = [:]
    var showTaskHistory = false
    var reviewingWorkspace: TaskWorkspace?
    var taskNotice: String?
    var teamWorkspace: TaskWorkspace?
    var teamPreparing = false
    var teamTaskID: UUID?
    var taskMutationBusy = false
    var uiVerification: UIVerificationController?
    var showUIVerification = false
    var showAgentSettings = false
    /// The ⌘K inline edit in progress, if any; the sheet binds to it.
    var inlineEdit: InlineEditSession?
    /// Which Agent settings tab to open next; consumed by the sheet.
    var requestedSettingsSection: String?
    var showNativeOptions = false
    var showSetup = false
    /// Bumped on every plugin/registry reload so menus built from the snapshots re-evaluate.
    var extensionsRevision = 0
    /// Every agent and the user in one thread.
    let roundtable = Roundtable()
    let git = GitRepository()
    /// Replaceable so audits can give it a temporary key folder.
    var remote = AppModel.persistsPreferences ? RemoteControl.shared : RemoteControl()
    var editorSurface: EditorSurface = .browser
    /// True while desktop control is on only because the blanket bypass turned it on.
    var desktopByBlanket = false
    /// One line for a hang report: what this window was doing when the main thread stopped answering.
    var watchdogNote: String {
        "project \(projectURL?.lastPathComponent ?? "none"), mode \(assistantMode), roundtable \(roundtable.isRunning ? "running" : "idle") with \(roundtable.entries.count) entries, layout \(workspaceLayout)"
    }
    /// Providers whose last failure was a login problem (an expired or revoked token, a missing
    /// key). The pane shows a banner with a one-click sign-in until a turn succeeds again.
    var needsSignIn: Set<Provider> = []

    /// The CLIs' own words for "you are signed out", across providers and versions. A recurring
    /// pain in use: Claude Code's OAuth token lasts about eight hours, and once it cannot be
    /// refreshed every turn fails with a 401 until `claude auth login` is run again.
    static func looksLikeAuthFailure(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["oauth", "not logged in", "please run /login", "re-authenticate", "authentication_error", "authentication error",
                "401", "unauthorized", "session expired", "login required", "invalid api key", "no api key", "access token",
                "failed to authenticate", "sign in again", "not authenticated"].contains { lowered.contains($0) }
    }

    /// Runs the provider's own sign-in in the CLI pane (unconfined, so its browser opens).
    func signIn(_ provider: Provider) {
        presetNativeCLI(ProviderAccounts.loginArguments(for: provider), for: provider)
        startNativeCLI()
    }

    func dismissSignIn(_ provider: Provider) { needsSignIn.remove(provider) }
    /// The IDE's browser (Browser pane and browser_* tools), created on first use.
    private(set) var browser: UIVerificationController?
    @ObservationIgnored var historyStore: TaskHistoryStore?
    @ObservationIgnored var historySaveTask: Task<Void, Never>?
    @ObservationIgnored var restoringHistory = false
    @ObservationIgnored var idleStopTasks: [Provider: Task<Void, Never>] = [:]
    /// Seconds a connected session may sit without a turn before its child is released.
    /// The audit shortens it; the app reconnects on the next send.
    static var idleReleaseDelay: Double = 180
    /// The model label each released session was showing, so the toolbar and the Solo header
    /// keep naming the model while the child is gone.
    @ObservationIgnored var idleModelLabels: [Provider: String] = [:]
    /// CLI probes and legacy audit fixtures retain their explicit execution directory.
    /// Workflow audits opt in to exercise exactly the same task coordinator as the UI.
    var taskWorkflowEnabled = !CommandLine.arguments.contains(where: {
        ["--audit", "--probe", "--selftest", "--demo", "--calibrate", "--orchestrate"].contains($0)
    })
    var chatDraft: String {
        get { chatDrafts[provider] ?? "" }
        set { chatDrafts[provider] = newValue }
    }
    var orchestratorDraft = "" { didSet { scheduleTaskSave() } }
    var teamAttachments: [MessageAttachment] = [] { didSet { scheduleTaskSave() } }
    var teamUseExistingPlan = false { didSet { scheduleTaskSave() } }
    var showsSoloAgentControls: Bool { assistantMode == .chat || assistantMode == .cli }
    private let trust: ProjectTrustStore
    private var trustObserverID: UUID?
    private var trustRevision = 0
    var isProjectTrusted: Bool {
        _ = trustRevision
        return projectURL.map { trust.contains($0) } ?? false
    }

    func setProjectTrusted(_ value: Bool) {
        guard let projectURL else { return }
        trust.setTrusted(projectURL, value)
        reloadRegistry()
        if value { ensureStudioTools() } else { computerControl?.stop(); computerControl = nil }
        if value {
            recheckAll()
            Task { await startIfNeeded() }
        }
    }
    var fileTree: FileNode?
    var diffText: String = ""
    /// Open editor tabs. Text lives in each document's storage, not here, so typing does not
    /// push the whole file through SwiftUI on every keystroke.
    let documents = DocumentStore()
    let index = ProjectIndex()
    let search = ProjectSearch()
    let diagnostics = DiagnosticsEngine()
    let lsp = LSPManager()
    let taskRun = TaskRunModel()
    /// The shell in the Terminal pane. Created when first shown, killed on project switch so a
    /// fresh pane always opens in the current project.
    var terminal: TerminalSession?
    /// Orchestrator mode: fresh sessions, never the chat tabs above.
    let orchestrator = Orchestrator()
    /// Whether the right-hand pane shows the orchestrator instead of the chat.
    var workspaceLayout: WorkspaceLayout = .workspace {
        didSet { if workspaceLayout == .editor { editorSurface = .code } }
    }
    var assistantMode: AssistantMode = .chat
    var bottomPaneHeight: CGFloat = 260
    var nativeSessions: [Provider: TerminalSession] = [:]
    var computerControl: ComputerControl?
    var agentSettings: [Provider: AgentSessionSettings] = [:]
    var nativeArguments: [Provider: String] = [:]
    var showOrchestrator: Bool {
        get { assistantMode == .team }
        set { assistantMode = newValue ? .team : .chat }
    }
    /// A one-shot instruction for the editor view (jump to a line, focus the caret).
    var editorRequest: EditorRequest?
    /// Status-line sentence for a failed hover / go-to-definition / completion. Named, never silent.
    var editorNote: String?
    /// Consumed by the editor view to show a completion popup without synthesizing keystrokes.
    var pendingLSPCompletions: [LSPCompletionItem]?
    /// Consumed by the editor view to show a hover card without a mouse dwell.
    var pendingLSPHover: String?
    /// Set when `openLaunchArguments` dispatches `--lsp-probe`, so the audit can await the
    /// same task the flag starts rather than calling `runLSPProbe` itself.
    private(set) var lspProbeTask: Task<String, Never>?
    /// Set when `openLaunchArguments` dispatches `--calibrate`. The audit awaits this
    /// rather than calling `Calibration.handleLaunch` itself.
    private(set) var calibrateTask: Task<String, Never>?
    /// Which auxiliary pane is showing under the editor.
    var bottomPane: BottomPane = .hidden {
        didSet {
            if bottomPane == .browser { showBrowser() }
            else if bottomPane != .hidden {
                editorSurface = .code
                if workspaceLayout == .assistant { workspaceLayout = .workspace }
            }
        }
    }
    var showQuickOpen = false
    var showGoToLine = false
    var showCommandPalette = false
    var showShortcuts = false

    /// A queue, not a single slot: two agents — or one agent asking about two commands — can
    /// have approvals in flight at once, and dropping one hangs that agent forever.
    var permissionQueue: [PermissionRequest] = []
    var pendingPermission: PermissionRequest? { permissionQueue.first }

    /// Shared across windows; injectable so the audit never writes the user's defaults.
    var recentProjects: RecentProjects = .shared
    /// `--demo` overlay so the Projects section is visible with no real history.
    var demoRecentProjects: [RecentProject]?
    /// Set when a recent-project click cannot proceed; the sidebar surfaces it.
    var recentOpenError: String?

    // Not private so the --audit harness can inject a stub backend.
    var backends: [Provider: any AgentBackend] = [:]
    /// `start` is async, so two switches in quick succession can both pass the "not running"
    /// check before either child exists — which leaves an orphaned second process.
    var starting: Set<Provider> = []
    /// Last follow-edits reload per path — at most one reload per file per second.
    private var lastFollowReloadAt: [String: Date] = [:]
    private var slashToken: SlashCommandToken?
    private(set) var isShutDown = false
    var sessionGeneration = UUID()
    @ObservationIgnored private var loadingProjectSettings = false
    private var permissionSources: [UUID: Provider] = [:]
    var cancelTokens: [Provider: UUID] = [:]

    // MARK: Derived

    var state: ProviderState { states[provider] ?? ProviderState() }
    var backend: (any AgentBackend)? { backends[provider] }
    var entries: [Entry] { state.entries }
    var isBusy: Bool { state.isBusy }
    var isConnected: Bool { state.isConnected && !starting.contains(provider) }
    var status: String { state.status }
    var sessionTitle: String { state.title }
    var models: [ModelOption] { backend?.models ?? state.lastReportedModels }
    var availableEfforts: [String] { backend?.efforts ?? state.lastReportedEfforts }
    var selectedEffort: String { backend?.currentEffort ?? state.lastSelectedEffort }
    var knownModelVersions: [ModelOption] { backend?.knownVersions ?? (provider == .claude ? ClaudeBackend.knownVersions : []) }

    /// User-facing phrase when a backend has a catalogue that was never emitted
    /// as a models event. Exact wording is load-bearing for the honesty checks.
    static let unverifiedCatalogPhrase = "unverified catalog"

    /// Model ids each installed provider's connected backend has actually listed
    /// via a `.models` event. A constructor-populated catalogue is not a model
    /// id — it is omitted here rather than encoded as `unverified catalog` or
    /// leaked as the constructor's ids. `catalogIsUnverified` surfaces it.
    func reportedModels(installed: [Provider]) -> [String: [String]] {
        var reported: [String: [String]] = [:]
        for provider in installed {
            guard let backend = backends[provider] else { continue }
            guard states[provider]?.hasReportedModels == true else { continue }
            let ids = backend.models.map(\.id).filter { !$0.isEmpty }
            if !ids.isEmpty { reported[provider.rawValue] = ids }
        }
        return reported
    }

    /// True when this provider has a non-empty constructor catalogue that no
    /// `.models` event has confirmed. Independent of `reportedModels`, which
    /// must only ever contain real model ids.
    func catalogIsUnverified(_ provider: Provider) -> Bool {
        guard let backend = backends[provider] else { return false }
        guard states[provider]?.hasReportedModels != true else { return false }
        return backend.models.contains { !$0.id.isEmpty }
    }

    /// Toolbar title for a provider's model menu. An unverified constructor
    /// catalogue is named in those words rather than as a constructor model.
    func modelToolbarLabel(for provider: Provider) -> String {
        if catalogIsUnverified(provider) {
            return Self.unverifiedCatalogPhrase
        }
        guard let backend = backends[provider] else { return idleModelLabels[provider] ?? Self.savedModelLabel(for: provider) ?? "Model" }
        let name = backend.models.first { $0.id == backend.currentModel }?.name
            ?? backend.currentModel
        guard !name.isEmpty else { return "Model" }
        if backend.supportsEffort, !backend.currentEffort.isEmpty {
            return "\(name) · \(backend.currentEffort)"
        }
        return name
    }
    /// Before any session has started, the model the provider will use: the saved choice, shown
    /// by its known name when the app has one.
    static func savedModelLabel(for provider: Provider) -> String? {
        guard let saved = preferences.string(forKey: provider.rawValue + "Model"), !saved.isEmpty else { return nil }
        let known: [ModelOption] = provider == .claude ? ClaudeBackend.knownVersions : []
        return known.first { $0.id == saved }?.name ?? saved
    }

    /// The toolbar menu belongs to one agent at a time; say which.
    func modelMenuTitle(for provider: Provider) -> String {
        "\(provider.displayName) · \(modelToolbarLabel(for: provider))"
    }
    var currentModel: String { backend?.currentModel ?? state.lastSelectedModel }
    var slashCommands: [String] { SlashCommandStore.shared.names(for: provider) }
    var logLines: [String] { state.log }
    var displayedRecentProjects: [RecentProject] {
        demoRecentProjects ?? recentProjects.entries
    }

    init(trust: ProjectTrustStore? = nil) {
        self.trust = trust ?? .shared
        observeBlanketApproval()
        remote.attach(self)
        if remote.enabled, Self.persistsPreferences { remote.start() }
        documents.onDidSave = { [weak self] document in
            self?.pluginsDidSave(document)
            Task { await self?.git.refresh(reporting: false) }
        }
        installed = [
            .grok: GrokBackend.locate() != nil,
            .claude: ClaudeBackend.locate() != nil,
            .codex: CodexBackend.locate() != nil,
        ]
        trustObserverID = self.trust.observe { [weak self] root, trusted in
            guard let self, !self.isShutDown,
                  self.projectURL?.resolvingSymlinksInPath().standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL
            else { return }
            self.trustRevision += 1
            guard !trusted else { return }
            self.stopChatSessions()
            self.orchestrator.stop()
            self.terminal?.terminate()
            self.terminal = nil
            self.stopNativeSessions()
            self.computerControl?.stop(); self.computerControl = nil
            self.taskRun.stop()
            self.lsp.shutdownAll()
        }
        taskRun.canExecute = { [weak self] in self?.isProjectTrusted == true }
        diagnostics.canExecute = { [weak self] in self?.isProjectTrusted == true }
        taskRun.onFinished = { [weak self] in self?.refreshAfterWork() }
        orchestrator.canExecute = { [weak self] in self?.isProjectTrusted == true }
        orchestrator.makeBackend = { [weak self] provider in
            self?.configuredBackend(provider, forTeam: true) ?? Self.newBackend(provider)
        }
        orchestrator.singleProviderTeam = Self.preferences.bool(forKey: "team.singleProvider.v1")
        orchestrator.persistPreference = { key, value in Self.preferences.set(value, forKey: key) }
        orchestrator.onPermission = { [weak self] request, provider in
            self?.handle(.permission(request), from: provider)
        }
        orchestrator.onPermissionEnded = { [weak self] id in
            self?.permissionQueue.first(where: { $0.id == id })?.reply(nil)
        }
        if installed[provider] != true,
           let fallback = Provider.allCases.first(where: { installed[$0] == true }) {
            provider = fallback
        }
        let id = SlashCommandStore.shared.addSubscriber { [weak self] in
            // Touch a published property so the composer picks up new commands.
            guard let self else { return }
            self.states[self.provider] = self.states[self.provider] ?? ProviderState()
        }
        slashToken = SlashCommandToken(id: id)
        // Orchestrator sessions edit files outside the chat pipeline, so they trigger the same
        // refresh a chat turn does — clean tabs reload, dirty tabs get the changed-on-disk flag.
        orchestrator.onWorkSettled = { [weak self] in
            self?.refreshAfterWork()
            self?.saveTeamProgress()
        }
        orchestrator.onFileEdited = { [weak self] path in
            self?.followOrchestratorEdit(path)
        }
        documents.onWillClose = { [weak self] document in
            guard let self else { return }
            self.lsp.didClose(document)
            self.diagnostics.clear(document.url)
        }
        documents.onReloaded = { [weak self] document in
            self?.syncAfterReload(document)
        }
        diagnostics.languageServerNote = { [weak self] language in
            self?.lsp.unavailableNote(for: language)
        }
        lsp.onDiagnostics = { [weak self] url, found in
            guard let self, let document = self.documents.document(for: url) else { return }
            self.diagnostics.applyLSPDiagnostics(found, for: document)
        }
        lsp.onCoverageChange = { [weak self] url, server in
            self?.diagnostics.setLiveCoverage(url, server: server)
        }
        lsp.onFailureNote = { [weak self] url, message in
            guard let self else { return }
            let document = self.documents.document(for: url)
            self.diagnostics.noteLSPFailure(for: url, message: message, document: document)
            if let document {
                Task { await self.diagnostics.check(document) }
            }
        }
    }

    /// Open the file the author just edited and reload it from disk. A dirty tab is never
    /// reloaded and never has its content replaced; if the active tab is dirty the edited
    /// file opens without taking focus. At most one reload per file per second.
    private func followOrchestratorEdit(_ path: String) {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let activeIsDirty = documents.active?.isDirty == true
        if let existing = documents.document(for: url), existing.isDirty {
            if !activeIsDirty { _ = documents.open(url, activate: true) }
            return
        }
        _ = documents.open(url, activate: !activeIsDirty)
        guard let document = documents.document(for: url), !document.isDirty else { return }
        let key = url.path
        let now = Date()
        if let last = lastFollowReloadAt[key], now.timeIntervalSince(last) < 1 { return }
        lastFollowReloadAt[key] = now
        document.reload()
        syncAfterReload(document)
    }

    /// Paths that must never be remembered as the project.
    static func isScratchPath(_ path: String) -> Bool {
        path.hasPrefix(NSTemporaryDirectory()) || path.hasPrefix("/private/var/folders")
            || path.hasPrefix("/private/tmp") || path.hasPrefix("/tmp")
    }

    static var lastProject: URL? {
        get {
            guard let path = preferences.string(forKey: "lastProject"),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set { preferences.set(newValue?.path, forKey: "lastProject") }
    }

    // MARK: Lifecycle

    static func newBackend(_ provider: Provider) -> any AgentBackend {
        switch provider {
        case .grok: return GrokBackend()
        case .claude: return ClaudeBackend()
        case .codex: return CodexBackend()
        }
    }

    /// This project's settings for one agent, stamped with the agent they belong to so the
    /// shared connectors reach the right sessions. Every path that starts something for an
    /// agent — a chat backend, the Team, the native CLI pane — goes through here.
    func sessionSettings(for provider: Provider) -> AgentSessionSettings {
        var settings = agentSettings[provider] ?? AgentSessionSettings()
        settings.connectorProvider = provider
        let guidance = NativeComputerControl.guidance(for: provider, preferred: settings.nativeComputerControl)
        settings.instructions = [settings.instructions, guidance].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return settings
    }

    func configuredBackend(_ provider: Provider, forTeam: Bool = false) -> any AgentBackend {
        if computerControl?.isEnabled != true { ensureStudioTools() }
        let backend = Self.newBackend(provider)
        backend.persistsSelection = Self.persistsPreferences
        backend.computerConnection = computerControl.flatMap { $0.isEnabled ? $0.connection(for: provider) : nil }
        var settings = sessionSettings(for: provider)
        if !forTeam, let id = activeTaskIDs[provider],
           let record = taskRecords.first(where: { $0.id == id }) {
            settings.resumeSession = Self.isResumableSession(record.sessionID) ? (record.sessionID ?? "") : ""
        }
        if forTeam {
            // Team owns fresh conversations, its role models, planning and response formats.
            // Execution restrictions, instructions, plugins and MCP still follow this project.
            settings.resumeSession = ""
            settings.model = ""; settings.effort = ""
            settings.planMode = false; settings.outputSchema = ""
        }
        backend.sessionSettings = settings
        backend.preconfigure(model: settings.model.isEmpty ? nil : settings.model,
                             effort: settings.effort.isEmpty ? nil : settings.effort)
        return backend
    }

    /// A backend for a single detached turn (the ⌘K inline edit): the project's execution
    /// boundary, instructions, model and effort, but never the Solo task's session — resuming it
    /// from a second process would splice the edit into that conversation's history.
    func makeOneShotBackend(_ provider: Provider) -> any AgentBackend {
        let backend = configuredBackend(provider)
        var settings = backend.sessionSettings
        settings.resumeSession = ""; settings.planMode = false; settings.outputSchema = ""
        backend.sessionSettings = settings
        return backend
    }

    func makeBackend(_ provider: Provider) -> any AgentBackend {
        let backend = configuredBackend(provider)
        let generation = sessionGeneration
        let taskID = activeTaskIDs[provider]
        backend.onEvent = { [weak self] event in
            guard let self, self.sessionGeneration == generation, !self.isShutDown,
                  self.activeTaskIDs[provider] == taskID else { return }
            self.handle(event, from: provider)
        }
        return backend
    }

    func startIfNeeded() async {
        guard !isShutDown, let projectURL else { return }
        let requestedProvider = provider
        guard await restoreTaskWorkspace(for: requestedProvider), requestedProvider == provider, !isShutDown else { return }
        guard isProjectTrusted else {
            update { $0.status = "Restricted project — trust to enable agents" }
            return
        }
        guard installed[provider] == true else {
            update { $0.status = "\(provider.displayName) CLI not found" }
            return
        }
        if backends[provider] == nil { backends[provider] = makeBackend(provider) }
        if isShutDown {
            backends[provider]?.stop()
            backends.removeValue(forKey: provider)
            return
        }
        guard let backend = backends[provider], !backend.isRunning else { return }
        let target = provider
        let generation = sessionGeneration
        guard !starting.contains(target) else { return }
        starting.insert(target)
        defer { if generation == sessionGeneration { starting.remove(target) } }
        trimConnectionBookkeeping(for: target)
        update { $0.status = "Starting…" }
        await backend.start(project: executionRoot(for: target) ?? projectURL, autoApprove: autoApprove)
        if isShutDown || generation != sessionGeneration {
            backend.stop()
        }
    }

    func newSession() async {
        if historyStore != nil { await createTask(); return }
        guard !isShutDown, isProjectTrusted else { return }
        guard let backend = backends[provider] else { await startIfNeeded(); return }
        guard !starting.contains(provider) else { return }
        cancelTokens[provider] = nil
        cancelPermissions(from: provider)
        backend.stop()
        update {
            $0 = ProviderState()
            $0.status = "Starting…"
        }
        guard !isShutDown, let projectURL else { return }
        let target = provider
        let generation = sessionGeneration
        starting.insert(target)
        defer { if generation == sessionGeneration { starting.remove(target) } }
        await backend.start(project: projectURL, autoApprove: autoApprove)
        if isShutDown || generation != sessionGeneration {
            backend.stop()
        }
    }

    func restartAll() async {
        guard !isShutDown else { return }
        roundtable.refreshToolsForNextTurn()
        stopChatSessions()
        await startIfNeeded()
    }

    private func stopChatSessions() {
        saveTaskHistoryNow()
        sessionGeneration = UUID()
        cancelTokens.removeAll()
        starting.removeAll()
        cancelPermissions()
        for (_, backend) in backends { backend.onEvent = nil }
        for (_, backend) in backends { backend.stop() }
        backends.removeAll()
        for key in states.keys {
            if historyStore == nil { states[key] = ProviderState() }
            else {
                states[key]?.isConnected = false
                states[key]?.inFlight = 0
                states[key]?.status = "Stopped — history saved"
                queuePaused.insert(key)
            }
        }
    }

    /// Kill every child this window started. Closing the window must call this — AppModel
    /// deinit does not run `AgentBackend.stop()`, so a Grok/Claude/Codex CLI would otherwise
    /// outlive the window with nobody left to reap it.
    func shutdown() {
        remote.detach(self)
        guard !isShutDown else { return }
        roundtable.stop()
        saveTaskHistoryNow()
        documents.flushRecoveryNow()
        historySaveTask?.cancel(); historySaveTask = nil
        for task in idleStopTasks.values { task.cancel() }; idleStopTasks = [:]
        isShutDown = true
        if let trustObserverID { trust.removeObserver(trustObserverID); self.trustObserverID = nil }
        cancelPermissions()
        for (_, backend) in backends { backend.stop() }
        backends.removeAll()
        orchestrator.stop()
        terminal?.terminate()
        terminal = nil
        stopNativeSessions()
        computerControl?.stop(); computerControl = nil
        uiVerification?.stop(); uiVerification = nil
        taskRun.stop()
        lsp.shutdownAll()
        if let slashToken {
            SlashCommandStore.shared.removeSubscriber(slashToken.id)
            self.slashToken = nil
        }
        search.cancel()
        index.cancel()
    }

    func send(_ text: String, attachments: [MessageAttachment] = []) async {
        await sendToProvider(text, attachments: attachments, target: provider)
    }

    func sendToProvider(_ text: String, attachments: [MessageAttachment] = [], target: Provider) async {
        guard !isShutDown, isProjectTrusted, !taskMutationBusy else { return }
        guard !starting.contains(target), !taskPreparing.contains(target) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if historyStore != nil, states[target]?.isBusy == true {
            enqueuePrompt(trimmed, attachments: attachments, for: target)
            return
        }
        guard await prepareTaskWorkspace(for: target) else { return }
        guard let backend = backends[target], backend.isRunning else {
            append(.failure, "\(target.displayName) is not connected.", to: target)
            return
        }
        idleStopTasks.removeValue(forKey: target)?.cancel()
        append(.user, trimmed + (attachments.isEmpty ? "" : "\n\nAttached: " + attachments.map(\.name).joined(separator: ", ")), to: target)
        update(target) {
            $0.inFlight += 1
            if Self.isResumableSession($0.sessionID) { $0.sessionUsed = true }
            $0.openAssistantID = nil
            $0.openThoughtID = nil
        }
        saveTaskHistoryNow()
        await backend.send(trimmed, attachments: attachments)
    }

    /// Ask the agent to stop, then guarantee the UI recovers.
    ///
    /// A turn can end without any completion event — the CLI is killed, a pipe breaks, a protocol
    /// message is dropped. Without this the window sits on "Working…" with no way out but a new
    /// session, so after a grace period the turn is ended locally.
    func cancel() {
        let target = provider
        queuePaused.insert(target)
        let cancelToken = UUID()
        cancelTokens[target] = cancelToken
        let generation = sessionGeneration
        let cancelledBackend = backends[target]
        cancelPermissions(from: target)
        backends[target]?.cancel()
        append(.system, "Cancel requested")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.cancelGraceSeconds * 1_000_000_000))
            guard let self, self.sessionGeneration == generation,
                  self.cancelTokens[target] == cancelToken,
                  self.states[target]?.isBusy == true else { return }
            cancelledBackend?.stop()
            self.update(target) {
                $0.inFlight = 0
                for index in $0.entries.indices where $0.entries[index].isOpen {
                    $0.entries[index].isOpen = false
                }
                $0.openAssistantID = nil
                $0.openThoughtID = nil
            }
            self.append(.system,
                        "The agent did not acknowledge Stop, so its session was stopped. ⌘N starts a clean session.",
                        to: target)
        }
    }

    /// Overridable so the audit can exercise the recovery path without a real wait.
    static var cancelGraceSeconds: Double = 5

    func setModel(_ id: String) async {
        guard states[provider]?.isBusy != true else { append(.system, "Stop the current turn before changing models.", to: provider); return }
        let target = provider, generation = sessionGeneration
        guard !starting.contains(target) else { return }
        if backends[target] == nil { saveIdleSelection(model: id, effort: nil); return }
        starting.insert(target)
        defer { if generation == sessionGeneration { starting.remove(target) } }
        await backends[target]?.setModel(id)
    }

    func setEffort(_ effort: String) async {
        guard states[provider]?.isBusy != true else { append(.system, "Stop the current turn before changing effort.", to: provider); return }
        let target = provider, generation = sessionGeneration
        guard !starting.contains(target) else { return }
        if backends[target] == nil { saveIdleSelection(model: nil, effort: effort); return }
        starting.insert(target)
        defer { if generation == sessionGeneration { starting.remove(target) } }
        await backends[target]?.setEffort(effort)
    }

    private func saveIdleSelection(model id: String?, effort: String?) {
        guard let projectURL else { return }
        var updated = agentSettings
        var settings = updated[provider] ?? AgentSessionSettings()
        if let id { settings.model = id }
        if let effort { settings.effort = effort }
        do {
            try settings.validate()
            updated[provider] = settings
            try AgentSettingsStore.save(updated, project: projectURL)
            agentSettings = updated
            update(provider) { state in
                if let id { state.lastSelectedModel = id }
                if let effort { state.lastSelectedEffort = effort }
            }
            let name = models.first { $0.id == currentModel }?.name ?? currentModel
            idleModelLabels[provider] = name + (selectedEffort.isEmpty ? "" : " · " + selectedEffort)
        } catch { taskNotice = "Could not save the next session's selection: \(error.localizedDescription)" }
    }

    // MARK: Events

    /// Test seam for `--audit`; production code routes events through the backend closure.
    func handleForTest(_ event: BackendEvent, from source: Provider) { handle(event, from: source) }

    func requestComputerPermission(_ request: PermissionRequest, provider: Provider) {
        handle(.permission(request), from: provider)
    }

    // Not private so the --audit harness can drive the connected path directly.
    func handle(_ event: BackendEvent, from source: Provider) {
        switch event {
        case let .status(text):
            if text.contains("% of window used") { UsageLedger.shared.record(quota: source, text: text) }
            update(source) { $0.status = text }

        case let .disconnected(reason):
            cancelPermissions(from: source)
            update(source) {
                $0.isConnected = false
                $0.inFlight = 0
                $0.status = reason
                // Claude uses sessionID "pending" until system/init. A models
                // event that arrived before that is not a confirmed catalog —
                // a child that exits during initialization must not leave
                // constructor IDs trusted and eligible.
                if $0.sessionID == "pending" {
                    $0.hasReportedModels = false
                }
            }

        case let .connected(sessionID):
            update(source) {
                $0.isConnected = true
                $0.status = "Connected"
                // Claude reports "ready" before a resumed conversation's init names the session
                // again; a placeholder never replaces a real, resumable id.
                if Self.isResumableSession(sessionID) {
                    // A new real id counts as used only when a turn is running in it right now
                    // (Claude names a fresh session at its first turn's init).
                    if sessionID != $0.sessionID { $0.sessionUsed = $0.inFlight > 0 }
                    $0.sessionID = sessionID
                } else if !Self.isResumableSession($0.sessionID) {
                    $0.sessionID = sessionID
                }
            }
            if sessionID != "pending" {
                append(.system, "Session \(sessionID.prefix(8)) · \(source.displayName)", to: source)
            }
            // A session opened by selecting a tab and never used is a child holding memory for
            // nothing; release it on the same clock as one that finished a turn.
            scheduleIdleRelease(for: source, after: Self.idleReleaseDelay)

        case let .assistantDelta(text):
            stream(text, kind: .assistant, in: source)

        case let .thoughtDelta(text):
            stream(text, kind: .thought, in: source)

        case let .toolStarted(id, title, kind, input):
            var detail = ToolDetail()
            detail.kind = kind
            // A write or patch tool can carry an entire file as its argument. Output was already
            // capped; input needs the same, or one call can put megabytes in the transcript.
            detail.rawInput = input.count > 8_000
                ? String(input.prefix(8_000)) + "\n… (\(input.count - 8_000) more characters)"
                : input
            update(source) {
                $0.openAssistantID = nil
                $0.openThoughtID = nil
                if let index = $0.entries.lastIndex(where: { $0.id == id }) {
                    $0.entries[index].title = title
                } else {
                    $0.entries.append(Entry(id: id, kind: .tool, title: title,
                                            tool: detail))
                }
            }

        case let .toolUpdated(id, status, output, diff):
            update(source) {
                guard let index = $0.entries.lastIndex(where: { $0.id == id }) else { return }
                var detail = $0.entries[index].tool ?? ToolDetail()
                if let status { detail.status = status }
                if let output, !output.isEmpty {
                    detail.output += (detail.output.isEmpty ? "" : "\n") + output
                    if detail.output.count > 20_000 {
                        detail.output = String(detail.output.suffix(20_000))
                    }
                }
                if let diff {
                    if let existing = detail.diffs.firstIndex(where: { $0.path == diff.path }) {
                        detail.diffs[existing] = diff
                    } else {
                        detail.diffs.append(diff)
                    }
                }
                $0.entries[index].tool = detail
            }

        case let .plan(steps):
            update(source) {
                let text = steps.joined(separator: "\n")
                if let index = $0.entries.lastIndex(where: { $0.kind == .plan }), $0.entries[index].isOpen {
                    $0.entries[index].text = text
                } else {
                    $0.entries.append(Entry(id: UUID().uuidString, kind: .plan, text: text,
                                            title: "Plan"))
                }
            }

        case let .models(options, current):
            // Keep reported choices available after idle processes are released. This cache
            // is scoped to this project/provider and is labelled as last reported in the UI.
            let efforts = backends[source]?.efforts ?? []
            let effort = backends[source]?.currentEffort ?? ""
            let selected = current ?? backends[source]?.currentModel ?? ""
            update(source) {
                $0.hasReportedModels = true
                $0.lastReportedModels = options
                $0.lastSelectedModel = selected
                $0.lastReportedEfforts = efforts
                $0.lastSelectedEffort = effort
            }

        case let .permission(request):
            let requestID = request.id
            let queued = PermissionRequest(
                id: requestID, title: "\(source.displayName): \(request.title)",
                detail: request.detail, options: request.options,
                questions: request.questions,
                answer: request.answer.map { callback in { [weak self] answers in
                    guard let self, let index = self.permissionQueue.firstIndex(where: { $0.id == requestID }),
                          request.questions.allSatisfy({ !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    else { return }
                    let pending = self.permissionQueue.remove(at: index)
                    // The queued request owns this closure. Optimized Swift may borrow the
                    // callback when invoking it, so retain its owner through the entire reply.
                    withExtendedLifetime(pending) {
                        self.permissionSources.removeValue(forKey: requestID)
                        callback(answers.filter { key, _ in request.questions.contains { $0.id == key } })
                    }
                } },
                reply: { [weak self] choice in
                    guard let self,
                          let index = self.permissionQueue.firstIndex(where: { $0.id == requestID })
                    else { return }
                    let pending = self.permissionQueue.remove(at: index)
                    withExtendedLifetime(pending) {
                        self.permissionSources.removeValue(forKey: requestID)
                        let valid = choice.flatMap { id in request.options.contains { $0.id == id } ? id : nil }
                        request.reply(valid)
                    }
                })
            permissionQueue.append(queued)
            permissionSources[requestID] = source
            remote.noteChange(); MainThreadWatchdog.shared.note(watchdogNote)

        case let .turnFinished(stopReason, cost):
            UsageLedger.shared.record(turn: source, costUSD: cost)
            if states[source]?.entries.last?.kind != .failure { needsSignIn.remove(source) }
            let wasCancelled = cancelTokens[source] != nil
            update(source) {
                $0.inFlight = max(0, $0.inFlight - 1)
                if Self.isResumableSession($0.sessionID) { $0.sessionUsed = true }
                for index in $0.entries.indices where $0.entries[index].isOpen {
                    $0.entries[index].isOpen = false
                }
                $0.openAssistantID = nil
                $0.openThoughtID = nil
            }
            if states[source]?.isBusy != true { cancelTokens[source] = nil }
            if let stopReason, !["end_turn", "completed", "success", "stop"].contains(stopReason) {
                append(.system, "Turn ended: \(stopReason)", to: source)
            }
            if let cost, cost > 0 {
                append(.system, String(format: "Cost: $%.4f", cost), to: source)
            }
            // The agent most likely just edited something. Without this the stale-file banner
            // and the Diff tab only refresh when the user happens to switch tabs.
            refreshAfterWork()
            settleTask(for: source, continueQueue: !wasCancelled && (stopReason == nil || ["end_turn", "completed", "success", "stop"].contains(stopReason!)))

        case let .failure(message):
            queuePaused.insert(source)
            append(.failure, message, to: source)
            if Self.looksLikeAuthFailure(message) {
                needsSignIn.insert(source)
                // A session that answered 401 is not worth resuming: the next start is fresh.
                update(source) { $0.sessionID = nil; $0.sessionUsed = false }
            }

        case let .note(text):
            if text.hasPrefix("Codex usage:") || text.hasPrefix("Rate limit:") { UsageLedger.shared.record(quota: source, text: text) }
            append(.system, text, to: source)
            if text.contains("could not be resumed"), Self.looksLikeAuthFailure(text) { needsSignIn.insert(source) }

        case .sessionDropped:
            update(source) { $0.sessionID = nil; $0.sessionUsed = false }

        case let .log(text):
            update(source) {
                $0.log.append(text)
                if $0.log.count > 500 { $0.log.removeFirst($0.log.count - 500) }
            }
        }
    }

    func cancelPermissions(from source: Provider? = nil) {
        let victims = permissionQueue.filter { source == nil || permissionSources[$0.id] == source }
        for request in victims { request.reply(nil) }
        let ids = Set(victims.map(\.id))
        permissionQueue.removeAll { ids.contains($0.id) }
        for id in ids { permissionSources.removeValue(forKey: id) }
    }

    // MARK: Transcript helpers

    /// Backends report "pending" (Claude before its init) and "ready" (a fresh Claude session
    /// that has not run a turn, so no conversation exists on disk yet). Neither can be resumed,
    /// and saving one would make every later launch retry a resume that cannot succeed.
    static func isResumableSession(_ id: String?) -> Bool {
        guard let id, !id.isEmpty else { return false }
        return id != "pending" && id != "ready"
    }

    /// Entries a connection writes about itself: the session header, the permission note and a
    /// failed-resume note. A new connection replaces the previous connection's trailing ones
    /// instead of stacking them, so a task opened daily does not fill with headers.
    static func isConnectionBookkeeping(_ entry: Entry) -> Bool {
        guard entry.kind == .system else { return false }
        return (entry.text.hasPrefix("Session ") && entry.text.contains(" · "))
            || entry.text.contains("could not be resumed")
            || entry.text.contains("uses its default permission rules")
            || entry.text.hasPrefix("Codex usage:") || entry.text.hasPrefix("Rate limit:")
    }

    func trimConnectionBookkeeping(for provider: Provider) {
        guard let last = states[provider]?.entries.last, Self.isConnectionBookkeeping(last) else { return }
        update(provider) {
            while let tail = $0.entries.last, Self.isConnectionBookkeeping(tail) { $0.entries.removeLast() }
        }
    }

    func update(_ provider: Provider? = nil, _ change: (inout ProviderState) -> Void) {
        let key = provider ?? self.provider
        var current = states[key] ?? ProviderState()
        change(&current)
        if current.entries.count > 1_500 { current.entries.removeFirst(current.entries.count - 1_500) }
        states[key] = current
        scheduleTaskSave()
        remote.noteChange(); MainThreadWatchdog.shared.note(watchdogNote)
    }

    /// Which provider a queued permission request came from (the remote shows it).
    func permissionProvider(for id: UUID) -> Provider? { permissionSources[id] }

    private func stream(_ text: String, kind: EntryKind, in source: Provider) {
        guard !text.isEmpty else { return }
        update(source) {
            let openID = kind == .assistant ? $0.openAssistantID : $0.openThoughtID
            if let openID, let index = $0.entries.lastIndex(where: { $0.id == openID }) {
                $0.entries[index].text += text
                return
            }
            let id = UUID().uuidString
            if kind == .assistant {
                $0.openAssistantID = id
                $0.openThoughtID = nil
            } else {
                $0.openThoughtID = id
                $0.openAssistantID = nil
            }
            $0.entries.append(Entry(id: id, kind: kind, text: text,
                                    title: kind == .thought ? "Thinking" : ""))
        }
    }

    func append(_ kind: EntryKind, _ text: String, to source: Provider? = nil) {
        update(source) {
            $0.entries.append(Entry(id: UUID().uuidString, kind: kind, text: text))
            $0.openAssistantID = nil
            $0.openThoughtID = nil
        }
    }

    /// Visual-inspection fixture; see `--demo`.
    func seedDemoTranscript() {
        var tool = ToolDetail()
        tool.kind = "edit"; tool.status = "completed"
        tool.rawInput = #"{"target_file":"src/parser.swift","instructions":"tighten the guard"}"#
        tool.diffs = [FileDiff(path: "src/parser.swift",
                               oldText: "if tokens.count > 0 {\n    return tokens.first!\n}",
                               newText: "guard let first = tokens.first else { return nil }\nreturn first")]
        var shell = ToolDetail()
        shell.kind = "execute"; shell.status = "failed"
        shell.rawInput = #"{"command":"swift test"}"#
        shell.output = "Compiling Orrery\nerror: cannot find 'parseToken' in scope\n1 error generated."

        var state = ProviderState()
        state.status = "Preview — no agent running"
        state.title = "Tighten the parser guard"
        state.entries = [
            Entry(id: "s", kind: .system, text: "Session 01a053d6 · Grok", isOpen: false),
            Entry(id: "u", kind: .user, text: "Tighten the guard in parser.swift and run the tests.",
                  isOpen: false),
            Entry(id: "t", kind: .thought, text: "The force unwrap after a count check is the usual "
                  + "shape. A guard-let says the same thing without the trap.",
                  title: "Thinking", isOpen: false),
            Entry(id: "p", kind: .plan, text: "✓ Read parser.swift\n→ Replace the count check\n• Run tests",
                  title: "Plan", isOpen: false),
            Entry(id: "a1", kind: .assistant,
                  text: "Replacing the count-then-force-unwrap with a guard:", isOpen: false),
            Entry(id: "e", kind: .tool, title: "search_replace · parser.swift", tool: tool,
                  isOpen: false),
            Entry(id: "a2", kind: .assistant,
                  text: "Now running the suite:\n\n```bash\nswift test\n```", isOpen: false),
            Entry(id: "b", kind: .tool, title: "bash · swift test", tool: shell,
                  isOpen: false),
            Entry(id: "f", kind: .failure,
                  text: "swift test exited 1 — `parseToken` is not in scope.", isOpen: false),
        ]
        states[.grok] = state
        if CommandLine.arguments.contains("--demo-permission") {
            permissionQueue = [PermissionRequest(
                title: "Execute `chmod 700 /tmp/wiring-dir`",
                detail: "chmod 700 /tmp/wiring-dir\n\nGrok wants to change permissions on a directory.",
                options: [
                    PermissionOption(id: "always-allow",
                                     name: "Yes, and don't ask again for bash commands",
                                     kind: "allow_always"),
                    PermissionOption(id: "allow-once", name: "Yes, proceed", kind: "allow_once"),
                    PermissionOption(id: "reject-once",
                                     name: "No, and tell Grok what to do differently",
                                     kind: "reject_once"),
                    PermissionOption(id: "reject-always",
                                     name: "No, and don't ask again for this command",
                                     kind: "reject_always"),
                ],
                reply: { _ in })]
        }
        // Show the editor with real content too, not just its empty state.
        if let project = projectURL ?? AppModel.lastProject {
            let readme = project.appendingPathComponent("README.md")
            if FileManager.default.fileExists(atPath: readme.path) { open(file: readme) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        demoRecentProjects = [
            RecentProject(path: home),
            RecentProject(path: "/Applications"),
            RecentProject(path: "/Users/Shared/Orrery-Missing-Project"),
        ]
    }


    // MARK: Files

    @discardableResult
    func openProject(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            recentOpenError = "The project folder is unavailable."
            return false
        }
        guard documents.closeAll() else { return false }
        saveTaskHistoryNow()
        stopChatSessions()
        orchestrator.stop()
        taskRun.stop()
        // Never remember a scratch directory as "the project" — the audit harness opens one, and
        // a deleted temp path as your saved project is a confusing thing to come back to.
        // (/private/tmp was missing from this list once; a demo project vanished with it and
        // took the user's "last project" along.)
        recentProjects.record(url)
        if !AppModel.isScratchPath(url.path) {
            AppModel.lastProject = url
        }
        projectURL = url
        configureTaskHistory(project: url)
        agentSettings = AgentSettingsStore.load(url)
        reloadRegistry()
        attachRoundtable()
        browser?.stop(); browser = nil
        git.attach(project: url)
        ensureStudioTools()
        // Restoration is configuration, not a request to launch an agent. Window preparation
        // owns startup, after SwiftUI has retained this model for a real project tab.
        loadingProjectSettings = true
        projectAutoApprove = Self.preferences.bool(forKey: "studio.automaticTools." + AgentSettingsStore.location(url).lastPathComponent)
        orchestrator.autoApprove = autoApprove
        loadingProjectSettings = false
        fileTree = FileNode(url: url)
        lsp.shutdownAll()
        diffText = ""
        search.clear()
        index.scan(root: url)
        // The old project's shell would sit in the wrong directory; a fresh pane starts here.
        terminal?.terminate()
        terminal = nil
        stopNativeSessions()
        computerControl?.stop(); computerControl = nil
        // IDE and preview tools come up with the project; desktop tools wait for the grant.
        ensureStudioTools()
        taskRun.refreshTasks(project: url, activeFile: nil, language: nil)
        return true
    }

    /// Switch this window to a recent project — same path as the folder picker, including
    /// restarting agent sessions. A missing folder is named, not crashed through.
    func openRecent(_ entry: RecentProject) {
        let url = entry.url
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            recentOpenError = "The folder “\(entry.name)” is no longer there."
            return
        }
        guard isDirectory.boolValue else {
            recentOpenError = "“\(entry.name)” is not a folder."
            return
        }
        if let openProjectInWindow { openProjectInWindow(url); return }
        guard openProject(url) else { return }
        Task { await restartAll() }
    }

    /// Show the Terminal pane, starting the shell on first use.
    func showTerminal() {
        guard isProjectTrusted else { editorNote = "Trust this project to start its terminal."; return }
        bottomPane = .terminal
        if terminal == nil {
            terminal = TerminalSession(
                directory: projectURL ?? FileManager.default.homeDirectoryForCurrentUser)
            terminal?.start()
        }
    }

    /// ⌘R / ⌘⇧B / ⌘U: run the project's own idea of run, build, or test.
    func runTask(kind: RunTask.Kind) {
        taskRun.refreshTasks(project: projectURL, activeFile: activeDocument?.url,
                             language: activeDocument?.language)
        if let task = taskRun.defaultTask(kind) { runTask(task) }
        else { bottomPane = .output; taskRun.reportNoTask(kind, project: projectURL) }
    }

    func runTask(_ task: RunTask) {
        guard !taskMutationBusy else { taskNotice = "Wait for the file operation to finish."; return }
        guard isProjectTrusted else { editorNote = "Trust this project before running tasks."; return }
        _ = documents.saveAll()
        guard !documents.hasUnsavedChanges else {
            documents.notice = "Save or resolve the conflicting files before running a task."
            return
        }
        bottomPane = .output
        taskRun.run(task)
    }

    func open(file url: URL) {
        guard let document = documents.open(url) else { return }
        showCode()
        refreshDiff()
        prepareChecking(document)
    }

    /// Open a file and put the caret on a specific line — used by search results, diagnostics
    /// and the orchestrator's review findings.
    func open(file url: URL, atLine line: Int, column: Int = 1) {
        guard let document = documents.open(url) else { return }
        showCode()
        refreshDiff()
        prepareChecking(document)
        if let range = document.decorator.range(ofLine: line) {
            let offset = min(range.location + max(0, column - 1),
                             range.location + range.length)
            editorRequest = .select(NSRange(location: offset, length: 0))
        } else {
            editorRequest = .goToLine(line)
        }
    }

    func open(file url: URL, selecting range: NSRange) {
        guard let document = documents.open(url) else { return }
        showCode()
        refreshDiff()
        prepareChecking(document)
        editorRequest = .select(range)
    }

    /// ⌃⌘J and the Navigate menu. Uses the active tab's caret. Missing / timed-out / errored
    /// lookups are named in `editorNote`; a hit navigates, including across files.
    func jumpToDefinition() async {
        guard let document = documents.active else {
            editorNote = "No file open to jump from."
            return
        }
        await jumpToDefinition(in: document, line: document.caretLine, column: document.caretColumn)
    }

    func jumpToDefinition(in document: CodeDocument, line: Int, column: Int) async {
        guard isProjectTrusted else { editorNote = "Trust this project to enable language tools."; return }
        let result = await lsp.definition(for: document, line: line, column: column)
        switch result.outcome {
        case .success:
            if let location = result.value {
                editorNote = nil
                open(file: location.url, atLine: location.line, column: location.column)
            } else {
                editorNote = "No definition at line \(line), column \(column)."
            }
        case .noServer:
            editorNote = result.note ?? "No language server wired."
        case .timedOut:
            editorNote = result.note ?? "Go to definition timed out."
        case .error:
            editorNote = result.note ?? "Go to definition failed."
        }
    }

    func runLSPProbe(_ spec: String) async -> String {
        switch LSPProbe.parse(spec) {
        case let .failure(error):
            return Self.probePrint("lsp-probe error: \(error.message)")
        case let .success(parsed):
            guard isProjectTrusted else { return Self.probePrint("lsp-probe error: project is not trusted") }
            let url = LSPProbe.resolve(parsed.path, project: projectURL)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return Self.probePrint("lsp-probe error: file not found: \(url.path)")
            }
            let root = LSPProbe.projectRoot(for: url)
            if projectURL == nil || !(url.path.hasPrefix((projectURL?.path ?? "") + "/")
                                      || url.path == projectURL?.path) {
                openProject(root)
            }
            open(file: url, atLine: parsed.line, column: parsed.column)
            guard let document = documents.document(for: url) ?? documents.active else {
                return Self.probePrint("lsp-probe error: could not open \(url.path)")
            }
            if let projectURL {
                await lsp.ensureOpen(document, root: projectURL)
            }
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline, lsp.initializeResult(for: document) == nil {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            var result = await lsp.completions(for: document, line: parsed.line, column: parsed.column)
            // sourcekit-lsp often handshakes before it can complete; an empty success is
            // retried so the probe does not print a clean miss while the index is still cold.
            if result.outcome == .success && result.value.isEmpty {
                let until = Date().addingTimeInterval(15)
                while Date() < until && result.outcome == .success && result.value.isEmpty {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    result = await lsp.completions(for: document, line: parsed.line, column: parsed.column)
                }
            }
            if result.outcome == .success, !result.value.isEmpty {
                pendingLSPCompletions = result.value
            }
            var hover = await lsp.hover(for: document, line: parsed.line, column: parsed.column)
            if hover.outcome == .success && (hover.value ?? "").isEmpty {
                let until = Date().addingTimeInterval(8)
                while Date() < until && hover.outcome == .success && (hover.value ?? "").isEmpty {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    hover = await lsp.hover(for: document, line: parsed.line, column: parsed.column)
                }
            }
            if let text = hover.value, !text.isEmpty {
                pendingLSPHover = text
            }
            return Self.probePrint(LSPProbe.output(for: result))
        }
    }

    private static func probePrint(_ line: String) -> String {
        print(line)
        fflush(stdout)
        return line
    }

    var activeDocument: CodeDocument? { documents.active }

    func saveActiveFile() {
        guard let document = documents.active else { return }
        if documents.save(document) {
            refreshDiff()
            prepareChecking(document)
        }
    }

    /// Called from the editor on every keystroke; the engine coalesces the bursts.
    func noteEdit() {
        guard let document = documents.active else { return }
        guard isProjectTrusted else { return }
        lsp.didChange(document)
        diagnostics.scheduleCheck(document)
    }

    /// Re-check every open tab — after an agent's turn, or when checking is switched back on.
    func recheckAll() {
        for document in documents.documents {
            prepareChecking(document)
        }
    }

    private func prepareChecking(_ document: CodeDocument) {
        guard isProjectTrusted else { return }
        Task { await diagnostics.check(document) }
        if let projectURL {
            Task { await lsp.ensureOpen(document, root: projectURL) }
        }
    }

    func saveAllFiles() {
        _ = documents.saveAll()
        refreshDiff()
    }

    func reloadActiveFile() {
        guard let document = documents.active else { return }
        guard documents.approveClosing([document]) else { return }
        document.reload()
        refreshDiff()
        syncAfterReload(document)
    }

    /// The language menu used to only restyle highlighting, leaving the old server live-covered.
    func setLanguage(_ language: Language, on document: CodeDocument) {
        guard language.id != document.language.id else { return }
        lsp.didClose(document)
        diagnostics.clear(document.url)
        document.setLanguage(language)
        prepareChecking(document)
    }

    /// Rename changes the URI the server knows; without didClose/didOpen the old document is orphaned.
    func renameDocument(_ document: CodeDocument, to newURL: URL) {
        lsp.didClose(document)
        diagnostics.clear(document.url)
        document.rename(to: newURL)
        prepareChecking(document)
    }

    private func syncAfterReload(_ document: CodeDocument) {
        lsp.didChange(document)
        lsp.flush(document)
        prepareChecking(document)
    }

    /// Empty output from `git diff` means "no changes" only inside a repository — outside one it
    /// means the question does not apply, and saying "no changes" there is a small lie.
    var projectIsGitRepo = false

    func refreshDiff() {
        guard let projectURL, let file = documents.active?.url else { diffText = ""; return }
        projectIsGitRepo = !Shell.run("/usr/bin/git",
                                      ["-C", projectURL.path, "rev-parse", "--is-inside-work-tree"],
                                      cwd: projectURL.path)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard projectIsGitRepo else { diffText = ""; return }
        diffText = Shell.run("/usr/bin/git",
                             ["-C", projectURL.path, "--no-pager", "diff", "--no-ext-diff", "--no-textconv", "--", file.path],
                             cwd: projectURL.path)
    }

    func refreshTree() {
        guard let projectURL else { return }
        fileTree = FileNode(url: projectURL)
        index.refresh()
    }

    func refreshAfterWork() {
        guard !isShutDown else { return }
        documents.checkAllOnDisk()
        if autoReloadAfterTurns { _ = documents.reloadUnmodifiedFromDisk() }
        refreshDiff()
        refreshTree()
        recheckAll()
        Task { await git.refresh(reporting: false) }
    }

    /// Paths given on the command line, the way any editor accepts them:
    /// `Orrery ~/project` opens the project, `Orrery a.py b.py` opens tabs.
    /// `--pane terminal|output|problems|search` opens that pane, `--run-default run|build|test`
    /// starts the matching task, `--term-exec "<cmd>"` types a command into the terminal —
    /// the scriptable path for driving the window when no keystrokes can be sent.
    func openLaunchArguments() {
        openLaunchArguments(CommandLine.arguments)
    }

    func openLaunchArguments(_ all: [String]) {
        func value(after flag: String) -> String? {
            LaunchArguments.value(after: flag, in: all)
        }
        defer {
            if all.contains("--orchestrate-demo") {
                orchestrator.seedDemo()
                showOrchestrator = true
            }
            if let task = value(after: "--orchestrate") {
                showOrchestrator = true
                if let name = value(after: "--orchestrator"),
                   let provider = Provider(rawValue: name) {
                    orchestrator.orchestratorProvider = provider
                }
                if let rounds = value(after: "--rounds").flatMap(Int.init) {
                    orchestrator.maxRounds = max(1, min(5, rounds))
                }
                // --models "claude=claude-fable-5,grok=grok-4.6" / --efforts "claude=max,grok=xhigh"
                func overrides(_ flag: String) -> [Provider: String] {
                    var parsed: [Provider: String] = [:]
                    for pair in (value(after: flag) ?? "").split(separator: ",") {
                        let parts = pair.split(separator: "=", maxSplits: 1)
                        if parts.count == 2, let provider = Provider(rawValue: String(parts[0])) {
                            parsed[provider] = String(parts[1])
                        }
                    }
                    return parsed
                }
                orchestrator.modelOverrides.merge(overrides("--models")) { _, new in new }
                orchestrator.effortOverrides.merge(overrides("--efforts")) { _, new in new }
                // Role-scoped forms win over the all-roles form above.
                for (flag, role) in [("--author", SessionRole.author),
                                     ("--reviewer", .reviewer),
                                     ("--orchestrator-role", .orchestrator)] {
                    orchestrator.roleModelOverrides[role, default: [:]]
                        .merge(overrides("\(flag)-models")) { _, new in new }
                    orchestrator.roleEffortOverrides[role, default: [:]]
                        .merge(overrides("\(flag)-efforts")) { _, new in new }
                }
                if let timeout = value(after: "--turn-timeout").flatMap(Double.init), timeout > 0 {
                    orchestrator.turnTimeout = timeout
                }
                if let log = value(after: "--orchestrate-log") {
                    orchestrator.runLogURL = URL(fileURLWithPath:
                        (log as NSString).expandingTildeInPath)
                }
                if let workers = value(after: "--workers") {
                    let wanted = Set(workers.split(separator: ",")
                        .compactMap { Provider(rawValue: String($0)) })
                    orchestrator.disabledWorkers = Set(Provider.allCases)
                        .subtracting(wanted)
                        .subtracting([orchestrator.orchestratorProvider])
                }
                if let projectURL {
                    orchestrator.start(task: task, project: projectURL)
                }
            }
            if let pane = value(after: "--pane"), let target = BottomPane(rawValue: pane) {
                target == .terminal ? showTerminal() : (bottomPane = target)
            }
            if let kind = value(after: "--run-default").flatMap(RunTask.Kind.init(rawValue:)) {
                runTask(kind: kind)
            }
            if let command = value(after: "--term-exec") {
                showTerminal()
                Task { @MainActor [weak self] in
                    // Give the shell a beat to print its prompt first.
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    self?.terminal?.send(text: command + "\r")
                }
            }
            if all.contains("--lsp-probe") {
                if let spec = value(after: "--lsp-probe") {
                    lspProbeTask = Task { @MainActor [weak self] in
                        await self?.runLSPProbe(spec) ?? "lsp-probe error: window closed"
                    }
                } else {
                    print("lsp-probe error: --lsp-probe needs \"<file>:<line>:<col>\"")
                    fflush(stdout)
                }
            }
            if all.contains("--import-run-log") {
                if let path = value(after: "--import-run-log") {
                    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    let line = TeamStats.importRunLog(from: url)
                    print(line)
                    fflush(stdout)
                } else {
                    print("import-run-log: --import-run-log needs a path")
                    fflush(stdout)
                }
            }
            if all.contains("--calibrate") {
                showOrchestrator = true
                if let spec = value(after: "--calibrate") {
                    calibrateTask = Task { @MainActor [weak self] in
                        guard let self else { return "calibrate: window closed" }
                        let line = await Calibration.handleLaunch(
                            spec, project: self.projectURL,
                            makeBackend: self.orchestrator.makeBackend)
                        print(line)
                        fflush(stdout)
                        return line
                    }
                } else {
                    print(Calibration.missingValueLine)
                    fflush(stdout)
                }
            }
        }
        let paths = LaunchArguments.positionalPaths(in: all)
        guard !paths.isEmpty else { return }
        var files: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path,
                                                 isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                openProject(url)
            } else {
                files.append(url)
            }
        }
        // A file with no project given: use its enclosing directory as the project.
        if projectURL == nil, let first = files.first {
            openProject(first.deletingLastPathComponent())
        }
        for file in files { open(file: file) }
    }

    func runProjectSearch(_ query: String, options: SearchOptions) {
        guard let projectURL else { return }
        search.run(query: query, options: options, files: index.files, root: projectURL)
    }
}

enum LaunchArguments {
    static let valueFlags = [
        "--pane", "--run-default", "--term-exec", "--orchestrate",
        "--orchestrator", "--rounds", "--workers", "--orchestrate-log",
        "--models", "--efforts", "--turn-timeout", "--lsp-probe", "--import-run-log",
        "--calibrate",
        "--author-models", "--author-efforts", "--reviewer-models", "--reviewer-efforts",
        "--orchestrator-role-models", "--orchestrator-role-efforts",
    ]

    static func value(after flag: String, in all: [String]) -> String? {
        guard let index = all.firstIndex(of: flag), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    static func flagValues(in all: [String]) -> Set<String> {
        Set(valueFlags.compactMap { value(after: $0, in: all) })
    }

    static func positionalPaths(in all: [String]) -> [String] {
        let values = flagValues(in: all)
        return all.dropFirst().filter { !$0.hasPrefix("-") && !values.contains($0) }
    }
}

enum LSPProbe {
    struct Spec: Equatable {
        var path: String
        var line: Int
        var column: Int
    }

    enum ParseError: Error, Equatable {
        case malformed
        var message: String { "malformed --lsp-probe spec (want file:line:col)" }
    }

    static func parse(_ spec: String) -> Result<Spec, ParseError> {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.malformed) }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3,
              let column = Int(parts[parts.count - 1]),
              let line = Int(parts[parts.count - 2]),
              line >= 1, column >= 1 else {
            return .failure(.malformed)
        }
        let path = parts.dropLast(2).joined(separator: ":")
        guard !path.isEmpty else { return .failure(.malformed) }
        return .success(Spec(path: path, line: line, column: column))
    }

    static func resolve(_ path: String, project: URL?) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        if let project {
            let under = project.appendingPathComponent(expanded)
            if FileManager.default.fileExists(atPath: under.path) {
                return under.standardizedFileURL
            }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                      isDirectory: true)
        return URL(fileURLWithPath: expanded, relativeTo: cwd).standardizedFileURL
    }

    static func projectRoot(for file: URL) -> URL {
        var dir = file.deletingLastPathComponent()
        let fm = FileManager.default
        while dir.path != "/" {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("compile_flags.txt").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return file.deletingLastPathComponent()
    }

    static func output(for result: LSPQueryResult<[LSPCompletionItem]>) -> String {
        switch result.outcome {
        case .timedOut:
            return "lsp-probe timed out: \(result.note ?? "the language server did not reply")"
        case .error:
            return "lsp-probe error: \(result.note ?? "request failed")"
        case .noServer:
            return "lsp-probe: \(result.note ?? "no language server wired")"
        case .success:
            if result.value.isEmpty {
                return "lsp-probe: no completions"
            }
            return result.value.prefix(10).map(\.label).joined(separator: "\n")
        }
    }
}

/// What is showing in the pane below the editor.
enum BottomPane: String, CaseIterable, Identifiable {
    case hidden, problems, search, terminal, output, browser, git

    var id: String { rawValue }
    var title: String {
        switch self {
        case .hidden: return "Hidden"
        case .problems: return "Problems"
        case .search: return "Search"
        case .terminal: return "Terminal"
        case .output: return "Output"
        case .browser: return "Browser"
        case .git: return "Git"
        }
    }
    var symbol: String {
        switch self {
        case .hidden: return "rectangle.bottomhalf.inset.filled"
        case .problems: return "exclamationmark.triangle"
        case .search: return "magnifyingglass"
        case .terminal: return "terminal"
        case .output: return "play.rectangle"
        case .browser: return "globe"
        case .git: return "arrow.triangle.branch"
        }
    }
}

// MARK: - Files and shell

@Observable
final class FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var id: String { url.path }
    private var cachedChildren: [FileNode]?

    static let skipped: Set<String> = [
        ".git", "node_modules", ".build", "target", "dist", ".next", ".venv", "venv",
        "__pycache__", ".DS_Store", ".mypy_cache", ".pytest_cache", "Pods", ".gradle",
    ]

    init(url: URL) {
        self.url = url
        self.isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    var name: String { url.lastPathComponent }

    var children: [FileNode]? {
        guard isDirectory else { return nil }
        if let cachedChildren { return cachedChildren }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let nodes = contents
            .filter { !FileNode.skipped.contains($0.lastPathComponent) }
            .map(FileNode.init)
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        cachedChildren = nodes
        return nodes
    }

    static func == (a: FileNode, b: FileNode) -> Bool { a.url == b.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

enum Shell {
    static func run(_ executable: String, _ arguments: [String], cwd: String? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Studio tools (IDE, preview, browser, desktop) and the IDE browser

extension AppModel {
    private var browserPreferenceStem: String { projectURL.map { AgentSettingsStore.location($0).lastPathComponent } ?? "none" }

    /// Sites the IDE browser may visit, for you and for the agents; loopback is always allowed.
    var browserAllowedHosts: [String] {
        get { Self.preferences.stringArray(forKey: "browser.allowedHosts." + browserPreferenceStem) ?? [] }
        set {
            let cleaned = newValue.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.contains("/") && $0.count <= 253 }
            Self.preferences.set(Array(Set(cleaned)).sorted(), forKey: "browser.allowedHosts." + browserPreferenceStem)
            browser?.allowedHosts = browserAllowedHosts
            refreshToolGroups()
        }
    }

    /// Whether agents may drive the IDE browser (browser_* tools). Off until you switch it on.
    var browserAgentsAllowed: Bool {
        get { Self.preferences.bool(forKey: "browser.agents." + browserPreferenceStem) }
        set { Self.preferences.set(newValue, forKey: "browser.agents." + browserPreferenceStem); refreshToolGroups(); Task { await restartAll() } }
    }

    static var browserDataStoreIdentifier: UUID {
        if let saved = preferences.string(forKey: "browser.dataStore.v1"), let id = UUID(uuidString: saved) { return id }
        let id = UUID()
        preferences.set(id.uuidString, forKey: "browser.dataStore.v1")
        return id
    }

    /// The browser for the pane: any open project, any allowed site, you at the controls.
    func browserController() throws -> UIVerificationController {
        guard let projectURL else { throw ComputerError("Open a project first.") }
        if let browser {
            browser.allowedHosts = browserAllowedHosts
            browser.bypassHostRestrictions = blanketApproval
            return browser
        }
        let controller = UIVerificationController(project: projectURL, mode: .browser)
        controller.allowedHosts = browserAllowedHosts
        controller.bypassHostRestrictions = blanketApproval
        controller.dataStoreIdentifier = Self.persistsPreferences ? Self.browserDataStoreIdentifier : nil
        browser = controller
        return controller
    }

    /// Whether agents get the browser: the per-project switch with at least one named site, or the
    /// blanket bypass, which also removes the browser website restriction.
    var agentsMayUseBrowser: Bool { blanketApproval || (browserAgentsAllowed && !browserAllowedHosts.isEmpty) }
    /// Whether agents get the iPhone simulator: the pane's switch, or the blanket bypass.
    var agentsMayUseSimulator: Bool { blanketApproval || simulatorAgentsAllowed }

    /// The same browser for the agents, only when you switched it on and named at least one site.
    func agentBrowserController() throws -> UIVerificationController {
        guard isProjectTrusted else { throw ComputerError("Trust the project first.") }
        guard agentsMayUseBrowser else {
            throw ComputerError("The IDE browser is not enabled for agents. In Agent settings → Computer, name the allowed sites and switch on \"Agents may use the browser\".")
        }
        return try browserController()
    }

    /// What the editor area shows: the code editor, the browser, or the iPhone simulator.
    enum EditorSurface: String { case code, browser, simulator }

    /// Whether agents may drive the iOS simulator (simulator_* tools). Off until you switch it on
    /// in the iPhone pane.
    var simulatorAgentsAllowed: Bool {
        get { Self.preferences.bool(forKey: "simulator.agents." + browserPreferenceStem) }
        set { Self.preferences.set(newValue, forKey: "simulator.agents." + browserPreferenceStem); refreshToolGroups(); Task { await restartAll() } }
    }
    func showSimulator() { editorSurface = .simulator; workspaceLayout = .workspace }

    /// The browser takes the editor area at full height; the bottom strip was too small for a
    /// page. Code comes back with `showCode()` or the Code button in the browser's toolbar.
    func showBrowser() { editorSurface = .browser; workspaceLayout = .workspace }
    func showCode() {
        editorSurface = .code
        if workspaceLayout == .assistant { workspaceLayout = .workspace }
        if bottomPane == .browser { bottomPane = .hidden }
    }
    func showGit() { bottomPane = .git; workspaceLayout = .workspace }

    var baseToolGroups: Set<ToolGroup> {
        var groups: Set<ToolGroup> = [.ide, .preview]
        if agentsMayUseBrowser { groups.insert(.browser) }
        if agentsMayUseSimulator { groups.insert(.simulator) }
        return groups
    }

    /// IDE, preview and (when allowed) browser tools exist for every trusted project; desktop
    /// tools are added by `enableComputerControl`.
    func ensureStudioTools() {
        guard !isShutDown, isProjectTrusted, let projectURL else { return }
        if let control = computerControl, control.isEnabled, control.project == projectURL {
            refreshToolGroups()
            return
        }
        computerControl?.stop()
        desktopByBlanket = blanketApproval
        computerControl = try? ComputerControl(model: self, project: projectURL, groups: blanketApproval ? baseToolGroups.union([.desktop]) : baseToolGroups)
    }

    /// Recomputes the tool groups. The blanket bypass adds desktop control on its own; what it
    /// added it takes back when switched off, while a session you enabled yourself stays.
    func refreshToolGroups() {
        guard let control = computerControl, control.isEnabled else { return }
        var groups = baseToolGroups
        if blanketApproval {
            groups.insert(.desktop)
            desktopByBlanket = true
        } else if control.desktopEnabled && !desktopByBlanket {
            groups.insert(.desktop)
        } else {
            desktopByBlanket = false
        }
        if groups != control.groups {
            control.setGroups(groups)
            roundtable.refreshToolsForNextTurn()
        }
    }
}

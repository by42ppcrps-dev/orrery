import SwiftUI
import AppKit

/// Launch-argument flags fire in the first window only. A second window must not re-run
/// `--orchestrate` / `--demo` / `--term-exec` against a different project.
@MainActor
enum WindowLaunch {
    static var consumedArguments = false
    static var companionOpened = false
    /// Test seam so the audit can count consumes without touching real CommandLine flags.
    static var onConsumeLaunchArguments: (AppModel) -> Void = { $0.openLaunchArguments() }

    /// Test seam so the watchdog start does not read CommandLine during `--audit`.
    static var arguments: () -> [String] = { CommandLine.arguments }
    /// Test seam so the audit can count watchdog starts without a 24-hour Task.
    static var onStartWatchdog: () -> Void = { ToolchainWatch.shared.startPeriodicSweep() }

    static func shouldStartWatchdog() -> Bool {
        !arguments().contains("--audit")
    }

    static func resetForTests() {
        consumedArguments = false
        companionOpened = false
        onConsumeLaunchArguments = { $0.openLaunchArguments() }
        arguments = { CommandLine.arguments }
        onStartWatchdog = { ToolchainWatch.shared.startPeriodicSweep() }
    }

    /// Project restore + first-window flag latch. Does not start agents — `prepare` does that.
    static func configure(model: AppModel, initialProject: URL?, restoreLastProject: Bool) {
        if let initialProject {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: initialProject.path,
                                              isDirectory: &isDirectory),
               isDirectory.boolValue {
                model.openProject(initialProject)
            }
        } else if restoreLastProject, model.projectURL == nil, let last = AppModel.lastProject {
            model.openProject(last)
        }
        if !consumedArguments {
            consumedArguments = true
            onConsumeLaunchArguments(model)
            // `--demo` fills the window with a representative transcript instead of connecting,
            // so every renderer can be inspected at once. It starts no agent and sends no prompt.
            if CommandLine.arguments.contains("--demo") {
                model.seedDemoTranscript()
            }
        }
    }

    static func prepare(model: AppModel, initialProject: URL?,
                        restoreLastProject: Bool = true) async {
        configure(model: model, initialProject: initialProject,
                  restoreLastProject: restoreLastProject)
        // App-owned Task, not a LaunchAgent. `--audit` never starts it.
        if shouldStartWatchdog() {
            onStartWatchdog()
        }
        if CommandLine.arguments.contains("--demo") { return }
        if model.projectURL != nil {
            await model.startIfNeeded()
        }
    }
}

/// Stops this window's agent CLIs when the NSWindow closes — including the SwiftUI
/// WindowGroup path, which ExtraWindowSupport does not own.
struct WindowShutdownHook: NSViewRepresentable {
    let models: [AppModel]

    func makeCoordinator() -> Coordinator { Coordinator(models: models) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.models = models
        for model in models { StudioApplicationDelegate.register(model) }
        if let window = nsView.window {
            context.coordinator.observe(window)
        } else {
            DispatchQueue.main.async {
                if let window = nsView.window {
                    context.coordinator.observe(window)
                }
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.shutdown()
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var models: [AppModel]
        private var observer: NSObjectProtocol?
        private weak var observed: NSWindow?
        private weak var originalDelegate: NSWindowDelegate?

        init(models: [AppModel]) { self.models = models; super.init() }

        func observe(_ window: NSWindow) {
            guard window !== observed else { return }
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observed = window
            originalDelegate = window.delegate
            window.delegate = self
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.shutdown()
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            for model in models where !model.documents.approveClosing() { return false }
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        // Preserve SwiftUI's own window behavior and ExtraWindowSupport's cleanup.
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true { return originalDelegate }
            return super.forwardingTarget(for: selector)
        }

        func shutdown() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            let closing = models
            models = []
            if Thread.isMainThread {
                MainActor.assumeIsolated { for model in closing { model.shutdown() } }
            } else {
                Task { @MainActor in for model in closing { model.shutdown() } }
            }
        }
    }
}

struct ContentView: View {
    @State private var model: AppModel
    var initialProject: URL?
    var restoreLastProject: Bool
    var managesWindowLifecycle = true
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @State private var showLog = false
    @State private var showToolchain = false

    init(initialProject: URL? = nil, restoreLastProject: Bool = true) {
        self.initialProject = initialProject
        self.restoreLastProject = restoreLastProject
        _model = State(wrappedValue: AppModel())
    }

    init(model: AppModel, initialProject: URL? = nil, restoreLastProject: Bool = true,
         managesWindowLifecycle: Bool = true) {
        self.initialProject = initialProject
        self.restoreLastProject = restoreLastProject
        self.managesWindowLifecycle = managesWindowLifecycle
        _model = State(wrappedValue: model)
    }

    var body: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            if model.projectURL != nil, !model.isProjectTrusted { trustBanner }
            if model.projectURL == nil {
                ProjectWelcomeView(model: model)
            } else {
            GeometryReader { geometry in
                NavigationSplitView(columnVisibility: $columns) {
                    FileTreeView(model: model)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
                } detail: {
                    HSplitView {
                        if model.workspaceLayout != .editor {
                            AssistantPane(model: model)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioStyle.border))
                                .padding(.leading, 10).padding(.vertical, 10).padding(.trailing, 5)
                                .frame(minWidth: 360, idealWidth: 440, maxWidth: model.workspaceLayout == .assistant ? .infinity : 620,
                                       minHeight: 0, maxHeight: .infinity)
                        }
                        if model.workspaceLayout != .assistant {
                            EditorPane(model: model)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioStyle.border))
                                .padding(.trailing, 10).padding(.vertical, 10).padding(.leading, 5)
                                .frame(minWidth: 340, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(StudioStyle.canvas)
                }
                .onChange(of: geometry.size.width < 1080) { _, compact in
                    if compact { columns = .detailOnly }
                }
            }
            }
        }
        .tint(StudioStyle.accent)
        .toolbar { if model.projectURL != nil { toolbarContent } }
        .sheet(isPresented: $model.showSetup) { StudioSetupView(model: model) }
        .sheet(isPresented: $model.showAgentSettings) { AgentSettingsSheet(model: model) }
        .sheet(item: Binding(get: { model.pendingPermission },
                             set: { _ in })) { request in
            // Dismissing without choosing still has to answer the agent, or it waits forever.
            PermissionSheet(request: request)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showLog) { LogSheet(model: model, isPresented: $showLog) }
        .sheet(isPresented: $model.showTaskHistory) { TaskHistoryView(model: model) }
        .sheet(item: $model.inlineEdit) { session in InlineEditSheet(model: model, session: session) }
        .sheet(item: $model.reviewingWorkspace) { workspace in
            TaskChangesView(workspace: workspace, canApply: { paths in
                model.taskMutationAllowed && !model.documents.dirtyDocuments.contains { document in
                    paths.contains { workspace.projectRoot.appendingPathComponent($0).standardizedFileURL == document.url.standardizedFileURL }
                }
            }, didApply: { model.refreshAfterWork() }, operationStateChanged: { model.taskMutationBusy = $0 }, openFile: { model.open(file: $0) })
        }
        .sheet(isPresented: $model.showUIVerification) {
            if let controller = model.uiVerification { UIVerificationView(controller: controller) }
        }
        .sheet(isPresented: $showToolchain) {
            ToolchainSheet(watch: ToolchainWatch.shared, isPresented: $showToolchain)
        }
        .sheet(isPresented: $model.showQuickOpen) {
            QuickOpenSheet(model: model, isPresented: $model.showQuickOpen)
        }
        .sheet(isPresented: $model.showGoToLine) {
            GoToLineSheet(model: model, isPresented: $model.showGoToLine)
        }
        .sheet(isPresented: $model.showCommandPalette) {
            CommandPaletteSheet(model: model, isPresented: $model.showCommandPalette)
        }
        .sheet(isPresented: $model.showShortcuts) {
            ShortcutsSheet(model: model, isPresented: $model.showShortcuts)
        }
        .focusedSceneValue(\.studioModel, model)
        .focusedValue(\.studioModel, model)
        .background {
            if managesWindowLifecycle { WindowShutdownHook(models: [model]) }
        }
        .task {
            await WindowLaunch.prepare(model: model, initialProject: initialProject,
                                       restoreLastProject: restoreLastProject)
            if CommandLine.arguments.contains("--new-project-window"),
               !WindowLaunch.companionOpened {
                WindowLaunch.companionOpened = true
                ExtraWindowSupport.shared.open(project: nil)
            }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                model.documents.checkAllOnDisk()
                if model.autoReloadAfterTurns { _ = model.documents.reloadUnmodifiedFromDisk() }
            }
        }
    }

    private var trustBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
            VStack(alignment: .leading, spacing: 2) {
                Text("Restricted project").font(.callout.weight(.medium))
                Text("You can edit and search. Trust this folder to run agents, terminals and project tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Trust Project") { model.setProjectTrusted(true) }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Workspace layout", selection: $model.workspaceLayout) {
                ForEach([WorkspaceLayout.assistant, .workspace, .editor]) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .help("Focus on the conversation, build beside a preview, or open the full code workspace. Show files with the sidebar button.")
        }

        if model.showsSoloAgentControls {
        ToolbarItem {
            Menu {
                Section("\(model.backend == nil ? "Last reported by" : "Reported by") \(model.provider.displayName)") {
                    if model.catalogIsUnverified(model.provider) {
                        Text(AppModel.unverifiedCatalogPhrase).foregroundStyle(.secondary)
                    } else if model.models.isEmpty {
                        Text("Connect this agent to load its models").foregroundStyle(.secondary)
                    }
                    ForEach(model.catalogIsUnverified(model.provider) ? [] : model.models) { option in
                        Button {
                            Task { await model.setModel(option.id) }
                        } label: {
                            if option.id == model.currentModel {
                                Label(option.name, systemImage: "checkmark")
                            } else {
                                Text(option.name)
                            }
                        }
                    }
                }
                if !model.knownModelVersions.isEmpty {
                    Section("Specific versions (full model IDs from this app’s list)") {
                        ForEach(model.knownModelVersions) { option in
                            Button {
                                Task { await model.setModel(option.id) }
                            } label: {
                                if option.id == model.currentModel {
                                    Label(option.name, systemImage: "checkmark")
                                } else {
                                    Text(option.name)
                                }
                            }
                        }
                    }
                }
                if !model.availableEfforts.isEmpty {
                    Divider()
                    Section("Reasoning effort") {
                        ForEach(model.availableEfforts, id: \.self) { effort in
                            Button {
                                Task { await model.setEffort(effort) }
                            } label: {
                                if effort == model.selectedEffort {
                                    Label(effort.capitalized, systemImage: "checkmark")
                                } else {
                                    Text(effort.capitalized)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Agent settings and model override…") { model.showAgentSettings = true }
            } label: {
                Label(modelLabel, systemImage: "cpu")
                    .labelStyle(.titleAndIcon)
            }
            .fixedSize()
            .help("Model and reasoning effort for the agent selected in Solo mode. Team sets its own models per agent.")
        }
        }

        ToolbarItem {
            Menu {
                Toggle("Automatically approve agent tools", isOn: $model.autoApprove).disabled(model.blanketApproval)
                    .help("Bypasses ordinary agent tool prompts. Computer control has its own session permission.")
                Divider()
                Toggle("Auto-reload files after a turn", isOn: $model.autoReloadAfterTurns)
                    .help("Re-read open tabs an agent changed. Tabs with your own unsaved edits "
                          + "are never touched.")
                Divider()
                Button("Set up this workspace…") { model.showSetup = true }
                Button("Agent Log…") { showLog = true }
                Button(ToolchainWatch.moreMenuTitle) { showToolchain = true }
                Button("Reload Changed Files Now") {
                    model.documents.checkAllOnDisk()
                    _ = model.documents.reloadUnmodifiedFromDisk()
                }
                Button("Rebuild Search Index") { model.refreshTree() }
                Divider()
                Button("Revoke Project Trust") { model.setProjectTrusted(false) }
                    .disabled(!model.isProjectTrusted)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }

    }

    private var modelLabel: String {
        model.modelMenuTitle(for: model.provider)
    }
}

struct LogSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("\(model.provider.displayName) log (stderr)").font(.headline)
                Spacer()
                Button("Close") { isPresented = false }
            }
            ScrollView {
                Text(model.logLines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .padding()
        .frame(width: 760, height: 460)
    }
}


/// ⌘L.
struct GoToLineSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    private var lineCount: Int { model.documents.active?.lineCount ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to line").font(.headline)
            TextField("1 – \(lineCount)", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onSubmit(go)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(Int(text) == nil)
            }
        }
        .padding(18)
        .onAppear { focused = true }
    }

    private func go() {
        guard let line = Int(text), line >= 1 else { return }
        model.editorRequest = .goToLine(min(line, max(1, lineCount)))
        isPresented = false
    }
}

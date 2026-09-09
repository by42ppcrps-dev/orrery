import SwiftUI

/// One thing the app can do, named the way a person would search for it.
struct AppCommand: Identifiable {
    let id: String
    let title: String
    let group: String
    var detail: String = ""
    var symbol: String = "circle"
    var shortcut: String? = nil
    var enabled: Bool = true
    let run: @MainActor () -> Void
}

/// The command palette's list (⌘⇧P) and the keyboard-shortcuts reference (⌘⌥/), built from
/// one source so the two can never disagree. The search is a pure function.
enum AppCommands {
    @MainActor static func all(_ model: AppModel) -> [AppCommand] {
        var list: [AppCommand] = []
        func add(_ id: String, _ title: String, _ group: String, detail: String = "", symbol: String,
                 shortcut: String? = nil, enabled: Bool = true, _ run: @escaping @MainActor () -> Void) {
            list.append(AppCommand(id: id, title: title, group: group, detail: detail, symbol: symbol,
                                   shortcut: shortcut, enabled: enabled, run: run))
        }
        func mode(_ mode: AssistantMode) { switchMode(model, to: mode) }
        func settings(_ section: String) {
            model.requestedSettingsSection = section
            model.showAgentSettings = true
        }

        add("mode.solo", "Switch to Solo", "Mode", detail: "One agent, one conversation", symbol: "person", shortcut: "⌘1") { mode(.chat) }
        add("mode.team", "Switch to Team", "Mode", detail: "An orchestrator plans, workers build, reviewers check", symbol: "person.3", shortcut: "⌘2") { mode(.team) }
        add("mode.roundtable", "Switch to Roundtable", "Mode", detail: "Every agent in one discussion", symbol: "bubble.left.and.bubble.right", shortcut: "⌘3") { mode(.roundtable) }
        add("mode.cli", "Switch to CLI", "Mode", detail: "The agent's own terminal, inside Orrery (also ⌘⇧C)", symbol: "terminal", shortcut: "⌘4") { mode(.cli) }

        for provider in Provider.allCases {
            add("agent.use.\(provider.rawValue)", "Use \(provider.displayName)", "Agent",
                detail: "The agent for Solo and CLI", symbol: "cpu") { model.provider = provider }
        }
        for provider in Provider.allCases {
            add("agent.signin.\(provider.rawValue)", "Sign in to \(provider.displayName)", "Agent",
                detail: "Opens its CLI to sign in with your subscription", symbol: "person.badge.key") { model.signIn(provider) }
        }

        for layout in WorkspaceLayout.allCases {
            add("layout.\(layout.rawValue)", "Layout: \(layout.title)", "Layout", detail: layoutDetail(layout),
                symbol: "rectangle.split.2x1") { model.workspaceLayout = layout }
        }

        add("show.activity", "Activity Across Devices", "Show", detail: "All open projects and agents on your paired Macs", symbol: "laptopcomputer.and.iphone") { ActivityWindowSupport.shared.open() }
        add("show.browser", "Show the Browser", "Show", detail: "In the editor area", symbol: "globe", shortcut: "⌘⌥B") { model.showBrowser() }
        add("show.simulator", "Show the iPhone Simulator", "Show", detail: "In the editor area", symbol: "iphone") { model.showSimulator() }
        add("show.code", "Show the Code editor", "Show", symbol: "chevron.left.forwardslash.chevron.right") { model.showCode() }
        add("show.git", "Show Source Control", "Show", detail: "Changes, commits, pushes", symbol: "arrow.triangle.branch", shortcut: "⌘⌃G") { model.showGit() }
        add("show.terminal", "Show the Terminal", "Show", symbol: "terminal", shortcut: "⌃`") { model.showTerminal() }
        add("show.problems", "Show Problems", "Show", symbol: "exclamationmark.triangle", shortcut: "⌘⇧M") { model.bottomPane = .problems; model.workspaceLayout = .workspace }
        add("show.output", "Show Output", "Show", symbol: "text.alignleft", shortcut: "⌘⇧U") { model.bottomPane = .output; model.workspaceLayout = .workspace }
        add("show.search", "Find in Project…", "Show", symbol: "magnifyingglass", shortcut: "⌘⇧F") { model.bottomPane = .search; model.workspaceLayout = .workspace }
        add("show.hideBottom", "Hide the bottom pane", "Show", symbol: "rectangle.bottomthird.inset.filled", shortcut: "⌘J") { model.bottomPane = .hidden }
        add("nav.quickOpen", "Go to File…", "Navigate", symbol: "doc.text.magnifyingglass", shortcut: "⌘P") { model.showQuickOpen = true }
        add("nav.goToLine", "Go to Line…", "Navigate", symbol: "number", shortcut: "⌘L") { model.showGoToLine = true }

        add("setup.workspace", "Set up this workspace", "Set up", detail: "Project, agents, tools", symbol: "slider.horizontal.3") { model.showSetup = true }
        add("setup.connectors", "Connections & plugins", "Set up", detail: "MCP servers shared by every agent", symbol: "point.3.connected.trianglepath.dotted") { settings("Connectors") }
        add("setup.session", "Agent settings", "Set up", detail: "Model, effort, session options", symbol: "gearshape") { settings("Session") }
        add("setup.tools", "Tool access", "Set up", detail: "What each agent may run without asking", symbol: "checklist") { settings("Tools") }
        add("setup.computer", "Computer control settings", "Set up", symbol: "desktopcomputer") { settings("Computer") }
        add("setup.remote", "Pair your iPhone", "Set up", detail: "Orrery Remote, on this network or through a relay", symbol: "iphone.radiowaves.left.and.right") { settings("Remote") }

        let bypass = model.blanketApproval
        add("approvals.bypass", bypass ? "Turn off bypass" : "Turn on bypass", "Approvals",
            detail: bypass ? "Agents will ask before risky tools again" : "Every agent runs every tool, browser, simulator and computer without asking",
            symbol: bypass ? "lock" : "lock.open", enabled: !model.orchestrator.isRunning) { model.blanketApproval.toggle() }
        let desktop = model.computerControl?.desktopEnabled == true
        add("approvals.computer", desktop ? "Stop computer control" : "Allow computer control", "Approvals",
            detail: desktop ? "Agents lose the mouse and keyboard" : "Agents may drive this Mac", symbol: "desktopcomputer") {
            if desktop { model.disableComputerControl() } else { try? model.enableComputerControl() }
        }

        add("run.newSession", "New session", "Run", detail: "A fresh conversation with the current agent", symbol: "plus.bubble", shortcut: "⌘N") { Task { await model.newSession() } }
        add("run.stopRoundtable", "Stop the roundtable", "Run", symbol: "stop.circle", enabled: model.roundtable.isRunning) { model.roundtable.stop() }
        add("run.clearRoundtable", "Clear the roundtable", "Run", detail: "Forgets the transcript", symbol: "trash",
            enabled: !model.roundtable.isRunning && !model.roundtable.entries.isEmpty) { model.roundtable.clear() }
        add("run.stopTeam", "Stop the team", "Run", symbol: "stop.circle", enabled: model.orchestrator.isRunning) { model.orchestrator.stop() }
        add("run.run", "Run the project", "Run", symbol: "play", shortcut: "⌘R") { model.runTask(kind: .run) }
        add("run.build", "Build the project", "Run", symbol: "hammer", shortcut: "⌘⇧B") { model.runTask(kind: .build) }
        add("run.test", "Test the project", "Run", symbol: "checkmark.seal", shortcut: "⌘U") { model.runTask(kind: .test) }
        add("run.stopTask", "Stop the task", "Run", symbol: "stop", shortcut: "⌘.") { model.taskRun.stop() }

        add("file.save", "Save", "File", symbol: "square.and.arrow.down", shortcut: "⌘S") { model.saveActiveFile() }
        add("file.saveAll", "Save All", "File", symbol: "square.and.arrow.down.on.square", shortcut: "⌘⌥S") { model.saveAllFiles() }
        add("file.refresh", "Refresh the file tree", "File", symbol: "arrow.clockwise", shortcut: "⌘⇧R") { model.refreshTree() }
        add("editor.comment", "Toggle comment", "Editor", symbol: "number", shortcut: "⌘/") {
            NSApp.sendAction(#selector(CodeTextView.toggleLineComment(_:)), to: nil, from: nil)
        }
        add("editor.duplicate", "Duplicate line", "Editor", symbol: "doc.on.doc", shortcut: "⌘⇧D") {
            NSApp.sendAction(#selector(CodeTextView.duplicateLine(_:)), to: nil, from: nil)
        }

        add("help.shortcuts", "Keyboard shortcuts", "Help", detail: "Every key in one place", symbol: "keyboard", shortcut: "⌘⌥/") { model.showShortcuts = true }
        add("help.palette", "Commands…", "Help", detail: "This list", symbol: "command", shortcut: "⌘⇧P") { model.showCommandPalette = true }
        return list
    }

    /// A mode switch from the code-only layout brings the assistant back, or the switch is invisible.
    @MainActor static func switchMode(_ model: AppModel?, to mode: AssistantMode) {
        guard let model else { return }
        model.assistantMode = mode
        if model.workspaceLayout == .editor { model.workspaceLayout = .workspace }
    }

    private static func layoutDetail(_ layout: WorkspaceLayout) -> String {
        switch layout {
        case .editor: return "Code only"
        case .workspace: return "Code beside the assistant"
        case .assistant: return "Assistant only"
        }
    }

    /// Ranked by how well the query matches: a title that starts with it, then a word that starts
    /// with it, then the query somewhere inside, then its letters in order. The detail counts for
    /// half. Ties keep the list order.
    static func filter(_ commands: [AppCommand], query: String) -> [AppCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return commands }
        let scored: [(Int, Int, AppCommand)] = commands.enumerated().compactMap { index, command in
            let best: Int?
            if let title = score(command.title, query: trimmed) { best = title }
            else if let detail = score(command.detail, query: trimmed) { best = detail / 2 }
            else { best = nil }
            return best.map { ($0, index, command) }
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map(\.2)
    }

    static func score(_ text: String, query: String) -> Int? {
        let text = text.lowercased(), query = query.lowercased()
        guard !text.isEmpty, !query.isEmpty else { return nil }
        if text.hasPrefix(query) { return 400 - text.count }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if let word = words.firstIndex(where: { $0.hasPrefix(query) }) { return 300 - word }
        if let range = text.range(of: query) { return 200 - text.distance(from: text.startIndex, to: range.lowerBound) }
        var cursor = text.startIndex
        var first: String.Index?
        var last = text.startIndex
        for character in query {
            guard let found = text[cursor...].firstIndex(of: character) else { return nil }
            if first == nil { first = found }
            last = found
            cursor = text.index(after: found)
        }
        let spread = text.distance(from: first ?? text.startIndex, to: last)
        return max(1, 100 - spread)
    }

    /// Commands with a key, in group order, for the shortcuts reference.
    static func shortcutGroups(_ commands: [AppCommand]) -> [(group: String, commands: [AppCommand])] {
        var order: [String] = []
        var byGroup: [String: [AppCommand]] = [:]
        for command in commands where command.shortcut != nil {
            if byGroup[command.group] == nil { order.append(command.group) }
            byGroup[command.group, default: []].append(command)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }
}

/// ⌘⇧P. Type part of what you want, hit return.
struct CommandPaletteSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var commands: [AppCommand] {
        AppCommands.filter(AppCommands.all(model).filter(\.enabled), query: query)
    }

    var body: some View {
        let commands = commands
        VStack(spacing: 0) {
            TextField("What do you want to do?", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($focused)
                .onChange(of: query) { _, _ in selection = 0 }
                .onSubmit { run(commands) }
            Divider()
            if commands.isEmpty {
                Text("No command matches.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                    List(Array(commands.enumerated()), id: \.element.id) { position, command in
                        row(command, isSelected: position == selection)
                            .id(position)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = position; run(commands) }
                    }
                    .listStyle(.plain)
                    .frame(height: 380)
                    .onChange(of: selection) { _, new in proxy.scrollTo(new) }
                }
            }
            Divider()
            HStack {
                Text("\(commands.count) commands")
                Spacer()
                Text("↑↓ to move · ↩ to run · esc to close")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(width: 640)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
        .onKeyPress(.downArrow) { selection = min(max(0, commands.count - 1), selection + 1); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
    }

    private func row(_ command: AppCommand, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title).lineLimit(1)
                if !command.detail.isEmpty {
                    Text(command.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(command.group).font(.caption).foregroundStyle(.tertiary)
            if let shortcut = command.shortcut {
                Text(shortcut).font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.vertical, 3)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        .accessibilityElement(children: .combine)
    }

    private func run(_ commands: [AppCommand]) {
        guard selection < commands.count else { return }
        let command = commands[selection]
        isPresented = false
        command.run()
    }
}

/// ⌘⌥/. Every key, generated from the command list.
struct ShortcutsSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(AppCommands.shortcutGroups(AppCommands.all(model)), id: \.group) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.group).font(.headline)
                            ForEach(entry.commands) { command in
                                HStack {
                                    Text(command.title)
                                    Spacer()
                                    Text(command.shortcut ?? "").font(.body.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("⌘⇧P opens the command list: type part of any action above, or of anything else the app can do.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 520, height: 560)
    }
}

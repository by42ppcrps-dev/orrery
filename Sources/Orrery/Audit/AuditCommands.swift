import Foundation

/// The command palette: every action in one searchable list, with the same keys the menus use.
/// The search is pure, so it is checked on fixtures; then the real list is built on a headless
/// model and its switches are pulled.
@MainActor
enum AuditCommands {
    static func run(_ audit: Auditor) async {
        audit.section("Commands — search ranks the way people type")
        func fixture(_ title: String, detail: String = "") -> AppCommand {
            AppCommand(id: title, title: title, group: "Test", detail: detail, run: {})
        }
        let fixtures = [fixture("Show the Browser"), fixture("Show the iPhone Simulator"), fixture("Switch to Roundtable"),
                        fixture("Unstoppable settings"), fixture("Stop the roundtable"), fixture("Source Control", detail: "git changes and commits")]
        func titles(_ query: String) -> [String] { AppCommands.filter(fixtures, query: query).map(\.title) }
        audit.equal("an empty query keeps every command in order", titles(""), fixtures.map(\.title))
        audit.equal("a title that starts with the query comes first", titles("stop"), ["Stop the roundtable", "Unstoppable settings"])
        audit.equal("a word that starts with the query comes next", titles("round"), ["Switch to Roundtable", "Stop the roundtable"])
        audit.equal("letters in order still find it", titles("ipsim").first, "Show the iPhone Simulator")
        audit.check("nonsense finds nothing", titles("zzqx").isEmpty, titles("zzqx").description)
        audit.equal("the detail is searched too", titles("git").first, "Source Control")
        audit.equal("search ignores case", titles("BROWSER").first, "Show the Browser")
        audit.equal("spaces around the query are ignored", titles("  stop ").first, "Stop the roundtable")
        audit.check("a prefix outranks an inside hit", (AppCommands.score("stop", query: "sto") ?? 0) > (AppCommands.score("unstop", query: "sto") ?? 0))

        audit.section("Commands — the real list")
        let model = AppModel(trust: .forAudit)
        let all = AppCommands.all(model)
        audit.check("there are commands", all.count >= 40, "\(all.count)")
        audit.equal("ids are unique", Set(all.map(\.id)).count, all.count)
        audit.equal("titles are unique", Set(all.map(\.title)).count, all.count)
        audit.check("every command has a symbol", all.allSatisfy { !$0.symbol.isEmpty })
        let shortcuts = all.compactMap(\.shortcut)
        let duplicates = Dictionary(grouping: shortcuts, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        audit.check("no two commands share a key", duplicates.isEmpty, duplicates.description)
        audit.check("every key starts with a modifier", shortcuts.allSatisfy { $0.first.map { "⌘⇧⌥⌃".contains($0) } ?? false }, shortcuts.description)
        audit.check("the four modes are ⌘1–⌘4", ["⌘1", "⌘2", "⌘3", "⌘4"].allSatisfy { shortcuts.contains($0) })
        audit.check("the keys match the menus", ["⌘P", "⌘L", "⌘J", "⌘N", "⌘R", "⌘U", "⌘S", "⌘/", "⌘⇧B", "⌘⌥B", "⌘⌃G"].allSatisfy { shortcuts.contains($0) }, shortcuts.description)
        @discardableResult func run(_ title: String, in list: [AppCommand]? = nil) -> Bool {
            guard let command = (list ?? all).first(where: { $0.title == title }) else { return false }
            command.run()
            return true
        }
        audit.check("Switch to Team switches", run("Switch to Team") && model.assistantMode == .team)
        audit.check("Switch to Roundtable switches", run("Switch to Roundtable") && model.assistantMode == .roundtable)
        audit.check("Switch to CLI switches", run("Switch to CLI") && model.assistantMode == .cli)
        model.workspaceLayout = .editor
        audit.check("Switch to Solo switches", run("Switch to Solo") && model.assistantMode == .chat)
        audit.equal("a mode switch from the code-only layout brings the assistant back", model.workspaceLayout, .workspace)
        audit.check("Show the Browser shows it", run("Show the Browser") && model.editorSurface == .browser)
        audit.check("Show the iPhone Simulator shows it", run("Show the iPhone Simulator") && model.editorSurface == .simulator)
        audit.check("Show Source Control shows it", run("Show Source Control") && model.bottomPane == .git)
        audit.check("Hide the bottom pane hides it", run("Hide the bottom pane") && model.bottomPane == .hidden)
        audit.check("Set up opens the setup sheet", run("Set up this workspace") && model.showSetup)
        audit.check("Connections opens settings on Connectors", run("Connections & plugins") && model.showAgentSettings && model.requestedSettingsSection == "Connectors")
        audit.check("Pair your iPhone opens settings on Remote", run("Pair your iPhone") && model.requestedSettingsSection == "Remote")
        audit.check("Keyboard shortcuts opens the reference", run("Keyboard shortcuts") && model.showShortcuts)
        audit.check("Go to File opens quick open", run("Go to File…") && model.showQuickOpen)
        audit.equal("Stop the roundtable is off while nothing runs", all.first { $0.id == "run.stopRoundtable" }?.enabled, false)
        audit.equal("Clear the roundtable is off while it is empty", all.first { $0.id == "run.clearRoundtable" }?.enabled, false)
        audit.equal("Stop the team is off while nothing runs", all.first { $0.id == "run.stopTeam" }?.enabled, false)
        let before = model.blanketApproval
        run(before ? "Turn off bypass" : "Turn on bypass")
        audit.equal("the bypass command flips the blanket switch", model.blanketApproval, !before)
        let after = AppCommands.all(model)
        audit.equal("the bypass command reads its new state", after.first { $0.id == "approvals.bypass" }?.title, before ? "Turn on bypass" : "Turn off bypass")
        run(before ? "Turn on bypass" : "Turn off bypass", in: after)
        audit.equal("and flips it back", model.blanketApproval, before)

        audit.section("Commands — the reference is generated from the same list")
        let groups = AppCommands.shortcutGroups(all)
        audit.check("groups keep list order", groups.first?.group == "Mode", groups.map(\.group).description)
        audit.check("only keyed commands are listed", groups.allSatisfy { $0.commands.allSatisfy { $0.shortcut != nil } })
        audit.equal("every keyed command is listed once", groups.flatMap(\.commands).count, shortcuts.count)
        audit.check("the palette hides what cannot run right now", !AppCommands.filter(all.filter(\.enabled), query: "stop the roundtable").contains { $0.id == "run.stopRoundtable" })
        audit.equal("typing sim finds the simulator first", AppCommands.filter(all, query: "sim").first?.id, "show.simulator")
        audit.equal("typing pair finds the phone", AppCommands.filter(all, query: "pair").first?.id, "setup.remote")
    }
}

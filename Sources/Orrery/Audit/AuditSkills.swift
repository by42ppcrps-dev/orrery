import Foundation
import AppKit
import SwiftUI

/// Skills: each CLI's own skill system must keep working inside Orrery. Project skills travel
/// with the working copy, the confinement leaves every skill folder readable, and the launch
/// arguments and config overlays never switch skills off.
@MainActor
enum AuditSkills {
    static func run(_ audit: Auditor) async {
        await directContext(audit)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        audit.section("Skills — project skill folders travel into the working copy")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orrery-skills-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        for path in [".claude/skills/orrery-check/SKILL.md", ".agents/skills/repo-check/SKILL.md", ".codex/skills/local/SKILL.md", "src/main.py", "AGENTS.md", "CLAUDE.md"] {
            let file = project.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "---\nname: \(file.deletingLastPathComponent().lastPathComponent)\n---\nSay SKILL-OK.\n".write(to: file, atomically: true, encoding: .utf8)
        }
        do {
            let workspace = try await TaskWorkspaceStore(directory: root.appendingPathComponent("workspaces")).create(taskID: UUID(), project: project)
            let copy = workspace.executionRoot
            for path in [".claude/skills/orrery-check/SKILL.md", ".agents/skills/repo-check/SKILL.md", ".codex/skills/local/SKILL.md", "AGENTS.md", "CLAUDE.md"] {
                audit.check("\(path) is in the working copy", FileManager.default.fileExists(atPath: copy.appendingPathComponent(path).path))
            }
        } catch { audit.check("a working copy could be made for the fixture", false, error.localizedDescription) }
        audit.check("hidden skill folders are not on the exclusion list", TaskWorkspaceStore.excludedDirectories.isDisjoint(with: [".claude", ".codex", ".agents", ".grok"]))

        audit.section("Skills — the confinement leaves every skill folder readable")
        for provider in Provider.allCases {
            let denied = AgentExecutionBoundary.protectedPaths(provider: provider, home: home).map(\.path)
            let skillFolders = [".claude/skills", ".codex/skills", ".agents/skills", ".grok/skills", "Grok_build/skills"].map { home.appendingPathComponent($0).path }
            audit.check("\(provider.displayName)'s denied paths do not cover a skill folder",
                        !skillFolders.contains { folder in denied.contains { folder.hasPrefix($0) } }, denied.description)
        }
        // A real read under each provider's profile, for the folders this Mac has.
        if AgentExecutionBoundary.isAvailable {
            let candidates: [(Provider, URL)] = [
                (.codex, home.appendingPathComponent(".codex/skills")),
                (.claude, home.appendingPathComponent(".claude/skills")),
                (.grok, home.appendingPathComponent("Grok_build/skills")),
                (.codex, home.appendingPathComponent(".agents/skills")),
            ]
            for (provider, folder) in candidates {
                guard let skill = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }) else {
                    audit.skip("\(provider.displayName): native skill read", "No installed skill in \(folder.lastPathComponent) on this machine")
                    continue
                }
                let file = skill.appendingPathComponent("SKILL.md")
                do {
                    let launch = try AgentExecutionBoundary.prepare(executable: "/bin/cat", arguments: [file.path], environment: [:],
                        execution: AgentExecutionRequest(policy: .confinedWrites, workspace: project, provider: provider))
                    let result = try await ProcessRunner.run(launch.executable, launch.arguments, cwd: project, environment: launch.environment, timeout: 20)
                    audit.check("\(provider.displayName) can read \(folder.path.replacingOccurrences(of: home.path, with: "~"))/\(skill.lastPathComponent)/SKILL.md under confinement",
                                result.status == 0 && !result.standardOutput.isEmpty, result.standardError.prefix(160).description)
                } catch { audit.check("\(provider.displayName) confinement probe ran", false, error.localizedDescription) }
            }
        }

        audit.section("Skills — nothing Orrery passes switches them off")
        let settings = AgentSessionSettings()
        let claude = settings.nativeArguments(for: .claude, autoApprove: false) + settings.claudeArguments(adding: nil)
        audit.check("Claude is never launched with --bare or --disable-slash-commands", !claude.contains("--bare") && !claude.contains("--disable-slash-commands") && !claude.contains("--strict-mcp-config"))
        audit.check("Claude keeps its default setting sources (skills come from ~/.claude and the project)", !claude.contains("--setting-sources"))
        var grok = AgentSessionSettings()
        grok.effort = "high"
        let overlay = grok.grokEnvironment["GROK_CONFIG"].flatMap { JSON(data: Data($0.utf8)) }
        audit.check("Grok's config overlay carries the effort and nothing about skills, so its config.toml skill paths stay", overlay?["models"]["default_reasoning_effort"].string == "high" && overlay?["skills"].raw == nil)
        audit.check("Codex gets no skills override", !settings.nativeArguments(for: .codex, autoApprove: false).contains { $0.hasPrefix("skills") } && settings.codexConfiguration["skills"] == nil)
        audit.check("no tool is denied by default, so the Skill tool stays available", settings.deniedTools.isEmpty && settings.allowedTools.isEmpty)
    }

    private static func directContext(_ audit: Auditor) async {
        audit.section("Team context — real file reads, discovery and every role receives selected skills")
        await Auditor.withTemporaryDirectory { root in
            do {
                let folder = root.appendingPathComponent(".agents/skills/fixture")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let skillURL = folder.appendingPathComponent("SKILL.md")
                try "---\nname: fixture\n---\nSKILL-CONTEXT-SENTINEL".write(to: skillURL, atomically: true, encoding: .utf8)
                let attachment = try TeamContext.attachment(at: skillURL)
                audit.check("skill attachment preserves content and supporting-file directory", attachment.textContext.contains("SKILL-CONTEXT-SENTINEL") && attachment.textContext.contains(folder.path))
                let skills = TeamContext.discover(project: root, home: root.appendingPathComponent("empty-home"))
                audit.check("the picker finds a real project skill", skills.count == 1 && skills.first?.name == "fixture")
                let link = folder.appendingPathComponent("link.md")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: skillURL)
                do { _ = try TeamContext.attachment(at: link); audit.check("symlink attachment refused", false) }
                catch { audit.check("symlink attachment refused", true) }
                do { try TeamContext.validate(Array(repeating: attachment, count: 9)); audit.check("attachment count bounded", false) }
                catch { audit.check("attachment count bounded", true) }
                let large = try MessageAttachment(name: "large", text: String(repeating: "a", count: TeamContext.byteLimit + 1))
                do { try TeamContext.validate([large]); audit.check("attachment bytes bounded", false) }
                catch { audit.check("attachment bytes bounded", true) }
                let restored = try JSONDecoder().decode(TaskRecord.self, from: JSONEncoder().encode(TaskRecord(provider: .grok, title: "Team", attachments: [attachment], origin: "team")))
                audit.check("saved Team tasks retain their selected skill snapshot", restored.attachments.first?.data == attachment.data)
                let draftStore = TaskHistoryStore(project: root, directory: root.appendingPathComponent("draft-store"))
                let snapshot = TaskHistorySnapshot(teamDraft: TeamDraft(text: "Unsent plan", attachments: [attachment], orchestrator: .codex, useExistingPlan: true))
                let saved = await draftStore.flush(snapshot)
                let draft = draftStore.load().teamDraft
                audit.check("unsent Team drafts preserve lead, plan mode and attachments on disk", saved && draft?.text == "Unsent plan" && draft?.orchestrator == .codex && draft?.useExistingPlan == true && draft?.attachments.first?.data == attachment.data)
                let model = AppModel()
                model.assistantMode = .team
                model.orchestrator.installedProviders = Provider.allCases
                let teamView = NSHostingView(rootView: OrchestratorView(model: model))
                let teamWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
                teamWindow.contentView = teamView; teamWindow.layoutIfNeeded()
                try? await Task.sleep(for: .milliseconds(100))
                teamView.layoutSubtreeIfNeeded()
                func popups(_ view: NSView) -> [NSPopUpButton] {
                    (view as? NSPopUpButton).map { [$0] } ?? [] + view.subviews.flatMap { popups($0) }
                }
                audit.check("the collapsed Team setup mounts the three-agent orchestrator picker", popups(teamView).contains { Set($0.itemTitles) == Set(Provider.allCases.map(\.displayName)) })
                teamWindow.contentView = nil
                audit.check("Team hides the unrelated Solo model controls", !model.showsSoloAgentControls)
                model.assistantMode = .roundtable
                audit.check("Roundtable hides the unrelated Solo model controls", !model.showsSoloAgentControls)
                model.teamAttachments = [attachment]; model.orchestratorDraft = "other project"; model.teamUseExistingPlan = true
                let capturedDraft = model.taskSnapshot().teamDraft
                audit.check("the app's recovery snapshot includes the Team composer", capturedDraft?.text == "other project" && capturedDraft?.attachments.count == 1 && capturedDraft?.useExistingPlan == true)
                model.configureTaskHistory(project: root)
                audit.check("changing project clears another project's Team context", model.teamAttachments.isEmpty && model.orchestratorDraft.isEmpty && !model.teamUseExistingPlan)
                model.shutdown()

                let engine = Orchestrator()
                engine.installedProviders = [.grok, .claude]; engine.orchestratorProvider = .grok
                engine.followGate = false; engine.turnTimeout = 2
                var backends: [ScriptedBackend] = []
                engine.makeBackend = { provider in
                    let scripts = backends.isEmpty
                        ? [ScriptedBackend.reply("```json\n{\"items\":[{\"title\":\"First\",\"author\":\"claude\",\"brief\":\"Do first\"},{\"title\":\"Second\",\"author\":\"claude\",\"brief\":\"Do second\"}]}\n```")]
                        : [ScriptedBackend.reply(provider == .claude ? "Done\nFILES:" : "NO FINDINGS"), ScriptedBackend.reply(provider == .claude ? "Done\nFILES:" : "NO FINDINGS")]
                    let backend = ScriptedBackend(provider: provider, scripts: scripts)
                    backends.append(backend); return backend
                }
                engine.start(task: "Build both items", project: root, attachments: [attachment])
                let deadline = Date().addingTimeInterval(8)
                while engine.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
                audit.check("Team finishes two items with the selected context", engine.phase == .done && engine.items.count == 2)
                audit.check("planner, author and reviewer each receive the skill directly", backends.count == 3 && backends.allSatisfy { $0.prompts.first?.contains("SKILL-CONTEXT-SENTINEL") == true })
                audit.check("pooled sessions do not resend the skill with every item", backends.filter { $0.prompts.count == 2 }.count == 2 && backends.allSatisfy { $0.prompts.dropFirst().allSatisfy { !$0.contains("SKILL-CONTEXT-SENTINEL") } })
                engine.stop()
                backends = []
                engine.makeBackend = { provider in
                    let backend = ScriptedBackend(provider: provider, scripts: [ScriptedBackend.reply(provider == .claude ? "Implemented supplied plan\nFILES:" : "NO FINDINGS")])
                    backends.append(backend); return backend
                }
                engine.start(task: "A plan already prepared in chat", project: root, attachments: [attachment], useExistingPlan: true)
                let directDeadline = Date().addingTimeInterval(8)
                while engine.isRunning && Date() < directDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
                audit.check("an existing plan skips the planner turn and still gets independent review", engine.phase == .done && engine.planRaw.isEmpty && backends.map(\.provider) == [.claude, .grok] && engine.totalTurns == 2)
                audit.check("existing-plan workers and reviewers receive the selected skill", backends.count == 2 && backends.allSatisfy { $0.prompts.first?.contains("SKILL-CONTEXT-SENTINEL") == true })
                engine.stop()
            } catch { audit.check("Team context fixture completed", false, error.localizedDescription) }
        }
    }
}

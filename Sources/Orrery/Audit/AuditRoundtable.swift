import Foundation

/// Roundtable: one message reaches every enabled agent at once, replies are attributed, the
/// second round shows each agent the others' answers (never its own), @mentions narrow the
/// audience, tool approvals are refused, the transcript persists per project, and idle sessions
/// are released and reconnected with a recap.
@MainActor
enum AuditRoundtable {
    static func run(_ audit: Auditor) async {
        audit.section("Roundtable — changed tool access refreshes provider catalogs")
        await Auditor.withTemporaryDirectory { project in
            let table = Roundtable()
            table.installed = [.grok]
            table.rounds = 1
            var backends: [ScriptedBackend] = []
            table.makeBackend = { provider in
                let backend = ScriptedBackend(provider: provider, scripts: [[.assistantDelta("Tools checked"), .turnFinished(stopReason: "end_turn", costUSD: nil)]])
                backend.eventDelay = 0.1
                backends.append(backend)
                return backend
            }
            table.attach(project: project, storeDirectory: project.appendingPathComponent("store"))
            let task = Task { await table.send("Check tools") }
            _ = await waitUntil(2) { !backends.isEmpty && table.isRunning }
            table.refreshToolsForNextTurn()
            audit.check("changing grants does not interrupt the current Roundtable turn", backends.first?.stopCount == 0 && table.isRunning)
            await task.value
            await table.send("Check newly enabled tools")
            audit.equal("the next turn creates a session with a fresh MCP catalog", backends.count, 2)
            let count = table.entries.count
            table.refreshToolsForNextTurn()
            audit.check("an idle grant change releases cached sessions immediately", table.activeSessions.isEmpty)
            audit.equal("refreshing tools preserves the transcript", table.entries.count, count)
            table.stop()
        }
        audit.section("Roundtable — everyone answers, then answers each other")
        await Auditor.withTemporaryDirectory { base in
            let project = base.appendingPathComponent("project")
            let store = base.appendingPathComponent("store")
            try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            var backends: [Provider: [ScriptedBackend]] = [:]
            let table = Roundtable()
            table.installed = [.grok, .claude, .codex]
            table.stallTimeout = 2
            table.idleReleaseDelay = 0.2
            table.makeBackend = { provider in
                let backend = ScriptedBackend(provider: provider, scripts: [
                    [.assistantDelta("\(provider.displayName) says: use a queue."), .turnFinished(stopReason: "end_turn", costUSD: provider == .claude ? 0.01 : nil)],
                    [.assistantDelta("\(provider.displayName) agrees with the others."), .turnFinished(stopReason: "end_turn", costUSD: nil)],
                    [.assistantDelta("\(provider.displayName) again."), .turnFinished(stopReason: "end_turn", costUSD: nil)],
                    [.assistantDelta("\(provider.displayName) once more."), .turnFinished(stopReason: "end_turn", costUSD: nil)],
                ])
                backends[provider, default: []].append(backend)
                return backend
            }
            table.attach(project: project, storeDirectory: store)
            audit.equal("three targets when everyone is enabled and installed", table.enabledTargets, [.grok, .claude, .codex])
            audit.equal("@Claude narrows the audience", Roundtable.targets(in: "@Claude what do you think?", among: table.enabledTargets), [.claude])
            audit.equal("two mentions combine", Roundtable.targets(in: "@grok and @codex, thoughts?", among: table.enabledTargets), [.grok, .codex])
            audit.equal("a mention of a disabled agent falls back to everyone", Roundtable.targets(in: "@codex?", among: [.grok, .claude]), [.grok, .claude])

            await table.send("Should we add a queue or a lock?")
            audit.equal("one session per agent was opened", backends.values.map(\.count), [1, 1, 1])
            let speakers = table.entries.map(\.speaker)
            audit.equal("the transcript holds the question, three answers and three replies", speakers, ["human", "grok", "claude", "codex", "grok", "claude", "codex"])
            let first = backends[.claude]!.first!.prompts
            audit.check("the first prompt introduces the roundtable and carries the question",
                        first.count == 2 && first[0].contains("You are Claude in a roundtable with Grok, Codex and the user") && first[0].contains("[You] Should we add a queue or a lock?"))
            audit.check("the second prompt shows the others' answers and not the agent's own",
                        first[1].contains("[Grok] Grok says") && first[1].contains("[Codex] Codex says") && !first[1].contains("[Claude] Claude says") && first[1].contains("agree"))
            audit.check("the first prompt forbids file changes", first[0].contains("do not modify files"))
            audit.equal("reported costs are kept per entry", table.entries.first { $0.speaker == "claude" && $0.round == 1 }?.costUSD, 0.01)
            audit.check("entries are attributed and rounds numbered", table.entries.filter { $0.round == 2 }.count == 3 && table.entries[1].round == 1)
            audit.check("the run ended idle", !table.isRunning && table.thinking.isEmpty)

            table.rounds = 1
            await table.send("@Codex only you: is 6 a good number?")
            audit.equal("a mention sends only to that agent", backends[.codex]!.first!.prompts.count, 3)
            audit.equal("…and the others were not asked", backends[.grok]!.first!.prompts.count + backends[.claude]!.first!.prompts.count, 4)
            audit.check("with one reply round there is no second round", table.entries.suffix(2).map(\.speaker) == ["human", "codex"])
            let codexPrompt = backends[.codex]!.first!.prompts.last ?? ""
            audit.check("a later prompt carries only what the agent has not seen", codexPrompt.contains("New messages since you last spoke") && codexPrompt.contains("is 6 a good number") && !codexPrompt.contains("Should we add a queue"))

            let reloaded = Roundtable()
            reloaded.attach(project: project, storeDirectory: store)
            audit.equal("the transcript persists per project", reloaded.entries.map(\.text), table.entries.map(\.text))
            let mode = (try? FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            audit.equal("the store folder is owner-only", mode & 0o777, 0o700)

            audit.section("Roundtable — refusals, failures, stop and idle release")
            _ = await waitUntil(2) { table.activeSessions.isEmpty }
            audit.check("idle sessions are released after the delay", table.activeSessions.isEmpty && table.notice?.contains("released") == true, table.notice ?? "nil")
            await table.send("@Grok back again")
            audit.equal("a released agent reconnects on a new backend", backends[.grok]!.count, 2)
            let reconnect = backends[.grok]!.last!.prompts.first ?? ""
            audit.equal("…that resumes the provider's own session", backends[.grok]!.last!.sessionSettings.resumeSession, "scripted-grok")
            audit.check("…so it gets only the new message, not a recap of the transcript it already holds", reconnect.contains("back again") && reconnect.contains("New messages since you last spoke") && !reconnect.contains("Recent transcript"))

            let refusing = ScriptedBackend(provider: .claude, scripts: [[
                .permission(PermissionRequest(title: "Write a.txt", detail: "", options: [PermissionOption(id: "allow-once", name: "Yes", kind: "allow_once"), PermissionOption(id: "reject-once", name: "No", kind: "reject_once")], reply: { _ in })),
                .assistantDelta("Fine, no writes."), .turnFinished(stopReason: "end_turn", costUSD: nil)]])
            let failing = ScriptedBackend(provider: .codex, scripts: [[.failure("quota exhausted")]])
            let silent = ScriptedBackend(provider: .grok, scripts: [])
            let hard = Roundtable()
            hard.installed = [.grok, .claude, .codex]
            hard.stallTimeout = 0.3
            hard.makeBackend = { provider in
                switch provider { case .claude: return refusing; case .codex: return failing; case .grok: return silent }
            }
            hard.attach(project: project, storeDirectory: base.appendingPathComponent("store2"))
            hard.rounds = 1
            await hard.send("Try to write a file")
            audit.check("a tool request is refused and the answer still lands", hard.entries.contains { $0.speaker == "claude" && $0.text == "Fine, no writes." && !$0.failed })
            audit.check("a failed agent is shown as failed with its reason", hard.entries.contains { $0.speaker == "codex" && $0.failed && $0.text.contains("quota") })
            audit.check("a silent agent is shown as failed by the stall deadline", hard.entries.contains { $0.speaker == "grok" && $0.failed })

            let stopping = Roundtable()
            stopping.installed = [.grok]
            stopping.stallTimeout = 5
            let neverAnswers = ScriptedBackend(provider: .grok, scripts: [])
            stopping.makeBackend = { _ in neverAnswers }
            stopping.attach(project: project, storeDirectory: base.appendingPathComponent("store3"))
            let run = Task { await stopping.send("Hello?") }
            _ = await waitUntil(2) { stopping.isRunning && neverAnswers.prompts.count == 1 }
            stopping.stop()
            await run.value
            audit.check("stop ends the run, cancels the session and marks the transcript", !stopping.isRunning && neverAnswers.stopCount >= 1 && stopping.entries.last?.text == "(stopped)")

            let model = AppModel(trust: .forAudit)
            defer { model.shutdown() }
            model.installed = [.grok: true, .claude: true, .codex: false]
            model.openProject(project)
            audit.equal("opening a project attaches the roundtable with the installed agents", model.roundtable.installed, [.grok, .claude])
            audit.check("the assistant mode exists", AssistantMode.allCases.contains(.roundtable))
            audit.check("the app gives the roundtable its working-copy plumbing and approval sheet",
                        model.roundtable.makeWorkspace != nil && model.roundtable.loadWorkspace != nil && model.roundtable.permissionHandler != nil)
            model.autoApprove = true
            audit.check("the project's run-without-asking rule reaches the roundtable", model.roundtable.autoApprove)
            model.autoApprove = false

            audit.section("Roundtable — unlimited replies end when everyone has nothing further")
            audit.check("a pass is a short 'nothing further' reply", Roundtable.isPass("Nothing further.") && Roundtable.isPass("I have nothing to add.") && Roundtable.isPass("**Nothing further**"))
            audit.check("a real contribution is not a pass, even when it uses the words",
                        !Roundtable.isPass("I have nothing further to add on the queue, but the lock still needs a timeout because the worker can hang.") && !Roundtable.isPass("Use a queue."))
            let unlimited = Roundtable()
            unlimited.installed = [.grok, .claude]
            unlimited.stallTimeout = 2
            unlimited.unlimitedReplies = true
            unlimited.unlimitedCeiling = 6
            var unlimitedBackends: [Provider: ScriptedBackend] = [:]
            unlimited.makeBackend = { provider in
                // Grok passes from reply round 1; Claude keeps going for two reply rounds, then passes.
                let answers: [String] = provider == .grok
                    ? ["Grok: a queue.", "Nothing further.", "Nothing further.", "Nothing further.", "Nothing further.", "Nothing further.", "Nothing further."]
                    : ["Claude: a lock.", "Claude: the queue needs a timeout.", "Claude: and a metric.", "Nothing further.", "Nothing further.", "Nothing further.", "Nothing further."]
                let backend = ScriptedBackend(provider: provider, scripts: answers.map { [.assistantDelta($0), .turnFinished(stopReason: "end_turn", costUSD: nil)] })
                unlimitedBackends[provider] = backend
                return backend
            }
            unlimited.attach(project: project, storeDirectory: base.appendingPathComponent("store-unlimited"))
            await unlimited.send("Queue or lock?")
            audit.equal("rounds continue past the capped maximum while someone still contributes, and stop when everyone passes", unlimited.lastRoundCount, 4)
            audit.equal("…and Grok, who passed in reply round 1 and was never named, was not asked again: two prompts for Grok, four for Claude",
                        [unlimitedBackends[.grok]?.prompts.count ?? 0, unlimitedBackends[.claude]?.prompts.count ?? 0], [2, 4])
            audit.check("the unlimited prompt names the pass phrase", unlimitedBackends[.claude]?.prompts[1].contains(Roundtable.passPhrase) == true)
            audit.check("the run ended idle without hitting the ceiling", !unlimited.isRunning && unlimited.notice == nil, unlimited.notice ?? "nil")
            let endless = Roundtable()
            endless.installed = [.grok, .claude]
            endless.stallTimeout = 2
            endless.unlimitedReplies = true
            endless.unlimitedCeiling = 3
            endless.makeBackend = { provider in
                ScriptedBackend(provider: provider, scripts: (0..<10).map { _ in [.assistantDelta("\(provider.displayName) still has more."), .turnFinished(stopReason: "end_turn", costUSD: nil)] })
            }
            endless.attach(project: project, storeDirectory: base.appendingPathComponent("store-endless"))
            await endless.send("Argue forever.")
            audit.equal("the hard ceiling ends a run nobody passes", endless.lastRoundCount, 4)
            audit.check("…and says so", endless.notice?.contains("hard stop") == true, endless.notice ?? "nil")
            let capped = Roundtable()
            capped.installed = [.grok, .claude]
            capped.stallTimeout = 2
            capped.rounds = 3
            capped.makeBackend = { provider in
                ScriptedBackend(provider: provider, scripts: (0..<10).map { _ in [.assistantDelta("\(provider.displayName) more."), .turnFinished(stopReason: "end_turn", costUSD: nil)] })
            }
            capped.attach(project: project, storeDirectory: base.appendingPathComponent("store-capped"))
            await capped.send("Capped.")
            audit.equal("capped replies still stop at the cap", capped.lastRoundCount, 3)

            audit.section("Roundtable — Work mode shares a working copy, takes turns and asks for approvals")
            let work = Roundtable()
            work.installed = [.grok, .codex]
            work.stallTimeout = 2
            work.rounds = 1
            var workBackends: [Provider: ScriptedBackend] = [:]
            var forwarded: [(PermissionRequest, Provider)] = []
            work.permissionHandler = { request, provider in
                forwarded.append((request, provider))
                request.reply(request.options.first { $0.kind == "allow_once" }?.id)
            }
            let workRoot = base.appendingPathComponent("work-copy", isDirectory: true)
            try? FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
            var madeWorkspaces = 0
            work.makeWorkspace = { project in
                madeWorkspaces += 1
                return TaskWorkspace(id: UUID(), projectRoot: project, executionRoot: workRoot, createdAt: Date(), isolated: true, notices: [])
            }
            var removed: [UUID] = []
            work.removeWorkspace = { removed.append($0) }
            work.makeBackend = { provider in
                let backend = ScriptedBackend(provider: provider, scripts: provider == .grok
                    ? [[.permission(PermissionRequest(title: "Write notes.md", detail: "", options: [PermissionOption(id: "allow-once", name: "Yes", kind: "allow_once"), PermissionOption(id: "reject-once", name: "No", kind: "reject_once")], reply: { _ in })),
                        .toolStarted(id: "t1", title: "Edit notes.md", kind: "edit", input: #"{"file_path":"notes.md"}"#),
                        .assistantDelta("Grok wrote the notes.\nFILES: notes.md"), .turnFinished(stopReason: "end_turn", costUSD: nil)]]
                    : [[.assistantDelta("Codex read Grok's notes and has nothing to change.\nFILES: none"), .turnFinished(stopReason: "end_turn", costUSD: nil)]])
                workBackends[provider] = backend
                return backend
            }
            work.attach(project: project, storeDirectory: base.appendingPathComponent("store-work"))
            work.mode = .work
            await work.send("Write the plan into notes.md.")
            audit.equal("the first message makes one working copy", madeWorkspaces, 1)
            audit.check("every session runs in the working copy, not the project",
                        workBackends.values.allSatisfy { $0.projectURL?.standardizedFileURL == workRoot.standardizedFileURL }, workBackends.values.map { $0.projectURL?.path ?? "nil" }.joined(separator: " | "))
            audit.check("the work prompt explains the shared copy, the tools and the FILES line, and drops the no-edit rule",
                        (workBackends[.grok]?.prompts.first ?? "").contains("share one working copy") && (workBackends[.grok]?.prompts.first ?? "").contains("FILES:") && !(workBackends[.grok]?.prompts.first ?? "").contains("do not modify files"))
            audit.check("a tool approval is forwarded to the app's sheet instead of being refused", forwarded.count == 1 && forwarded.first?.1 == .grok)
            audit.check("the turn landed with its edited files", work.entries.contains { $0.speaker == "grok" && !$0.failed && $0.editedFiles == ["notes.md"] })
            audit.equal("edited paths are shown relative to the working copy", Roundtable.relativePaths([workRoot.path + "/src/a.py", "b.py"], root: workRoot), ["src/a.py", "b.py"])
            audit.check("turns are sequential: the second agent's prompt already shows the first agent's reply and edit",
                        (workBackends[.codex]?.prompts.first ?? "").contains("[Grok] (edited: notes.md) Grok wrote the notes"), workBackends[.codex]?.prompts.first ?? "nil")
            let reopened = Roundtable()
            var loaded: [UUID] = []
            reopened.loadWorkspace = { id in loaded.append(id); return work.workspace }
            reopened.attach(project: project, storeDirectory: base.appendingPathComponent("store-work"))
            _ = await waitUntil(2) { reopened.workspace != nil }
            audit.check("mode and working copy persist per project", reopened.mode == .work && loaded == [work.workspace!.id] && reopened.workspace?.id == work.workspace?.id)
            let workspaceID = work.workspace!.id
            work.clear()
            _ = await waitUntil(2) { removed == [workspaceID] }
            audit.check("Clear forgets the transcript and removes the working copy", work.entries.isEmpty && work.workspace == nil && removed == [workspaceID])
            let auto = Roundtable()
            auto.installed = [.grok]
            auto.stallTimeout = 2
            auto.autoApprove = true
            var autoForwarded = 0
            auto.permissionHandler = { _, _ in autoForwarded += 1 }
            auto.makeWorkspace = { project in TaskWorkspace(id: UUID(), projectRoot: project, executionRoot: workRoot, createdAt: Date(), isolated: true, notices: []) }
            auto.makeBackend = { provider in
                ScriptedBackend(provider: provider, scripts: [[
                    .permission(PermissionRequest(title: "Write a.txt", detail: "", options: [PermissionOption(id: "allow-once", name: "Yes", kind: "allow_once"), PermissionOption(id: "reject-once", name: "No", kind: "reject_once")], reply: { _ in })),
                    .assistantDelta("Done.\nFILES: a.txt"), .turnFinished(stopReason: "end_turn", costUSD: nil)]])
            }
            auto.attach(project: project, storeDirectory: base.appendingPathComponent("store-auto"))
            auto.mode = .work
            await auto.send("Write a.txt")
            audit.check("with run-without-asking on, work-mode approvals are answered without the sheet", autoForwarded == 0 && auto.entries.contains { $0.speaker == "grok" && !$0.failed })
            let discussStill = Roundtable()
            discussStill.installed = [.grok]
            discussStill.stallTimeout = 2
            var discussForwarded = 0
            discussStill.permissionHandler = { _, _ in discussForwarded += 1 }
            discussStill.makeBackend = { provider in
                ScriptedBackend(provider: provider, scripts: [[
                    .permission(PermissionRequest(title: "Write a.txt", detail: "", options: [PermissionOption(id: "allow-once", name: "Yes", kind: "allow_once"), PermissionOption(id: "reject-once", name: "No", kind: "reject_once")], reply: { _ in })),
                    .assistantDelta("Fine, no writes."), .turnFinished(stopReason: "end_turn", costUSD: nil)]])
            }
            discussStill.attach(project: project, storeDirectory: base.appendingPathComponent("store-discuss"))
            await discussStill.send("Try to write")
            audit.check("Discuss mode still refuses tools even with a handler available", discussForwarded == 0 && discussStill.entries.contains { $0.text == "Fine, no writes." })

            audit.section("Roundtable — each seat picks its model and reasoning effort")
            let seats = Roundtable()
            seats.installed = [.grok, .claude]
            seats.stallTimeout = 2
            seats.rounds = 1
            var seatBackends: [Provider: [ScriptedBackend]] = [:]
            seats.makeBackend = { provider in
                let backend = ScriptedBackend(provider: provider, scripts: (0..<4).map { _ in [.assistantDelta("\(provider.displayName) ok."), .turnFinished(stopReason: "end_turn", costUSD: nil)] })
                backend.currentModel = provider == .grok ? "grok-4.6" : "claude-fable-5-1"
                seatBackends[provider, default: []].append(backend)
                return backend
            }
            seats.attach(project: project, storeDirectory: base.appendingPathComponent("store-seats"))
            seats.setSeat(model: "grok-4.5", for: .grok)
            seats.setSeat(effort: "max", for: .claude)
            await seats.send("Hello")
            audit.check("a seat's model is configured before its session starts", seatBackends[.grok]?.first?.configuredModel == "grok-4.5" && seatBackends[.grok]?.first?.configuredBeforeStart == true)
            audit.check("a seat's effort likewise", seatBackends[.claude]?.first?.configuredEffort == "max" && seatBackends[.claude]?.first?.configuredBeforeStart == true)
            audit.check("Inherit leaves the other setting alone", seatBackends[.grok]?.first?.configuredEffort == nil && seatBackends[.claude]?.first?.configuredModel == nil)
            audit.check("each reply records the model and effort that produced it",
                        seats.entries.contains { $0.speaker == "grok" && $0.model == "grok-4.5" } && seats.entries.contains { $0.speaker == "claude" && $0.model == "claude-fable-5-1" && $0.effort == "max" })
            seats.setSeat(model: "grok-4.6", for: .grok)
            await seats.send("Again")
            audit.equal("changing a seat's model starts a fresh session for that agent only", seatBackends.mapValues(\.count), [.grok: 2, .claude: 1])
            audit.equal("…configured with the new model", seatBackends[.grok]?.last?.configuredModel, "grok-4.6")
            seats.setSeat(model: "grok-4.6", for: .grok)
            audit.equal("setting the same value again does not restart anything", seatBackends[.grok]?.count, 2)
            let reopenedSeats = Roundtable()
            reopenedSeats.attach(project: project, storeDirectory: base.appendingPathComponent("store-seats"))
            audit.check("seat choices persist per project", reopenedSeats.seatModels[.grok] == "grok-4.6" && reopenedSeats.seatEfforts[.claude] == "max" && reopenedSeats.seatModels[.claude] == nil)

            audit.section("Roundtable — a seat can move to another model without stopping the run")
            audit.check("an out-of-credits reply is read as a subscription limit, not a broken request",
                        Roundtable.isUsageLimit("You're out of usage credits. Switch to another model, or manage usage credits at claude.ai/settings/usage?from=cc_cli_limit_message, to continue.")
                        && Roundtable.isUsageLimit("Rate limit reached for this model") && Roundtable.isUsageLimit("429 Too Many Requests"))
            audit.check("an ordinary failure is not", !Roundtable.isUsageLimit("the file could not be written") && !Roundtable.isUsageLimit("went silent"))

            let limited = Roundtable()
            limited.installed = [.claude, .codex]
            limited.stallTimeout = 2
            limited.rounds = 1
            var limitedBackends: [Provider: [ScriptedBackend]] = [:]
            limited.makeBackend = { provider in
                let backend = provider == .claude
                    ? ScriptedBackend(provider: provider, scripts: [[.failure("You're out of usage credits. Switch to another model, or manage usage credits at claude.ai/settings/usage, to continue.")]])
                    : ScriptedBackend(provider: provider, scripts: [[.assistantDelta("Codex ok."), .turnFinished(stopReason: "end_turn", costUSD: nil)]])
                backend.currentModel = provider == .claude ? "claude-fable-5-1" : "gpt-6-astra"
                limitedBackends[provider, default: []].append(backend)
                return backend
            }
            limited.attach(project: project, storeDirectory: base.appendingPathComponent("store-limited"))
            await limited.send("Hello")
            audit.check("the seat that ran out is remembered", limited.usageLimited == [.claude])
            audit.check("the notice names the agent, its model and what to do",
                        (limited.notice ?? "").contains("Claude is out of usage credits on Fable 5.1")
                        && (limited.notice ?? "").contains("Pick another model for its seat")
                        && (limited.notice ?? "").contains("no need to stop"), limited.notice ?? "no notice")
            audit.check("the other agent still answered", limited.entries.contains { $0.speaker == "codex" && !$0.failed })
            limited.setSeat(model: "claude-opus-5", for: .claude)
            audit.check("choosing another model clears the warning", limited.usageLimited.isEmpty && limited.notice == nil)

            let midRun = Roundtable()
            midRun.installed = [.claude, .codex]
            midRun.stallTimeout = 5
            midRun.rounds = 2
            var midRunBackends: [Provider: [ScriptedBackend]] = [:]
            midRun.makeBackend = { provider in
                let backend = ScriptedBackend(provider: provider, scripts: (0..<4).map { _ in
                    [.assistantDelta("\(provider.displayName) is working"), .assistantDelta(" on it."), .turnFinished(stopReason: "end_turn", costUSD: nil)] })
                backend.eventDelay = 0.25
                backend.currentModel = provider == .claude ? "claude-fable-5-1" : "gpt-6-astra"
                midRunBackends[provider, default: []].append(backend)
                return backend
            }
            midRun.attach(project: project, storeDirectory: base.appendingPathComponent("store-midrun"))
            let running = Task { await midRun.send("Hello") }
            var waited = 0
            while !(midRun.isRunning && midRun.thinking.contains(.claude)) && waited < 100 {
                try? await Task.sleep(nanoseconds: 20_000_000); waited += 1
            }
            audit.check("the run is under way with Claude mid-turn", midRun.isRunning && midRun.thinking.contains(.claude))
            let sessionsBefore = midRunBackends[.claude]?.count ?? 0
            midRun.setSeat(model: "claude-opus-5", for: .claude)
            audit.check("the turn in flight is not interrupted", midRunBackends[.claude]?.first?.stopCount == 0 && midRunBackends[.claude]?.count == sessionsBefore)
            await running.value
            audit.check("Claude's next turn ran on a new session", (midRunBackends[.claude]?.count ?? 0) == sessionsBefore + 1)
            audit.equal("…configured with the model chosen mid-run", midRunBackends[.claude]?.last?.configuredModel, "claude-opus-5")
            audit.equal("the other agent kept its session", midRunBackends[.codex]?.count, 1)
            audit.check("the first turn still produced its reply", midRun.entries.contains { $0.speaker == "claude" && $0.round == 1 && !$0.failed })
            audit.check("the reply after the change records the new model", midRun.entries.contains { $0.speaker == "claude" && $0.round == 2 && $0.model == "claude-opus-5" },
                        midRun.entries.filter { $0.speaker == "claude" }.map { "r\($0.round ?? 0):\($0.model ?? "-")" }.joined(separator: " "))

            audit.section("Roundtable — you can steer the conversation without stopping it")
            let idleTable = Roundtable()
            idleTable.installed = [.grok, .claude]
            idleTable.attach(project: project, storeDirectory: base.appendingPathComponent("store-steer-idle"))
            audit.check("there is nothing to steer when no run is going", idleTable.steer("hello") == false && idleTable.entries.isEmpty)

            /// Runs a table until it finishes, steering once the given condition holds.
            @MainActor func runSteered(_ table: Roundtable, message: String, storeName: String, ready: @escaping () -> Bool) async -> Bool {
                table.attach(project: project, storeDirectory: base.appendingPathComponent(storeName))
                let task = Task { await table.send("Start.") }
                var waited = 0
                while !(table.isRunning && ready()) && waited < 250 {
                    try? await Task.sleep(nanoseconds: 20_000_000); waited += 1
                }
                let steered = table.isRunning && ready() ? table.steer(message) : false
                await task.value
                return steered
            }

            // Replies capped at 1 (no reply rounds at all): the steer still gets a round.
            let cappedTable = Roundtable()
            cappedTable.installed = [.grok, .claude]
            cappedTable.stallTimeout = 5
            cappedTable.rounds = 1
            cappedTable.unlimitedReplies = false
            var cappedBackends: [Provider: ScriptedBackend] = [:]
            cappedTable.makeBackend = { provider in
                let backend = ScriptedBackend(provider: provider, scripts: (0..<4).map { _ in
                    [.assistantDelta("\(provider.displayName) working"), .assistantDelta(" on it."), .turnFinished(stopReason: "end_turn", costUSD: nil)] })
                backend.eventDelay = 0.25
                cappedBackends[provider] = backend
                return backend
            }
            let cappedSteered = await runSteered(cappedTable, message: "Actually, start with the tests.", storeName: "store-steer-capped") { cappedTable.thinking.contains(.grok) }
            audit.check("a message typed during a run is accepted", cappedSteered)
            audit.check("it joins the transcript as the user's own message",
                        cappedTable.entries.contains { $0.speaker == "human" && $0.text == "Actually, start with the tests." })
            audit.check("the agents answer it even though the reply rounds were used up",
                        cappedTable.entries.contains { $0.speaker != "human" && ($0.round ?? 0) >= 2 },
                        cappedTable.entries.map { "\($0.speaker)/r\($0.round ?? 0)" }.joined(separator: " "))
            let steerPrompt = cappedBackends[.claude]?.prompts.last ?? ""
            audit.check("the agent is given the message and told it arrived mid-run",
                        steerPrompt.contains("Actually, start with the tests.") && steerPrompt.contains("just added a message above"), steerPrompt.suffix(160).description)
            audit.check("the run then ends as before", !cappedTable.isRunning)
            let roundsAfterSteer = cappedTable.entries.filter { $0.speaker != "human" }.count
            await cappedTable.send("Next question.")
            audit.equal("the next run is not given a phantom extra round by the steer that is done",
                        cappedTable.entries.filter { $0.speaker != "human" }.count - roundsAfterSteer, 2)

            // Unlimited replies where everyone has already said "Nothing further.": a steer that
            // lands during that round still gets answered.
            let passingTable = Roundtable()
            passingTable.installed = [.grok, .claude]
            passingTable.stallTimeout = 5
            passingTable.unlimitedReplies = true
            var passingBackends: [Provider: ScriptedBackend] = [:]
            passingTable.makeBackend = { provider in
                let backend = ScriptedBackend(provider: provider, scripts: [
                    [.assistantDelta("\(provider.displayName) answers."), .turnFinished(stopReason: "end_turn", costUSD: nil)],
                    [.assistantDelta("Nothing further."), .turnFinished(stopReason: "end_turn", costUSD: nil)],
                    [.assistantDelta("Noted, I will look at the tests."), .turnFinished(stopReason: "end_turn", costUSD: nil)],
                    [.assistantDelta("Nothing further."), .turnFinished(stopReason: "end_turn", costUSD: nil)],
                ])
                backend.eventDelay = 0.3
                passingBackends[provider] = backend
                return backend
            }
            let passingSteered = await runSteered(passingTable, message: "One more thing: check the tests.", storeName: "store-steer-passing") {
                passingTable.entries.filter { ($0.round ?? 0) == 1 && $0.speaker != "human" }.count == 2 && !passingTable.thinking.isEmpty
            }
            audit.check("a steer during the round where everyone passes is accepted", passingSteered)
            audit.check("…and the agents come back for another round to answer it",
                        passingTable.entries.contains { $0.speaker != "human" && ($0.round ?? 0) >= 3 },
                        passingTable.entries.map { "\($0.speaker)/r\($0.round ?? 0)" }.joined(separator: " "))
            audit.check("the steered round carries the message and says it arrived mid-run",
                        passingBackends[.grok]?.prompts.contains { $0.contains("One more thing: check the tests.") && $0.contains("just added a message above") } == true,
                        (passingBackends[.grok]?.prompts.count ?? 0).description + " prompts")
            audit.check("the conversation then runs on until everyone passes again",
                        passingTable.entries.filter { $0.speaker != "human" }.suffix(2).allSatisfy { Roundtable.isPass($0.text) } && !passingTable.isRunning)

            // One agent, so there are no reply rounds at all.
            let aloneTable = Roundtable()
            aloneTable.installed = [.codex]
            aloneTable.stallTimeout = 5
            aloneTable.rounds = 1
            var aloneBackend: ScriptedBackend?
            aloneTable.makeBackend = { provider in
                let backend = ScriptedBackend(provider: provider, scripts: (0..<3).map { _ in
                    [.assistantDelta("Codex working"), .assistantDelta(" on it."), .turnFinished(stopReason: "end_turn", costUSD: nil)] })
                backend.eventDelay = 0.3
                aloneBackend = backend
                return backend
            }
            let aloneSteered = await runSteered(aloneTable, message: "Stop and summarise instead.", storeName: "store-steer-alone") { aloneTable.thinking.contains(.codex) }
            audit.check("a single agent answers a steer too", aloneSteered && aloneTable.entries.contains { $0.speaker == "codex" && ($0.round ?? 0) >= 2 })
            audit.check("…with the message in its prompt", (aloneBackend?.prompts.last ?? "").contains("Stop and summarise instead."))
            audit.check("an empty steer is ignored", aloneTable.steer("   ") == false)
            audit.section("Roundtable — the agent you put in charge goes first and runs the plan")
            audit.equal("\"Claude, you lead this one\" names Claude", Roundtable.leaderMention(in: "Claude, you lead this one: pick a product."), .claude)
            audit.equal("\"let Codex take the lead\" names Codex", Roundtable.leaderMention(in: "Let Codex take the lead and the rest of you follow."), .codex)
            audit.equal("\"Grok leads\" names Grok", Roundtable.leaderMention(in: "grok leads; everyone else reviews"), .grok)
            audit.equal("\"@Claude lead this\" names Claude", Roundtable.leaderMention(in: "@Claude lead this session please"), .claude)
            audit.equal("\"Codex is in charge\" names Codex", Roundtable.leaderMention(in: "For today Codex is in charge of the plan."), .codex)
            audit.equal("\"leader: Grok\" names Grok", Roundtable.leaderMention(in: "leader: Grok. Claude and Codex build."), .grok)
            audit.check("a message that names no leader sets none", Roundtable.leaderMention(in: "pick a leader from the three of you and bring money in") == nil
                        && Roundtable.leaderMention(in: "Claude, review the plan; Codex, fix the tests") == nil)
            audit.check("two agents put in charge at once sets none", Roundtable.leaderMention(in: "Claude leads the design and Codex leads the build") == nil)

            let led = Roundtable()
            led.installed = [.grok, .claude, .codex]
            led.stallTimeout = 5
            led.rounds = 2
            led.mode = .work
            let ledRoot = base.appendingPathComponent("led-work", isDirectory: true)
            try? FileManager.default.createDirectory(at: ledRoot, withIntermediateDirectories: true)
            led.makeWorkspace = { project in TaskWorkspace(id: UUID(), projectRoot: project, executionRoot: ledRoot, createdAt: Date(), isolated: true, notices: []) }
            var ledBackends: [Provider: ScriptedBackend] = [:]
            led.makeBackend = { provider in
                let backend = ScriptedBackend(provider: provider, scripts: (0..<4).map { _ in
                    [.assistantDelta("\(provider.displayName) reporting.\nFILES: none"), .turnFinished(stopReason: "end_turn", costUSD: nil)] })
                ledBackends[provider] = backend
                return backend
            }
            led.attach(project: project, storeDirectory: base.appendingPathComponent("store-led"))
            audit.check("a table starts with nobody in charge", led.leader == nil)
            await led.send("Codex, you lead: pick a product and give the others their parts.")
            audit.equal("the message puts Codex in charge", led.leader, .codex)
            let firstRound = led.entries.filter { ($0.round ?? 0) == 1 && $0.speaker != "human" }.map(\.speaker)
            audit.equal("Codex speaks first each round, then the usual order", firstRound, ["codex", "grok", "claude"])
            let secondRound = led.entries.filter { ($0.round ?? 0) == 2 && $0.speaker != "human" }.map(\.speaker)
            audit.equal("…and again in the reply round", secondRound, ["codex", "grok", "claude"])
            audit.check("Codex is told it leads", (ledBackends[.codex]?.prompts.first ?? "").contains("You lead this roundtable"))
            audit.check("the others are told to follow Codex", (ledBackends[.grok]?.prompts.first ?? "").contains("Codex leads this roundtable")
                        && (ledBackends[.claude]?.prompts.first ?? "").contains("report back to Codex"))
            let reopenedLed = Roundtable()
            reopenedLed.attach(project: project, storeDirectory: base.appendingPathComponent("store-led"))
            audit.equal("the leader is saved with the roundtable", reopenedLed.leader, .codex)
            led.setLeader(.claude)
            audit.equal("Leads in the seats changes it", led.leader, .claude)
            await led.send("Carry on.")
            let thirdOrder = led.entries.suffix(3).map(\.speaker)
            audit.equal("the new leader goes first from the next run", thirdOrder, ["claude", "grok", "codex"])
            led.setLeader(nil)
            await led.send("And now nobody leads.")
            audit.equal("with nobody in charge the order is Grok, Claude, Codex again", led.entries.suffix(3).map(\.speaker), ["grok", "claude", "codex"])
            audit.check("…and nobody is told to lead or follow", !(ledBackends[.grok]?.prompts.last ?? "").contains("leads this roundtable") && !(ledBackends[.grok]?.prompts.last ?? "").contains("You lead"))

            let discussLed = Roundtable()
            discussLed.installed = [.grok, .claude]
            discussLed.stallTimeout = 5
            discussLed.rounds = 1
            discussLed.makeBackend = { provider in ScriptedBackend(provider: provider, scripts: [[.assistantDelta("\(provider.displayName) here."), .turnFinished(stopReason: "end_turn", costUSD: nil)]]) }
            discussLed.attach(project: project, storeDirectory: base.appendingPathComponent("store-discuss-led"))
            await discussLed.send("Claude leads. What should we build?")
            audit.equal("in Discuss mode the leader's answer is shown first", discussLed.entries.filter { $0.speaker != "human" }.map(\.speaker), ["claude", "grok"])

            audit.section("Roundtable — sessions are resumed, not recapped, and passes are not asked again")
            let resumeTable = Roundtable()
            resumeTable.installed = [.grok, .claude]
            resumeTable.stallTimeout = 5
            resumeTable.rounds = 1
            resumeTable.idleReleaseDelay = 0.05
            var resumeBackends: [Provider: [ScriptedBackend]] = [:]
            resumeTable.makeBackend = { provider in
                let backend = ScriptedBackend(provider: provider, scripts: (0..<6).map { _ in [.assistantDelta("\(provider.displayName) answers."), .turnFinished(stopReason: "end_turn", costUSD: nil)] })
                resumeBackends[provider, default: []].append(backend)
                return backend
            }
            resumeTable.attach(project: project, storeDirectory: base.appendingPathComponent("store-resume"))
            await resumeTable.send("First question.")
            audit.check("the first turn starts fresh with the transcript recap", resumeBackends[.grok]?.first?.sessionSettings.resumeSession == "" && (resumeBackends[.grok]?.first?.prompts.first ?? "").contains("Reply to the user's latest message"))
            try? await Task.sleep(nanoseconds: 400_000_000)   // the idle release fires
            audit.check("idle releases the sessions and says they will be resumed", resumeTable.activeSessions.isEmpty && (resumeTable.notice ?? "").contains("resumes"))
            await resumeTable.send("Second question.")
            let second = resumeBackends[.grok]?.last
            audit.equal("the next message resumes the provider's own session", second?.sessionSettings.resumeSession, "scripted-grok")
            audit.check("…so only the new message is sent, not a recap", (second?.prompts.first ?? "").contains("New messages since you last spoke") && !(second?.prompts.first ?? "").contains("Recent transcript:") && !(second?.prompts.first ?? "").contains("You are Grok in a roundtable"))
            audit.check("the resumed seats are marked", resumeTable.resumedProviders == [.grok, .claude])
            let reopenedResume = Roundtable()
            reopenedResume.installed = [.grok, .claude]
            reopenedResume.stallTimeout = 5
            reopenedResume.rounds = 1
            var reopenedBackends: [Provider: ScriptedBackend] = [:]
            reopenedResume.makeBackend = { provider in
                let backend = ScriptedBackend(provider: provider, scripts: [[.assistantDelta("\(provider.displayName) again."), .turnFinished(stopReason: "end_turn", costUSD: nil)]])
                reopenedBackends[provider] = backend
                return backend
            }
            reopenedResume.attach(project: project, storeDirectory: base.appendingPathComponent("store-resume"))
            await reopenedResume.send("Third question, after a relaunch.")
            audit.equal("after a relaunch the session ids are still resumed", reopenedBackends[.claude]?.sessionSettings.resumeSession, "scripted-claude")
            audit.check("…and the prompt carries only what that session has not seen", (reopenedBackends[.claude]?.prompts.first ?? "").contains("Third question") && !(reopenedBackends[.claude]?.prompts.first ?? "").contains("First question"))

            let dropped = Roundtable()
            dropped.installed = [.grok]
            dropped.stallTimeout = 5
            dropped.rounds = 1
            var droppedBackends: [ScriptedBackend] = []
            dropped.makeBackend = { provider in
                let backend = droppedBackends.isEmpty
                    ? ScriptedBackend(provider: provider, scripts: [[.assistantDelta("Grok answers."), .turnFinished(stopReason: "end_turn", costUSD: nil)]])
                    : ScriptedBackend(provider: provider, scripts: [[.assistantDelta("Grok again."), .turnFinished(stopReason: "end_turn", costUSD: nil)]], dropsSessionOnStart: true)
                droppedBackends.append(backend)
                return backend
            }
            dropped.attach(project: project, storeDirectory: base.appendingPathComponent("store-dropped"))
            await dropped.send("Hello")
            dropped.releaseIdle()
            await dropped.send("Again")
            audit.check("a session the provider no longer has falls back to a fresh start with the recap",
                        droppedBackends.count == 2 && droppedBackends[1].sessionSettings.resumeSession == "scripted-grok"
                        && (droppedBackends[1].prompts.first ?? "").contains("Recent transcript:") && !dropped.resumedProviders.contains(.grok),
                        droppedBackends.last?.prompts.first?.prefix(120).description ?? "")

            audit.section("Roundtable — an agent with nothing further is not asked again until someone names it")
            audit.equal("who still talks: contributors stay, passes drop — a pass given after being named counts as the answer",
                        Roundtable.stillTalking([.grok, .claude, .codex], entries: [
                            Roundtable.Entry(speaker: "grok", text: "Nothing further.", round: 1),
                            Roundtable.Entry(speaker: "claude", text: "I propose X. Codex, can you check it?", round: 1),
                            Roundtable.Entry(speaker: "codex", text: "Nothing further.", round: 1),
                        ], previousRound: 1), [.claude])
            audit.equal("…but a pass that is named afterwards comes back",
                        Roundtable.stillTalking([.grok, .claude, .codex], entries: [
                            Roundtable.Entry(speaker: "codex", text: "Nothing further.", round: 1),
                            Roundtable.Entry(speaker: "grok", text: "Nothing further.", round: 1),
                            Roundtable.Entry(speaker: "claude", text: "I propose X. Codex, can you check it?", round: 1),
                        ], previousRound: 1), [.claude, .codex])
            audit.equal("a pass in an earlier round still counts when the agent was skipped since",
                        Roundtable.stillTalking([.grok, .claude], entries: [
                            Roundtable.Entry(speaker: "grok", text: "Nothing further.", round: 1),
                            Roundtable.Entry(speaker: "claude", text: "Point A.", round: 1),
                            Roundtable.Entry(speaker: "claude", text: "Point B.", round: 2),
                        ], previousRound: 2), [.claude])
            audit.equal("a failed seat is treated as a pass", Roundtable.stillTalking([.grok, .claude], entries: [
                            Roundtable.Entry(speaker: "grok", text: "out of credits", round: 1, failed: true),
                            Roundtable.Entry(speaker: "claude", text: "Working on it.", round: 1),
                        ], previousRound: 1), [.claude])
            audit.equal("an agent that has not spoken is kept", Roundtable.stillTalking([.grok, .claude], entries: [
                            Roundtable.Entry(speaker: "claude", text: "Nothing further.", round: 1),
                        ], previousRound: 1), [.grok])
            let skipTable = Roundtable()
            skipTable.installed = [.grok, .claude, .codex]
            skipTable.stallTimeout = 5
            skipTable.unlimitedReplies = true
            var skipBackends: [Provider: ScriptedBackend] = [:]
            skipTable.makeBackend = { provider in
                let scripts: [[BackendEvent]] = switch provider {
                case .grok: [[.assistantDelta("Nothing further."), .turnFinished(stopReason: "end_turn", costUSD: nil)],
                             [.assistantDelta("Claude, yes: X works."), .turnFinished(stopReason: "end_turn", costUSD: nil)],
                             [.assistantDelta("Nothing further."), .turnFinished(stopReason: "end_turn", costUSD: nil)]]
                case .claude: [[.assistantDelta("I propose X."), .turnFinished(stopReason: "end_turn", costUSD: nil)],
                               [.assistantDelta("More on X. Grok, what do you think?"), .turnFinished(stopReason: "end_turn", costUSD: nil)],
                               [.assistantDelta("Nothing further."), .turnFinished(stopReason: "end_turn", costUSD: nil)]]
                case .codex: [[.assistantDelta("Nothing further."), .turnFinished(stopReason: "end_turn", costUSD: nil)]]
                }
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                skipBackends[provider] = backend
                return backend
            }
            skipTable.attach(project: project, storeDirectory: base.appendingPathComponent("store-skip"))
            await skipTable.send("Ideas?")
            let byRound = Dictionary(grouping: skipTable.entries.filter { $0.speaker != "human" }, by: { $0.round ?? 0 }).mapValues { $0.map(\.speaker) }
            audit.equal("round 1 has everyone", byRound[1] ?? [], ["grok", "claude", "codex"])
            audit.equal("round 2 asks only the one who contributed", byRound[2] ?? [], ["claude"])
            audit.equal("round 3 brings back the agent Claude named", byRound[3] ?? [], ["grok", "claude"])
            audit.equal("round 4 asks only the contributor again, who then passes, and the run ends", byRound[4] ?? [], ["grok"])
            audit.equal("Codex was asked exactly once", skipBackends[.codex]?.prompts.count, 1)
            audit.equal("…and eleven turns were spent instead of the twelve or more the old rounds would have", skipTable.entries.filter { $0.speaker != "human" }.count, 7)
            audit.check("the run ended on its own", !skipTable.isRunning)

            audit.section("Roundtable — a Grok seat's model is switched before its first prompt")
            // Inside the workspace: the scripted agent runs under the write confinement like the real one.
            let log = project.appendingPathComponent("grok-seat.log").path
            let scriptURL = base.appendingPathComponent("grok-seat.sh")
            try? ("#!/bin/sh\n" + #"""
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -nE 's/.*"id":([0-9]+).*/\1/p')
              case "$line" in
                *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\n' "$id";;
                *'"method":"session'*'new"'*) printf 'session/new\n' >> "LOGFILE"; printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"seat-session","models":{"currentModelId":"grok-4.6","availableModels":[{"modelId":"grok-4.6","name":"Grok 4.6"},{"modelId":"grok-4.5","name":"Grok 4.5"}]}}}\n' "$id";;
                *'"method":"session'*'set_model"'*) model=$(printf '%s' "$line" | sed -nE 's/.*"modelId":"([^"]+)".*/\1/p'); printf 'set_model:%s\n' "$model" >> "LOGFILE"; printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id";;
                *'"method":"session'*'prompt"'*) printf 'prompt\n' >> "LOGFILE"; printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id";;
              esac
            done
            """#.replacingOccurrences(of: "LOGFILE", with: log)).write(to: scriptURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            let grokSeat = GrokBackend()
            grokSeat.persistsSelection = false
            grokSeat.executableForTest = scriptURL.path
            grokSeat.preconfigure(model: "grok-4.5", effort: "low")
            await grokSeat.start(project: project, autoApprove: true)
            let afterStart = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            audit.check("the parked model is switched before start returns", afterStart.contains("set_model:grok-4.5") && grokSeat.currentModel == "grok-4.5", "log: \(afterStart.replacingOccurrences(of: "\n", with: " | ")) current: \(grokSeat.currentModel)")
            await grokSeat.send("hello")
            let afterPrompt = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            audit.equal("…so the first prompt runs on the chosen model", afterPrompt, ["session/new", "set_model:grok-4.5", "prompt"])
            grokSeat.stop()

            audit.section("Model catalog — every picker offers what the CLIs themselves list")
            let savedCodex = ModelCatalog.codexCacheURL, savedGrok = ModelCatalog.grokCacheURL
            defer { ModelCatalog.codexCacheURL = savedCodex; ModelCatalog.grokCacheURL = savedGrok }
            let codexCache = base.appendingPathComponent("codex-cache.json")
            try? #"""
            {"models":[{"slug":"gpt-7-fixture","display_name":"GPT-7 Fixture","supported_reasoning_levels":[{"effort":"low"},{"effort":"ultra"}]},
                       {"slug":"gpt-6-astra","display_name":"GPT-6-Astra","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}]},
                       {"slug":"gpt-5.5","display_name":"GPT-5.5","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}]}]}
            """#.write(to: codexCache, atomically: true, encoding: .utf8)
            let grokCache = base.appendingPathComponent("grok-cache.json")
            try? #"""
            {"models":{"grok-4.6":{"info":{"id":"grok-4.6","name":"Grok 4.6"},"reasoning":{"efforts":[{"id":"low"},{"id":"high"},{"id":"xhigh"}]}},
                       "grok-9-fixture":{"info":{"id":"grok-9-fixture","name":"Grok 9 Fixture"}}}}
            """#.write(to: grokCache, atomically: true, encoding: .utf8)
            ModelCatalog.codexCacheURL = codexCache
            ModelCatalog.grokCacheURL = grokCache
            let codexChoices = ModelCatalog.choices(.codex)
            audit.check("Codex offers what its own cache lists, in the cache's order, before the known aliases",
                        codexChoices.prefix(3).map(\.id) == ["gpt-7-fixture", "gpt-6-astra", "gpt-5.5"] && codexChoices.contains { $0.id == "gpt-5.6-terra" }, codexChoices.map(\.id).joined(separator: ","))
            audit.equal("a model that is both cached and known appears once", codexChoices.filter { $0.id == "gpt-5.5" }.count, 1)
            audit.equal("efforts follow the cache per model: Astra reaches ultra", ModelCatalog.efforts(.codex, model: "gpt-6-astra"), ["low", "medium", "high", "xhigh", "max", "ultra"])
            audit.equal("…and GPT-5.5 stops at xhigh", ModelCatalog.efforts(.codex, model: "gpt-5.5"), ["low", "medium", "high", "xhigh"])
            audit.equal("an unknown model gets the provider's full set", ModelCatalog.efforts(.codex, model: "gpt-unknown"), ["low", "medium", "high", "xhigh", "max", "ultra"])
            let grokChoices = ModelCatalog.choices(.grok)
            audit.check("Grok's cache is read, keyed by id, with its nested effort ids",
                        grokChoices.contains { $0.id == "grok-9-fixture" && $0.name == "Grok 9 Fixture" } && ModelCatalog.efforts(.grok, model: "grok-4.6") == ["low", "high", "xhigh"], grokChoices.map(\.id).joined(separator: ","))
            audit.check("the live list a session reported comes first", ModelCatalog.choices(.codex, live: [ModelOption(id: "live-model", name: "Live")]).first?.id == "live-model")
            audit.check("Claude keeps its known versions (its handshake reports aliases only)", ModelCatalog.choices(.claude).contains { $0.id == "claude-fable-5-1" })
            try? "not json".write(to: codexCache, atomically: true, encoding: .utf8)
            audit.check("a corrupt cache falls back to the known list without the fixture model",
                        ModelCatalog.choices(.codex).contains { $0.id == "gpt-6-astra" } && !ModelCatalog.choices(.codex).contains { $0.id == "gpt-7-fixture" })
            ModelCatalog.codexCacheURL = base.appendingPathComponent("missing.json")
            audit.check("a missing cache does the same", ModelCatalog.choices(.codex).first?.id == "gpt-6-astra")
        }
    }

    private static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

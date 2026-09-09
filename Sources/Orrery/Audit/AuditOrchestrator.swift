import Foundation

/// A backend that replies from a queue of canned scripts — one script per send(). What the
/// orchestrator audit runs against, so the whole state machine is driven with no network, no
/// CLI, and no subscription quota.
@MainActor
final class ScriptedBackend: AgentBackend {
    let provider: Provider
    var models: [ModelOption] = []
    var currentModel = ""
    var currentEffort = ""
    var persistsSelection = true
    var sessionSettings = AgentSessionSettings()
    var onEvent: ((BackendEvent) -> Void)?
    private var running = false
    var isRunning: Bool { running }
    /// What preconfigure delivered, and whether it arrived before start — the audit reads it.
    private(set) var configuredModel: String?
    private(set) var configuredEffort: String?
    private(set) var configuredBeforeStart = false

    /// Each send() consumes the next script and emits its events. An empty queue means the
    /// backend goes silent — the stand-in for a hung CLI.
    var scripts: [[BackendEvent]]
    private(set) var prompts: [String] = []
    private(set) var stopCount = 0
    private(set) var cancelCount = 0

    /// When true, start reports that the session it was asked to resume no longer exists.
    var dropsSessionOnStart = false

    init(provider: Provider, scripts: [[BackendEvent]], dropsSessionOnStart: Bool = false) {
        self.provider = provider
        self.scripts = scripts
        self.dropsSessionOnStart = dropsSessionOnStart
    }

    static func locate() -> String? { "/usr/bin/true" }
    func preconfigure(model: String?, effort: String?) {
        configuredModel = model
        configuredEffort = effort
        configuredBeforeStart = !running
        if let effort { currentEffort = effort }
        if let model { currentModel = model }
    }
    /// Project the session was started against. Isolation audits read this to
    /// prove the scripted agent was pointed at the temp copy, not the real tree.
    private(set) var projectURL: URL?

    func start(project: URL, autoApprove: Bool) async {
        projectURL = project
        running = true
        if dropsSessionOnStart, !sessionSettings.resumeSession.isEmpty { emit(.sessionDropped(reason: "no such session")) }
        emit(.connected(sessionID: "scripted-\(provider.rawValue)"))
    }
    func stop() { running = false; stopCount += 1 }
    /// Seconds between scripted events — simulates an agent that streams over time.
    var eventDelay: TimeInterval = 0
    /// Fires on every send, before the canned events, so an audit can flip a marker file
    /// the moment a GATE: revise prompt is actually delivered to the author.
    var onPrompt: ((String) -> Void)?
    func send(_ text: String) async {
        prompts.append(text)
        onPrompt?(text)
        guard !scripts.isEmpty else { return }        // deliberately silent
        let events = scripts.removeFirst()
        guard eventDelay > 0 else {
            for event in events { apply(event) }
            return
        }
        Task { @MainActor [weak self] in
            for event in events {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.eventDelay * 1_000_000_000))
                self.apply(event)
            }
        }
    }

    /// Canned FileDiff events actually land on disk under `projectURL`. An isolation
    /// check that passes because nothing was written proves nothing; this is how
    /// the scripted agent writes files.
    private func apply(_ event: BackendEvent) {
        if case let .toolUpdated(_, _, _, diff) = event, let diff {
            writeDiff(diff)
        }
        emit(event)
    }

    private func writeDiff(_ diff: FileDiff) {
        guard let root = projectURL else { return }
        let url: URL
        if diff.path.hasPrefix("/") {
            url = URL(fileURLWithPath: diff.path)
        } else {
            url = root.appendingPathComponent(diff.path)
        }
        let dest = url.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let destPath = dest.path
        guard destPath == rootPath || destPath.hasPrefix(rootPath + "/") else { return }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? diff.newText.write(to: dest, atomically: true, encoding: .utf8)
    }
    func cancel() { cancelCount += 1 }
    func setModel(_ id: String) async {}

    /// A normal turn: some assistant text, then completion with a cost.
    static func reply(_ text: String, cost: Double? = nil) -> [BackendEvent] {
        [.assistantDelta(text), .turnFinished(stopReason: "end_turn", costUSD: cost)]
    }
}

/// The orchestrator: plan parsing, author→reviewer routing (the reviewer is NEVER the author),
/// file capture from tool events, the bounded revise loop, costs, cancellation, and honest
/// failure when the plan cannot be parsed. All headless, all scripted, zero quota.
@MainActor
enum AuditOrchestrator {

    @discardableResult
    private static func waitUntil(_ timeout: Double,
                                  _ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    static func run(_ audit: Auditor) async {
        repoGate(audit)
        await convergence(audit)
        await grantClosesOnPlainClean(audit)
        roleScopedSettings(audit)
        audit.section("Orchestrator — demo data is labeled, never mistaken for a run")
        let demo = Orchestrator()
        demo.reuseSessions = false   // these fixtures script one backend per session
        demo.seedDemo()
        audit.check("seedDemo marks the state as demo",
                    demo.isDemo && demo.items.contains { $0.live != nil })
        demo.installedProviders = [.grok, .claude]
        demo.makeBackend = { provider in ScriptedBackend(provider: provider, scripts: []) }
        demo.turnTimeout = 0.2
        demo.start(task: "real task", project: URL(fileURLWithPath: NSTemporaryDirectory()))
        audit.check("a real start clears the demo label", !demo.isDemo)
        demo.stop()

        parsing(audit)
        sessionConfiguration(audit)
        await happyPath(audit)
        await roundCap(audit)
        await honestFailures(audit)
        await twoProviders(audit)
        await cancellation(audit)
        await timeout(audit)
        await stallAndLiveView(audit)
        await liveDiffAndFollowEdits(audit)
        await roundBudgetsAndResume(audit)
        await acceptanceGate(audit)
        await auditSessionReuse(audit)
    }

    // MARK: Convergence mechanics

    /// Field-measured pathologies: identical rounds burning budget, and post-grant reviewers
    /// re-litigating instead of verifying. The breaker stops the first; the scoped grant
    /// protocol closes the second.
    private static func convergence(_ audit: Auditor) async {
        audit.section("Orchestrator — identical rounds stop the loop, scoped grants close it")

        let same = Orchestrator.normalizedFindingSet([
            ReviewFinding(file: "/a/b/File.swift", line: 10, severity: "bug",
                          message: "  Broken thing ", round: 1)])
        let drifted = Orchestrator.normalizedFindingSet([
            ReviewFinding(file: "File.swift", line: 99, severity: "BUG",
                          message: "broken thing", round: 2)])
        audit.check("normalization ignores line drift, path prefix and case", same == drifted)

        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude, .codex]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.followGate = false
            let plan = #"{"items":[{"title":"Stuck","author":"claude","brief":"Try.","rounds":4}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)],
                        [ScriptedBackend.reply("RECOMMEND: accept: nobody is moving")]],
                .claude: [[ScriptedBackend.reply("Done. FILES: x.py"),
                           ScriptedBackend.reply("Revised nothing much. FILES: x.py")]],
                .codex: [[ScriptedBackend.reply("FINDING: x.py:1: bug: guard is wrong"),
                          ScriptedBackend.reply("FINDING: x.py:9: BUG:  guard is WRONG ")]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Stall out.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            let item = engine.items.first
            audit.equal("identical rounds land the non-convergence stop",
                        item?.state, .notConverging)
            audit.equal("…after exactly two rounds of a four-round budget", item?.round, 2)
            audit.check("…with the note naming the repetition and unspent budget",
                        item?.nonConvergenceNote?.contains("repeated") == true
                        && item?.nonConvergenceNote?.contains("2") == true,
                        item?.nonConvergenceNote ?? "nil")
            audit.check("…and reassignment advice present (honest no-data form here)",
                        item?.reassignAdvice?.isEmpty == false, item?.reassignAdvice ?? "nil")
            audit.check("a non-convergence stop accepts a resume",
                        { if let item { engine.resume(item, extraRounds: 1, project: dir)
                                        engine.stop(); return true } ; return false }())
        }

        // Scoped grant verdicts, unit level.
        let standing = [ReviewFinding(file: "a.swift", line: 3, severity: "bug",
                                      message: "first", round: 3),
                        ReviewFinding(file: "b.swift", line: 9, severity: "gap",
                                      message: "second", round: 3)]
        let verdict = Orchestrator.parseGrantReview("""
        RESOLVED: F1
        NOT RESOLVED: F2: the guard is still missing
        REGRESSION: c.swift:12: the new path drops errors
        ADVISORY: consider renaming the helper
        """, standing: standing, round: 4)
        audit.check("grant verdicts parse all four forms",
                    verdict.parsed && verdict.resolvedIndices == [0]
                    && verdict.notResolvedReasons[1]?.contains("guard") == true
                    && verdict.regressions.count == 1
                    && verdict.regressions[0].severity == "regression"
                    && verdict.advisories == ["consider renaming the helper"])
        audit.check("silence on a finding is NOT resolution",
                    !verdict.resolvedIndices.contains(1))
        // The bug the user hit: reviewers answer the way the rest of the system taught
        // them, and a granted item could never close.
        let clean = Orchestrator.parseGrantReview("NO FINDINGS", standing: standing, round: 4)
        audit.check("a granted reviewer's NO FINDINGS resolves every standing finding",
                    clean.parsed && clean.resolvedIndices == Set(standing.indices),
                    "parsed=\(clean.parsed) resolved=\(clean.resolvedIndices.sorted())")
        let mixed = Orchestrator.parseGrantReview("""
        NOT RESOLVED: F2: still missing
        Otherwise NO FINDINGS
        """, standing: standing, round: 4)
        audit.check("…but a blanket phrase never overrides an explicit NOT RESOLVED",
                    mixed.resolvedIndices.isEmpty
                    && mixed.notResolvedReasons[1]?.isEmpty == false,
                    "resolved=\(mixed.resolvedIndices.sorted())")
        let mixedRegression = Orchestrator.parseGrantReview("""
        REGRESSION: z.swift:1: the fix broke startup
        NO FINDINGS otherwise
        """, standing: standing, round: 4)
        audit.check("…nor a REGRESSION", mixedRegression.resolvedIndices.isEmpty
                    && mixedRegression.regressions.count == 1)
        let oldDialect = Orchestrator.parseGrantReview("""
        RESOLVED: F1
        RESOLVED: F2
        FINDING: q.swift:4: gap: unrelated nit I noticed
        """, standing: standing, round: 4)
        audit.check("an open-dialect FINDING inside a grant is kept as a visible advisory",
                    oldDialect.resolvedIndices == Set(standing.indices)
                    && oldDialect.advisories.count == 1
                    && oldDialect.advisories[0].contains("outside the grant scope")
                    && oldDialect.advisories[0].contains("unrelated nit"),
                    "\(oldDialect.advisories)")
        audit.check("prose without the forms is unparsed",
                    !Orchestrator.parseGrantReview("looks fine", standing: standing,
                                                   round: 4).parsed)

        // End-to-end: a granted round that resolves everything (plus an advisory) CLOSES.
        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.followGate = false
            let plan = #"{"items":[{"title":"Close me","author":"claude","brief":"Do.","rounds":1}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)],
                        [ScriptedBackend.reply("FINDING: y.py:1: bug: broken start")],
                        [ScriptedBackend.reply("RECOMMEND: 1 more rounds: nearly there")],
                        [ScriptedBackend.reply("RESOLVED: F1\nADVISORY: tests could be broader")]],
                .claude: [[ScriptedBackend.reply("Done. FILES: y.py")],
                          [ScriptedBackend.reply("Fixed. FILES: y.py")]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "One item.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            guard let item = engine.items.first,
                  item.state == .acceptedWithObjections else {
                audit.check("fixture reached objections before the grant",
                            false, "\(String(describing: engine.items.first?.state))")
                return
            }
            engine.resume(item, extraRounds: 1, project: dir)
            _ = await waitUntil(10) { engine.phase == .done && item.state.isTerminal }
            audit.equal("a scoped grant that resolves all standing findings ACCEPTS",
                        item.state, .accepted)
            audit.check("…with the advisory recorded, visible and non-blocking",
                        item.advisoryNotes == ["tests could be broader"])
        }
    }

    /// End to end in the reviewers' own dialect: a granted round answered "NO FINDINGS"
    /// must close the item. Scripted with the exact reply real backends send.
    private static func grantClosesOnPlainClean(_ audit: Auditor) async {
        audit.section("Orchestrator — a granted round answered NO FINDINGS closes the item")
        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.followGate = false
            let plan = #"{"items":[{"title":"Closer","author":"claude","brief":"Do.","rounds":1}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)],
                        [ScriptedBackend.reply("FINDING: z.py:1: bug: broken")],
                        [ScriptedBackend.reply("RECOMMEND: 1 more rounds: close to done")],
                        [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[ScriptedBackend.reply("Done. FILES: z.py")],
                          [ScriptedBackend.reply("Fixed it. FILES: z.py")]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "One item.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            guard let item = engine.items.first,
                  item.state == .acceptedWithObjections else {
                audit.check("fixture reached objections before the grant", false,
                            "\(String(describing: engine.items.first?.state))")
                return
            }
            engine.resume(item, extraRounds: 1, project: dir)
            _ = await waitUntil(10) { engine.phase == .done && item.state.isTerminal }
            audit.equal("the granted round ends ACCEPTED, not stuck on objections",
                        item.state, .accepted)
            audit.check("…with nothing left standing", item.openFindings.isEmpty,
                        item.openFindings.map(\.message).joined(separator: " | "))
        }
    }

    // MARK: Repo gate convention

    /// `.orrery-gate.json` folds repo-specific commands into the acceptance gate — born
    /// from run 10 landing with 8 red audit checks behind a green build/test gate.
    private static func repoGate(_ audit: Auditor) {
        audit.section("Orchestrator — repo gate commands join the acceptance gate")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gatejson-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? #"{"commands": [{"title": "always-fails", "executable": "/usr/bin/false"}]}"#
            .write(to: dir.appendingPathComponent(".orrery-gate.json"),
                   atomically: true, encoding: .utf8)
        let tasks = Orchestrator.repoGateTasks(project: dir)
        audit.check("a gate command is read as a test task",
                    tasks.count == 1 && tasks[0].kind == .test
                    && tasks[0].executable == "/usr/bin/false"
                    && tasks[0].missingTool == nil)
        audit.check("no gate file, no tasks",
                    Orchestrator.repoGateTasks(project: URL(fileURLWithPath: "/tmp")).isEmpty)
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let own = Orchestrator.repoGateTasks(project: repo)
        audit.check("this repo's own gate file wires the audit",
                    own.contains { $0.arguments == ["--audit"] },
                    own.map(\.title).joined(separator: ","))
    }

    // MARK: Role-scoped session settings

    /// One provider, two hats: the author session and the reviewer session of the SAME run can
    /// carry different models. Resolution: explicit role > provider-wide > baked default —
    /// The default role allocation (Codex: Terra writes, Sol reviews/orchestrates) is the baked layer.
    private static func roleScopedSettings(_ audit: Auditor) {
        audit.section("Orchestrator — role-scoped models: Terra writes, Sol reviews")
        let engine = Orchestrator()
        engine.reuseSessions = false   // these fixtures script one backend per session
        audit.equal("baked default: codex authors as terra",
                    engine.resolvedModel(for: .codex, role: .author), "gpt-5.6-terra")
        audit.equal("baked default: codex reviews as sol",
                    engine.resolvedModel(for: .codex, role: .reviewer), "gpt-5.6-sol")
        audit.equal("baked default: codex orchestrates as sol",
                    engine.resolvedModel(for: .codex, role: .orchestrator), "gpt-5.6-sol")
        audit.check("no baked defaults for grok or claude",
                    engine.resolvedModel(for: .grok, role: .author) == nil
                    && engine.resolvedModel(for: .claude, role: .reviewer) == nil)
        engine.modelOverrides[.codex] = "gpt-5.5"
        audit.equal("a provider-wide override beats the baked default",
                    engine.resolvedModel(for: .codex, role: .author), "gpt-5.5")
        engine.roleModelOverrides[.author] = [.codex: "gpt-5.6-terra"]
        audit.equal("an explicit role override beats both",
                    engine.resolvedModel(for: .codex, role: .author), "gpt-5.6-terra")
        audit.equal("…without leaking into the other role",
                    engine.resolvedModel(for: .codex, role: .reviewer), "gpt-5.5")
        engine.roleEffortOverrides[.reviewer] = [.grok: "xhigh"]
        audit.equal("role efforts resolve the same way",
                    engine.resolvedEffort(for: .grok, role: .reviewer), "xhigh")
        audit.check("grant controls: enabled when idle with allowance",
                    {
                        let item = WorkItem(title: "t", brief: "b", author: .grok,
                                            reviewer: .claude)
                        item.state = .acceptedWithObjections
                        return engine.grantControlState(for: item)
                            == Orchestrator.GrantControlState(enabled: true, caption: nil)
                    }())
        audit.check("grant controls: disabled with the caption while a run is in flight",
                    {
                        let busy = Orchestrator()
                        busy.reuseSessions = false   // these fixtures script one backend per session
                        busy.installedProviders = [.grok, .claude]
                        busy.makeBackend = { p in ScriptedBackend(provider: p, scripts: []) }
                        busy.turnTimeout = 30
                        let item = WorkItem(title: "t", brief: "b", author: .grok,
                                            reviewer: .claude)
                        item.state = .acceptedWithObjections
                        busy.start(task: "hold the engine busy",
                                   project: URL(fileURLWithPath: NSTemporaryDirectory()))
                        let state = busy.grantControlState(for: item)
                        busy.stop()
                        return state.enabled == false
                            && state.caption?.contains("available when the current run finishes")
                                == true
                    }())
    }

    // MARK: Parsers

    private static func parsing(_ audit: Auditor) {
        audit.section("Orchestrator — strict parsing, no invented structure")

        let fenced = """
        Here is the plan.
        ```json
        {"items": [{"title": "Do a thing", "author": "claude", "brief": "do it"}]}
        ```
        """
        if case let .success(items) = Orchestrator.parsePlan(fenced, allowed: [.grok, .claude]) {
            audit.check("a fenced plan parses",
                        items == [.init(title: "Do a thing", author: .claude, brief: "do it")])
        } else {
            audit.check("a fenced plan parses", false)
        }
        if case .success = Orchestrator.parsePlan(
            #"{"items":[{"title":"t","author":"grok","brief":"b"}]}"#,
            allowed: [.grok, .claude]) {
            audit.check("a bare JSON plan parses", true)
        } else {
            audit.check("a bare JSON plan parses", false)
        }
        if case let .failure(reason) = Orchestrator.parsePlan("I would suggest starting with…",
                                                              allowed: [.grok]) {
            audit.check("prose is a parse failure, not guessed items",
                        reason.contains("no JSON"), reason)
        } else {
            audit.check("prose is a parse failure, not guessed items", false)
        }
        if case let .failure(reason) = Orchestrator.parsePlan(
            #"{"items":[{"title":"t","author":"codex","brief":"b"}]}"#,
            allowed: [.grok, .claude]) {
            audit.check("an author outside the enabled workers is refused by name",
                        reason.contains("not an enabled worker"), reason)
        } else {
            audit.check("an author outside the enabled workers is refused by name", false)
        }
        let runaway = (1...9).map {
            #"{"title":"t\#($0)","author":"grok","brief":"b"}"#
        }.joined(separator: ",")
        if case let .failure(reason) = Orchestrator.parsePlan(#"{"items":[\#(runaway)]}"#,
                                                              allowed: [.grok]) {
            audit.check("a runaway plan is capped", reason.contains("cap"), reason)
        } else {
            audit.check("a runaway plan is capped", false)
        }

        if case let .success(items) = Orchestrator.parsePlan(
            #"{"items":[{"title":"t","author":"grok","brief":"b","rounds":3}]}"#,
            allowed: [.grok]) {
            audit.equal("a present rounds field is kept", items.first?.rounds, 3)
        } else {
            audit.check("a present rounds field is kept", false)
        }
        if case let .success(items) = Orchestrator.parsePlan(
            #"{"items":[{"title":"t","author":"grok","brief":"b"}]}"#,
            allowed: [.grok]) {
            audit.check("an absent rounds field is not invented", items.first?.rounds == nil)
        } else {
            audit.check("an absent rounds field is not invented", false)
        }
        if case let .success(items) = Orchestrator.parsePlan(
            #"{"items":[{"title":"t","author":"grok","brief":"b","rounds":0}]}"#,
            allowed: [.grok]) {
            audit.equal("rounds below 1 clamps to 1", items.first?.rounds, 1)
        } else {
            audit.check("rounds below 1 clamps to 1", false)
        }
        if case let .success(items) = Orchestrator.parsePlan(
            #"{"items":[{"title":"t","author":"grok","brief":"b","rounds":9}]}"#,
            allowed: [.grok]) {
            audit.equal("rounds above 5 clamps to 5", items.first?.rounds, 5)
        } else {
            audit.check("rounds above 5 clamps to 5", false)
        }

        let rec = Orchestrator.parseRecommendation(
            "RECOMMEND: 2 more rounds: remaining bugs are real")
        audit.equal("a structured extra-round recommendation parses", rec.extraRounds, 2)
        audit.check("…and keeps the reason", rec.reason.contains("remaining bugs"))
        let acc = Orchestrator.parseRecommendation("RECOMMEND: accept: style nits only")
        audit.check("an accept recommendation is the accept form, not 0 extra rounds",
                    acc.accept && acc.extraRounds == nil, "\(acc)")
        let zero = Orchestrator.parseRecommendation("RECOMMEND: 0 more rounds: no more time")
        audit.check("0 more rounds parses as 0, not as accept",
                    zero.extraRounds == 0 && !zero.accept, "\(zero)")
        let zeroItem = WorkItem(title: "t", brief: "b", author: .claude, reviewer: .grok)
        zeroItem.recommendedExtraRounds = 0
        zeroItem.recommendationReason = "no more time"
        audit.check("0 more rounds is not relabeled as accept in the UI",
                    zeroItem.recommendationLineText?.contains("0 more rounds") == true
                    && zeroItem.recommendationLineText?.contains("accept") == false,
                    zeroItem.recommendationLineText ?? "nil")
        let junk = Orchestrator.parseRecommendation("I would maybe do a few more")
        audit.check("an unparseable recommendation does not invent a number",
                    junk.extraRounds == nil && !junk.accept
                    && junk.reason == "I would maybe do a few more")

        let findings = Orchestrator.parseFindings("""
        Overall decent, but:
        FINDING: src/a.py:12: bug: off-by-one in the loop bound
        FINDING: b.swift:0: gap: no test covers the empty case
        """, round: 1)
        audit.equal("two findings parsed", findings.count, 2)
        audit.check("path, line, severity, message all captured",
                    findings.first.map {
                        $0.file == "src/a.py" && $0.line == 12 && $0.severity == "bug"
                        && $0.message.contains("off-by-one")
                    } ?? false)
        audit.check("NO FINDINGS is clean",
                    Orchestrator.parseFindings("NO FINDINGS", round: 1).isEmpty)
        // Seen live from Grok: the verdict glued to the end of a prose sentence. Still clean —
        // there are no FINDING lines to lose.
        audit.check("a clean verdict wrapped in prose is clean",
                    Orchestrator.parseFindings(
                        "I re-ran fib.py and the behavior is identical.NO FINDINGS",
                        round: 2).isEmpty)
        audit.check("…but the phrase never suppresses real findings",
                    Orchestrator.parseFindings(
                        "FINDING: a.py:1: bug: broken\nOtherwise NO FINDINGS",
                        round: 1).count == 1)
        let unstructured = Orchestrator.parseFindings("looks fine to me overall!", round: 2)
        audit.check("an unstructured review is surfaced verbatim, not dropped",
                    unstructured.count == 1 && unstructured[0].severity == "unparsed"
                    && unstructured[0].message.contains("looks fine"))
    }

    // MARK: Session configuration

    /// A run's model/effort choices reach the session before it starts and never leak into the
    /// user's saved chat defaults — a run at max effort must not become tomorrow's default.
    private static func sessionConfiguration(_ audit: Auditor) {
        audit.section("Orchestrator — per-run model and effort, without touching defaults")
        let defaults = UserDefaults.standard
        let saved = ["claudeModel", "claudeEffort", "grokEffort", "codexModel", "codexEffort"]
            .reduce(into: [String: String?]()) { $0[$1] = defaults.string(forKey: $1) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("sentinel-model", forKey: "claudeModel")
        defaults.set("sentinel-effort", forKey: "claudeEffort")
        defaults.set("sentinel-effort", forKey: "grokEffort")
        defaults.set("sentinel-effort", forKey: "codexEffort")

        let claude = ClaudeBackend()
        claude.persistsSelection = false
        claude.preconfigure(model: "claude-fable-5", effort: "max")
        audit.check("Claude takes the session's model and effort",
                    claude.currentModel == "claude-fable-5" && claude.currentEffort == "max")
        audit.check("…without rewriting the chat defaults",
                    defaults.string(forKey: "claudeModel") == "sentinel-model"
                    && defaults.string(forKey: "claudeEffort") == "sentinel-effort")
        audit.check("Fable 5 is in Claude's model list",
                    claude.models.contains { $0.id == "claude-fable-5" })

        let grok = GrokBackend()
        grok.persistsSelection = false
        grok.preconfigure(model: nil, effort: "xhigh")
        audit.check("Grok takes the session's effort (a spawn flag)",
                    grok.currentEffort == "xhigh")
        audit.check("…without rewriting the chat default",
                    defaults.string(forKey: "grokEffort") == "sentinel-effort")

        let codex = CodexBackend()
        codex.persistsSelection = false
        codex.preconfigure(model: "gpt-5.5", effort: "low")
        audit.check("Codex takes both, without persisting",
                    codex.currentModel == "gpt-5.5" && codex.currentEffort == "low"
                    && defaults.string(forKey: "codexModel") != "gpt-5.5"
                    && defaults.string(forKey: "codexEffort") == "sentinel-effort")
    }

    // MARK: Happy path

    private static func happyPath(_ audit: Auditor) async {
        audit.section("Orchestrator — assign, author, review, revise, accept")
        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude, .codex]
            engine.orchestratorProvider = .grok
            engine.maxRounds = 3
            engine.turnTimeout = 5
            engine.modelOverrides[.claude] = "test-model-x"
            engine.effortOverrides[.grok] = "xhigh"

            audit.equal("the worker pool excludes the orchestrator",
                        engine.workerPool, [.claude, .codex])

            let plan = """
            ```json
            {"items": [
              {"title": "Parser fix", "author": "claude", "brief": "Fix the parser loop."},
              {"title": "Add tests", "author": "codex", "brief": "Cover the empty case."}
            ]}
            ```
            """
            var editDetail = ToolDetail()
            editDetail.kind = "edit"
            let authorTurn1: [BackendEvent] = [
                .toolStarted(id: "t1", title: "Edit · a.py", kind: "edit",
                             input: #"{"file_path": "a.py", "old_string": "x"}"#),
                .toolUpdated(id: "t1", status: "completed", output: nil,
                             diff: FileDiff(path: "a.py", oldText: "x", newText: "y")),
                .assistantDelta("Tightened the loop.\nFILES: a.py"),
                .turnFinished(stopReason: "end_turn", costUSD: 0.01),
            ]
            var sessionQueues: [Provider: [[[BackendEvent]]]] = [
                // Session scripts per provider, in creation order.
                .grok: [[ScriptedBackend.reply(plan, cost: 0.003)]],
                .claude: [
                    [authorTurn1, ScriptedBackend.reply("Fixed the bound.\nFILES: a.py",
                                                        cost: 0.02)],
                    [ScriptedBackend.reply("NO FINDINGS", cost: 0.011)],
                ],
                .codex: [
                    [ScriptedBackend.reply("FINDING: a.py:3: bug: off-by-one survives an empty input",
                                           cost: 0.005),
                     ScriptedBackend.reply("NO FINDINGS", cost: 0.005)],
                    [ScriptedBackend.reply("Added the tests.\nFILES: tests/test_a.py")],
                ],
            ]
            var created: [ScriptedBackend] = []
            engine.makeBackend = { provider in
                let scripts = sessionQueues[provider]?.isEmpty == false
                    ? sessionQueues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                created.append(backend)
                return backend
            }

            engine.start(task: "Fix the parser and cover it with tests.", project: dir)
            let finished = await waitUntil(10) { engine.phase == .done }
            audit.check("the run completed", finished, "\(engine.phase)")
            audit.equal("two work items", engine.items.count, 2)

            guard engine.items.count == 2 else { return }
            let first = engine.items[0], second = engine.items[1]

            audit.check("authors follow the plan",
                        first.author == .claude && second.author == .codex)
            audit.check("the reviewer is the OTHER worker",
                        first.reviewer == .codex && second.reviewer == .claude)
            audit.check("the reviewer is never the author",
                        engine.items.allSatisfy { $0.reviewer != $0.author })

            audit.equal("item 1 accepted after the revise loop", first.state, .accepted)
            audit.equal("…in two review rounds", first.round, 2)
            audit.equal("the finding was recorded", first.findings.count, 1)
            audit.check("files captured from the tool events, deduplicated",
                        first.filesTouched == ["a.py"], "\(first.filesTouched)")
            audit.check("nothing is still open once accepted", first.openFindings.isEmpty)

            let planner = created.first { $0.provider == .grok }
            audit.check("the plan prompt names only the workers",
                        planner?.prompts.first?.contains("Your workers: claude, codex") == true
                        && planner?.prompts.first?.contains("Your workers: grok") == false)
            let author1 = created.first { $0.provider == .claude }
            audit.check("the author got the brief",
                        author1?.prompts.first?.contains("Fix the parser loop.") == true)
            audit.check("the revise prompt carries the reviewer's findings",
                        author1?.prompts.count == 2
                        && author1?.prompts[1].contains("off-by-one") == true)
            let reviewer1 = created.first { $0.provider == .codex }
            audit.check("the review prompt names the touched files",
                        reviewer1?.prompts.first?.contains("- a.py") == true)
            audit.check("the re-review says the author revised",
                        reviewer1?.prompts.count == 2
                        && reviewer1?.prompts[1].contains("revised") == true)

            audit.check("item 1 cost is the sum of its four turns",
                        abs(first.costUSD - 0.04) < 0.0001, "\(first.costUSD)")
            audit.equal("item 1 turn count", first.turns, 4)
            audit.equal("codex's costless turn is counted as unreported",
                        second.unreportedTurns, 1)
            audit.check("the run total includes the planning turn",
                        abs(engine.totalCostUSD - (0.003 + 0.04 + 0.011)) < 0.0001,
                        "\(engine.totalCostUSD)")
            audit.check("every scripted session was stopped afterwards",
                        created.allSatisfy { $0.stopCount > 0 },
                        "\(created.map(\.stopCount))")
            audit.check("session overrides arrive before each session starts",
                        created.allSatisfy { $0.configuredBeforeStart }
                        && created.first { $0.provider == .claude }?.configuredModel
                            == "test-model-x"
                        && created.first { $0.provider == .grok }?.configuredEffort == "xhigh")
            audit.check("orchestrator sessions never persist their selections",
                        created.allSatisfy { !$0.persistsSelection })
            let codexSessions = created.filter { $0.provider == .codex }
            audit.check("codex reviewer session got Sol, author session got Terra — baked, "
                        + "before start",
                        codexSessions.count == 2
                        && codexSessions[0].configuredModel == "gpt-5.6-sol"
                        && codexSessions[1].configuredModel == "gpt-5.6-terra"
                        && codexSessions.allSatisfy { $0.configuredBeforeStart },
                        codexSessions.map { $0.configuredModel ?? "nil" }
                            .joined(separator: ","))
            audit.check("each lane names who said what",
                        first.lane.contains { $0.role == "reviewer" && $0.provider == .codex }
                        && first.lane.contains { $0.role == "author" && $0.provider == .claude })
        }
    }

    // MARK: Round cap

    private static func roundCap(_ audit: Auditor) async {
        audit.section("Orchestrator — the loop is bounded")
        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude, .codex]
            engine.orchestratorProvider = .grok
            engine.maxRounds = 2
            engine.turnTimeout = 5

            let plan = #"{"items":[{"title":"Stubborn","author":"claude","brief":"Try."}]}"#
            var sessionQueues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan, cost: 0.001)],
                        [ScriptedBackend.reply("RECOMMEND: 2 more rounds: still wrong")]],
                .claude: [[ScriptedBackend.reply("Done. FILES: x.py", cost: 0.01),
                           ScriptedBackend.reply("Revised. FILES: x.py", cost: 0.01),
                           ScriptedBackend.reply("Revised again. FILES: x.py", cost: 0.01)]],
                .codex: [[ScriptedBackend.reply("FINDING: x.py:1: bug: the bound is off by one", cost: 0.002),
                          ScriptedBackend.reply("FINDING: x.py:2: bug: the rewrite dropped the empty case", cost: 0.002),
                          ScriptedBackend.reply("FINDING: x.py:3: bug: now the overflow path is gone", cost: 0.002)]],
            ]
            var created: [ScriptedBackend] = []
            engine.makeBackend = { provider in
                let scripts = sessionQueues[provider]?.isEmpty == false
                    ? sessionQueues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                created.append(backend)
                return backend
            }

            engine.start(task: "Do the impossible.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            guard let item = engine.items.first else {
                audit.check("the item exists", false)
                return
            }
            audit.equal("the loop stopped at the cap", item.round, 2)
            audit.equal("…as accepted with the objections standing", item.state,
                        .acceptedWithObjections)
            audit.check("the standing objection is shown",
                        item.openFindings.count == 1
                        && item.openFindings[0].message.contains("dropped the empty case"))
            let author = created.first { $0.provider == .claude }
            audit.equal("the author was asked to revise exactly once",
                        author?.prompts.count, 2)
            let reviewer = created.first { $0.provider == .codex }
            audit.equal("the reviewer reviewed exactly twice", reviewer?.prompts.count, 2)
        }
    }

    // MARK: Session reuse

    /// Three items, two workers: the author that wrote item 1 writes item 3 on the same session,
    /// and each reviewer keeps one session too. Five sessions instead of seven.
    static func auditSessionReuse(_ audit: Auditor) async {
        audit.section("Team — authors and reviewers keep one session across work items")
        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.installedProviders = [.grok, .claude, .codex]
            engine.orchestratorProvider = .grok
            engine.maxRounds = 1
            engine.turnTimeout = 5
            let plan = """
            ```json
            {"items": [
              {"title": "One", "author": "claude", "brief": "Do one."},
              {"title": "Two", "author": "codex", "brief": "Do two."},
              {"title": "Three", "author": "claude", "brief": "Do three."}
            ]}
            ```
            """
            @MainActor func wrote(_ file: String) -> [BackendEvent] { ScriptedBackend.reply("Done.\nFILES: \(file)", cost: 0.01) }
            // One script list per *session*; a reused session answers several times from one list.
            var sessionQueues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan, cost: 0.01)]],
                .claude: [[wrote("one.py"), wrote("three.py")],            // author: items 1 and 3
                          [ScriptedBackend.reply("NO FINDINGS", cost: 0.01)]],   // reviewer: item 2
                .codex: [[ScriptedBackend.reply("NO FINDINGS", cost: 0.01), ScriptedBackend.reply("NO FINDINGS", cost: 0.01)],   // reviewer: items 1 and 3
                         [wrote("two.py")]],                                // author: item 2
            ]
            var created: [ScriptedBackend] = []
            engine.makeBackend = { provider in
                let scripts = sessionQueues[provider]?.isEmpty == false ? sessionQueues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                created.append(backend)
                return backend
            }
            engine.start(task: "Three small things.", project: dir)
            let finished = await waitUntil(10) { engine.phase == .done }
            audit.check("the run completed", finished, "\(engine.phase)")
            audit.equal("three items", engine.items.count, 3)
            audit.check("every item was accepted", engine.items.allSatisfy { $0.state == .accepted }, engine.items.map { "\($0.title): \($0.state)" }.joined(separator: ", "))
            audit.equal("five sessions for three items: planner, two authors, two reviewers", engine.sessionsOpened, 5)
            audit.equal("…which is what was created", created.count, 5)
            let claudeAuthor = created.first { $0.provider == .claude }
            audit.equal("Claude wrote item 1 and item 3 on one session", claudeAuthor?.prompts.count, 2)
            audit.check("…and the second brief reached that same session", claudeAuthor?.prompts.last?.contains("Do three.") == true)
            audit.check("the sessions are closed when the run ends", created.allSatisfy { !$0.isRunning })
            engine.reuseSessions = false
        }
    }

    // MARK: Honest failure

    private static func honestFailures(_ audit: Auditor) async {
        audit.section("Orchestrator — failures are surfaced, not papered over")
        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            let prose = "First I would look at the parser, then maybe the tests…"
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(prose, cost: 0.002)]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Fix it.", project: dir)
            _ = await waitUntil(10) {
                if case .failed = engine.phase { return true } else { return false }
            }
            if case let .failed(reason) = engine.phase {
                audit.check("an unparseable plan fails with the reason",
                            reason.contains("parsed"), reason)
            } else {
                audit.check("an unparseable plan fails with the reason", false,
                            "\(engine.phase)")
            }
            audit.check("no work items were invented", engine.items.isEmpty)
            audit.equal("the raw reply is preserved for the user", engine.planRaw, prose)
            audit.check("the planning spend is still counted",
                        abs(engine.totalCostUSD - 0.002) < 0.0001)

            // One installed provider: refuse to start, in words.
            let lonely = Orchestrator()
            lonely.reuseSessions = false   // these fixtures script one backend per session
            lonely.installedProviders = [.grok]
            audit.check("one installed CLI blocks the start honestly",
                        lonely.startBlocker?.contains("at least two") == true)

            // A remembered planner that is not installed: Team plans with an installed CLI.
            let unplanned = Orchestrator()
            unplanned.reuseSessions = false   // these fixtures script one backend per session
            unplanned.installedProviders = [.claude, .codex]
            unplanned.orchestratorProvider = .grok
            unplanned.adoptInstalledOrchestrator()
            audit.equal("Team adopts an installed planner when the chosen one is missing",
                        unplanned.orchestratorProvider, .claude)
            let planned = Orchestrator()
            planned.reuseSessions = false   // these fixtures script one backend per session
            planned.installedProviders = [.grok, .claude]
            planned.orchestratorProvider = .claude
            planned.adoptInstalledOrchestrator()
            audit.equal("an installed planner choice is kept", planned.orchestratorProvider, .claude)

            // Spend control: a switched-off worker is out of the pool, out of the plan, and
            // impossible switch states refuse to start in words.
            let picky = Orchestrator()
            picky.reuseSessions = false   // these fixtures script one backend per session
            picky.installedProviders = [.grok, .claude, .codex]
            picky.orchestratorProvider = .grok
            picky.disabledWorkers = [.codex]
            audit.equal("a disabled worker leaves the pool", picky.workerPool, [.claude])
            if case let .failure(reason) = Orchestrator.parsePlan(
                #"{"items":[{"title":"t","author":"codex","brief":"b"}]}"#,
                allowed: picky.workerPool) {
                audit.check("a plan naming a disabled worker is refused",
                            reason.contains("not an enabled worker"), reason)
            } else {
                audit.check("a plan naming a disabled worker is refused", false)
            }
            picky.disabledWorkers = [.claude, .codex]
            audit.check("all workers off blocks the start in words",
                        picky.startBlocker?.contains("switched off") == true,
                        picky.startBlocker ?? "nil")
            let cornered = Orchestrator()
            cornered.reuseSessions = false   // these fixtures script one backend per session
            cornered.installedProviders = [.grok, .claude]
            cornered.orchestratorProvider = .grok
            cornered.disabledWorkers = [.claude]
            audit.check("a switch state with no possible reviewer refuses to start",
                        cornered.startBlocker != nil, cornered.startBlocker ?? "nil")

            // No captured files: the reviewer is told so, not left to assume.
            let item = WorkItem(title: "t", brief: "b", author: .claude, reviewer: .grok)
            item.lane.append(LaneEntry(provider: .claude, role: "author", title: "Wrote it",
                                       text: "I refactored things.", costUSD: nil))
            audit.check("an empty change set is named in the review prompt",
                        Prompts.review(item: item, project: dir)
                            .contains("No file edits were captured"))
        }
    }

    // MARK: Two providers

    private static func twoProviders(_ audit: Auditor) async {
        audit.section("Orchestrator — two installed CLIs still split author and reviewer")
        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            let plan = #"{"items":[{"title":"Solo","author":"claude","brief":"Do it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)],
                        [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[ScriptedBackend.reply("Done. FILES: y.py")]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Small change.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            audit.equal("the sole worker authors", engine.items.first?.author, .claude)
            audit.equal("the orchestrator's provider reviews — never the author",
                        engine.items.first?.reviewer, .grok)
            audit.equal("…and accepts", engine.items.first?.state, .accepted)
            // Every turn here — the plan included — reported no cost. All of them count.
            audit.equal("costless turns are all counted, the planning one too",
                        engine.totalUnreportedTurns, 3)
        }

        audit.section("Orchestrator — the editor picks up what the agents wrote")
        await Auditor.withTemporaryDirectory { dir in
            let model = AppModel(trust: .forAudit)
            model.openProject(dir)
            let file = dir.appendingPathComponent("edited-by-agents.txt")
            try? "before the run\n".write(to: file, atomically: true, encoding: .utf8)
            model.open(file: file)
            model.autoReloadAfterTurns = true

            let engine = model.orchestrator
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            let plan = #"{"items":[{"title":"Edit","author":"claude","brief":"Change it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)], [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[ScriptedBackend.reply("Done. FILES: edited-by-agents.txt")]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            // The "agent" edit: the file changes on disk underneath the clean open tab.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
            try? "after the run\n".write(to: file, atomically: true, encoding: .utf8)
            engine.start(task: "Edit the file.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            audit.equal("a clean tab reloads when orchestrator work settles",
                        model.documents.active?.text, "after the run\n")
        }
    }

    // MARK: Cancellation

    private static func cancellation(_ audit: Auditor) async {
        audit.section("Orchestrator — one Stop cancels everything")
        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 60          // long: Stop must win, not the timeout
            let plan = #"{"items":[{"title":"Hang","author":"claude","brief":"Never ends."}]}"#
            var created: [ScriptedBackend] = []
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)]],
                .claude: [[]],               // the author never answers
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                created.append(backend)
                return backend
            }
            engine.start(task: "Loop forever.", project: dir)
            let authoring = await waitUntil(5) {
                engine.items.first?.state == .authoring
            }
            audit.check("the item reached authoring", authoring)
            engine.stop()
            audit.equal("the run is cancelled", engine.phase, .cancelled)
            audit.equal("the in-flight item is cancelled", engine.items.first?.state,
                        .cancelled)
            let author = created.first { $0.provider == .claude }
            audit.check("the hung author was cancelled and stopped",
                        (author?.cancelCount ?? 0) > 0 && (author?.stopCount ?? 0) > 0,
                        "cancel=\(author?.cancelCount ?? -1) stop=\(author?.stopCount ?? -1)")
            let promptsAtStop = created.reduce(0) { $0 + $1.prompts.count }
            try? await Task.sleep(nanoseconds: 300_000_000)
            audit.equal("nothing was sent after Stop",
                        created.reduce(0) { $0 + $1.prompts.count }, promptsAtStop)
        }
    }

    // MARK: Timeout

    private static func timeout(_ audit: Auditor) async {
        audit.section("Orchestrator — a silent agent cannot hang the run")
        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 0.4
            let plan = #"{"items":[{"title":"Quiet","author":"claude","brief":"Say nothing."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)]],
                .claude: [[]],               // never answers
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Test the deadline.", project: dir)
            let finished = await waitUntil(10) { engine.phase == .done }
            audit.check("the run finished despite the silence", finished, "\(engine.phase)")
            audit.equal("the silent item failed rather than hanging",
                        engine.items.first?.state, .failed)
            audit.check("the silence is named in the lane",
                        engine.items.first?.lane.contains {
                            $0.text.contains("no activity") && $0.text.contains("deadline")
                        } == true)
        }
    }

    // MARK: Stall detection and the live view

    /// The deadline measures SILENCE, not total time: an agent that keeps streaming events
    /// may run far past the window, and what it streams is visible on the item while it runs.
    /// Found by use: a wall-clock cap killed a Grok turn right after it wrote a whole feature.
    private static func stallAndLiveView(_ audit: Auditor) async {
        audit.section("Orchestrator — progress beats the clock, and it is visible")

        // A busy turn outlives the stall window: five events 0.15s apart with a 0.4s window
        // means total time ~0.9s > window, yet every gap is under it.
        let busy = ScriptedBackend(provider: .claude, scripts: [[
            .assistantDelta("one "), .assistantDelta("two "), .assistantDelta("three "),
            .assistantDelta("four "),
            .turnFinished(stopReason: "end_turn", costUSD: 0.001),
        ]])
        busy.eventDelay = 0.15
        let collector = TurnCollector(backend: busy, provider: .claude)
        let started = Date()
        let result = await collector.send("go", stallTimeout: 0.4)
        let elapsed = Date().timeIntervalSince(started)
        audit.check("a turn that keeps streaming outlives the stall window",
                    !result.timedOut && result.text.contains("four") && elapsed > 0.5,
                    "timedOut=\(result.timedOut) elapsed=\(String(format: "%.2f", elapsed))s")

        // Silence still fails, promptly and in words.
        let quiet = ScriptedBackend(provider: .claude, scripts: [[
            .assistantDelta("started then went dark"),
        ]])
        let quietCollector = TurnCollector(backend: quiet, provider: .claude)
        let quietResult = await quietCollector.send("go", stallTimeout: 0.4)
        audit.check("silence after a burst still stalls out",
                    quietResult.timedOut
                    && quietResult.failureMessage?.contains("no activity") == true,
                    quietResult.failureMessage ?? "nil")

        // The live view: while the author streams, the item shows its text, tools and files;
        // when the turn lands the live slot clears and the lane holds the record.
        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            let plan = #"{"items":[{"title":"Slow","author":"claude","brief":"Take your time."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)], [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[[
                    .thoughtDelta("weighing the options"),
                    .assistantDelta("writing the change now"),
                    .toolStarted(id: "t1", title: "Edit · slow.py", kind: "edit",
                                 input: #"{"file_path": "slow.py"}"#),
                    .toolUpdated(id: "t1", status: "completed", output: nil, diff: nil),
                    .assistantDelta(" …done. FILES: slow.py"),
                    .turnFinished(stopReason: "end_turn", costUSD: 0.01),
                ]]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                if provider == .claude { backend.eventDelay = 0.25 }
                return backend
            }
            engine.start(task: "Watch me work.", project: dir)
            let sawLive = await waitUntil(6) {
                guard let live = engine.items.first?.live else { return false }
                return live.text.contains("writing the change")
                    && live.tools.contains { $0.contains("slow.py") }
                    && live.thinkingCharacters > 0
            }
            audit.check("mid-turn, the item shows streamed text, tools and thinking", sawLive)
            audit.check("…and the touched file is already listed",
                        engine.items.first?.filesTouched.contains("slow.py") == true)
            _ = await waitUntil(10) { engine.phase == .done }
            audit.check("when the turn lands, the live slot clears",
                        engine.items.first?.live == nil && engine.planningLive == nil)
            audit.equal("…and the item accepted", engine.items.first?.state, .accepted)
        }

        // The real Grok/Claude event shape: a diff update followed by a status-only
        // "completed" on the same tool id must NOT wipe the live diff — and the no-diff
        // honesty note is per TOOL, not per turn: a later edit whose own tool never
        // streamed a patch gets the note even though an earlier tool did.
        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.followEdits = false
            let plan = #"{"items":[{"title":"Shapes","author":"claude","brief":"Edit twice."}]}"#
            let diff = FileDiff(path: "a.py", oldText: "x = 1\n", newText: "x = 2\n")
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)], [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[[
                    .toolStarted(id: "t1", title: "Edit · a.py", kind: "edit",
                                 input: #"{"file_path": "a.py"}"#),
                    .toolUpdated(id: "t1", status: nil, output: nil, diff: diff),
                    .toolUpdated(id: "t1", status: "completed", output: nil, diff: nil),
                    .toolStarted(id: "t2", title: "Edit · b.py", kind: "edit",
                                 input: #"{"file_path": "b.py"}"#),
                    .toolUpdated(id: "t2", status: "completed", output: nil, diff: nil),
                    .assistantDelta("done"),
                    .turnFinished(stopReason: "end_turn", costUSD: nil),
                ]]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                if provider == .claude { backend.eventDelay = 0.2 }
                return backend
            }
            engine.start(task: "Event shapes.", project: dir)
            let survived = await waitUntil(6) {
                guard let live = engine.items.first?.live else { return false }
                return live.diff?.path == "a.py" && !live.diffUnavailable
                    && live.tools.contains { $0.contains("a.py") }
            }
            audit.check("a status-only completed update does not wipe the live diff",
                        survived)
            let toolScoped = await waitUntil(6) {
                guard let live = engine.items.first?.live else { return false }
                return live.diffUnavailable && live.diff?.path == "a.py"
                    && live.editedPath == "b.py"
            }
            audit.check("the no-diff note is tool-scoped, not turn-scoped", toolScoped)
            _ = await waitUntil(10) { engine.phase == .done }
        }
    }

    // MARK: Live diff and follow-edits

    /// The live view shows the code being written (or honestly says the CLI did not stream a
    /// diff), and follow-edits opens clean tabs as the author writes — never a dirty one.
    private static func liveDiffAndFollowEdits(_ audit: Auditor) async {
        audit.section("Orchestrator — live code view and follow-edits")

        audit.check("follow-edits is on by default", Orchestrator().followEdits)

        let demo = Orchestrator()

        demo.reuseSessions = false   // these fixtures script one backend per session
        demo.seedDemo()
        let demoDiff = demo.items.first { $0.live != nil }?.live?.diff
        audit.check("the demo seeds a live diff on the in-flight item",
                    demoDiff?.path == "Sources/Parser/Tokenizer.swift"
                    && demoDiff?.newText.contains("source.isEmpty") == true
                    && demoDiff?.oldText.contains("source.isEmpty") == false,
                    demoDiff?.path ?? "nil")
        let demoStuck = demo.items.first { $0.state == .acceptedWithObjections }
        audit.check("the demo includes an objections card with a parsed recommendation",
                    demoStuck?.recommendedExtraRounds == 2
                    && demoStuck?.recommendationLineText?.contains("2 more rounds") == true
                    && demoStuck?.recommendationAccepts == false,
                    demoStuck?.recommendationLineText ?? "nil")
        audit.check("the demo is idle so grant controls render", !demo.isRunning)
        let nearCap = WorkItem(title: "t", brief: "b", author: .claude, reviewer: .grok)
        nearCap.round = 8
        audit.equal("near the lifetime cap the grant range shrinks to the remainder",
                    nearCap.grantableExtraRounds, 2)
        audit.equal("…and the remaining allowance is the lifetime remainder",
                    nearCap.remainingLifetimeRounds, 2)
        nearCap.round = 10
        audit.equal("at the lifetime cap no grant is offered",
                    nearCap.grantableExtraRounds, 0)

        let small = LiveDiff.render(FileDiff(
            path: "t.py",
            oldText: "keep\nalpha\nkeep\n",
            newText: "keep\nbeta\nkeep\n"))
        audit.check("a one-line replacement renders minus then plus",
                    small.contains("-alpha") && small.contains("+beta"),
                    small.joined(separator: " | "))
        audit.check("unchanged neighbours stay as context",
                    small.contains(" keep"),
                    small.joined(separator: " | "))

        let deepOld = (1...3000).map { $0 == 2500 ? "old-changed" : "line \($0)" }
            .joined(separator: "\n")
        let deepNew = (1...3000).map { $0 == 2500 ? "new-changed" : "line \($0)" }
            .joined(separator: "\n")
        let deep = LiveDiff.render(FileDiff(path: "deep.py", oldText: deepOld, newText: deepNew))
        audit.check("an edit past line 2000 still renders added and removed lines",
                    deep.contains("-old-changed") && deep.contains("+new-changed"),
                    "rendered=\(deep.count) lines")

        let oldLong = (1...60).map { "old \($0)" }.joined(separator: "\n")
        let newLong = (1...60).map { "new \($0)" }.joined(separator: "\n")
        let allLong = LiveDiff.lines(old: oldLong, new: newLong)
        let renderedLong = LiveDiff.render(FileDiff(path: "big.py",
                                                    oldText: oldLong, newText: newLong))
        audit.check("a long diff is capped at 40 lines plus a remainder tail",
                    allLong.count > 40
                    && renderedLong.count == LiveDiff.renderedLineCap + 1
                    && renderedLong.last == "… \(allLong.count - LiveDiff.renderedLineCap) more lines",
                    "all=\(allLong.count) rendered=\(renderedLong.count) tail=\(renderedLong.last ?? "nil")")
        audit.check("the capped window keeps the hunk header and the first removals",
                    renderedLong.first?.hasPrefix("@@") == true
                    && renderedLong.contains { $0.hasPrefix("-old") })

        let rewriteN = 600
        let oldRewrite = (1...rewriteN).map { "old \($0)" }.joined(separator: "\n")
        let newRewrite = (1...rewriteN).map { "new \($0)" }.joined(separator: "\n")
        let renderedRewrite = LiveDiff.render(FileDiff(path: "rewrite.py",
                                                       oldText: oldRewrite, newText: newRewrite))
        let trueRewrite = 1 + rewriteN + rewriteN   // hunk + every deletion + every insertion
        audit.check("the remainder counts the real rewrite, not the LCS window",
                    renderedRewrite.count == LiveDiff.renderedLineCap + 1
                    && renderedRewrite.last == "… \(trueRewrite - LiveDiff.renderedLineCap) more lines",
                    renderedRewrite.last ?? "nil")

        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.followEdits = false
            let plan = #"{"items":[{"title":"Live","author":"claude","brief":"Edit it."}]}"#
            let streamed = FileDiff(path: "src/token.py",
                                    oldText: "keep\nalpha\nkeep\n",
                                    newText: "keep\nbeta\nkeep\n")
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)], [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[[
                    .toolStarted(id: "e1", title: "Edit · token.py", kind: "edit",
                                 input: #"{"file_path":"src/token.py"}"#),
                    .toolUpdated(id: "e1", status: "in_progress", output: nil, diff: nil),
                    .thoughtDelta("between status and diff"),
                    .toolUpdated(id: "e1", status: "completed", output: nil, diff: streamed),
                    .thoughtDelta("still writing"),
                    .thoughtDelta("still writing"),
                    .thoughtDelta("still writing"),
                    .assistantDelta("Done. FILES: src/token.py"),
                    .turnFinished(stopReason: "end_turn", costUSD: 0.01),
                ]]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                if provider == .claude { backend.eventDelay = 0.2 }
                return backend
            }
            engine.start(task: "Show the live diff.", project: dir)
            let noFalseHonesty = await waitUntil(8) {
                guard let live = engine.items.first?.live else { return false }
                // After the in_progress update (and the thought that follows it), before the
                // streamed FileDiff — Grok's shape. Must not already be marked unavailable.
                return live.editedPath == "src/token.py"
                    && live.diff == nil
                    && !live.diffUnavailable
                    && live.thinkingCharacters > 0
            }
            audit.check("an in-progress edit does not claim the CLI cannot stream diffs",
                        noFalseHonesty)
            var captured: FileDiff?
            let sawLive = await waitUntil(8) {
                guard let live = engine.items.first?.live, let diff = live.diff else { return false }
                captured = diff
                return diff.path == "src/token.py"
                    && diff.oldText.contains("alpha")
                    && diff.newText.contains("beta")
            }
            audit.check("mid-turn, the live view carries the streamed diff",
                        sawLive && captured?.path == "src/token.py",
                        "live=\(engine.items.first?.live?.diff?.path ?? "nil")")
            if let captured {
                let rendered = LiveDiff.render(captured)
                audit.check("…and the added and removed lines match the FileDiff",
                            rendered.contains("-alpha") && rendered.contains("+beta"),
                            rendered.joined(separator: " | "))
            } else {
                audit.check("…and the added and removed lines match the FileDiff", false)
            }
            _ = await waitUntil(10) { engine.phase == .done }
        }

        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            let plan = #"{"items":[{"title":"Silent","author":"claude","brief":"Edit without a diff."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)], [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[[
                    .toolStarted(id: "e1", title: "Edit · nodiff.py", kind: "edit",
                                 input: #"{"file_path":"nodiff.py"}"#),
                    .toolUpdated(id: "e1", status: "completed", output: "wrote it", diff: nil),
                    .thoughtDelta("no patch on the wire"),
                    .thoughtDelta("no patch on the wire"),
                    .assistantDelta("Done. FILES: nodiff.py"),
                    .turnFinished(stopReason: "end_turn", costUSD: 0.01),
                ]]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                if provider == .claude { backend.eventDelay = 0.2 }
                return backend
            }
            engine.start(task: "Edit without streaming a diff.", project: dir)
            var honestPath: String?
            var honestHadDiff = true
            var honestUnavailable = false
            let sawHonest = await waitUntil(8) {
                guard let live = engine.items.first?.live, let path = live.editedPath else {
                    return false
                }
                honestPath = path
                honestHadDiff = live.diff != nil
                honestUnavailable = live.diffUnavailable
                return path == "nodiff.py" && live.diff == nil && live.diffUnavailable
            }
            audit.check("an edit with no streamed diff is named honestly, not invented",
                        sawHonest && honestPath == "nodiff.py" && !honestHadDiff
                        && honestUnavailable,
                        "path=\(honestPath ?? "nil") hadDiff=\(honestHadDiff) unavailable=\(honestUnavailable)")
            _ = await waitUntil(10) { engine.phase == .done }
        }

        await Auditor.withTemporaryDirectory { dir in
            let model = AppModel(trust: .forAudit)
            model.openProject(dir)
            let file = dir.appendingPathComponent("src/live.swift")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? "after the edit\n".write(to: file, atomically: true, encoding: .utf8)

            let engine = model.orchestrator
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.followEdits = true
            let plan = #"{"items":[{"title":"Follow","author":"claude","brief":"Change live.swift."}]}"#
            let streamed = FileDiff(path: "src/live.swift",
                                    oldText: "before the edit\n",
                                    newText: "after the edit\n")
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)], [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[[
                    .toolStarted(id: "e1", title: "Edit · live.swift", kind: "edit",
                                 input: #"{"file_path":"src/live.swift"}"#),
                    .toolUpdated(id: "e1", status: "completed", output: nil, diff: streamed),
                    .thoughtDelta("keeping the turn in flight"),
                    .thoughtDelta("keeping the turn in flight"),
                    .assistantDelta("Done. FILES: src/live.swift"),
                    .turnFinished(stopReason: "end_turn", costUSD: 0.01),
                ]]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                if provider == .claude { backend.eventDelay = 0.2 }
                return backend
            }
            engine.start(task: "Follow the edit.", project: dir)
            let opened = await waitUntil(8) {
                guard engine.items.first?.live != nil else { return false }
                let active = model.documents.active
                return active?.url.lastPathComponent == "live.swift"
                    && active?.text == "after the edit\n"
            }
            audit.check("follow-edits opens the file as the active tab before the run finishes",
                        opened,
                        "active=\(model.documents.active?.name ?? "nil") text=\(String(reflecting: model.documents.active?.text ?? ""))")
            audit.equal("the followed tab matches what is on disk",
                        model.documents.active?.text, "after the edit\n")
            _ = await waitUntil(10) { engine.phase == .done }
        }

        await Auditor.withTemporaryDirectory { dir in
            let model = AppModel(trust: .forAudit)
            model.openProject(dir)
            let file = dir.appendingPathComponent("kept.swift")
            try? "on disk originally\n".write(to: file, atomically: true, encoding: .utf8)
            model.open(file: file)
            model.documents.active?.replaceAll(with: "I am typing\n")
            let dirtyID = model.documents.activeID
            try? "agent overwrote me\n".write(to: file, atomically: true, encoding: .utf8)
            audit.check("the dirty-tab fixture is actually dirty",
                        model.documents.active?.isDirty == true
                        && model.documents.active?.text == "I am typing\n")

            let engine = model.orchestrator
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.followEdits = true
            let plan = #"{"items":[{"title":"Leave it","author":"claude","brief":"Edit kept.swift."}]}"#
            let streamed = FileDiff(path: "kept.swift",
                                    oldText: "on disk originally\n",
                                    newText: "agent overwrote me\n")
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)], [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[[
                    .toolStarted(id: "e1", title: "Edit · kept.swift", kind: "edit",
                                 input: #"{"file_path":"kept.swift"}"#),
                    .toolUpdated(id: "e1", status: "completed", output: nil, diff: streamed),
                    .assistantDelta("Done. FILES: kept.swift"),
                    .turnFinished(stopReason: "end_turn", costUSD: 0.01),
                ]]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Do not clobber the dirty tab.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            audit.equal("a dirty tab still holds the user's text",
                        model.documents.active?.text, "I am typing\n")
            audit.check("the dirty tab was not reloaded",
                        model.documents.active?.isDirty == true)
            audit.equal("follow-edits does not steal focus from a dirty tab",
                        model.documents.activeID, dirtyID)
            audit.equal("the file on disk did change",
                        try? String(contentsOf: file, encoding: .utf8), "agent overwrote me\n")
        }

        await Auditor.withTemporaryDirectory { dir in
            let model = AppModel(trust: .forAudit)
            model.openProject(dir)
            let file = dir.appendingPathComponent("already-open.swift")
            try? "before\n".write(to: file, atomically: true, encoding: .utf8)
            model.open(file: file)
            audit.equal("the reload fixture starts with the original text",
                        model.documents.active?.text, "before\n")
            try? "after\n".write(to: file, atomically: true, encoding: .utf8)

            let engine = model.orchestrator
            engine.followEdits = true
            configureScriptedEdit(engine, path: "already-open.swift",
                                  oldText: "before\n", newText: "after\n",
                                  eventDelay: 0.2)
            engine.start(task: "Reload the open tab.", project: dir)
            let reloaded = await waitUntil(8) {
                engine.items.first?.live != nil
                    && model.documents.active?.text == "after\n"
            }
            audit.check("follow-edits reloads a clean open tab from disk",
                        reloaded,
                        "text=\(String(reflecting: model.documents.active?.text ?? ""))")
            _ = await waitUntil(10) { engine.phase == .done }
        }

        await Auditor.withTemporaryDirectory { dir in
            let model = AppModel(trust: .forAudit)
            model.openProject(dir)
            let file = dir.appendingPathComponent("gated.swift")
            try? "on disk\n".write(to: file, atomically: true, encoding: .utf8)

            let engine = model.orchestrator
            engine.followEdits = false
            configureScriptedEdit(engine, path: "gated.swift",
                                  oldText: "old\n", newText: "on disk\n")
            engine.start(task: "Do not follow.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            audit.check("follow-edits off does not open the file",
                        model.documents.document(for: file) == nil,
                        "open=\(model.documents.documents.map(\.name))")
        }

        await Auditor.withTemporaryDirectory { dir in
            let model = AppModel(trust: .forAudit)
            model.openProject(dir)
            let file = dir.appendingPathComponent("throttled.swift")
            try? "first\n".write(to: file, atomically: true, encoding: .utf8)
            model.open(file: file)

            let engine = model.orchestrator
            engine.followEdits = true
            configureScriptedEdit(engine, path: "throttled.swift",
                                  oldText: "first\n", newText: "second\n",
                                  eventDelay: 0.2)
            engine.start(task: "Throttle reloads.", project: dir)
            let started = await waitUntil(8) {
                engine.items.first?.live?.tools.isEmpty == false
            }
            audit.check("the throttle fixture saw the first edit event", started)
            try? "second\n".write(to: file, atomically: true, encoding: .utf8)
            _ = await waitUntil(8) { engine.items.first?.live?.diff != nil }
            audit.equal("a second edit within a second does not reload",
                        model.documents.active?.text, "first\n")
            _ = await waitUntil(10) { engine.phase == .done }
        }

        await Auditor.withTemporaryDirectory { dir in
            let model = AppModel(trust: .forAudit)
            model.openProject(dir)
            let dirtyFile = dir.appendingPathComponent("dirty.swift")
            let otherFile = dir.appendingPathComponent("other.swift")
            try? "user original\n".write(to: dirtyFile, atomically: true, encoding: .utf8)
            try? "agent wrote this\n".write(to: otherFile, atomically: true, encoding: .utf8)
            model.open(file: dirtyFile)
            model.documents.active?.replaceAll(with: "I am typing\n")
            let dirtyID = model.documents.activeID

            let engine = model.orchestrator
            engine.followEdits = true
            configureScriptedEdit(engine, path: "other.swift",
                                  oldText: "before\n", newText: "agent wrote this\n",
                                  eventDelay: 0.2)
            engine.start(task: "Edit a different file.", project: dir)
            let openedOther = await waitUntil(8) {
                engine.items.first?.live != nil
                    && model.documents.document(for: otherFile) != nil
            }
            audit.check("follow-edits opens a different edited file without taking focus",
                        openedOther
                        && model.documents.activeID == dirtyID
                        && model.documents.active?.text == "I am typing\n",
                        "active=\(model.documents.active?.name ?? "nil") otherOpen=\(openedOther)")
            _ = await waitUntil(10) { engine.phase == .done }
            audit.equal("the dirty tab still has focus after the run",
                        model.documents.activeID, dirtyID)
        }
    }

    // MARK: Round budgets and resume

    private static func roundBudgetsAndResume(_ audit: Auditor) async {
        audit.section("Orchestrator — per-item round budgets, recommendation, resume")

        let chipEngine = Orchestrator()

        chipEngine.reuseSessions = false   // these fixtures script one backend per session
        chipEngine.orchestratorProvider = .claude
        audit.check("the header chip text names the engine's orchestratorProvider",
                    chipEngine.orchestratorChipText
                        == "orchestrator: \(chipEngine.orchestratorProvider.displayName)",
                    chipEngine.orchestratorChipText)

        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude, .codex]
            engine.orchestratorProvider = .grok
            engine.maxRounds = 4
            engine.turnTimeout = 5

            let plan = """
            {"items": [
              {"title": "Hard", "author": "claude", "brief": "Hard thing.", "rounds": 1},
              {"title": "Easy", "author": "codex", "brief": "Easy thing."}
            ]}
            """
            var sessionQueues: [Provider: [[[BackendEvent]]]] = [
                .grok: [
                    [ScriptedBackend.reply(plan, cost: 0.001)],
                    [ScriptedBackend.reply(
                        "RECOMMEND: 2 more rounds: remaining bugs are real", cost: 0.003)],
                ],
                .claude: [
                    [ScriptedBackend.reply("Wrote it. FILES: h.py", cost: 0.10)],
                    [ScriptedBackend.reply("NO FINDINGS", cost: 0.004)],
                    [ScriptedBackend.reply("Revised. FILES: h.py", cost: 0.05)],
                ],
                .codex: [
                    [ScriptedBackend.reply("FINDING: h.py:1: bug: still broken", cost: 0.02)],
                    [ScriptedBackend.reply("Easy done. FILES: e.py", cost: 0.008)],
                    // The resume reviewer answers in the scoped grant form.
                    [ScriptedBackend.reply("RESOLVED: F1", cost: 0.01)],
                ],
            ]
            var created: [ScriptedBackend] = []
            engine.makeBackend = { provider in
                let scripts = sessionQueues[provider]?.isEmpty == false
                    ? sessionQueues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                created.append(backend)
                return backend
            }

            engine.start(task: "Split the work by complexity.", project: dir)
            let finished = await waitUntil(10) { engine.phase == .done }
            audit.check("the budgeted run completed", finished, "\(engine.phase)")
            guard engine.items.count == 2 else {
                audit.check("two work items from the plan", false)
                return
            }
            let first = engine.items[0], second = engine.items[1]

            audit.equal("rounds:1 is the item's budget", first.roundBudget, 1)
            audit.equal("rounds:1 stops after exactly one review pass", first.round, 1)
            audit.equal("…as accepted with objections", first.state, .acceptedWithObjections)
            let originalAuthor = created.first { $0.provider == .claude }
            audit.equal("the author was not asked to revise under a 1-round budget",
                        originalAuthor?.prompts.count, 1)
            audit.equal("the reviewer reviewed exactly once",
                        created.first { $0.provider == .codex }?.prompts.count, 1)
            audit.equal("absent rounds falls back to the engine default",
                        second.roundBudget, 4)
            audit.equal("…and the easy item was accepted", second.state, .accepted)

            audit.equal("budget exhaustion triggers exactly one recommendation session",
                        created.filter { $0.provider == .grok }.count, 2)
            let recommendPrompt = created.filter { $0.provider == .grok }.last?.prompts.first
            audit.check("the recommendation turn asked for the exact reply format",
                        recommendPrompt?.contains("RECOMMEND: accept: <one line why>") == true
                        && recommendPrompt?.contains(
                            "RECOMMEND: <N> more rounds: <one line why>") == true,
                        recommendPrompt ?? "nil")
            audit.equal("the scripted extra-round count lands on the item",
                        first.recommendedExtraRounds, 2)
            audit.check("…with the reason",
                        first.recommendationReason == "remaining bugs are real",
                        first.recommendationReason ?? "nil")
            audit.check("item 1 cost includes the recommendation turn",
                        abs(first.costUSD - 0.123) < 0.0001, "\(first.costUSD)")
            audit.equal("item 1 turns so far (author, review, recommend)", first.turns, 3)

            let turnsBeforeRefuse = first.turns
            engine.resume(first, extraRounds: 10, project: dir)
            audit.equal("a grant past the lifetime cap does not start a run",
                        engine.phase, .done)
            audit.equal("…and consumes no turns", first.turns, turnsBeforeRefuse)
            audit.check("the lifetime cap of 10 refuses further grants in words",
                        engine.log.contains {
                            $0.contains("lifetime cap of 10") && $0.contains("Cannot grant")
                        },
                        engine.log.last ?? "")

            engine.resume(first, extraRounds: 1, project: dir)
            let resumed = await waitUntil(10) {
                engine.phase == .done && first.state == .accepted
            }
            audit.check("resume ran revise + review and ended accepted", resumed,
                        "phase=\(engine.phase) state=\(first.state)")
            audit.check("resume keeps the reviewer distinct from the author",
                        first.reviewer != first.author
                        && first.author == .claude && first.reviewer == .codex)
            let resumeAuthor = created.filter { $0.provider == .claude }.last
            audit.check("resume seeds the author with the standing findings",
                        resumeAuthor?.prompts.first?.contains("still broken") == true,
                        resumeAuthor?.prompts.first ?? "nil")
            audit.check("costs from a resume accrue to the same item",
                        abs(first.costUSD - 0.183) < 0.0001, "\(first.costUSD)")
            audit.equal("resume turns accrue on the same item", first.turns, 5)
            audit.check("resume did not invent a second item",
                        engine.items.count == 2 && engine.items[0] === first)
        }

        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.maxRounds = 1
            engine.turnTimeout = 5
            let unparseable = "I dunno, maybe keep going?"
            let plan = #"{"items":[{"title":"X","author":"claude","brief":"Do it.","rounds":1}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [
                    [ScriptedBackend.reply(plan)],
                    [ScriptedBackend.reply("FINDING: x.py:1: bug: nope")],
                    [ScriptedBackend.reply(unparseable)],
                ],
                .claude: [[ScriptedBackend.reply("Done. FILES: x.py")]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "One item.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            guard let item = engine.items.first else {
                audit.check("the unparseable-recommendation item exists", false)
                return
            }
            audit.equal("unparseable extra rounds is nil — no number invented",
                        item.recommendedExtraRounds, nil)
            audit.equal("the unparseable recommendation is stored verbatim",
                        item.recommendationReason, unparseable)
            audit.equal("…and the item still landed with objections",
                        item.state, .acceptedWithObjections)
        }
    }

    // MARK: Acceptance gate

    private static func acceptanceGate(_ audit: Auditor) async {
        audit.section("Orchestrator — acceptance gate")

        audit.check("the gate is on by default", Orchestrator().followGate)

        let demo = Orchestrator()

        demo.reuseSessions = false   // these fixtures script one backend per session
        demo.seedDemo()
        let passedCard = demo.items.first { $0.title == "Cover the empty case" }
        audit.equal("demo accepted card reads gate passed",
                    passedCard?.cardStateText, "gate passed")
        audit.equal("…and the badge is green", passedCard?.cardBadgeKind, .green)
        let failedCard = demo.items.first { $0.title == "Rewrite the bound check" }
        audit.equal("demo objections card with a red gate reads gate failed",
                    failedCard?.cardStateText, "gate failed")
        audit.equal("…and the badge is red, not yellow-accepted",
                    failedCard?.cardBadgeKind, .red)
        audit.equal("…while the state machine stays acceptedWithObjections",
                    failedCard?.state, .acceptedWithObjections)
        audit.check("the demo still exposes grant controls on the objections card",
                    failedCard?.state == .acceptedWithObjections && !demo.isRunning)

        let stale = WorkItem(title: "t", brief: "b", author: .claude, reviewer: .grok)
        stale.gate = GateResult(tasks: [
            GateTaskResult(taskID: "t", title: "swift test", passed: false, exitCode: 1,
                           timedOut: false, skippedMissingTool: false, missingTool: nil,
                           outputTail: "boom", firstErrorLine: "boom", diagnostics: []),
        ])
        stale.state = .revising
        audit.equal("a red gate does not hide the revising state",
                    stale.cardStateText, "Claude is revising…")
        audit.equal("…and the badge stays in-flight orange", stale.cardBadgeKind, .orange)
        stale.state = .reviewing
        audit.equal("a red gate does not hide the reviewing state",
                    stale.cardStateText, "Grok is reviewing…")
        stale.state = .cancelled
        audit.equal("a red gate does not hide a stopped item",
                    stale.cardStateText, "stopped")
        stale.state = .failed
        audit.equal("a red gate does not hide a failed item",
                    stale.cardStateText, "failed")
        stale.state = .acceptedWithObjections
        audit.equal("a settled red gate still reads gate failed",
                    stale.cardStateText, "gate failed")
        audit.equal("…with a red badge", stale.cardBadgeKind, .red)

        await Auditor.withTemporaryDirectory { dir in
            let prefix = String(repeating: "progress xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n",
                                count: 80)
            let suffix = String(repeating: "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\n",
                                count: 200)
            let output = prefix + "UNIQUE_GATE_ERROR: error: the real failure\n" + suffix
            let scan = GateResult.scan(output, directory: dir)
            audit.check("the GATE error line is taken from the full output, not the tail",
                        scan.firstErrorLine.contains("UNIQUE_GATE_ERROR")
                        && scan.firstErrorLine.contains("the real failure")
                        && !scan.tail.contains("UNIQUE_GATE_ERROR"),
                        "first=\(scan.firstErrorLine) tailPrefix=\(scan.tail.prefix(80))")
        }

        await Auditor.withTemporaryDirectory { dir in
            try? "int main(void) { return 0; }\n"
                .write(to: dir.appendingPathComponent("boom.c"), atomically: true,
                       encoding: .utf8)
            let marker = dir.appendingPathComponent("fail.marker")
            try? "fail\n".write(to: marker, atomically: true, encoding: .utf8)
            let makefile = "test:\n"
                + "\t@if [ -f fail.marker ]; then "
                + "echo \"boom.c:1:1: error: marker is present\"; exit 1; fi\n"
                + "\t@echo ok\n"
            try? makefile.write(to: dir.appendingPathComponent("Makefile"), atomically: true,
                                encoding: .utf8)

            let engine = Orchestrator()

            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.maxRounds = 2
            engine.turnTimeout = 5
            engine.gateTimeout = 20
            let logURL = dir.appendingPathComponent("run.json")
            engine.runLogURL = logURL

            let plan = #"{"items":[{"title":"GateMe","author":"claude","brief":"Ship it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan, cost: 0.003)],
                        [ScriptedBackend.reply("NO FINDINGS", cost: 0.005),
                         ScriptedBackend.reply("NO FINDINGS", cost: 0.005)]],
                .claude: [[ScriptedBackend.reply("Wrote it. FILES: boom.c", cost: 0.01),
                           ScriptedBackend.reply("Fixed the marker. FILES: boom.c",
                                                 cost: 0.01)]],
            ]
            var created: [ScriptedBackend] = []
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                backend.onPrompt = { prompt in
                    if prompt.contains("GATE:") {
                        try? FileManager.default.removeItem(at: marker)
                    }
                }
                created.append(backend)
                return backend
            }

            engine.start(task: "Prove it with a gate.", project: dir)
            let finished = await waitUntil(20) { engine.phase == .done }
            audit.check("the marker-gate run completed", finished, "\(engine.phase)")
            guard let item = engine.items.first else {
                audit.check("the marker-gate item exists", false)
                return
            }
            let author = created.first { $0.provider == .claude }
            audit.check("a failing gate with budget left sent a GATE: revise prompt",
                        author?.prompts.count == 2
                        && author?.prompts.last?.contains("GATE:") == true,
                        author?.prompts.last ?? "prompts=\(author?.prompts.count ?? -1)")
            audit.check("…and the prompt names the task, exit code, and error line",
                        author?.prompts.last?.contains("GATE: make test exited") == true
                        && author?.prompts.last?.contains("marker is present") == true,
                        author?.prompts.last ?? "nil")
            let makeTest = item.gate?.tasks.first { $0.title == "make test" }
            audit.check("the re-gate passed after the marker was flipped",
                        item.gate?.passed == true
                        && makeTest?.passed == true
                        && makeTest?.exitCode == 0,
                        "passed=\(String(describing: item.gate?.passed)) makeTest=\(String(describing: makeTest?.exitCode))")
            audit.equal("…and the item accepted", item.state, .accepted)
            audit.equal("the card reads gate passed", item.cardStateText, "gate passed")
            audit.equal("…with a green badge", item.cardBadgeKind, .green)
            audit.check("gate runs add zero tokens to the item",
                        abs(item.costUSD - 0.03) < 0.0001, "\(item.costUSD)")
            audit.equal("gate runs do not count as agent turns", item.turns, 4)
            audit.equal("a nil-cost gate lane entry is not an unreported turn",
                        item.unreportedTurns, 0)
            audit.check("the run total is still only the agent spend",
                        abs(engine.totalCostUSD - 0.033) < 0.0001,
                        "\(engine.totalCostUSD)")
            audit.check("the failing output tail was recorded before the re-gate",
                        item.lane.contains(where: {
                            $0.title == "Acceptance gate"
                            && $0.text.contains("make test exited")
                            && !$0.text.contains("exited 0")
                        }))
            if let data = try? Data(contentsOf: logURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = json["items"] as? [[String: Any]],
               let gateJSON = rows.first?["gate"] as? Dictionary<String, Any> {
                audit.check("the run log includes the gate record",
                            gateJSON["passed"] as? Bool == true)
                let tasks = gateJSON["tasks"] as? [[String: Any]] ?? []
                audit.check("…with the make test task title",
                            tasks.contains(where: { $0["title"] as? String == "make test" }))
            } else {
                audit.check("the run log includes the gate record", false,
                            (try? String(contentsOf: logURL, encoding: .utf8)) ?? "no log")
            }
        }

        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.maxRounds = 1
            engine.turnTimeout = 5
            engine.gateTasksOverride = [
                RunTask(id: "false", title: "swift test", executable: "/usr/bin/false",
                        arguments: [], directory: dir, kind: .test, source: "audit"),
            ]
            let plan = #"{"items":[{"title":"NoBudget","author":"claude","brief":"Do it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)],
                        [ScriptedBackend.reply("NO FINDINGS")],
                        [ScriptedBackend.reply("RECOMMEND: 1 more rounds: the gate is red")]],
                .claude: [[ScriptedBackend.reply("Done. FILES: a.py", cost: 0.01)]],
            ]
            var created: [ScriptedBackend] = []
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                created.append(backend)
                return backend
            }
            engine.start(task: "No budget left.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            guard let item = engine.items.first else {
                audit.check("the no-budget accepted item exists", false)
                return
            }
            audit.equal("no-budget + red gate lands where rounds can still be granted",
                        item.state, .acceptedWithObjections)
            audit.check("…and the grant stepper has room",
                        item.grantableExtraRounds >= 1, "\(item.grantableExtraRounds)")
            audit.check("…and a recommendation turn ran",
                        item.recommendedExtraRounds == 1)
            let recommendPrompt = created.filter { $0.provider == .grok }.last?.prompts.first
            audit.check("a gate-only recommendation does not blame the reviewer",
                        recommendPrompt?.contains("the acceptance gate is still failing") == true
                        && recommendPrompt?.contains("the reviewer still has findings standing")
                            != true
                        && recommendPrompt?.contains("- : gate:") != true,
                        recommendPrompt ?? "nil")
            audit.equal("…but the card does not say plain accepted",
                        item.cardStateText, "gate failed")
            audit.equal("…and the badge is red, not green", item.cardBadgeKind, .red)
            audit.check("the failure is on the work item (title, exit code, tail)",
                        item.gate?.hasFailure == true
                        && item.gate?.tasks.first?.title == "swift test"
                        && item.gate?.tasks.first?.exitCode == 1
                        && item.gate?.tasks.first?.passed == false,
                        "\(item.gate?.tasks.first?.title ?? "nil") \(String(describing: item.gate?.tasks.first?.exitCode))")
            let author = created.first { $0.provider == .claude }
            audit.equal("no budget means no GATE: revise round", author?.prompts.count, 1)
        }

        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.maxRounds = 1
            engine.turnTimeout = 5
            engine.gateTasksOverride = [
                RunTask(id: "false", title: "swift test", executable: "/usr/bin/false",
                        arguments: [], directory: dir, kind: .test, source: "audit"),
            ]
            let plan = #"{"items":[{"title":"ObjGate","author":"claude","brief":"Do it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)],
                        [ScriptedBackend.reply("FINDING: a.py:1: bug: still wrong")],
                        [ScriptedBackend.reply("RECOMMEND: accept: nits")]],
                .claude: [[ScriptedBackend.reply("Done. FILES: a.py")]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Objections plus a red gate.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            guard let item = engine.items.first else {
                audit.check("the objections+gate item exists", false)
                return
            }
            audit.equal("no-budget + findings lands acceptedWithObjections",
                        item.state, .acceptedWithObjections)
            audit.equal("…and the card still reads gate failed, not plain accepted",
                        item.cardStateText, "gate failed")
            audit.equal("…with a red badge, not yellow", item.cardBadgeKind, .red)
        }

        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.gateTasksOverride = [
                RunTask(id: "missing", title: "swift test", executable: nil,
                        arguments: [], directory: dir, kind: .test, source: "audit",
                        missingTool: "swift"),
                RunTask(id: "true", title: "swift build", executable: "/usr/bin/true",
                        arguments: [], directory: dir, kind: .build, source: "audit"),
            ]
            let plan = #"{"items":[{"title":"Skip","author":"claude","brief":"Do it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)], [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[ScriptedBackend.reply("Done.")]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Skip a missing tool.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            guard let item = engine.items.first, let gate = item.gate else {
                audit.check("the missing-tool gate record exists", false)
                return
            }
            let skipped = gate.tasks.first { $0.taskID == "missing" }
            audit.check("a missing-tool task is recorded as skipped",
                        skipped?.skippedMissingTool == true
                        && skipped?.missingTool == "swift"
                        && skipped?.passed == false,
                        "skip=\(String(describing: skipped?.skippedMissingTool)) passed=\(String(describing: skipped?.passed))")
            audit.check("…and is never counted as a pass",
                        skipped?.passed == false
                        && gate.tasks.contains(where: { $0.taskID == "true" && $0.passed }))
            audit.equal("the executed task is what makes the gate pass", gate.passed, true)
        }

        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.gateTasksOverride = [
                RunTask(id: "missing-only", title: "cargo test", executable: nil,
                        arguments: [], directory: dir, kind: .test, source: "audit",
                        missingTool: "cargo"),
            ]
            let plan = #"{"items":[{"title":"SkipOnly","author":"claude","brief":"Do it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)], [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[ScriptedBackend.reply("Done.")]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Only a missing tool.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            guard let item = engine.items.first else {
                audit.check("the skip-only item exists", false)
                return
            }
            audit.check("skip-only is not presented as gate passed",
                        item.gate?.passed == false
                        && item.cardStateText == "accepted — reviewer had nothing left",
                        item.cardStateText)
            audit.equal("…and the item is accepted, not gate-failed",
                        item.cardBadgeKind, .green)
        }

        await Auditor.withTemporaryDirectory { dir in
            let sentinel = dir.appendingPathComponent("gate-ran")
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.followGate = false
            engine.gateTasksOverride = [
                RunTask(id: "touch", title: "swift test", executable: "/usr/bin/touch",
                        arguments: [sentinel.path], directory: dir, kind: .test,
                        source: "audit"),
            ]
            let plan = #"{"items":[{"title":"Off","author":"claude","brief":"Do it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)], [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[ScriptedBackend.reply("Done.")]],
            ]
            var created: [ScriptedBackend] = []
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                created.append(backend)
                return backend
            }
            engine.start(task: "Gate off.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            guard let item = engine.items.first else {
                audit.check("the followGate=false item exists", false)
                return
            }
            audit.check("followGate = false runs no processes",
                        !FileManager.default.fileExists(atPath: sentinel.path))
            audit.check("…and writes no gate record", item.gate == nil)
            audit.equal("…and leaves today's accepted wording in place",
                        item.cardStateText, "accepted — reviewer had nothing left")
            audit.equal("…with a green accepted badge", item.cardBadgeKind, .green)
            let author = created.first { $0.provider == .claude }
            audit.equal("…and does not send a revise round", author?.prompts.count, 1)
        }

        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.maxRounds = 1
            engine.gateTimeout = 0.4
            engine.gateTasksOverride = [
                RunTask(id: "sleep", title: "swift test", executable: "/bin/sleep",
                        arguments: ["8"], directory: dir, kind: .test, source: "audit"),
            ]
            let plan = #"{"items":[{"title":"Timeout","author":"claude","brief":"Do it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)],
                        [ScriptedBackend.reply("NO FINDINGS")],
                        [ScriptedBackend.reply("RECOMMEND: 1 more rounds: timed out")]],
                .claude: [[ScriptedBackend.reply("Done.")]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Time the gate out.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            guard let item = engine.items.first else {
                audit.check("the timeout-gate item exists", false)
                return
            }
            let timeoutTask = item.gate?.tasks.first
            let timeoutNamed = item.findings.contains(where: {
                $0.message.contains("GATE:") && $0.message.contains("timed out")
            })
            audit.check("a timed-out gate task is a failure, stated as such",
                        timeoutTask?.timedOut == true
                        && item.gate?.hasFailure == true
                        && timeoutNamed,
                        "timedOut=\(String(describing: timeoutTask?.timedOut)) code=\(String(describing: timeoutTask?.exitCode))")
            audit.equal("the card reads gate failed", item.cardStateText, "gate failed")
        }

        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.gateTimeout = 30
            engine.maxRounds = 1
            engine.gateTasksOverride = [
                RunTask(id: "sleep", title: "swift test", executable: "/bin/sleep",
                        arguments: ["20"], directory: dir, kind: .test, source: "audit"),
            ]
            let plan = #"{"items":[{"title":"StopGate","author":"claude","brief":"Do it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)], [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[ScriptedBackend.reply("Done.")]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Stop during the gate.", project: dir)
            let gating = await waitUntil(6) { engine.items.first?.isGating == true }
            audit.check("the item shows the gate is running (MainActor is not blocked)",
                        gating)
            let t0 = Date()
            engine.stop()
            let stopped = await waitUntil(6) { engine.phase == .cancelled }
            let elapsed = Date().timeIntervalSince(t0)
            audit.check("Stop cancels a gate run without waiting out the deadline",
                        stopped && elapsed < 5,
                        "phase=\(engine.phase) elapsed=\(String(format: "%.2f", elapsed))s")
            audit.equal("the in-flight item is cancelled",
                        engine.items.first?.state, .cancelled)
        }

        await Auditor.withTemporaryDirectory { dir in
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.maxRounds = 2
            engine.gateTasksOverride = [
                RunTask(id: "false", title: "swift test", executable: "/usr/bin/false",
                        arguments: [], directory: dir, kind: .test, source: "audit"),
            ]
            let plan = #"{"items":[{"title":"Revise","author":"claude","brief":"Do it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)],
                        [ScriptedBackend.reply("NO FINDINGS"),
                         ScriptedBackend.reply("NO FINDINGS")],
                        [ScriptedBackend.reply("RECOMMEND: 1 more rounds: still red")]],
                .claude: [[ScriptedBackend.reply("Wrote it."),
                           ScriptedBackend.reply("Tried.")]],
            ]
            var created: [ScriptedBackend] = []
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                created.append(backend)
                return backend
            }
            engine.start(task: "Keep failing.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            guard let item = engine.items.first else {
                audit.check("the keep-failing item exists", false)
                return
            }
            let author = created.first { $0.provider == .claude }
            audit.check("a failing gate with remaining budget revises the author",
                        author?.prompts.count == 2
                        && author?.prompts[1].contains("GATE: swift test exited 1") == true,
                        author?.prompts.last ?? "nil")
            audit.check("a gate-only revise does not blame the reviewer",
                        author?.prompts[1].contains("The acceptance gate") == true
                        && author?.prompts[1].contains("The reviewer examined") != true
                        && author?.prompts[1].contains("- : gate:") != true,
                        author?.prompts[1] ?? "nil")
            let reviewer = created.filter { $0.provider == .grok }.dropFirst().first
            audit.check("the re-review after a gate revise does not invent reviewer findings",
                        reviewer?.prompts.count == 2
                        && reviewer?.prompts[1].contains("after the acceptance gate failed")
                            == true
                        && reviewer?.prompts[1].contains("after your findings") != true,
                        reviewer?.prompts.last ?? "nil")
            audit.equal("at the cap the red gate is not a green accept",
                        item.cardStateText, "gate failed")
            audit.equal("…badge red", item.cardBadgeKind, .red)
        }

        await Auditor.withTemporaryDirectory { dir in
            let makefile = "clean:\n\ttouch ran-clean\n"
                + "install:\n\ttouch ran-install\n"
                + "test:\n\techo ok\n"
            try? makefile.write(to: dir.appendingPathComponent("Makefile"),
                                atomically: true, encoding: .utf8)
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.gateTimeout = 20
            let plan = #"{"items":[{"title":"MakeKinds","author":"claude","brief":"Do it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)], [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[ScriptedBackend.reply("Done.")]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Only test, not clean.", project: dir)
            _ = await waitUntil(15) { engine.phase == .done }
            let titles = engine.items.first?.gate?.tasks.map(\.title) ?? []
            audit.check("the gate does not run make clean or make install",
                        !FileManager.default.fileExists(
                            atPath: dir.appendingPathComponent("ran-clean").path)
                        && !FileManager.default.fileExists(
                            atPath: dir.appendingPathComponent("ran-install").path),
                        "tasks=\(titles)")
            audit.check("…and does run make test",
                        titles == ["make test"], "tasks=\(titles)")
        }

        await Auditor.withTemporaryDirectory { dir in
            let script = dir.appendingPathComponent("noisy.sh")
            try? """
                #!/bin/sh
                i=0
                while [ "$i" -lt 80 ]; do
                  echo "progress $i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
                  i=$((i + 1))
                done
                echo "UNIQUE_GATE_ERROR: error: the real failure"
                i=0
                while [ "$i" -lt 200 ]; do
                  echo "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
                  i=$((i + 1))
                done
                exit 1
                """.write(to: script, atomically: true, encoding: .utf8)
            let engine = Orchestrator()
            engine.reuseSessions = false   // these fixtures script one backend per session
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.maxRounds = 2
            engine.turnTimeout = 5
            engine.gateTimeout = 20
            engine.gateTasksOverride = [
                RunTask(id: "noisy", title: "swift test", executable: "/bin/sh",
                        arguments: [script.path], directory: dir, kind: .test, source: "audit"),
            ]
            let plan = #"{"items":[{"title":"Noisy","author":"claude","brief":"Do it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)],
                        [ScriptedBackend.reply("NO FINDINGS"),
                         ScriptedBackend.reply("NO FINDINGS")],
                        [ScriptedBackend.reply("RECOMMEND: 1 more rounds: still noisy")]],
                .claude: [[ScriptedBackend.reply("Wrote it."),
                           ScriptedBackend.reply("Tried.")]],
            ]
            var created: [ScriptedBackend] = []
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                created.append(backend)
                return backend
            }
            engine.start(task: "Find the real error.", project: dir)
            _ = await waitUntil(15) { engine.phase == .done }
            let author = created.first { $0.provider == .claude }
            let task = engine.items.first?.gate?.tasks.first
            audit.check("a noisy log's GATE: finding names the real error, not the tail",
                        author?.prompts.last?.contains("UNIQUE_GATE_ERROR") == true
                        && author?.prompts.last?.contains("the real failure") == true
                        && task?.firstErrorLine.contains("UNIQUE_GATE_ERROR") == true
                        && task?.outputTail.contains("UNIQUE_GATE_ERROR") != true,
                        "prompt=\(author?.prompts.last ?? "nil") first=\(task?.firstErrorLine ?? "nil")")
        }
    }

    /// One-item Grok-plan + Claude-author + Grok-review, with a scripted edit on `path`.
    private static func configureScriptedEdit(_ engine: Orchestrator, path: String,
                                             oldText: String, newText: String,
                                             eventDelay: TimeInterval = 0) {
        let plan = #"{"items":[{"title":"T","author":"claude","brief":"Edit."}]}"#
        let diff = FileDiff(path: path, oldText: oldText, newText: newText)
        let events: [BackendEvent] = [
            .toolStarted(id: "e1", title: "Edit · \(path)", kind: "edit",
                         input: #"{"file_path":"\#(path)"}"#),
            .toolUpdated(id: "e1", status: "completed", output: nil, diff: diff),
            .assistantDelta("Done. FILES: \(path)"),
            .turnFinished(stopReason: "end_turn", costUSD: 0.01),
        ]
        var queues: [Provider: [[[BackendEvent]]]] = [
            .grok: [[ScriptedBackend.reply(plan)], [ScriptedBackend.reply("NO FINDINGS")]],
            .claude: [[events]],
        ]
        engine.installedProviders = [.grok, .claude]
        engine.orchestratorProvider = .grok
        engine.turnTimeout = 5
        engine.makeBackend = { provider in
            let scripts = queues[provider]?.isEmpty == false
                ? queues[provider]!.removeFirst() : []
            let backend = ScriptedBackend(provider: provider, scripts: scripts)
            if provider == .claude, eventDelay > 0 { backend.eventDelay = eventDelay }
            return backend
        }
    }
}
import Darwin
import Foundation

/// Team analytics: JSONL store, aggregation, run-end recording of resolved models, and
/// `--import-run-log`. Scripted backends, temp directories, no quota.
@MainActor
enum AuditTeamStats {

    /// A temp store holding ONLY the imported (fingerprinted) records from the real one — the
    /// live store grows with every finished run (run 10's own completion turned "7 records"
    /// literals red), so assertions about the backfilled history must filter by fingerprint.
    static func writeLegacyOnlyCopy(from real: URL, to copy: URL) {
        let loaded = TeamStats.load(from: real)
        for record in loaded.records where record.importFingerprint != nil {
            TeamStats.append(record, to: copy)
        }
    }

    private static func writeLegacyOnlyCopyThrowing(at real: URL, to copy: URL) throws {
        writeLegacyOnlyCopy(from: real, to: copy)
        guard FileManager.default.fileExists(atPath: copy.path) else {
            throw NSError(domain: "audit", code: 1)
        }
    }


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
        defaultsAndFlags(audit)
        storeAndRoundTrip(audit)
        aggregation(audit)
        await recording(audit)
        await importFlag(audit)
        await engineFixes(audit)
        schemaV2(audit)
        await recommendationsAndTrends(audit)
    }

    // MARK: - Seams and flags

    private static func defaultsAndFlags(_ audit: Auditor) {
        audit.section("Team stats — the pane shows what the store holds")
        do {
            let seat = TeamStats.SeatKey(provider: "codex", role: "author",
                                         model: "gpt-5.6-terra")
            var stats = TeamStats.SeatStats()
            stats.items = 2; stats.cleanAccepts = 0; stats.averageRounds = 2.5
            stats.totalCostUSD = 0.44
            audit.equal("a seat row renders the fixture literally",
                        TeamStats.rowText(seat: seat, stats: stats),
                        "Codex · author · gpt-5.6-terra — 2 items, 0 clean, avg 2.5 rounds, $0.44")
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("teamstats-display-\(UUID().uuidString.prefix(6))")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let store = dir.appendingPathComponent("s.jsonl")
            let empty = TeamStats.loadForDisplay(from: store)
            audit.check("no store yet reads as the honest empty state",
                        empty.seats.isEmpty && empty.recordCount == 0)
            // Build the record through the real type and writer — a handwritten JSON
            // fixture guessed the schema wrong once and only proved its own corruption.
            let item = TeamStats.ItemOutcome(
                title: "t",
                authorProvider: "grok", authorModel: "grok-4.6", authorEffort: "xhigh",
                reviewerProvider: "codex", reviewerModel: "gpt-5.6-sol",
                reviewerEffort: "high",
                state: "accepted", rounds: 1, roundBudget: "2",
                findings: [], findingsLeftStanding: false,
                gate: TeamStats.ItemGate(status: "pass", passed: true, hasExecuted: true,
                                         hasFailure: false, tasks: []),
                costUSD: 0.1, turns: 2, unreportedTurns: 1,
                stalled: false, failed: false)
            TeamStats.append(TeamStats.RunOutcome(
                date: Date(), orchestratorProvider: "claude",
                orchestratorModel: "claude-opus-5", orchestratorEffort: "high",
                items: [item], importFingerprint: nil), to: store)
            if let handle = try? FileHandle(forWritingTo: store) {
                handle.seekToEndOfFile()
                handle.write(Data("not json at all\n".utf8))
                try? handle.close()
            }
            let loaded = TeamStats.loadForDisplay(from: store)
            audit.check("display load aggregates and counts the corrupt line",
                        loaded.recordCount == 1 && loaded.skippedLines == 1
                        && loaded.seats.contains {
                            $0.0 == TeamStats.SeatKey(provider: "grok", role: "author",
                                                      model: "grok-4.6")
                        },
                        "records=\(loaded.recordCount) skipped=\(loaded.skippedLines)")
            try? FileManager.default.removeItem(at: dir)
        }

        audit.section("Team stats — store URL, audit seam, launch-arg trap")
        let engine = Orchestrator()
        audit.check("audit orchestrators do not default to the user's team-stats store",
                    engine.teamStatsURL == nil)
        let path = TeamStats.storeURL.path
        audit.check("the default store URL is Application Support/Orrery/team-stats.jsonl",
                    path.hasSuffix("Library/Application Support/Orrery/team-stats.jsonl"),
                    path)
        let args = ["Orrery", "--import-run-log", "Foo.json", "/tmp/proj"]
        audit.check("--import-run-log value is not treated as a project path",
                    LaunchArguments.flagValues(in: args).contains("Foo.json")
                    && LaunchArguments.positionalPaths(in: args) == ["/tmp/proj"],
                    "paths=\(LaunchArguments.positionalPaths(in: args))")
        audit.check("--import-run-log /tmp is not treated as a positional project path",
                    LaunchArguments.positionalPaths(in: ["Orrery", "--import-run-log", "/tmp"])
                        .isEmpty)
    }

    // MARK: - JSONL store

    private static func storeAndRoundTrip(_ audit: Auditor) {
        audit.section("Team stats — JSONL round-trip and corrupt lines")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-teamstats-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appendingPathComponent("no-such.jsonl")
        let emptyLoad = TeamStats.load(from: missing)
        audit.check("a missing store is ([], 0), not an error",
                    emptyLoad.records.isEmpty && emptyLoad.corruptLines == 0)

        let store = dir.appendingPathComponent("team-stats.jsonl")
        let r1 = fixtureRun(title: "A", date: Date(timeIntervalSince1970: 1_700_000_000))
        let r2 = fixtureRun(title: "B", date: Date(timeIntervalSince1970: 1_700_000_100))
        let r3 = fixtureRun(title: "C", date: Date(timeIntervalSince1970: 1_700_000_200))
        TeamStats.append(r1, to: store)
        TeamStats.append(r2, to: store)
        TeamStats.append(r3, to: store)
        let loaded = TeamStats.load(from: store)
        audit.equal("three appended records load back", loaded.records.count, 3)
        audit.equal("a well-formed store reports zero corrupt lines", loaded.corruptLines, 0)
        audit.equal("new records write the current schema version",
                    loaded.records.first?.schemaVersion, TeamStats.currentSchemaVersion)
        if loaded.records.count == 3 {
            audit.equal("record 1 round-trips identically", loaded.records[0], r1)
            audit.equal("record 2 round-trips identically", loaded.records[1], r2)
            audit.equal("record 3 round-trips identically", loaded.records[2], r3)
        } else {
            audit.check("record 1 round-trips identically", false, "count=\(loaded.records.count)")
            audit.check("record 2 round-trips identically", false)
            audit.check("record 3 round-trips identically", false)
        }
        if let text = try? String(contentsOf: store, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            audit.check("the store is one JSON line per run, newline-terminated",
                        text.hasSuffix("\n") && lines.filter { !$0.isEmpty }.count == 3,
                        String(reflecting: text.prefix(80)))
        } else {
            audit.check("the store is one JSON line per run, newline-terminated", false)
        }

        let mixed = dir.appendingPathComponent("mixed.jsonl")
        TeamStats.append(r1, to: mixed)
        if let handle = try? FileHandle(forWritingTo: mixed) {
            _ = try? handle.seekToEnd()
            handle.write(Data("THIS IS NOT JSON\n".utf8))
            _ = try? handle.close()
        }
        TeamStats.append(r3, to: mixed)
        let recovered = TeamStats.load(from: mixed)
        audit.equal("a corrupt line in the middle is skipped and counted as 1",
                    recovered.corruptLines, 1)
        audit.equal("the surviving records still load", recovered.records, [r1, r3])

        let binary = dir.appendingPathComponent("binary.jsonl")
        try? Data([0x00, 0x01, 0xFF, 0xFE, 0x0A]).write(to: binary)
        let fromBinary = TeamStats.load(from: binary)
        audit.check("binary garbage does not crash and counts as corrupt",
                    fromBinary.records.isEmpty && fromBinary.corruptLines == 1)

        let first = TeamStats.load(from: store).records.count
        TeamStats.append(r1, to: store)
        audit.equal("append never rewrites earlier records",
                    TeamStats.load(from: store).records.count, first + 1)
    }

    // MARK: - Aggregation

    private static func aggregation(_ audit: Auditor) {
        audit.section("Team stats — aggregation fixtures")
        audit.check("zero records aggregate to an empty dictionary",
                    TeamStats.aggregate(records: []).isEmpty)

        let cancelled = fixtureItem(title: "Stopped",
                                    author: "claude", authorModel: "c-model",
                                    reviewer: "grok", reviewerModel: "g-model",
                                    state: "cancelled", rounds: 0, costUSD: 0.10, turns: 1)
        let cancelledAgg = TeamStats.aggregate(records: [fixtureRun(items: [cancelled])])
        let cancelledAuthor = TeamStats.SeatKey(provider: "claude", role: "author",
                                                model: "c-model")
        let cancelledStats = cancelledAgg[cancelledAuthor]
        audit.check("a cancelled item counts in items but as neither clean accept nor failure",
                    cancelledStats?.items == 1
                    && cancelledStats?.cleanAccepts == 0
                    && cancelledStats?.failures == 0
                    && cancelledStats?.acceptedWithObjections == 0,
                    "\(String(describing: cancelledStats))")
        audit.equal("a cancelled item with zero rounds averages 0.0, no division by zero",
                    cancelledStats?.averageRounds ?? -1, 0.0)
        audit.equal("cancelled-item cost still accrues to the author seat",
                    cancelledStats?.totalCostUSD ?? -1, 0.10)
        let cancelledReviewer = cancelledAgg[TeamStats.SeatKey(provider: "grok", role: "reviewer",
                                                               model: "g-model")]
        audit.equal("cost does not accrue to the reviewer seat",
                    cancelledReviewer?.totalCostUSD ?? -1, 0.0)
        audit.equal("turns do not accrue to the reviewer seat",
                    cancelledReviewer?.turns ?? -1, 0)

        let planned = fixtureRun(
            items: [fixtureItem(author: "claude", authorModel: "writer",
                                reviewer: "grok", reviewerModel: "r-model",
                                costUSD: 0.10)],
            planCostUSD: 0.40, planUnreported: false)
        let plannedAgg = TeamStats.aggregate(records: [planned])
        let planOrch = plannedAgg[TeamStats.SeatKey(provider: "grok", role: "orchestrator",
                                                    model: TeamStats.unrecorded)]
        audit.equal("planning dollars accrue to the orchestrator seat",
                    planOrch?.totalCostUSD ?? -1, 0.40)
        audit.equal("planning dollars are unattributable per author/reviewer role",
                    planOrch?.unattributableCostUSD ?? -1, 0.40)
        audit.equal("a planning turn does not count as a work item",
                    planOrch?.items ?? -1, 0)
        audit.equal("planning spend is not claimed as authorSpend",
                    plannedAgg[TeamStats.SeatKey(provider: "claude", role: "author",
                                                 model: "writer")]?.authorSpend ?? -1, 0.0)
        let unreportedPlan = fixtureRun(
            items: [], planCostUSD: nil, planUnreported: true)
        let unreportedAgg = TeamStats.aggregate(records: [unreportedPlan])
        let unreportedOrch = unreportedAgg[TeamStats.SeatKey(provider: "grok", role: "orchestrator",
                                                            model: TeamStats.unrecorded)]
        audit.equal("an unreported planning turn still counts as an orchestrator turn",
                    unreportedOrch?.turns ?? -1, 1)
        audit.check("an unreported planning turn does not invent $0 of spend",
                    unreportedOrch?.totalCostUSD == 0 && unreportedOrch?.unattributableCostUSD == 0)

        let unknown = fixtureItem(author: "claude", authorModel: TeamStats.unrecorded,
                                  reviewer: "grok", reviewerModel: TeamStats.unrecorded,
                                  state: "accepted", rounds: 1)
        let unknownAgg = TeamStats.aggregate(records: [fixtureRun(items: [unknown])])
        audit.check("an unrecorded model is a real seat key, not dropped",
                    unknownAgg[TeamStats.SeatKey(provider: "claude", role: "author",
                                                 model: TeamStats.unrecorded)]?.items == 1)

        let standing = TeamStats.FindingRecord(round: 2, severity: "bug", file: "a.py",
                                               line: 3, message: "off-by-one")
        let objections = fixtureItem(
            author: "claude", authorModel: "writer",
            reviewer: "codex", reviewerModel: "gpt-5.6-sol",
            state: "acceptedWithObjections", rounds: 2, roundBudget: 2,
            findings: [standing], findingsLeftStanding: true,
            gate: TeamStats.ItemGate(
                status: "fail", passed: false, hasExecuted: true, hasFailure: true,
                tasks: [TeamStats.ItemGate.Task(
                    taskID: "test", title: "swift test", passed: false, exitCode: 1,
                    timedOut: false, skippedMissingTool: false, missingTool: nil,
                    outputTail: "failed", firstErrorLine: "error", diagnostics: [])]),
            costUSD: 1.25, turns: 4)
        let objAgg = TeamStats.aggregate(records: [fixtureRun(items: [objections])])
        let objAuthor = objAgg[TeamStats.SeatKey(provider: "claude", role: "author",
                                                 model: "writer")]
        let objReviewer = objAgg[TeamStats.SeatKey(provider: "codex", role: "reviewer",
                                                   model: "gpt-5.6-sol")]
        audit.check("acceptedWithObjections is not a clean accept and not a failure",
                    objAuthor?.cleanAccepts == 0 && objAuthor?.acceptedWithObjections == 1
                    && objAuthor?.failures == 0)
        audit.equal("standing findings accrue to the author seat",
                    objAuthor?.findingsLeftStandingWhileAuthoring ?? -1, 1)

        let resumedStanding = TeamStats.FindingRecord(round: 3, severity: "bug",
                                                      file: "a.py", line: 1,
                                                      message: "still broken")
        let resumeDelta = fixtureItem(
            author: "claude", authorModel: "resume-model",
            reviewer: "grok", reviewerModel: "r-model",
            state: "acceptedWithObjections", rounds: 1,
            findings: [resumedStanding], findingsLeftStanding: true)
        let resumeAgg = TeamStats.aggregate(records: [fixtureRun(items: [resumeDelta])])
        let resumeAuthor = resumeAgg[TeamStats.SeatKey(provider: "claude", role: "author",
                                                       model: "resume-model")]
        audit.equal("standing findings on a resume delta use the absolute round, not the delta count",
                    resumeAuthor?.findingsLeftStandingWhileAuthoring ?? -1, 1)
        audit.equal("findings raised accrue to the reviewer seat",
                    objReviewer?.findingsRaisedWhileReviewing ?? -1, 1)
        audit.equal("the author is not credited with findings raised",
                    objAuthor?.findingsRaisedWhileReviewing ?? -1, 0)
        audit.equal("a failing gate counts on the author seat",
                    objAuthor?.gateFailures ?? -1, 1)
        audit.equal("a failing gate does not count on the reviewer seat",
                    objReviewer?.gateFailures ?? -1, 0)

        let failed = fixtureItem(author: "grok", authorModel: "g",
                                 reviewer: "claude", reviewerModel: "c",
                                 state: "failed", rounds: 0, stalled: true, failed: true)
        let failStats = TeamStats.aggregate(records: [fixtureRun(items: [failed])])[
            TeamStats.SeatKey(provider: "grok", role: "author", model: "g")]
        audit.equal("a failed item counts as a failure", failStats?.failures ?? -1, 1)
        audit.equal("a failed item is not a clean accept", failStats?.cleanAccepts ?? -1, 0)

        let a = fixtureItem(author: "codex", authorModel: "gpt-5.6-terra",
                            reviewer: "grok", reviewerModel: "unrecorded",
                            state: "failed", rounds: 2, costUSD: 0.20, turns: 3, failed: true)
        let b = fixtureItem(author: "codex", authorModel: "gpt-5.6-terra",
                            reviewer: "grok", reviewerModel: "unrecorded",
                            state: "failed", rounds: 3, costUSD: 0.24, turns: 2, failed: true)
        let rowAgg = TeamStats.aggregate(records: [fixtureRun(items: [a, b])])
        let terra = TeamStats.SeatKey(provider: "codex", role: "author", model: "gpt-5.6-terra")
        let terraStats = rowAgg[terra]
        audit.equal("two failed terra-author items average 2.5 rounds",
                    terraStats?.averageRounds ?? -1, 2.5)
        audit.equal("rowText matches the contracted shape",
                    TeamStats.rowText(seat: terra, stats: terraStats ?? TeamStats.SeatStats()),
                    "Codex · author · gpt-5.6-terra — 2 items, 0 clean, avg 2.5 rounds, $0.44")

        // Sort: best accept rate first; ties by items descending, then provider, role, model.
        let high = fixtureItem(author: "claude", authorModel: "hot",
                               reviewer: "grok", reviewerModel: "rev-a",
                               state: "accepted", rounds: 1)
        let high2 = fixtureItem(author: "claude", authorModel: "hot",
                                reviewer: "grok", reviewerModel: "rev-a",
                                state: "accepted", rounds: 1)
        let midMany = fixtureItem(author: "grok", authorModel: "mid",
                                  reviewer: "claude", reviewerModel: "rev-b",
                                  state: "accepted", rounds: 1)
        let midMany2 = fixtureItem(author: "grok", authorModel: "mid",
                                   reviewer: "claude", reviewerModel: "rev-b",
                                   state: "accepted", rounds: 1)
        let midManyFail = fixtureItem(author: "grok", authorModel: "mid",
                                      reviewer: "claude", reviewerModel: "rev-b",
                                      state: "failed", rounds: 1, failed: true)
        let midManyFail2 = fixtureItem(author: "grok", authorModel: "mid",
                                       reviewer: "claude", reviewerModel: "rev-b",
                                       state: "failed", rounds: 1, failed: true)
        let midFew = fixtureItem(author: "codex", authorModel: "mid",
                                 reviewer: "claude", reviewerModel: "rev-c",
                                 state: "accepted", rounds: 1)
        let midFewFail = fixtureItem(author: "codex", authorModel: "mid",
                                     reviewer: "claude", reviewerModel: "rev-c",
                                     state: "failed", rounds: 1, failed: true)
        let sorted = TeamStats.sortedSeats(TeamStats.aggregate(records: [
            fixtureRun(items: [high, high2, midMany, midMany2, midManyFail, midManyFail2,
                               midFew, midFewFail])
        ]))
        func idx(_ provider: String, _ role: String, _ model: String) -> Int {
            sorted.firstIndex { $0.0 == TeamStats.SeatKey(provider: provider, role: role,
                                                          model: model) } ?? 99
        }
        let order = sorted.map { "\($0.0.provider)/\($0.0.role)/\($0.0.model)" }.joined(separator: ",")
        audit.check("sortedSeats puts the best accept rate first",
                    idx("claude", "author", "hot") < idx("grok", "author", "mid"),
                    order)
        audit.check("tied accept rate, more items sorts first",
                    idx("grok", "author", "mid") < idx("codex", "author", "mid"),
                    order)
    }

    // MARK: - Run-end recording

    private static func recording(_ audit: Auditor) async {
        audit.section("Team stats — recording at run end")
        await Auditor.withTemporaryDirectory { dir in
            let store = dir.appendingPathComponent("team-stats.jsonl")
            let log = dir.appendingPathComponent("run.json")
            let engine = Orchestrator()
            engine.installedProviders = [.grok, .claude, .codex]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.followGate = false
            engine.teamStatsURL = store
            engine.runLogURL = log
            engine.modelOverrides[.claude] = "provider-wide-should-not-win"
            engine.roleModelOverrides[.reviewer] = [.claude: "claude-review-model"]
            engine.roleModelOverrides[.orchestrator] = [.grok: "grok-plan-model"]
            engine.roleEffortOverrides[.author] = [.codex: "low"]
            engine.roleEffortOverrides[.reviewer] = [.claude: "high"]

            let plan = #"{"items":[{"title":"One","author":"codex","brief":"Do it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan, cost: 0.001)]],
                .codex: [[ScriptedBackend.reply("Done. FILES: a.py", cost: 0.02)]],
                .claude: [[ScriptedBackend.reply("NO FINDINGS")]],
            ]
            var created: [ScriptedBackend] = []
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                if provider == .codex { backend.eventDelay = 0.15 }
                created.append(backend)
                return backend
            }
            engine.start(task: "Measure the seats.", project: dir)
            let authorConfigured = await waitUntil(5) {
                created.contains { $0.provider == .codex && $0.configuredModel == "gpt-5.6-terra" }
            }
            audit.check("the Codex author session was preconfigured as terra before the run ended",
                        authorConfigured)
            engine.roleModelOverrides[.author] = [.codex: "changed-mid-run"]
            engine.roleModelOverrides[.orchestrator] = [.grok: "changed-plan-too"]
            engine.orchestratorProvider = .claude
            let finished = await waitUntil(10) { engine.phase == .done }
            audit.check("the scripted recording run completed", finished, "\(engine.phase)")
            let loaded = await waitForRecords(store, count: 1)
            audit.equal("a finished run appends exactly one team-stats record",
                        loaded.count, 1)
            guard let record = loaded.first, let item = record.items.first else {
                audit.check("the recorded run has an item", false)
                return
            }
            audit.equal("the recorded author is Codex", item.authorProvider, "codex")
            audit.equal("a baked Codex author records gpt-5.6-terra, not unrecorded",
                        item.authorModel, "gpt-5.6-terra")
            audit.equal("a mid-run override change does not rewrite a session already preconfigured",
                        item.authorModel, "gpt-5.6-terra")
            audit.equal("the recorded author effort is the role override",
                        item.authorEffort, "low")
            audit.equal("the recorded reviewer is Claude", item.reviewerProvider, "claude")
            audit.equal("the recorded reviewer model is the role override, not the provider-wide value",
                        item.reviewerModel, "claude-review-model")
            audit.equal("the recorded reviewer effort is the role override",
                        item.reviewerEffort, "high")
            audit.equal("the recorded orchestrator provider is the planning session's, not a later selection",
                        record.orchestratorProvider, "grok")
            audit.equal("the recorded orchestrator model is the planning session's, not a later override",
                        record.orchestratorModel, "grok-plan-model")
            audit.equal("an orchestrator effort with no override is unrecorded, not empty",
                        record.orchestratorEffort, TeamStats.unrecorded)
            audit.check("a finished run records the planning turn's cost, not dropping it",
                        abs((record.planCostUSD ?? -1) - 0.001) < 0.0001,
                        "planCostUSD=\(record.planCostUSD ?? -1)")
            audit.equal("a planning turn that reported a figure is not marked unreported",
                        record.planUnreported, Optional(false))
            let orchSeat = TeamStats.aggregate(records: [record])[
                TeamStats.SeatKey(provider: "grok", role: "orchestrator",
                                  model: "grok-plan-model")]
            audit.check("planning spend lands on the orchestrator seat, not dropped",
                        abs((orchSeat?.unattributableCostUSD ?? -1) - 0.001) < 0.0001
                        && abs((orchSeat?.totalCostUSD ?? -1) - 0.001) < 0.0001
                        && orchSeat?.items == 0,
                        "unattr=\(orchSeat?.unattributableCostUSD ?? -1) total=\(orchSeat?.totalCostUSD ?? -1) items=\(orchSeat?.items ?? -1)")
            audit.equal("the recorded item state is accepted", item.state, "accepted")
            audit.check("the recorded gate is not-run when the gate was switched off",
                        item.gate.status == "not run")

            _ = await waitUntil(2) { (try? Data(contentsOf: log)) != nil }
            if let data = try? Data(contentsOf: log),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                audit.check("the orchestrate-log is still a pretty-printed JSON object",
                            json["phase"] != nil && json["items"] != nil
                            && (String(data: data, encoding: .utf8)?.hasPrefix("{") == true))
                audit.check("team stats is a separate store from the orchestrate-log",
                            store.path != log.path
                            && (try? String(contentsOf: store, encoding: .utf8))?
                                .split(separator: "\n", omittingEmptySubsequences: true).count == 1)
            } else {
                audit.check("the orchestrate-log is still a pretty-printed JSON object", false)
            }
        }

        await Auditor.withTemporaryDirectory { dir in
            let store = dir.appendingPathComponent("team-stats.jsonl")
            let engine = Orchestrator()
            engine.teamStatsURL = store
            engine.seedDemo()
            let loaded = TeamStats.load(from: store)
            audit.check("seedDemo does not append a team-stats record",
                        loaded.records.isEmpty && loaded.corruptLines == 0)
        }

        await Auditor.withTemporaryDirectory { dir in
            let store = dir.appendingPathComponent("team-stats.jsonl")
            let engine = Orchestrator()
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 60
            engine.followGate = false
            engine.teamStatsURL = store
            let plan = #"{"items":[{"title":"Hang","author":"claude","brief":"Never ends."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)]],
                .claude: [[]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Loop forever.", project: dir)
            let authoring = await waitUntil(5) { engine.items.first?.state == .authoring }
            audit.check("the cancelled-run fixture reached authoring", authoring)
            engine.stop()
            audit.equal("the cancelled run's phase is cancelled", engine.phase, .cancelled)
            let loaded = await waitForRecords(store, count: 1)
            audit.equal("a cancelled run appends exactly one team-stats record",
                        loaded.count, 1)
            audit.equal("the cancelled record's item is cancelled, not failed",
                        loaded.first?.items.first?.state, "cancelled")
        }

        await Auditor.withTemporaryDirectory { dir in
            let store = dir.appendingPathComponent("team-stats.jsonl")
            let engine = Orchestrator()
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.followGate = false
            engine.teamStatsURL = store
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply("I would suggest starting with…")]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Please fail to parse.", project: dir)
            let failed = await waitUntil(10) {
                if case .failed = engine.phase { return true }
                return false
            }
            audit.check("the failed-plan fixture ended as a failed run", failed, "\(engine.phase)")
            let loaded = await waitForRecords(store, count: 1)
            audit.equal("a failed plan parse appends exactly one team-stats record",
                        loaded.count, 1)
            audit.equal("a failed plan parse records no invented work items",
                        loaded.first?.items.count, 0)
            audit.check("a failed plan with no reported cost records planCostUSD as nil, not 0",
                        loaded.first?.planCostUSD == nil)
            audit.equal("a failed plan with no reported cost records the planning turn as unreported",
                        loaded.first?.planUnreported, Optional(true))
        }

        await Auditor.withTemporaryDirectory { dir in
            let store = dir.appendingPathComponent("team-stats.jsonl")
            let engine = Orchestrator()
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.maxRounds = 1
            engine.turnTimeout = 5
            engine.followGate = false
            engine.teamStatsURL = store
            let plan = #"{"items":[{"title":"Hard","author":"claude","brief":"Try.","rounds":1}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [
                    [ScriptedBackend.reply(plan)],
                    [ScriptedBackend.reply("FINDING: a.py:1: bug: still broken")],
                    [ScriptedBackend.reply("RECOMMEND: 1 more rounds: still broken")],
                    [ScriptedBackend.reply("RESOLVED: F1")],
                ],
                .claude: [
                    [ScriptedBackend.reply("Wrote it. FILES: a.py", cost: 0.01)],
                    [ScriptedBackend.reply("Revised. FILES: a.py", cost: 0.02)],
                ],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Budget of one.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            audit.equal("the resume fixture's first run wrote one record",
                        (await waitForRecords(store, count: 1)).count, 1)
            guard let item = engine.items.first, item.state == .acceptedWithObjections else {
                audit.check("the resume fixture finished with objections", false,
                            "state=\(String(describing: engine.items.first?.state))")
                return
            }
            let first = (await waitForRecords(store, count: 1)).first
            let originalCost = first?.items.first?.costUSD ?? -1
            engine.roleModelOverrides[.author] = [.claude: "resume-model"]
            engine.resume(item, extraRounds: 1, project: dir)
            let resumed = await waitUntil(10) { engine.phase == .done && item.state == .accepted }
            audit.check("resume finished accepted", resumed,
                        "phase=\(engine.phase) state=\(item.state)")
            let both = await waitForRecords(store, count: 2)
            audit.equal("a resume that finishes via finishResume appends a second record",
                        both.count, 2)
            let original = both.first?.items.first
            let delta = both.dropFirst().first?.items.first
            audit.check("the resume record's cost is the increment, not the cumulative total",
                        abs((delta?.costUSD ?? -1) - 0.02) < 0.0001
                        && abs(originalCost - 0.01) < 0.0001,
                        "original=\(originalCost) delta=\(delta?.costUSD ?? -1) cumulative=\(item.costUSD)")
            audit.check("the resume record does not repeat the original run's findings",
                        delta?.findings.isEmpty == true
                        && (original?.findings.isEmpty == false),
                        "original=\(original?.findings.count ?? -1) delta=\(delta?.findings.count ?? -1)")
            audit.equal("resume-session spend is attributed to the resume model, not the original",
                        delta?.authorModel, "resume-model")
            audit.check("the original record keeps its pre-resume author model",
                        original?.authorModel != "resume-model",
                        original?.authorModel ?? "nil")
            let agg = TeamStats.aggregate(records: both)
            let claudeUnrecorded = agg[TeamStats.SeatKey(provider: "claude", role: "author",
                                                         model: TeamStats.unrecorded)]
            let claudeResume = agg[TeamStats.SeatKey(provider: "claude", role: "author",
                                                     model: "resume-model")]
            audit.check("aggregation does not double-count original spend onto the resume model",
                        abs((claudeUnrecorded?.totalCostUSD ?? -1) - 0.01) < 0.0001
                        && abs((claudeResume?.totalCostUSD ?? -1) - 0.02) < 0.0001,
                        "unrecorded=\(claudeUnrecorded?.totalCostUSD ?? -1) resume=\(claudeResume?.totalCostUSD ?? -1)")
            audit.check("a resume record does not inherit the original run's planning cost",
                        both.dropFirst().first?.planCostUSD == nil)
            audit.equal("a resume record does not claim a planning turn",
                        both.dropFirst().first?.planUnreported, Optional(false))
        }
    }

    // MARK: - --import-run-log

    private static func importFlag(_ audit: Auditor) async {
        audit.section("Team stats — --import-run-log via openLaunchArguments")
        await Auditor.withTemporaryDirectory { dir in
            let log = dir.appendingPathComponent("run.json")
            let engine = Orchestrator()
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.turnTimeout = 5
            engine.followGate = false
            engine.teamStatsURL = nil
            engine.runLogURL = log
            let plan = #"{"items":[{"title":"Imported","author":"claude","brief":"Do it."}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [[ScriptedBackend.reply(plan)],
                        [ScriptedBackend.reply("NO FINDINGS")]],
                .claude: [[ScriptedBackend.reply("Done. FILES: a.py", cost: 0.11)]],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Write a log to import.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            let logged = await waitUntil(2) { FileManager.default.fileExists(atPath: log.path) }
            audit.check("the import fixture wrote an orchestrate-log", logged)
            guard logged else { return }

            let store = dir.appendingPathComponent("imported.jsonl")
            let previous = TeamStats.storeURL
            TeamStats.storeURL = store
            defer { TeamStats.storeURL = previous }

            let model = AppModel(trust: .forAudit)
            defer { model.shutdown() }
            let first = captureStdout {
                model.openLaunchArguments(["Orrery", "--import-run-log", log.path])
            }
            let loaded = TeamStats.load(from: store)
            audit.check("openLaunchArguments dispatches --import-run-log and prints a summary",
                        first.contains("imported") && first.contains("1 item"),
                        String(reflecting: first))
            audit.equal("the happy-path import appends exactly one record",
                        loaded.records.count, 1)
            let imported = loaded.records.first
            audit.equal("an imported log records author model as unrecorded, never inferred",
                        imported?.items.first?.authorModel, TeamStats.unrecorded)
            audit.equal("an imported log records reviewer model as unrecorded",
                        imported?.items.first?.reviewerModel, TeamStats.unrecorded)
            audit.equal("an imported log records orchestrator model as unrecorded",
                        imported?.orchestratorModel, TeamStats.unrecorded)
            audit.equal("an imported log records effort as unrecorded",
                        imported?.items.first?.authorEffort, TeamStats.unrecorded)
            audit.check("an imported log with a null planCostUSD does not invent $0",
                        imported?.planCostUSD == nil)
            audit.equal("an imported log with a plan reply and no figure records the planning turn unreported",
                        imported?.planUnreported, Optional(true))
            let paidPlan = dir.appendingPathComponent("paid-plan.json")
            try? """
            {"phase":"done","totalCostUSD":0.25,"totalTurns":1,"unreportedTurns":0,\
            "planCostUSD":0.25,"planRaw":"x",\
            "items":[{"title":"t","author":"claude","reviewer":"grok","state":"accepted",\
            "round":1,"costUSD":0,"turns":0,"unreportedTurns":0,\
            "findings":[],"lane":[],"filesTouched":[]}]}
            """.write(to: paidPlan, atomically: true, encoding: .utf8)
            if let data = try? Data(contentsOf: paidPlan),
               let paid = TeamStats.outcome(fromRunLog: data, fingerprint: "paid") {
                audit.equal("import copies a reported planning cost",
                            paid.planCostUSD, Optional(0.25))
                audit.equal("a reported planning cost is not marked unreported on import",
                            paid.planUnreported, Optional(false))
            } else {
                audit.check("import copies a reported planning cost", false)
                audit.check("a reported planning cost is not marked unreported on import", false)
            }
            audit.equal("an imported log records roundBudget as unrecorded, not an invented 0",
                        imported?.items.first?.roundBudget, TeamStats.unrecorded)
            audit.check("the imported record carries the log file's SHA-256 fingerprint",
                        imported?.importFingerprint?.count == 64,
                        imported?.importFingerprint ?? "nil")
            audit.equal("the imported item title comes from the log",
                        imported?.items.first?.title, "Imported")

            let second = captureStdout {
                model.openLaunchArguments(["Orrery", "--import-run-log", log.path])
            }
            audit.check("importing the same file twice prints an already-imported summary",
                        second.contains("already imported"),
                        String(reflecting: second))
            audit.equal("a second import of the same file does not duplicate the record",
                        TeamStats.load(from: store).records.count, 1)

            let missing = captureStdout {
                model.openLaunchArguments(["Orrery", "--import-run-log",
                                          dir.appendingPathComponent("nope.json").path])
            }
            audit.check("a missing log prints an honest file-not-found summary",
                        missing.contains("file not found"),
                        String(reflecting: missing))
            audit.equal("a missing log does not append a record",
                        TeamStats.load(from: store).records.count, 1)

            let phaseOnly = dir.appendingPathComponent("phase-only.json")
            try? #"{"phase":"done","hello":true}"#.write(to: phaseOnly, atomically: true, encoding: .utf8)
            let phaseOnlyLine = captureStdout {
                model.openLaunchArguments(["Orrery", "--import-run-log", phaseOnly.path])
            }
            audit.check("a JSON object with phase but no items array is not imported as a run",
                        phaseOnlyLine.contains("not an orchestrate-log"),
                        String(reflecting: phaseOnlyLine))

            let itemsOnly = dir.appendingPathComponent("items-only.json")
            try? #"{"items":[{"title":"t","author":"claude","reviewer":"grok","state":"accepted"}]}"#
                .write(to: itemsOnly, atomically: true, encoding: .utf8)
            let itemsOnlyLine = captureStdout {
                model.openLaunchArguments(["Orrery", "--import-run-log", itemsOnly.path])
            }
            audit.check("a JSON object with items but no phase is not imported as a run",
                        itemsOnlyLine.contains("not an orchestrate-log"),
                        String(reflecting: itemsOnlyLine))

            let thin = dir.appendingPathComponent("thin.json")
            try? """
            {"phase":"done","totalCostUSD":0,"totalTurns":1,"unreportedTurns":0,\
            "planCostUSD":null,"planRaw":"x",\
            "items":[{"title":"t","author":"claude","reviewer":"grok","state":"accepted"}]}
            """.write(to: thin, atomically: true, encoding: .utf8)
            let thinLine = captureStdout {
                model.openLaunchArguments(["Orrery", "--import-run-log", thin.path])
            }
            audit.check("a phase plus a minimally named item is not an orchestrate-log",
                        thinLine.contains("not an orchestrate-log"),
                        String(reflecting: thinLine))
            audit.equal("malformed JSON objects do not append a record",
                        TeamStats.load(from: store).records.count, 1)

            malformedElementShapes(audit, dir: dir, store: store, model: model)
        }
    }

    /// A3: findings/lane must be arrays of objects; filesTouched must be strings.
    /// Empty arrays stay valid. Each malformed shape is rejected as not-an-orchestrate-log.
    private static func malformedElementShapes(_ audit: Auditor, dir: URL, store: URL,
                                               model: AppModel) {
        audit.section("Team stats — A3 orchestrate-log element shapes")
        func writeLog(_ name: String, editItem: ((inout [String: Any]) -> Void)? = nil) -> URL {
            var item: [String: Any] = [
                "title": "t",
                "author": "claude",
                "reviewer": "grok",
                "state": "accepted",
                "round": 1,
                "costUSD": 0,
                "turns": 1,
                "unreportedTurns": 0,
                "findings": [] as [Any],
                "lane": [] as [Any],
                "filesTouched": [] as [Any],
            ]
            editItem?(&item)
            let object: [String: Any] = [
                "phase": "done",
                "planRaw": "x",
                "planCostUSD": NSNull(),
                "totalCostUSD": 0,
                "totalTurns": 1,
                "unreportedTurns": 0,
                "items": [item],
            ]
            let url = dir.appendingPathComponent(name)
            if let data = try? JSONSerialization.data(withJSONObject: object) {
                try? data.write(to: url)
            }
            return url
        }

        let empty = writeLog("empty-arrays.json")
        let emptyLine = captureStdout {
            model.openLaunchArguments(["Orrery", "--import-run-log", empty.path])
        }
        audit.check("empty findings/lane/filesTouched arrays are a valid orchestrate-log",
                    emptyLine.contains("imported") && emptyLine.contains("1 item"),
                    String(reflecting: emptyLine))
        let afterEmpty = TeamStats.load(from: store).records.count

        let findingsStrings = writeLog("findings-strings.json") { item in
            item["findings"] = ["not", "objects"]
        }
        let findingsLine = captureStdout {
            model.openLaunchArguments(["Orrery", "--import-run-log", findingsStrings.path])
        }
        audit.check("findings as an array of strings is not an orchestrate-log",
                    findingsLine.contains("not an orchestrate-log"),
                    String(reflecting: findingsLine))
        audit.check("findings-as-strings does not decode as invented cleanliness",
                    TeamStats.orchestrateLogItems(
                        in: (try? Data(contentsOf: findingsStrings)) ?? Data()) == nil)

        let laneNumbers = writeLog("lane-numbers.json") { item in
            item["lane"] = [1, 2, 3]
        }
        let laneLine = captureStdout {
            model.openLaunchArguments(["Orrery", "--import-run-log", laneNumbers.path])
        }
        audit.check("lane as an array of numbers is not an orchestrate-log",
                    laneLine.contains("not an orchestrate-log"),
                    String(reflecting: laneLine))
        audit.check("lane-as-numbers does not decode as invented cleanliness",
                    TeamStats.orchestrateLogItems(
                        in: (try? Data(contentsOf: laneNumbers)) ?? Data()) == nil)

        let filesNumbers = writeLog("files-numbers.json") { item in
            item["filesTouched"] = [1, 2]
        }
        let filesLine = captureStdout {
            model.openLaunchArguments(["Orrery", "--import-run-log", filesNumbers.path])
        }
        audit.check("filesTouched as an array of numbers is not an orchestrate-log",
                    filesLine.contains("not an orchestrate-log"),
                    String(reflecting: filesLine))
        audit.check("filesTouched-as-numbers does not decode as invented cleanliness",
                    TeamStats.orchestrateLogItems(
                        in: (try? Data(contentsOf: filesNumbers)) ?? Data()) == nil)

        audit.equal("malformed element shapes do not append a record",
                    TeamStats.load(from: store).records.count, afterEmpty)
    }

    // MARK: - Part A engine fixes

    private static func engineFixes(_ audit: Auditor) async {
        await resumeStanding(audit)
        await recommendationStamp(audit)
        await planThenRecommend(audit)
        await revisionWallClock(audit)
    }

    /// A1: resume that never starts a new review still carries the objections
    /// that caused it. The old `item.round > resume.round` clause recorded a
    /// false clean.
    private static func resumeStanding(_ audit: Auditor) async {
        audit.section("Team stats — A1 resume-baseline standing findings")
        await Auditor.withTemporaryDirectory { dir in
            let store = dir.appendingPathComponent("team-stats.jsonl")
            let engine = Orchestrator()
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.maxRounds = 1
            engine.turnTimeout = 5
            engine.followGate = false
            engine.teamStatsURL = store
            let plan = #"{"items":[{"title":"Hard","author":"claude","brief":"Try.","rounds":1}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [
                    [ScriptedBackend.reply(plan)],
                    [ScriptedBackend.reply("FINDING: a.py:1: bug: still broken")],
                    [ScriptedBackend.reply("RECOMMEND: 1 more rounds: still broken")],
                ],
                .claude: [
                    [ScriptedBackend.reply("Wrote it. FILES: a.py", cost: 0.01)],
                    [[BackendEvent.disconnected(reason: "author crashed")]],
                ],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Budget of one.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            guard let item = engine.items.first, item.state == .acceptedWithObjections else {
                audit.check("A1 fixture finished the first run with objections", false,
                            "state=\(String(describing: engine.items.first?.state))")
                return
            }
            let firstRound = item.round
            audit.check("A1 first run left findings open at the resume baseline",
                        !item.openFindings.isEmpty && firstRound == 1,
                        "open=\(item.openFindings.count) round=\(item.round)")
            engine.resume(item, extraRounds: 1, project: dir)
            let finished = await waitUntil(10) {
                switch engine.phase {
                case .done, .failed: return true
                default: return false
                }
            }
            audit.check("A1 resume finished after the author session died",
                        finished && item.state == .failed,
                        "phase=\(engine.phase) state=\(item.state) round=\(item.round)")
            let both = await waitForRecords(store, count: 2)
            audit.equal("A1 resume appends a second record", both.count, 2)
            let delta = both.dropFirst().first?.items.first
            audit.equal("A1 resume did not advance the review round",
                        item.round, firstRound)
            audit.check("A1 resume still has the objections that caused it",
                        !item.openFindings.isEmpty,
                        "open=\(item.openFindings.count)")
            audit.equal("a resume that still carries its baseline objections records them standing",
                        delta?.findingsLeftStanding, true)
        }
    }

    /// A2: a resume whose only orchestrator turn is the recommendation stamps
    /// the run-level orchestrator values.
    private static func recommendationStamp(_ audit: Auditor) async {
        audit.section("Team stats — A2 recommendation-only orchestrator stamp")
        await Auditor.withTemporaryDirectory { dir in
            let store = dir.appendingPathComponent("team-stats.jsonl")
            let engine = Orchestrator()
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.maxRounds = 1
            engine.turnTimeout = 5
            engine.followGate = false
            engine.teamStatsURL = store
            let plan = #"{"items":[{"title":"Hard","author":"claude","brief":"Try.","rounds":1}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [
                    [ScriptedBackend.reply(plan)],
                    [ScriptedBackend.reply("FINDING: a.py:1: bug: still broken")],
                    [ScriptedBackend.reply("RECOMMEND: 1 more rounds: still broken")],
                    [ScriptedBackend.reply("FINDING: a.py:1: bug: still broken")],
                    [ScriptedBackend.reply("RECOMMEND: accept: ship it")],
                ],
                .claude: [
                    [ScriptedBackend.reply("Wrote it. FILES: a.py", cost: 0.01)],
                    [ScriptedBackend.reply("Revised. FILES: a.py", cost: 0.02)],
                ],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                return ScriptedBackend(provider: provider, scripts: scripts)
            }
            engine.start(task: "Budget of one.", project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            guard let item = engine.items.first, item.state == .acceptedWithObjections else {
                audit.check("A2 recommendation-only fixture finished with objections", false,
                            "state=\(String(describing: engine.items.first?.state))")
                return
            }
            engine.roleModelOverrides[.orchestrator] = [.grok: "resume-orch-model"]
            engine.roleEffortOverrides[.orchestrator] = [.grok: "low"]
            engine.resume(item, extraRounds: 1, project: dir)
            _ = await waitUntil(10) { engine.phase == .done }
            let both = await waitForRecords(store, count: 2)
            let delta = both.dropFirst().first
            audit.equal("a recommendation-only resume records the orchestrator provider",
                        delta?.orchestratorProvider, "grok")
            audit.equal("a recommendation-only resume records the recommendation session's model",
                        delta?.orchestratorModel, "resume-orch-model")
            audit.equal("a recommendation-only resume records the recommendation session's effort",
                        delta?.orchestratorEffort, "low")
            let deltaItem = both.dropFirst().first?.items.first
            audit.check("resume findings keep the absolute round number, not the delta",
                        deltaItem?.rounds == 1
                        && deltaItem?.findings.contains { $0.round > 1 } == true,
                        "rounds=\(deltaItem?.rounds ?? -1) findingRounds=\(deltaItem?.findings.map(\.round) ?? [])")
            let deltaAgg = TeamStats.aggregate(records: Array(both.dropFirst()))
            let deltaAuthor = deltaAgg[TeamStats.SeatKey(provider: "claude", role: "author",
                                                         model: TeamStats.unrecorded)]
            audit.equal("standing findings from a resumed round accrue to the author seat",
                        deltaAuthor?.findingsLeftStandingWhileAuthoring ?? -1, 1)
        }
    }

    /// A later round's wall-clock must include the author revision that belongs
    /// to it. Timestamping the lane row only when the turn finishes starts the
    /// span after that revision has already ended.
    private static func revisionWallClock(_ audit: Auditor) async {
        audit.section("Team stats — revision turn is inside the next round's wall-clock")
        await Auditor.withTemporaryDirectory { dir in
            let store = dir.appendingPathComponent("team-stats.jsonl")
            let engine = Orchestrator()
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.maxRounds = 2
            engine.turnTimeout = 5
            engine.followGate = false
            engine.teamStatsURL = store
            let plan = #"{"items":[{"title":"Timed","author":"claude","brief":"Try.","rounds":2}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [
                    [ScriptedBackend.reply(plan)],
                    [ScriptedBackend.reply("FINDING: a.py:1: bug: still broken"),
                     ScriptedBackend.reply("NO FINDINGS")],
                ],
                .claude: [
                    [ScriptedBackend.reply("Wrote it. FILES: a.py", cost: 0.01),
                     ScriptedBackend.reply("Revised. FILES: a.py", cost: 0.02)],
                ],
            ]
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                if provider == .claude { backend.eventDelay = 0.25 }
                return backend
            }
            engine.start(task: "Time the revision.", project: dir)
            let finished = await waitUntil(10) { engine.phase == .done }
            audit.check("the revision wall-clock fixture completed", finished, "\(engine.phase)")
            let loaded = await waitForRecords(store, count: 1)
            let round2 = loaded.first?.items.first?.roundRecords.first { $0.index == 2 }
            audit.check("round 2 wall-clock includes the delayed author revision",
                        (round2?.wallClockSeconds ?? 0) >= 0.2,
                        "wall=\(round2?.wallClockSeconds ?? -1) records=\(loaded.first?.items.first?.roundRecords.map { "r\($0.index)=\($0.wallClockSeconds ?? -1)" } ?? [])")
        }
    }

    /// A2: planning stamp wins over a later recommendation turn.
    private static func planThenRecommend(_ audit: Auditor) async {
        audit.section("Team stats — A2 plan stamp wins over recommendation")
        await Auditor.withTemporaryDirectory { dir in
            let store = dir.appendingPathComponent("team-stats.jsonl")
            let engine = Orchestrator()
            engine.installedProviders = [.grok, .claude]
            engine.orchestratorProvider = .grok
            engine.maxRounds = 1
            engine.turnTimeout = 5
            engine.followGate = false
            engine.teamStatsURL = store
            engine.roleModelOverrides[.orchestrator] = [.grok: "plan-orch-model"]
            engine.roleEffortOverrides[.orchestrator] = [.grok: "high"]
            let plan = #"{"items":[{"title":"Hard","author":"claude","brief":"Try.","rounds":1}]}"#
            var queues: [Provider: [[[BackendEvent]]]] = [
                .grok: [
                    [ScriptedBackend.reply(plan)],
                    [ScriptedBackend.reply("FINDING: a.py:1: bug: still broken")],
                    [ScriptedBackend.reply("RECOMMEND: 1 more rounds: still broken")],
                ],
                .claude: [
                    [ScriptedBackend.reply("Wrote it. FILES: a.py", cost: 0.01)],
                ],
            ]
            var created: [ScriptedBackend] = []
            engine.makeBackend = { provider in
                let scripts = queues[provider]?.isEmpty == false
                    ? queues[provider]!.removeFirst() : []
                let backend = ScriptedBackend(provider: provider, scripts: scripts)
                created.append(backend)
                return backend
            }
            engine.start(task: "Plan then recommend.", project: dir)
            let authorConfigured = await waitUntil(5) {
                created.contains { $0.provider == .claude && $0.configuredBeforeStart }
            }
            audit.check("A2 plan-then-recommend reached the author session", authorConfigured)
            engine.roleModelOverrides[.orchestrator] = [.grok: "recommend-orch-model"]
            engine.roleEffortOverrides[.orchestrator] = [.grok: "low"]
            _ = await waitUntil(10) { engine.phase == .done }
            let loaded = await waitForRecords(store, count: 1)
            let record = loaded.first
            audit.equal("plan-then-recommend keeps the planning provider",
                        record?.orchestratorProvider, "grok")
            audit.equal("plan-then-recommend keeps the planning model, not the recommendation override",
                        record?.orchestratorModel, "plan-orch-model")
            audit.equal("plan-then-recommend keeps the planning effort, not the recommendation override",
                        record?.orchestratorEffort, "high")
        }
    }

    // MARK: - Schema v2

    private static func schemaV2(_ audit: Auditor) {
        mixedStore(audit)
        roundDeltas(audit)
        costSplit(audit)
        realStoreCopy(audit)
    }

    private static func mixedStore(_ audit: Auditor) {
        audit.section("Team stats — mixed v1 and v2 store")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-teamstats-v2-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("mixed.jsonl")
        let v1 = """
        {"date":1700000000,"items":[{"authorEffort":"high","authorModel":"a-model","authorProvider":"claude","costUSD":1.5,"failed":false,"findings":[{"file":"a.py","line":3,"message":"off-by-one","round":1,"severity":"bug"}],"findingsLeftStanding":true,"gate":{"hasExecuted":false,"hasFailure":false,"passed":false,"status":"not run","tasks":[]},"reviewerEffort":"unrecorded","reviewerModel":"r-model","reviewerProvider":"grok","roundBudget":"2","rounds":3,"stalled":false,"state":"acceptedWithObjections","title":"Old","turns":4,"unreportedTurns":1}],"orchestratorEffort":"unrecorded","orchestratorModel":"unrecorded","orchestratorProvider":"grok"}
        """
        try? (v1 + "\n").write(to: store, atomically: true, encoding: .utf8)
        let v2 = fixtureRun(items: [fixtureItem(title: "New", rounds: 1, costUSD: 0.25)],
                            date: Date(timeIntervalSince1970: 1_700_000_100))
        TeamStats.append(v2, to: store)
        let loaded = TeamStats.load(from: store)
        audit.equal("a mixed v1+v2 store loads both records", loaded.records.count, 2)
        audit.equal("a mixed v1+v2 store reports zero corrupt lines", loaded.corruptLines, 0)
        let old = loaded.records.first
        let fresh = loaded.records.dropFirst().first
        audit.equal("a v1 line with no schemaVersion decodes as version 1",
                    old?.schemaVersion, 1)
        audit.equal("a newly appended record is the current schema version",
                    fresh?.schemaVersion, TeamStats.currentSchemaVersion)
        audit.equal("v1 roundRecords is empty, not an invented round list",
                    old?.items.first?.roundRecords.isEmpty, true)
        audit.check("v1 roleSpend is nil (unrecorded), not a guessed $0 split",
                    old?.items.first?.roleSpend == nil)
        audit.equal("v1 still loads its rounds count", old?.items.first?.rounds, 3)
        audit.equal("v1 still loads its findings", old?.items.first?.findings.count, 1)
        audit.check("v1 planning cost is unrecorded, not a guessed $0",
                    old?.planCostUSD == nil)
        audit.check("v1 planning unreported is unrecorded, not false",
                    old?.planUnreported == nil)
        let v1Agg = TeamStats.aggregate(records: old.map { [$0] } ?? [])
        let v1Author = v1Agg[TeamStats.SeatKey(provider: "claude", role: "author",
                                               model: "a-model")]
        audit.equal("v1 item-level cost is unattributable, not claimed as authorSpend",
                    v1Author?.authorSpend ?? -1, 0.0)
        audit.equal("v1 item-level cost lands in unattributableCostUSD",
                    v1Author?.unattributableCostUSD ?? -1, 1.5)
        audit.equal("v1 totalCostUSD still accrues to the author seat",
                    v1Author?.totalCostUSD ?? -1, 1.5)
        audit.equal("v1 reviewSpend is not guessed from the item total",
                    v1Agg[TeamStats.SeatKey(provider: "grok", role: "reviewer",
                                            model: "r-model")]?.reviewSpend ?? -1, 0.0)
    }

    private static func roundDeltas(_ audit: Auditor) {
        audit.section("Team stats — round-record deltas from a three-round fixture")
        let fixture = threeRoundFixture()
        audit.equal("the three-round fixture emits three round records",
                    fixture.records.count, 3)

        let r1 = fixture.records[0]
        audit.equal("round 1 index", r1.index, 1)
        audit.equal("round 1 findings raised", r1.findingsRaised, 3)
        audit.equal("round 1 severity bug", r1.severities["bug"] ?? -1, 1)
        audit.equal("round 1 severity style", r1.severities["style"] ?? -1, 1)
        audit.equal("round 1 severity gate", r1.severities["gate"] ?? -1, 1)
        audit.equal("round 1 previous resolved", r1.previousResolved, 0)
        audit.equal("round 1 previous still standing = all raised (nothing was resolvable)",
                    r1.previousStillStanding, 3)
        audit.equal("round 1 has no author revision", r1.authorRevisionPresent, false)
        audit.equal("round 1 stall count", r1.stallEvents, 1)
        audit.equal("round 1 wall-clock seconds", r1.wallClockSeconds, 11.0)

        let r2 = fixture.records[1]
        audit.equal("round 2 index", r2.index, 2)
        audit.equal("round 2 findings raised", r2.findingsRaised, 2)
        audit.equal("round 2 severity bug", r2.severities["bug"] ?? -1, 2)
        audit.equal("round 2 previous resolved (style + gate)", r2.previousResolved, 2)
        audit.equal("round 2 previous still standing (off-by-one)", r2.previousStillStanding, 1)
        audit.equal("round 2 has an author revision", r2.authorRevisionPresent, true)
        audit.equal("round 2 stall count", r2.stallEvents, 0)
        audit.equal("round 2 wall-clock seconds", r2.wallClockSeconds, 10.0)
        audit.equal("round 2 unreported grok turns",
                    r2.unreportedTurnsByProvider["grok"] ?? -1, 1)

        let r3 = fixture.records[2]
        audit.equal("round 3 index", r3.index, 3)
        audit.equal("round 3 findings raised", r3.findingsRaised, 2)
        audit.equal("round 3 severity warning", r3.severities["warning"] ?? -1, 1)
        audit.equal("round 3 severity bug", r3.severities["bug"] ?? -1, 1)
        audit.equal("round 3 previous resolved (off-by-one)", r3.previousResolved, 1)
        audit.equal("round 3 previous still standing (new hole, severity ignored)",
                    r3.previousStillStanding, 1)
        audit.equal("round 3 has an author revision", r3.authorRevisionPresent, true)
        audit.equal("round 3 stall count", r3.stallEvents, 0)
        audit.equal("round 3 wall-clock seconds", r3.wallClockSeconds, 21.0)
    }

    private static func costSplit(_ audit: Auditor) {
        audit.section("Team stats — per-round per-provider and per-seat cost split")
        let fixture = threeRoundFixture()
        let r1 = fixture.records[0]
        let r2 = fixture.records[1]
        let r3 = fixture.records[2]
        audit.equal("round 1 claude dollars", r1.costByProvider["claude"] ?? -1, 1.0)
        audit.equal("round 1 grok dollars", r1.costByProvider["grok"] ?? -1, 0.5)
        audit.equal("round 2 claude dollars", r2.costByProvider["claude"] ?? -1, 0.25)
        audit.check("round 2 grok has no reported dollars",
                    r2.costByProvider["grok"] == nil)
        audit.equal("round 3 claude dollars", r3.costByProvider["claude"] ?? -1, 0.125)
        audit.equal("round 3 grok dollars", r3.costByProvider["grok"] ?? -1, 0.09375)

        let item = fixtureItem(
            author: "claude", authorModel: "writer",
            reviewer: "grok", reviewerModel: "g-model",
            state: "acceptedWithObjections", rounds: 3,
            findings: fixture.findings, findingsLeftStanding: true,
            costUSD: 1.96875, turns: 6,
            roundRecords: fixture.records,
            roleSpend: fixture.spend)
        let agg = TeamStats.aggregate(records: [fixtureRun(items: [item])])
        let author = agg[TeamStats.SeatKey(provider: "claude", role: "author",
                                           model: "writer")]
        let reviewer = agg[TeamStats.SeatKey(provider: "grok", role: "reviewer",
                                             model: "g-model")]
        audit.equal("authorSpend is the author-role lane total",
                    author?.authorSpend ?? -1, 1.375)
        audit.equal("reviewSpend is the reviewer-role lane total",
                    reviewer?.reviewSpend ?? -1, 0.5625)
        audit.equal("orchestrator lane dollars are unattributable, not dropped",
                    author?.unattributableCostUSD ?? -1, 0.03125)
        audit.equal("reviewSpend does not land on the author seat",
                    author?.reviewSpend ?? -1, 0.0)
        audit.equal("authorSpend does not land on the reviewer seat",
                    reviewer?.authorSpend ?? -1, 0.0)
        audit.equal("totalCostUSD keeps the item-level total on the author seat",
                    author?.totalCostUSD ?? -1, 1.96875)
        audit.equal("totalCostUSD still does not accrue to the reviewer seat",
                    reviewer?.totalCostUSD ?? -1, 0.0)
    }

    /// Hand-built three-round lane + findings. Dollars are dyadic so equality is exact:
    /// wrote 1.0 + rev1 0.5 + revAfter1 0.25 + rev2 unreported + revAfter2 0.125
    /// + rev3 0.0625 + recommend 0.03125 = 1.96875.
    private static func threeRoundFixture()
        -> (records: [TeamStats.RoundRecord], findings: [TeamStats.FindingRecord],
            spend: TeamStats.RoleSpend) {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }
        let findings = [
            TeamStats.FindingRecord(round: 1, severity: "bug", file: "a.py",
                                    line: 10, message: "off-by-one"),
            TeamStats.FindingRecord(round: 1, severity: "style", file: "a.py",
                                    line: 20, message: "rename"),
            TeamStats.FindingRecord(round: 1, severity: "gate", file: "build",
                                    line: nil, message: "GATE: tests exited 1"),
            TeamStats.FindingRecord(round: 2, severity: "bug", file: "a.py",
                                    line: 10, message: "off-by-one"),
            TeamStats.FindingRecord(round: 2, severity: "bug", file: "b.py",
                                    line: 1, message: "new hole"),
            TeamStats.FindingRecord(round: 3, severity: "warning", file: "b.py",
                                    line: 1, message: "new hole"),
            TeamStats.FindingRecord(round: 3, severity: "bug", file: "c.py",
                                    line: 4, message: "another"),
        ]
        let lane = [
            TeamStats.LaneFact(provider: "grok", role: "orchestrator", title: "Brief",
                               text: "Do it.", costUSD: nil, at: at(0)),
            TeamStats.LaneFact(provider: "claude", role: "author", title: "Wrote it",
                               text: "Done.", costUSD: 1.0, at: at(1)),
            TeamStats.LaneFact(provider: "grok", role: "reviewer", title: "Review round 1",
                               text: "FINDING\n[stalled — no activity for 5s]",
                               costUSD: 0.5, at: at(11)),
            TeamStats.LaneFact(provider: "claude", role: "author",
                               title: "Revision after round 1",
                               text: "Revised.", costUSD: 0.25, editedFileCount: 1, at: at(21)),
            TeamStats.LaneFact(provider: "grok", role: "reviewer", title: "Review round 2",
                               text: "FINDING", costUSD: nil, at: at(31)),
            TeamStats.LaneFact(provider: "claude", role: "author",
                               title: "Revision after round 2",
                               text: "Revised again.", costUSD: 0.125, editedFileCount: 1, at: at(41)),
            TeamStats.LaneFact(provider: "grok", role: "reviewer", title: "Review round 3",
                               text: "FINDING", costUSD: 0.0625, at: at(51)),
            TeamStats.LaneFact(provider: "grok", role: "orchestrator",
                               title: "Round-budget recommendation",
                               text: "RECOMMEND: accept: nits", costUSD: 0.03125, at: at(61)),
            TeamStats.LaneFact(provider: "grok", role: "system", title: "Acceptance gate",
                               text: "swift test exited 1", costUSD: nil, at: at(62)),
        ]
        let records = TeamStats.roundRecords(findings: findings, lane: lane,
                                             fromRound: 1, throughRound: 3)
        return (records, findings, TeamStats.roleSpend(from: lane))
    }

    private static func realStoreCopy(_ audit: Auditor) {
        audit.section("Team stats — real 7-record store still loads")
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Orrery/team-stats.jsonl")
        guard FileManager.default.fileExists(atPath: real.path) else {
            audit.skip("the real team-stats store exists", "no Team run on this machine yet"); return
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-realstore-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("team-stats.jsonl")
        do {
            try Self.writeLegacyOnlyCopyThrowing(at: real, to: copy)
        } catch {
            audit.check("copied the real store into a temp file", false, "\(error)")
            return
        }
        let original = (try? Data(contentsOf: real)) ?? Data()
        let loaded = TeamStats.load(from: copy)
        let after = (try? Data(contentsOf: real)) ?? Data()
        audit.check("the real store was not mutated by the copy load", original == after)
        audit.equal("the real store still loads 7 legacy v1 real records",
                    TeamStats.legacyV1RealCount(loaded.records), 7)
        audit.equal("the real store has 0 corrupt lines", loaded.corruptLines, 0)
        let v1 = loaded.records.filter { $0.schemaVersion == 1 }
        audit.check("the seven legacy records are schema v1 and not calibration",
                    v1.count == 7 && v1.allSatisfy { !$0.isCalibration })
        audit.check("v1 real records do not invent round records",
                    v1.allSatisfy { rec in
                        rec.items.allSatisfy { $0.roundRecords.isEmpty }
                    })
        audit.check("v1 real records have unrecorded roleSpend, not a $0 claim",
                    v1.allSatisfy { rec in
                        rec.items.allSatisfy { $0.roleSpend == nil }
                    })
        audit.check("v1 real records have unrecorded planning spend, not a $0 claim",
                    v1.allSatisfy { $0.planCostUSD == nil && $0.planUnreported == nil })
    }

    // MARK: - Recommendations, trial seats, drift

    private static func recommendationsAndTrends(_ audit: Auditor) async {
        recommendSeats(audit)
        displayStrings(audit)
        trendBoundaries(audit)
        trendFromRecords(audit)
        await applyAndTrial(audit)
        realStoreRecommendations(audit)
    }

    private static func recommendSeats(_ audit: Auditor) {
        audit.section("Team stats — recommendSeats ranking and eligibility")
        let grok46 = TeamStats.CatalogSeat(provider: "grok", model: "grok-4.6")
        let grok45 = TeamStats.CatalogSeat(provider: "grok", model: "grok-4.5")
        let opus = TeamStats.CatalogSeat(provider: "claude", model: "claude-opus-5")
        let fable = TeamStats.CatalogSeat(provider: "claude", model: "claude-fable-5")
        let terra = TeamStats.CatalogSeat(provider: "codex", model: "gpt-5.6-terra")
        let catalog: Set<TeamStats.CatalogSeat> = [grok46, grok45, opus, fable, terra]
        let allOn: Set<String> = ["grok", "claude", "codex"]

        // A: 2/2 clean, under the floor. B: 1/3 clean, eligible. A must not win.
        let underFloor = TeamStats.recommendSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(2, fixtureItem(
                    author: "grok", authorModel: "grok-4.6", authorEffort: "xhigh",
                    reviewer: "claude", reviewerModel: "claude-opus-5",
                    state: "accepted", rounds: 1))),
                fixtureRun(items: copies(3, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5", authorEffort: "high",
                    reviewer: "grok", reviewerModel: "grok-4.6",
                    state: "failed", rounds: 2, failed: true))),
            ]),
            installed: catalog, enabledWorkers: allOn)
        audit.check("a seat with 2 items is excluded even at 100% clean accepts",
                    isPick(underFloor.author, provider: "claude", model: "claude-opus-5",
                           effort: "high", n: 3),
                    describe(underFloor.author))

        let byRate = TeamStats.recommendSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(3, fixtureItem(
                    author: "grok", authorModel: "grok-4.6", authorEffort: "xhigh",
                    reviewer: "claude", reviewerModel: "claude-opus-5", reviewerEffort: "high",
                    state: "accepted", rounds: 1))),
                fixtureRun(items: copies(2, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5", authorEffort: "high",
                    reviewer: "grok", reviewerModel: "grok-4.6", reviewerEffort: "xhigh",
                    state: "accepted", rounds: 1))
                    + copies(1, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5", authorEffort: "high",
                    reviewer: "grok", reviewerModel: "grok-4.6", reviewerEffort: "xhigh",
                    state: "failed", rounds: 1, failed: true))),
            ]),
            installed: catalog, enabledWorkers: allOn)
        audit.check("higher clean-accept rate ranks first",
                    isPick(byRate.author, provider: "grok", model: "grok-4.6",
                           effort: "xhigh", n: 3),
                    describe(byRate.author))

        let byRounds = TeamStats.recommendSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(2, fixtureItem(
                    author: "grok", authorModel: "grok-4.6", authorEffort: "high",
                    reviewer: "claude", reviewerModel: "claude-opus-5",
                    state: "accepted", rounds: 1))
                    + copies(1, fixtureItem(
                    author: "grok", authorModel: "grok-4.6", authorEffort: "high",
                    reviewer: "claude", reviewerModel: "claude-opus-5",
                    state: "failed", rounds: 1, failed: true))),
                fixtureRun(items: copies(2, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5", authorEffort: "max",
                    reviewer: "grok", reviewerModel: "grok-4.6",
                    state: "accepted", rounds: 3))
                    + copies(1, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5", authorEffort: "max",
                    reviewer: "grok", reviewerModel: "grok-4.6",
                    state: "failed", rounds: 3, failed: true))),
            ]),
            installed: catalog, enabledWorkers: allOn)
        audit.check("tied clean-accept rate, lower average rounds ranks first",
                    isPick(byRounds.author, provider: "grok", model: "grok-4.6",
                           effort: "high", n: 3),
                    describe(byRounds.author))

        let byItems = TeamStats.recommendSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(3, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5", authorEffort: "high",
                    reviewer: "grok", reviewerModel: "grok-4.6",
                    state: "accepted", rounds: 1))
                    + copies(3, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5", authorEffort: "high",
                    reviewer: "grok", reviewerModel: "grok-4.6",
                    state: "failed", rounds: 1, failed: true))),
                fixtureRun(items: copies(2, fixtureItem(
                    author: "grok", authorModel: "grok-4.6", authorEffort: "xhigh",
                    reviewer: "claude", reviewerModel: "claude-opus-5",
                    state: "accepted", rounds: 1))
                    + copies(2, fixtureItem(
                    author: "grok", authorModel: "grok-4.6", authorEffort: "xhigh",
                    reviewer: "claude", reviewerModel: "claude-opus-5",
                    state: "failed", rounds: 1, failed: true))),
            ]),
            installed: catalog, enabledWorkers: allOn)
        audit.check("tied rate and average rounds, more items ranks first",
                    isPick(byItems.author, provider: "claude", model: "claude-opus-5",
                           effort: "high", n: 6),
                    describe(byItems.author))

        let tied = TeamStats.recommendSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(2, fixtureItem(
                    author: "grok", authorModel: "grok-4.6", authorEffort: "xhigh",
                    reviewer: "claude", reviewerModel: "claude-opus-5", reviewerEffort: "high",
                    state: "accepted", rounds: 1))
                    + copies(1, fixtureItem(
                    author: "grok", authorModel: "grok-4.6", authorEffort: "xhigh",
                    reviewer: "claude", reviewerModel: "claude-opus-5", reviewerEffort: "high",
                    state: "failed", rounds: 1, failed: true))),
                fixtureRun(items: copies(2, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5", authorEffort: "high",
                    reviewer: "grok", reviewerModel: "grok-4.6", reviewerEffort: "xhigh",
                    state: "accepted", rounds: 1))
                    + copies(1, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5", authorEffort: "high",
                    reviewer: "grok", reviewerModel: "grok-4.6", reviewerEffort: "xhigh",
                    state: "failed", rounds: 1, failed: true))),
            ]),
            installed: catalog, enabledWorkers: allOn)
        audit.check("remaining tiebreak is provider then model, lexicographic ascending",
                    isPick(tied.author, provider: "claude", model: "claude-opus-5",
                           effort: "high", n: 3),
                    describe(tied.author))
        let tiedAgain = TeamStats.recommendSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(2, fixtureItem(
                    author: "grok", authorModel: "grok-4.6", authorEffort: "xhigh",
                    reviewer: "claude", reviewerModel: "claude-opus-5", reviewerEffort: "high",
                    state: "accepted", rounds: 1))
                    + copies(1, fixtureItem(
                    author: "grok", authorModel: "grok-4.6", authorEffort: "xhigh",
                    reviewer: "claude", reviewerModel: "claude-opus-5", reviewerEffort: "high",
                    state: "failed", rounds: 1, failed: true))),
                fixtureRun(items: copies(2, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5", authorEffort: "high",
                    reviewer: "grok", reviewerModel: "grok-4.6", reviewerEffort: "xhigh",
                    state: "accepted", rounds: 1))
                    + copies(1, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5", authorEffort: "high",
                    reviewer: "grok", reviewerModel: "grok-4.6", reviewerEffort: "xhigh",
                    state: "failed", rounds: 1, failed: true))),
            ]),
            installed: catalog, enabledWorkers: allOn)
        audit.equal("the same fixture recommends the same seats twice (deterministic)",
                    tied, tiedAgain)

        let secret = TeamStats.recommendSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(5, fixtureItem(
                    author: "grok", authorModel: "secret-model", authorEffort: "max",
                    reviewer: "claude", reviewerModel: "claude-opus-5",
                    state: "accepted", rounds: 1))),
            ]),
            installed: catalog, enabledWorkers: allOn)
        audit.check("an uninstalled model is never recommended, even at 5/5",
                    !isPick(secret.author, provider: "grok", model: "secret-model"),
                    describe(secret.author))

        let disabled = TeamStats.recommendSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(5, fixtureItem(
                    author: "grok", authorModel: "grok-4.6", authorEffort: "xhigh",
                    reviewer: "claude", reviewerModel: "claude-opus-5", reviewerEffort: "high",
                    state: "accepted", rounds: 1))),
                fixtureRun(items: copies(3, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5", authorEffort: "high",
                    reviewer: "codex", reviewerModel: "gpt-5.6-terra",
                    state: "failed", rounds: 2, failed: true))),
            ]),
            installed: catalog, enabledWorkers: ["claude", "codex"])
        audit.check("a disabled provider is never recommended, even with the best rate",
                    isPick(disabled.author, provider: "claude", model: "claude-opus-5",
                           effort: "high", n: 3),
                    describe(disabled.author))

        let sparse = TeamStats.recommendSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(2, fixtureItem(
                    author: "grok", authorModel: "grok-4.6",
                    reviewer: "claude", reviewerModel: "claude-opus-5",
                    state: "accepted", rounds: 1))),
                fixtureRun(items: copies(1, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5",
                    reviewer: "grok", reviewerModel: "grok-4.6",
                    state: "accepted", rounds: 1))),
            ]),
            installed: [grok46, grok45, opus],
            enabledWorkers: ["grok", "claude"])
        if case .needsData(let untested) = sparse.author {
            audit.equal("needsData lists exactly the untested installed+enabled author seats",
                        untested, [opus, grok45, grok46])
        } else {
            audit.check("needsData lists exactly the untested installed+enabled author seats",
                        false, describe(sparse.author))
        }
        if case .needsData(let untested) = sparse.author {
            audit.check("needsData does not invent a catalog seat that was not installed",
                        !untested.contains(fable) && !untested.contains(terra))
        }
        let sparseDisabled = TeamStats.recommendSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(2, fixtureItem(
                    author: "grok", authorModel: "grok-4.6",
                    reviewer: "claude", reviewerModel: "claude-opus-5"))),
            ]),
            installed: [grok46, grok45, opus],
            enabledWorkers: ["grok"])
        if case .needsData(let untested) = sparseDisabled.author {
            audit.equal("needsData omits disabled providers from the untested list",
                        untested, [grok45, grok46])
        } else {
            audit.check("needsData omits disabled providers from the untested list", false,
                        describe(sparseDisabled.author))
        }

        let planned = TeamStats.recommendSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(3, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5",
                    reviewer: "grok", reviewerModel: "grok-4.6",
                    state: "accepted", rounds: 1)),
                           planCostUSD: 0.4, planUnreported: false),
                fixtureRun(items: [], planCostUSD: 0.1, planUnreported: false),
                fixtureRun(items: [], planCostUSD: 0.1, planUnreported: false),
            ]),
            installed: [grok46, opus], enabledWorkers: ["grok", "claude"])
        if case .needsData(let untested) = planned.orchestrator {
            audit.equal("orchestrator planning turns do not clear the 3-item floor",
                        untested, [opus, grok46])
        } else {
            audit.check("orchestrator planning turns do not clear the 3-item floor",
                        false, describe(planned.orchestrator))
        }

        let effortTie = TeamStats.aggregate(records: [
            fixtureRun(items: copies(2, fixtureItem(
                author: "grok", authorModel: "grok-4.6", authorEffort: "high",
                reviewer: "claude", reviewerModel: "claude-opus-5",
                state: "accepted", rounds: 1))),
            fixtureRun(items: copies(2, fixtureItem(
                author: "grok", authorModel: "grok-4.6", authorEffort: "low",
                reviewer: "claude", reviewerModel: "claude-opus-5",
                state: "accepted", rounds: 1))),
        ])
        let effortRec = TeamStats.recommendSeats(stats: effortTie, installed: catalog,
                                                 enabledWorkers: allOn)
        audit.check("modal effort on a count tie is the lexicographically smaller string",
                    isPick(effortRec.author, provider: "grok", model: "grok-4.6",
                           effort: "high", n: 4),
                    describe(effortRec.author))

        let trials = TeamStats.untestedTrialSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(3, fixtureItem(
                    author: "grok", authorModel: "grok-4.6",
                    reviewer: "claude", reviewerModel: "claude-opus-5"))),
            ]),
            installed: catalog, enabledWorkers: allOn)
        audit.equal("a catalog model with reviewer-or-author records is not a trial seat",
                    trials.contains(grok46) || trials.contains(opus), false)
        audit.equal("the first trial seat is the lexicographically first zero-record catalog model",
                    trials.first, fable)
        let trialsOff = TeamStats.untestedTrialSeats(
            stats: [:], installed: catalog, enabledWorkers: ["grok"])
        audit.equal("trial seats never include a disabled provider",
                    trialsOff, [grok45, grok46])

        // Grok is the best author on paper, but it is the orchestrator this run
        // so it is not in the worker pool and cannot author.
        let orchIsGrok = TeamStats.recommendSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(5, fixtureItem(
                    author: "grok", authorModel: "grok-4.6", authorEffort: "xhigh",
                    reviewer: "claude", reviewerModel: "claude-opus-5", reviewerEffort: "high",
                    state: "accepted", rounds: 1))),
                fixtureRun(items: copies(3, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5", authorEffort: "high",
                    reviewer: "codex", reviewerModel: "gpt-5.6-terra",
                    state: "failed", rounds: 2, failed: true))),
            ]),
            installed: catalog, enabledWorkers: allOn,
            orchestratorProvider: "grok")
        audit.check("the current orchestrator is never recommended as author",
                    isPick(orchIsGrok.author, provider: "claude", model: "claude-opus-5",
                           effort: "high", n: 3),
                    describe(orchIsGrok.author))
        let grokReviews = TeamStats.recommendSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(5, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5", authorEffort: "high",
                    reviewer: "grok", reviewerModel: "grok-4.6", reviewerEffort: "xhigh",
                    state: "accepted", rounds: 1))),
            ]),
            installed: catalog, enabledWorkers: allOn,
            orchestratorProvider: "grok")
        audit.check("the current orchestrator may still be recommended as reviewer",
                    isPick(grokReviews.reviewer, provider: "grok", model: "grok-4.6",
                           effort: "xhigh", n: 5),
                    describe(grokReviews.reviewer))
        let sparseOrch = TeamStats.recommendSeats(
            stats: TeamStats.aggregate(records: [
                fixtureRun(items: copies(2, fixtureItem(
                    author: "claude", authorModel: "claude-opus-5",
                    reviewer: "codex", reviewerModel: "gpt-5.6-terra"))),
            ]),
            installed: catalog, enabledWorkers: allOn,
            orchestratorProvider: "grok")
        if case .needsData(let untested) = sparseOrch.author {
            audit.check("author needsData does not list the orchestrator's models",
                        !untested.contains(where: { $0.provider == "grok" })
                        && untested.contains(opus),
                        untested.map { "\($0.provider)/\($0.model)" }.joined(separator: ","))
        } else {
            audit.check("author needsData does not list the orchestrator's models", false,
                        describe(sparseOrch.author))
        }
        let orchTrials = TeamStats.untestedTrialSeats(
            stats: [:], installed: catalog,
            enabledWorkers: allOn, orchestratorProvider: "grok")
        audit.check("a trial seat is never the current orchestrator",
                    !orchTrials.contains(where: { $0.provider == "grok" }),
                    orchTrials.map { "\($0.provider)/\($0.model)" }.joined(separator: ","))
        audit.equal("trial seats still include a worker's untested model",
                    orchTrials.first, fable)

        let reported = TeamStats.catalogSeats(reportedModels: [
            "grok": ["grok-4.6"],
            "claude": ["claude-opus-5"],
        ])
        audit.check("catalogSeats includes a model the backend reported",
                    reported.contains(grok46) && reported.contains(opus))
        audit.check("catalogSeats omits a hard-coded model the backend did not report",
                    !reported.contains(grok45) && !reported.contains(fable)
                    && !reported.contains(terra))
        audit.check("a provider that has not reported models contributes no catalog seats",
                    TeamStats.catalogSeats(reportedModels: ["grok": []]).isEmpty)
    }

    private static func displayStrings(_ audit: Auditor) {
        audit.section("Team stats — recommendation, trial, and trend display strings")
        let rec = TeamStats.SeatRecommendations(
            author: .recommended(.init(provider: "grok", model: "grok-4.6",
                                       effort: "xhigh", sampleSize: 9)),
            reviewer: .recommended(.init(provider: "claude", model: "claude-opus-5",
                                         effort: "high", sampleSize: 5)),
            orchestrator: .needsData(untested: [
                .init(provider: "claude", model: "claude-opus-5"),
                .init(provider: "grok", model: "grok-4.6"),
            ]))
        audit.equal("the suggestion line names each role with sample sizes",
                    TeamStats.suggestionLine(rec),
                    "Suggested from your history: author Grok · grok-4.6 · xhigh (9 items); "
                        + "reviewer Claude · claude-opus-5 · high (5 items); "
                        + "orchestrator needs data (untested: Claude · claude-opus-5, Grok · grok-4.6)")

        let emptyNeeds = TeamStats.SeatRecommendations(
            author: .needsData(untested: []),
            reviewer: .needsData(untested: []),
            orchestrator: .needsData(untested: []))
        audit.equal("a needsData suggestion with no catalog seats says none, not a guess",
                    TeamStats.suggestionLine(emptyNeeds),
                    "Suggested from your history: author needs data (untested: none); "
                        + "reviewer needs data (untested: none); "
                        + "orchestrator needs data (untested: none)")

        audit.equal("the trial line names the catalog model as an author opt-in",
                    TeamStats.trialLine(seat: .init(provider: "claude",
                                                    model: "claude-fable-5")),
                    "untested: Claude · claude-fable-5 as author — trial it this run?")

        let seat = TeamStats.SeatKey(provider: "codex", role: "author",
                                     model: "gpt-5.6-terra")
        var stats = TeamStats.SeatStats()
        stats.items = 2; stats.cleanAccepts = 0; stats.averageRounds = 2.5
        stats.totalCostUSD = 0.44
        audit.equal("a trend row showing both windows for improving",
                    TeamStats.trendRowText(seat: seat, stats: stats, trend: .init(
                        kind: .improving, recentCleanAccepts: 4, recentItems: 5,
                        lifetimeCleanAccepts: 6, lifetimeItems: 10)),
                    "Codex · author · gpt-5.6-terra — 2 items, 0 clean, avg 2.5 rounds, $0.44"
                        + " · improving (recent 4/5 / life 6/10)")
        audit.equal("a trend row showing both windows for steady",
                    TeamStats.trendRowText(seat: seat, stats: stats, trend: .init(
                        kind: .steady, recentCleanAccepts: 4, recentItems: 5,
                        lifetimeCleanAccepts: 8, lifetimeItems: 10)),
                    "Codex · author · gpt-5.6-terra — 2 items, 0 clean, avg 2.5 rounds, $0.44"
                        + " · steady (recent 4/5 / life 8/10)")
        audit.equal("a trend row showing both windows for declining",
                    TeamStats.trendRowText(seat: seat, stats: stats, trend: .init(
                        kind: .declining, recentCleanAccepts: 1, recentItems: 5,
                        lifetimeCleanAccepts: 6, lifetimeItems: 10)),
                    "Codex · author · gpt-5.6-terra — 2 items, 0 clean, avg 2.5 rounds, $0.44"
                        + " · declining (recent 1/5 / life 6/10)")
        audit.equal("a trend row showing both windows for insufficient recent data",
                    TeamStats.trendRowText(seat: seat, stats: stats, trend: .init(
                        kind: .insufficient, recentCleanAccepts: 1, recentItems: 1,
                        lifetimeCleanAccepts: 1, lifetimeItems: 1)),
                    "Codex · author · gpt-5.6-terra — 2 items, 0 clean, avg 2.5 rounds, $0.44"
                        + " · insufficient recent data (recent 1/1 / life 1/1)")
    }

    private static func trendBoundaries(_ audit: Auditor) {
        audit.section("Team stats — trend classification at the thresholds")
        audit.equal("5/5 vs 9/10 is improving at the 0.10 boundary",
                    TeamStats.classifyTrend(recentCleanAccepts: 5, recentItems: 5, recentRuns: 5,
                                            lifetimeCleanAccepts: 9, lifetimeItems: 10,
                                            olderRuns: 2),
                    .improving)
        audit.equal("5/5 vs 91/100 is steady just inside the band",
                    TeamStats.classifyTrend(recentCleanAccepts: 5, recentItems: 5, recentRuns: 5,
                                            lifetimeCleanAccepts: 91, lifetimeItems: 100,
                                            olderRuns: 2),
                    .steady)
        audit.equal("4/5 vs 9/10 is declining at the -0.10 boundary",
                    TeamStats.classifyTrend(recentCleanAccepts: 4, recentItems: 5, recentRuns: 5,
                                            lifetimeCleanAccepts: 9, lifetimeItems: 10,
                                            olderRuns: 2),
                    .declining)
        audit.equal("4/5 vs 89/100 is steady just inside the declining band",
                    TeamStats.classifyTrend(recentCleanAccepts: 4, recentItems: 5, recentRuns: 5,
                                            lifetimeCleanAccepts: 89, lifetimeItems: 100,
                                            olderRuns: 2),
                    .steady)
        audit.equal("0/5 vs 1/10 is declining at the -0.10 boundary from zero",
                    TeamStats.classifyTrend(recentCleanAccepts: 0, recentItems: 5, recentRuns: 5,
                                            lifetimeCleanAccepts: 1, lifetimeItems: 10,
                                            olderRuns: 2),
                    .declining)
        audit.equal("a 0.00 gap with enough data is steady",
                    TeamStats.classifyTrend(recentCleanAccepts: 4, recentItems: 5, recentRuns: 5,
                                            lifetimeCleanAccepts: 8, lifetimeItems: 10,
                                            olderRuns: 2),
                    .steady)
        audit.equal("one recent run is insufficient, never labelled steady",
                    TeamStats.classifyTrend(recentCleanAccepts: 5, recentItems: 5, recentRuns: 1,
                                            lifetimeCleanAccepts: 5, lifetimeItems: 10,
                                            olderRuns: 4),
                    .insufficient)
        audit.equal("no older-window run is insufficient, never labelled steady",
                    TeamStats.classifyTrend(recentCleanAccepts: 5, recentItems: 5, recentRuns: 5,
                                            lifetimeCleanAccepts: 5, lifetimeItems: 5,
                                            olderRuns: 0),
                    .insufficient)
        audit.equal("zero recent items is insufficient rather than a 0% rate",
                    TeamStats.classifyTrend(recentCleanAccepts: 0, recentItems: 0, recentRuns: 5,
                                            lifetimeCleanAccepts: 5, lifetimeItems: 10,
                                            olderRuns: 2),
                    .insufficient)
    }

    private static func trendFromRecords(_ audit: Auditor) {
        audit.section("Team stats — last-5 vs lifetime from records")
        func runAt(_ t: TimeInterval, authorModel: String, accepted: Bool) -> TeamStats.RunOutcome {
            fixtureRun(
                items: [fixtureItem(
                    author: "grok", authorModel: authorModel, authorEffort: "xhigh",
                    reviewer: "claude", reviewerModel: "claude-opus-5",
                    state: accepted ? "accepted" : "failed",
                    rounds: 1, failed: !accepted)],
                date: Date(timeIntervalSince1970: t))
        }
        // 7 runs, oldest first. Last 5 are the newest. Older 2 fail, recent 5 accept.
        let improving = (0..<7).map { i in
            runAt(TimeInterval(i), authorModel: "grok-4.6", accepted: i >= 2)
        }
        let key = TeamStats.SeatKey(provider: "grok", role: "author", model: "grok-4.6")
        let improvingTrend = TeamStats.trends(records: improving)[key]
        audit.equal("seven records: last 5 clean vs 5/7 life is improving",
                    improvingTrend?.kind, .improving)
        audit.equal("improving recent clean accepts", improvingTrend?.recentCleanAccepts, 5)
        audit.equal("improving recent items", improvingTrend?.recentItems, 5)
        audit.equal("improving lifetime clean accepts", improvingTrend?.lifetimeCleanAccepts, 5)
        audit.equal("improving lifetime items", improvingTrend?.lifetimeItems, 7)

        let declining = (0..<7).map { i in
            runAt(TimeInterval(i), authorModel: "grok-4.6", accepted: i < 2)
        }
        let decliningTrend = TeamStats.trends(records: declining)[key]
        audit.equal("seven records: last 5 failing vs 2/7 life is declining",
                    decliningTrend?.kind, .declining)
        audit.equal("declining recent clean accepts", decliningTrend?.recentCleanAccepts, 0)
        audit.equal("declining recent items", decliningTrend?.recentItems, 5)

        let three = (0..<3).map { i in
            runAt(TimeInterval(i), authorModel: "grok-4.6", accepted: true)
        }
        audit.equal("fewer than 6 runs leaves no older window: insufficient, not steady",
                    TeamStats.trends(records: three)[key]?.kind, .insufficient)

        let oneRecent = (0..<7).map { i in
            runAt(TimeInterval(i), authorModel: i == 6 ? "grok-4.6" : "other",
                  accepted: true)
        }
        audit.equal("a seat that appears in only one of the last 5 runs is insufficient",
                    TeamStats.trends(records: oneRecent)[key]?.kind, .insufficient)
    }

    private static func applyAndTrial(_ audit: Auditor) async {
        audit.section("Team stats — Apply and trial seat write this run only")
        let defaults = UserDefaults.standard
        let keys = ["claudeModel", "claudeEffort", "grokEffort", "codexModel", "codexEffort"]
        let saved = keys.reduce(into: [String: String?]()) { $0[$1] = defaults.string(forKey: $1) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("sentinel-model", forKey: "claudeModel")
        defaults.set("sentinel-effort", forKey: "claudeEffort")
        defaults.set("sentinel-effort", forKey: "grokEffort")
        defaults.set("sentinel-model", forKey: "codexModel")
        defaults.set("sentinel-effort", forKey: "codexEffort")

        let engine = Orchestrator()
        engine.installedProviders = [.grok, .claude, .codex]
        engine.orchestratorProvider = .grok
        engine.modelOverrides[.claude] = "provider-wide-must-stay"
        engine.roleModelOverrides[.author] = [.codex: "gpt-5.6-terra"]
        let rec = TeamStats.SeatRecommendations(
            author: .recommended(.init(provider: "claude", model: "claude-opus-5",
                                       effort: "high", sampleSize: 6)),
            reviewer: .recommended(.init(provider: "grok", model: "grok-4.6",
                                         effort: "xhigh", sampleSize: 4)),
            orchestrator: .recommended(.init(provider: "codex", model: "gpt-5.6-sol",
                                             effort: "low", sampleSize: 3)))
        engine.applySeatRecommendations(rec)
        audit.equal("Apply fills the author role picker",
                    engine.roleModelOverrides[.author]?[.claude], Optional("claude-opus-5"))
        audit.equal("Apply fills the author effort picker",
                    engine.roleEffortOverrides[.author]?[.claude], Optional("high"))
        audit.equal("Apply fills the reviewer role picker",
                    engine.roleModelOverrides[.reviewer]?[.grok], Optional("grok-4.6"))
        audit.equal("Apply fills the reviewer effort picker",
                    engine.roleEffortOverrides[.reviewer]?[.grok], Optional("xhigh"))
        audit.equal("Apply fills the orchestrator role picker",
                    engine.roleModelOverrides[.orchestrator]?[.codex], Optional("gpt-5.6-sol"))
        audit.equal("Apply fills the orchestrator effort picker",
                    engine.roleEffortOverrides[.orchestrator]?[.codex], Optional("low"))
        audit.equal("Apply sets the orchestrator provider picker to the recommended provider",
                    engine.orchestratorProvider, .codex)
        audit.check("Apply leaves the author provider in the worker pool",
                    engine.workerPool.contains(.claude))
        audit.equal("Apply does not clear an unrelated author picker already set",
                    engine.roleModelOverrides[.author]?[.codex], Optional("gpt-5.6-terra"))

        let conflict = Orchestrator()
        conflict.installedProviders = [.grok, .claude, .codex]
        conflict.orchestratorProvider = .grok
        conflict.applySeatRecommendations(TeamStats.SeatRecommendations(
            author: .recommended(.init(provider: "claude", model: "claude-opus-5",
                                       effort: "high", sampleSize: 6)),
            reviewer: .needsData(untested: []),
            orchestrator: .recommended(.init(provider: "claude", model: "claude-opus-5",
                                             effort: "low", sampleSize: 3))))
        audit.equal("Apply does not switch the orchestrator onto the author provider",
                    conflict.orchestratorProvider, .grok)
        audit.equal("Apply still writes the author picker when orchestrator wanted the same provider",
                    conflict.roleModelOverrides[.author]?[.claude], Optional("claude-opus-5"))
        audit.check("the author provider remains in the worker pool after a conflicting Apply",
                    conflict.workerPool.contains(.claude)
                    && !conflict.workerPool.contains(.grok))
        audit.equal("the orchestrator model override is still recorded for if the user switches later",
                    conflict.roleModelOverrides[.orchestrator]?[.claude], Optional("claude-opus-5"))
        audit.equal("Apply does not write a provider-wide model override",
                    engine.modelOverrides[.claude], Optional("provider-wide-must-stay"))
        audit.check("Apply does not rewrite persisted chat defaults",
                    defaults.string(forKey: "claudeModel") == "sentinel-model"
                    && defaults.string(forKey: "claudeEffort") == "sentinel-effort"
                    && defaults.string(forKey: "grokEffort") == "sentinel-effort"
                    && defaults.string(forKey: "codexModel") == "sentinel-model"
                    && defaults.string(forKey: "codexEffort") == "sentinel-effort")

        let noop = Orchestrator()
        noop.orchestratorProvider = .grok
        let beforeModels = noop.roleModelOverrides
        let beforeEfforts = noop.roleEffortOverrides
        noop.applySeatRecommendations(TeamStats.SeatRecommendations(
            author: .needsData(untested: []),
            reviewer: .needsData(untested: []),
            orchestrator: .needsData(untested: [])))
        audit.check("Apply of a needsData result is a no-op on the pickers",
                    noop.roleModelOverrides == beforeModels
                    && noop.roleEffortOverrides == beforeEfforts
                    && noop.orchestratorProvider == .grok)

        let trial = Orchestrator()
        trial.installedProviders = [.grok, .claude, .codex]
        trial.orchestratorProvider = .grok
        trial.roleModelOverrides[.author] = [.grok: "grok-4.6"]
        trial.roleModelOverrides[.reviewer] = [.claude: "claude-opus-5"]
        trial.roleEffortOverrides[.author] = [.grok: "xhigh"]
        trial.modelOverrides[.claude] = "leave-me"
        trial.acceptTrialAuthorSeat(.init(provider: "claude", model: "claude-fable-5"))
        audit.equal("Accept assigns the trial model to exactly one author seat",
                    trial.roleModelOverrides[.author]?[.claude], Optional("claude-fable-5"))
        audit.equal("Accept leaves a different provider's author picker alone",
                    trial.roleModelOverrides[.author]?[.grok], Optional("grok-4.6"))
        audit.equal("Accept does not assign a reviewer seat",
                    trial.roleModelOverrides[.reviewer]?[.claude], Optional("claude-opus-5"))
        audit.check("Accept does not assign an orchestrator seat",
                    trial.roleModelOverrides[.orchestrator] == nil
                    || trial.roleModelOverrides[.orchestrator]?.isEmpty == true)
        audit.equal("Accept does not write an effort override",
                    trial.roleEffortOverrides[.author]?[.grok], Optional("xhigh"))
        audit.check("Accept does not write an effort for the trial provider",
                    trial.roleEffortOverrides[.author]?[.claude] == nil)
        audit.equal("Accept does not change the orchestrator provider picker",
                    trial.orchestratorProvider, .grok)
        audit.equal("Accept does not write a provider-wide model override",
                    trial.modelOverrides[.claude], Optional("leave-me"))
        audit.check("Accept does not rewrite persisted chat defaults",
                    defaults.string(forKey: "claudeModel") == "sentinel-model"
                    && defaults.string(forKey: "claudeEffort") == "sentinel-effort"
                    && defaults.string(forKey: "codexModel") == "sentinel-model")

        let unrecordedEffort = Orchestrator()
        unrecordedEffort.installedProviders = [.grok, .claude, .codex]
        unrecordedEffort.orchestratorProvider = .claude
        unrecordedEffort.applySeatRecommendations(TeamStats.SeatRecommendations(
            author: .recommended(.init(provider: "grok", model: "grok-4.6",
                                       effort: TeamStats.unrecorded, sampleSize: 3)),
            reviewer: .needsData(untested: []),
            orchestrator: .needsData(untested: [])))
        audit.equal("Apply with unrecorded effort still fills the model picker",
                    unrecordedEffort.roleModelOverrides[.author]?[.grok], Optional("grok-4.6"))
        audit.check("Apply with unrecorded effort does not invent an effort override",
                    unrecordedEffort.roleEffortOverrides[.author]?[.grok] == nil)

        let refuseOrch = Orchestrator()
        refuseOrch.installedProviders = [.grok, .claude, .codex]
        refuseOrch.orchestratorProvider = .claude
        refuseOrch.acceptTrialAuthorSeat(.init(provider: "claude", model: "claude-fable-5"))
        audit.check("Accept refuses a trial on the current orchestrator — it cannot author this run",
                    refuseOrch.roleModelOverrides[.author]?[.claude] == nil)

        let app = AppModel(trust: .forAudit)
        defer { app.shutdown() }
        let grokBackend = ScriptedBackend(provider: .grok, scripts: [])
        grokBackend.models = [ModelOption(id: "grok-4.6", name: "Grok 4.6")]
        app.backends[.grok] = grokBackend
        let fromBackends = app.reportedModels(installed: [.grok, .claude, .codex])
        audit.equal("the unverified catalog phrase is exactly those two words",
                    AppModel.unverifiedCatalogPhrase, "unverified catalog")
        audit.check("a backend catalog without a models event is reported as unverified catalog",
                    app.catalogIsUnverified(.grok))
        audit.check("an unverified catalog is not encoded as a model id",
                    !(fromBackends["grok"] ?? []).contains(AppModel.unverifiedCatalogPhrase))
        audit.check("an unverified catalog is not silently dropped",
                    app.catalogIsUnverified(.grok))
        audit.check("an unverified catalog is not presented as the constructor's model ids",
                    fromBackends["grok"] != Optional(["grok-4.6"]))
        audit.equal("a backend catalog without a models event contributes no reported model ids",
                    fromBackends["grok"], Optional<[String]>.none)
        audit.check("catalogIsUnverified is true before a models event",
                    app.catalogIsUnverified(.grok))
        audit.equal("the toolbar label is unverified catalog before a models event",
                    app.modelToolbarLabel(for: .grok), AppModel.unverifiedCatalogPhrase)
        let unverifiedSeats = TeamStats.catalogSeats(reportedModels: fromBackends)
        audit.check("catalogSeats does not treat unverified catalog as a seat model",
                    !unverifiedSeats.contains {
                        $0.model == AppModel.unverifiedCatalogPhrase
                    })
        audit.check("catalogSeats does not treat constructor ids as verified seats",
                    !unverifiedSeats.contains {
                        $0.provider == "grok" && $0.model == "grok-4.6"
                    })
        let unverifiedRec = TeamStats.recommendSeats(
            stats: [:], installed: unverifiedSeats, enabledWorkers: ["grok"])
        audit.check("team recommendations do not name unverified catalog as a model",
                    !TeamStats.suggestionLine(unverifiedRec)
                        .contains(AppModel.unverifiedCatalogPhrase),
                    TeamStats.suggestionLine(unverifiedRec))
        let unverifiedTrials = TeamStats.untestedTrialSeats(
            stats: [:], installed: unverifiedSeats, enabledWorkers: ["grok"])
        audit.check("a trial seat is never unverified catalog",
                    !unverifiedTrials.contains {
                        $0.model == AppModel.unverifiedCatalogPhrase
                    },
                    unverifiedTrials.map { "\($0.provider)/\($0.model)" }
                        .joined(separator: ","))
        app.handleForTest(.models([ModelOption(id: "grok-4.6", name: "Grok 4.6")],
                                  current: "grok-4.6"), from: .grok)
        let verified = app.reportedModels(installed: [.grok, .claude, .codex])
        audit.equal("reportedModels lists the ids from a models event",
                    verified["grok"], Optional(["grok-4.6"]))
        audit.check("a models event is not labelled unverified catalog",
                    verified["grok"]?.contains(AppModel.unverifiedCatalogPhrase) != true)
        audit.check("catalogIsUnverified is false after a models event",
                    !app.catalogIsUnverified(.grok))
        audit.check("the toolbar label is not unverified catalog after a models event",
                    app.modelToolbarLabel(for: .grok) != AppModel.unverifiedCatalogPhrase)
        audit.check("a provider with no connected backend contributes no reported models",
                    verified["claude"] == nil && verified["codex"] == nil)
        audit.check("hard-coded grok-4.5 is not reported just because the Grok CLI exists",
                    verified["grok"]?.contains("grok-4.5") != true)
        audit.check("catalogSeats from reported models does not invent grok-4.5",
                    !TeamStats.catalogSeats(reportedModels: verified)
                        .contains(.init(provider: "grok", model: "grok-4.5")))

        let claudeApp = AppModel(trust: .forAudit)
        defer { claudeApp.shutdown() }
        claudeApp.backends[.claude] = ClaudeBackend()
        let claudeReported = claudeApp.reportedModels(installed: [.claude])
        audit.check("Claude's constructor catalogue without a models event is unverified catalog",
                    claudeApp.catalogIsUnverified(.claude))
        audit.equal("Claude's toolbar label is unverified catalog before a models event",
                    claudeApp.modelToolbarLabel(for: .claude), AppModel.unverifiedCatalogPhrase)
        audit.equal("the agent-named menu title keeps the catalog-trust wording",
                    claudeApp.modelMenuTitle(for: .claude), "Claude · " + AppModel.unverifiedCatalogPhrase)
        audit.check("Claude's constructor catalogue is not encoded as model ids",
                    claudeReported["claude"] == nil)
        let claudeSeats = TeamStats.catalogSeats(reportedModels: claudeReported)
        let claudeRec = TeamStats.recommendSeats(
            stats: [:], installed: claudeSeats, enabledWorkers: ["claude"])
        audit.check("Claude's unverified catalog is not a team recommendation model",
                    !TeamStats.suggestionLine(claudeRec)
                        .contains(AppModel.unverifiedCatalogPhrase)
                    && claudeSeats.allSatisfy {
                        $0.model != AppModel.unverifiedCatalogPhrase
                    },
                    TeamStats.suggestionLine(claudeRec))
        claudeApp.handleForTest(.models(ClaudeBackend().models, current: nil), from: .claude)
        let claudeVerified = claudeApp.reportedModels(installed: [.claude])
        audit.check("after a models event Claude reports its listed ids, not unverified catalog",
                    claudeVerified["claude"]?.contains("claude-opus-5") == true
                    && claudeVerified["claude"]?.contains(AppModel.unverifiedCatalogPhrase) != true,
                    "\(claudeVerified["claude"] ?? [])")
        audit.check("after a models event Claude's toolbar label is not unverified catalog",
                    claudeApp.modelToolbarLabel(for: .claude) != AppModel.unverifiedCatalogPhrase
                    && !claudeApp.modelToolbarLabel(for: .claude)
                        .contains(AppModel.unverifiedCatalogPhrase))

        let contentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/Orrery/Views/ContentView.swift")
        let content = (try? String(contentsOf: contentURL, encoding: .utf8)) ?? ""
        audit.check("the model menu names an unverified catalog in those words",
                    content.contains("AppModel.unverifiedCatalogPhrase")
                    && content.contains("catalogIsUnverified"))
        // The menu title is named for its agent and wraps the catalog-trust title.
        audit.check("the toolbar model label uses the catalog-trust title",
                    content.contains("modelMenuTitle(for:") || content.contains("modelToolbarLabel(for:"))
        let appModelSource = (try? String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/Orrery/AppModel.swift"), encoding: .utf8)) ?? ""
        audit.check("the agent-named menu title is built from the catalog-trust title",
                    appModelSource.contains("func modelMenuTitle(for provider: Provider) -> String {\n        \"\\(provider.displayName) · \\(modelToolbarLabel(for: provider))\""))

        let claudeSrcURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/Orrery/Backends/ClaudeBackend.swift")
        let claudeSrc = (try? String(contentsOf: claudeSrcURL, encoding: .utf8)) ?? ""
        if let launchStart = claudeSrc.range(of: "private func launch(resume: String?) async {"),
           let nextFn = claudeSrc.range(of: "\n    func stop() {") {
            let launchBody = claudeSrc[launchStart.lowerBound..<nextFn.lowerBound]
            audit.check("spawning Claude does not emit models before system/init",
                        !launchBody.contains("emit(.models"))
        } else {
            audit.check("spawning Claude does not emit models before system/init", false,
                        "could not find launch() in ClaudeBackend.swift")
        }

        let claudeEvents = ClaudeBackend()
        var sawModelsBeforeInit = false
        var sawModelsOnInit = false
        claudeEvents.onEvent = { event in
            if case .models = event { sawModelsOnInit = true }
        }
        audit.check("constructing ClaudeBackend does not emit models",
                    !sawModelsOnInit)
        claudeEvents.handleJSONForTest(JSON(["type": "system", "subtype": "status"]))
        sawModelsBeforeInit = sawModelsOnInit
        audit.check("a non-init system event does not emit models",
                    !sawModelsBeforeInit)
        claudeEvents.handleJSONForTest(JSON([
            "type": "system", "subtype": "init", "session_id": "sess-init-1",
        ]))
        audit.check("system/init emits the constructor catalog as a models event",
                    sawModelsOnInit)

        let effortClaude = ClaudeBackend()
        effortClaude.persistsSelection = false
        var modelsFromEffort = 0
        effortClaude.onEvent = { event in
            if case .models = event { modelsFromEffort += 1 }
        }
        let otherEffort = effortClaude.efforts.first { $0 != effortClaude.currentEffort } ?? "low"
        await effortClaude.setEffort(otherEffort)
        audit.check("setEffort before system/init does not emit models",
                    modelsFromEffort == 0)
        let otherModel = effortClaude.models.first { $0.id != effortClaude.currentModel }?.id
            ?? "claude-sonnet-5"
        await effortClaude.setModel(otherModel)
        audit.check("setModel before system/init does not emit models",
                    modelsFromEffort == 0)
        effortClaude.handleJSONForTest(JSON([
            "type": "system", "subtype": "init", "session_id": "sess-effort-1",
        ]))
        let afterInitModels = modelsFromEffort
        audit.check("system/init still emits models after a pre-init setEffort",
                    afterInitModels >= 1)
        let laterEffort = effortClaude.efforts.first { $0 != effortClaude.currentEffort } ?? "max"
        await effortClaude.setEffort(laterEffort)
        audit.check("setEffort after system/init still emits models",
                    modelsFromEffort > afterInitModels)

        let effortApp = AppModel(trust: .forAudit)
        defer { effortApp.shutdown() }
        let effortBackend = ClaudeBackend()
        effortBackend.persistsSelection = false
        effortApp.backends[.claude] = effortBackend
        effortBackend.onEvent = { event in effortApp.handleForTest(event, from: .claude) }
        let appEffort = effortBackend.efforts.first { $0 != effortBackend.currentEffort } ?? "low"
        await effortBackend.setEffort(appEffort)
        audit.check("setEffort during initialization leaves Claude catalog unverified",
                    effortApp.catalogIsUnverified(.claude))
        audit.equal("setEffort during initialization keeps the toolbar on unverified catalog",
                    effortApp.modelToolbarLabel(for: .claude), AppModel.unverifiedCatalogPhrase)
        let effortSeats = TeamStats.catalogSeats(
            reportedModels: effortApp.reportedModels(installed: [.claude]))
        audit.check("setEffort during initialization does not make constructor ids eligible for recommendations",
                    !effortSeats.contains {
                        $0.provider == "claude" && $0.model == "claude-opus-5"
                    })
        let appModel = effortBackend.models.first { $0.id != effortBackend.currentModel }?.id
            ?? "claude-sonnet-5"
        await effortBackend.setModel(appModel)
        audit.check("setModel during initialization leaves Claude catalog unverified",
                    effortApp.catalogIsUnverified(.claude))
        let modelSeats = TeamStats.catalogSeats(
            reportedModels: effortApp.reportedModels(installed: [.claude]))
        audit.check("setModel during initialization does not make constructor ids eligible for recommendations",
                    !modelSeats.contains {
                        $0.provider == "claude" && !$0.model.isEmpty
                    })

        let pendingDie = AppModel(trust: .forAudit)
        defer { pendingDie.shutdown() }
        pendingDie.backends[.claude] = ClaudeBackend()
        pendingDie.handleForTest(.connected(sessionID: "pending"), from: .claude)
        pendingDie.handleForTest(.models(ClaudeBackend().models, current: "claude-opus-5"),
                                 from: .claude)
        audit.check("a models event while sessionID is pending would trust constructor ids",
                    pendingDie.reportedModels(installed: [.claude])["claude"]?
                        .contains("claude-opus-5") == true)
        pendingDie.handleForTest(.disconnected(reason: "Claude exited (1) — ⌘N to restart"),
                                 from: .claude)
        let afterInitExit = pendingDie.reportedModels(installed: [.claude])
        audit.check("a child that exits during initialization does not keep constructor ids trusted",
                    afterInitExit["claude"] == nil)
        audit.check("a child that exits during initialization leaves the catalog unverified",
                    pendingDie.catalogIsUnverified(.claude))

        let afterInit = AppModel(trust: .forAudit)
        defer { afterInit.shutdown() }
        afterInit.backends[.claude] = ClaudeBackend()
        afterInit.handleForTest(.connected(sessionID: "sess-real"), from: .claude)
        afterInit.handleForTest(.models(ClaudeBackend().models, current: "claude-opus-5"),
                                from: .claude)
        afterInit.handleForTest(.disconnected(reason: "Claude exited (0) — ⌘N to restart"),
                                from: .claude)
        audit.check("a catalog confirmed by system/init stays reported after disconnect",
                    afterInit.reportedModels(installed: [.claude])["claude"]?
                        .contains("claude-opus-5") == true)
    }

    private static func realStoreRecommendations(_ audit: Auditor) {
        audit.section("Team stats — real 7-record store still loads through a temp copy")
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Orrery/team-stats.jsonl")
        guard FileManager.default.fileExists(atPath: real.path) else {
            audit.skip("the real team-stats store exists for the recommendation copy", "no Team run on this machine yet"); return
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-realrec-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("team-stats.jsonl")
        do {
            try Self.writeLegacyOnlyCopyThrowing(at: real, to: copy)
        } catch {
            audit.check("copied the real store for recommendation checks", false, "\(error)")
            return
        }
        let original = (try? Data(contentsOf: real)) ?? Data()
        let loaded = TeamStats.load(from: copy)
        let display = TeamStats.loadForDisplay(from: copy)
        let after = (try? Data(contentsOf: real)) ?? Data()
        audit.check("the real store was not mutated by recommendation load", original == after)
        audit.equal("the recommendation copy still loads 7 legacy v1 real records",
                    TeamStats.legacyV1RealCount(loaded.records), 7)
        audit.equal("the recommendation copy has 0 corrupt lines", loaded.corruptLines, 0)
        let stats = TeamStats.aggregate(records: loaded.records)
        let catalog: Set<TeamStats.CatalogSeat> = [
            .init(provider: "grok", model: "grok-4.6"),
            .init(provider: "grok", model: "grok-4.5"),
            .init(provider: "claude", model: "claude-opus-5"),
            .init(provider: "claude", model: "claude-fable-5"),
            .init(provider: "codex", model: "gpt-5.6-terra"),
            .init(provider: "codex", model: "gpt-5.6-sol"),
        ]
        let rec = TeamStats.recommendSeats(stats: stats, installed: catalog,
                                           enabledWorkers: ["grok", "claude", "codex"])
        // Growth-proof, against the LIVE store: whatever the recommender says as records
        // accumulate, it must never name an unrecorded model.
        let liveStats = TeamStats.aggregate(records: TeamStats.load(from: real).records)
        let liveRec = TeamStats.recommendSeats(stats: liveStats, installed: catalog,
                                               enabledWorkers: ["grok", "claude", "codex"])
        audit.check("live-store recommendations never name an unrecorded model",
                    !TeamStats.suggestionLine(liveRec).contains(TeamStats.unrecorded)
                    || TeamStats.suggestionLine(liveRec).contains("needs data"),
                    TeamStats.suggestionLine(liveRec))
        audit.check("the real v1 store does not recommend an unrecorded model as if it were catalog",
                    !rec.hasAnyRecommendation,
                    TeamStats.suggestionLine(rec))
        if case .needsData(let untested) = rec.author {
            audit.check("real-store author needsData lists the catalog, not a guess",
                        untested == catalog.sorted { a, b in
                            if a.provider != b.provider { return a.provider < b.provider }
                            return a.model < b.model
                        })
        } else {
            audit.check("real-store author needsData lists the catalog, not a guess", false,
                        describe(rec.author))
        }
        audit.equal("loadForDisplay attaches a trend to every aggregated seat",
                    display.trends.count, display.seats.count)
        let grokAuthor = TeamStats.SeatKey(provider: "grok", role: "author",
                                           model: TeamStats.unrecorded)
        let grokTrend = display.trend(for: grokAuthor)
        audit.equal("real-store grok/unrecorded author last-5 vs life is declining",
                    grokTrend.kind, .declining)
        audit.equal("real-store grok author recent clean accepts",
                    grokTrend.recentCleanAccepts, 0)
        audit.equal("real-store grok author recent items", grokTrend.recentItems, 7)
        audit.equal("real-store grok author lifetime clean accepts",
                    grokTrend.lifetimeCleanAccepts, 2)
        audit.equal("real-store grok author lifetime items", grokTrend.lifetimeItems, 9)
        if let first = display.seats.first {
            let text = TeamStats.trendRowText(seat: first.0, stats: first.1,
                                              trend: display.trend(for: first.0))
            audit.check("a real-store stats row includes both trend windows",
                        text.contains("(recent ") && text.contains(" / life "),
                        text)
        } else {
            audit.check("a real-store stats row includes both trend windows", false)
        }
    }

    private static func copies(_ n: Int, _ item: TeamStats.ItemOutcome) -> [TeamStats.ItemOutcome] {
        (0..<n).map { i in
            var copy = item
            copy.title = "\(item.title)-\(i)"
            return copy
        }
    }

    private static func isPick(_ advice: TeamStats.RoleAdvice, provider: String, model: String,
                               effort: String? = nil, n: Int? = nil) -> Bool {
        guard case .recommended(let pick) = advice else { return false }
        if pick.provider != provider || pick.model != model { return false }
        if let effort, pick.effort != effort { return false }
        if let n, pick.sampleSize != n { return false }
        return true
    }

    private static func describe(_ advice: TeamStats.RoleAdvice) -> String {
        switch advice {
        case .recommended(let pick):
            return "recommended \(pick.provider)/\(pick.model)/\(pick.effort) n=\(pick.sampleSize)"
        case .needsData(let untested):
            return "needsData \(untested.map { "\($0.provider)/\($0.model)" }.joined(separator: ","))"
        }
    }

    // MARK: - Fixtures

    private static func fixtureRun(title: String,
                                   date: Date) -> TeamStats.RunOutcome {
        fixtureRun(items: [fixtureItem(title: title)], date: date)
    }

    private static func fixtureRun(items: [TeamStats.ItemOutcome],
                                   date: Date = Date(timeIntervalSince1970: 1_700_000_000),
                                   planCostUSD: Double? = nil,
                                   planUnreported: Bool? = nil)
        -> TeamStats.RunOutcome {
        TeamStats.RunOutcome(
            date: date,
            orchestratorProvider: "grok",
            orchestratorModel: TeamStats.unrecorded,
            orchestratorEffort: TeamStats.unrecorded,
            items: items,
            importFingerprint: nil,
            planCostUSD: planCostUSD,
            planUnreported: planUnreported)
    }

    private static func fixtureItem(
        title: String = "T",
        author: String = "claude",
        authorModel: String = "a-model",
        authorEffort: String = "high",
        reviewer: String = "grok",
        reviewerModel: String = "r-model",
        reviewerEffort: String = TeamStats.unrecorded,
        state: String = "accepted",
        rounds: Int = 1,
        roundBudget: Int = 2,
        findings: [TeamStats.FindingRecord] = [],
        findingsLeftStanding: Bool = false,
        gate: TeamStats.ItemGate = .notRun,
        costUSD: Double = 0,
        turns: Int = 0,
        unreportedTurns: Int = 0,
        stalled: Bool = false,
        failed: Bool = false,
        roundRecords: [TeamStats.RoundRecord] = [],
        roleSpend: TeamStats.RoleSpend? = nil
    ) -> TeamStats.ItemOutcome {
        TeamStats.ItemOutcome(
            title: title,
            authorProvider: author,
            authorModel: authorModel,
            authorEffort: authorEffort,
            reviewerProvider: reviewer,
            reviewerModel: reviewerModel,
            reviewerEffort: reviewerEffort,
            state: state,
            rounds: rounds,
            roundBudget: String(roundBudget),
            findings: findings,
            findingsLeftStanding: findingsLeftStanding,
            gate: gate,
            costUSD: costUSD,
            turns: turns,
            unreportedTurns: unreportedTurns,
            stalled: stalled,
            failed: failed,
            roundRecords: roundRecords,
            roleSpend: roleSpend)
    }

    private static func waitForRecords(_ url: URL, count: Int, timeout: Double = 2)
        async -> [TeamStats.RunOutcome] {
        _ = await waitUntil(timeout) { TeamStats.load(from: url).records.count == count }
        return TeamStats.load(from: url).records
    }

    /// Redirect fd 1 around `body` so a `print` + `fflush(stdout)` summary can be asserted.
    private static func captureStdout(_ body: () -> Void) -> String {
        fflush(stdout)
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { return "" }
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        body()
        fflush(stdout)
        try? pipe.fileHandleForWriting.close()
        dup2(saved, STDOUT_FILENO)
        close(saved)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

import CryptoKit
import Foundation

/// Persistent per-seat performance records for orchestrator runs. The most efficient team
/// setup is measured here, not guessed. UI reads `load` / `sortedSeats` / `rowText`;
/// this file is the store, the aggregation, and the `--import-run-log` converter.
enum TeamStats {
    /// What we write when a resolver returns nil — no override, no baked default, so the
    /// CLI's own default ran. Never an empty string and never a guessed model id.
    static let unrecorded = "unrecorded"

    /// New records write this. A v1 line (field absent) decodes as 1.
    static let currentSchemaVersion = 3

    /// Real-world orchestrator run. Absence of `kind` on a v1 line means this.
    static let kindRun = "run"
    /// Isolated calibration harness run. Excluded from real-world aggregates and
    /// from seat recommendations. Never mixed into the real-world stats rows.
    static let kindCalibration = "calibration"

    /// The original backfilled Application Support records: schema v1 and not
    /// calibration. A later calibration append must not change this count.
    static func legacyV1RealCount(_ records: [RunOutcome]) -> Int {
        records.filter { $0.schemaVersion == 1 && !$0.isCalibration }.count
    }

    /// `~/Library/Application Support/Orrery/team-stats.jsonl`. A `var` so `--audit`
    /// can redirect the import-flag handler away from the user's real store.
    static var storeURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Orrery/team-stats.jsonl")

    static func recorded(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? unrecorded : trimmed
    }

    // MARK: Records

    /// One finding as stored on a run. Enough to count by round and severity; not a
    /// reconstruction of the reviewer's full reply.
    struct FindingRecord: Codable, Equatable, Sendable {
        var round: Int
        var severity: String
        var file: String
        var line: Int?
        var message: String
    }

    /// Gate facts copied from `GateResult` — pass / fail / not run, plus the tasks the
    /// gate actually ran. Nothing is invented: a nil `GateResult` is "not run".
    struct ItemGate: Codable, Equatable, Sendable {
        /// `"pass"`, `"fail"`, or `"not run"`.
        var status: String
        var passed: Bool
        var hasExecuted: Bool
        var hasFailure: Bool
        var tasks: [Task]

        struct Task: Codable, Equatable, Sendable {
            var taskID: String
            var title: String
            var passed: Bool
            var exitCode: Int32?
            var timedOut: Bool
            var skippedMissingTool: Bool
            var missingTool: String?
            var outputTail: String
            var firstErrorLine: String
            var diagnostics: [Diagnostic]
        }

        struct Diagnostic: Codable, Equatable, Sendable {
            var file: String
            var line: Int?
            var column: Int?
            var severity: String
            var message: String
        }

        static let notRun = ItemGate(status: "not run", passed: false,
                                     hasExecuted: false, hasFailure: false, tasks: [])

        static func from(_ gate: GateResult?) -> ItemGate {
            guard let gate else { return .notRun }
            return ItemGate(gate)
        }

        init(status: String, passed: Bool, hasExecuted: Bool, hasFailure: Bool, tasks: [Task]) {
            self.status = status
            self.passed = passed
            self.hasExecuted = hasExecuted
            self.hasFailure = hasFailure
            self.tasks = tasks
        }

        init(_ gate: GateResult) {
            hasExecuted = gate.hasExecuted
            hasFailure = gate.hasFailure
            passed = gate.passed
            status = passed ? "pass" : (hasFailure ? "fail" : "not run")
            tasks = gate.tasks.map { task in
                Task(taskID: task.taskID, title: task.title, passed: task.passed,
                     exitCode: task.exitCode, timedOut: task.timedOut,
                     skippedMissingTool: task.skippedMissingTool,
                     missingTool: task.missingTool, outputTail: task.outputTail,
                     firstErrorLine: task.firstErrorLine,
                     diagnostics: task.diagnostics.map {
                         Diagnostic(file: $0.file, line: $0.line, column: $0.column,
                                    severity: $0.severity, message: $0.message)
                     })
            }
        }

        static func fromRunLog(_ object: [String: Any]) -> ItemGate {
            let tasks = (object["tasks"] as? [[String: Any]] ?? []).map { row -> Task in
                let diagnostics = (row["diagnostics"] as? [[String: Any]] ?? []).map { diag in
                    Diagnostic(file: string(diag["file"]) ?? "",
                               line: int(diag["line"]),
                               column: int(diag["column"]),
                               severity: string(diag["severity"]) ?? "",
                               message: string(diag["message"]) ?? "")
                }
                return Task(taskID: string(row["id"]) ?? string(row["taskID"]) ?? "",
                            title: string(row["title"]) ?? "",
                            passed: bool(row["passed"]) ?? false,
                            exitCode: int32(row["exitCode"]),
                            timedOut: bool(row["timedOut"]) ?? false,
                            skippedMissingTool: bool(row["skippedMissingTool"]) ?? false,
                            missingTool: string(row["missingTool"]),
                            outputTail: string(row["outputTail"]) ?? "",
                            firstErrorLine: string(row["firstErrorLine"]) ?? "",
                            diagnostics: diagnostics)
            }
            let hasExecuted = tasks.contains { !$0.skippedMissingTool }
            let hasFailure = tasks.contains { !$0.skippedMissingTool && !$0.passed }
            let passed = hasExecuted && !hasFailure
            let status = passed ? "pass" : (hasFailure ? "fail" : "not run")
            return ItemGate(status: status, passed: passed, hasExecuted: hasExecuted,
                            hasFailure: hasFailure, tasks: tasks)
        }
    }

    /// One review round of an item. Named `roundRecords` on `ItemOutcome` because
    /// `rounds: Int` already exists and is load-bearing for v1 lines and aggregation.
    struct RoundRecord: Codable, Equatable, Sendable {
        var index: Int
        var findingsRaised: Int
        /// Keys are the reviewer's severity strings as stored, `gate` included.
        var severities: [String: Int]
        /// Previous-round findings matched as still standing (see matching rule).
        var previousResolved: Int
        var previousStillStanding: Int
        var authorRevisionPresent: Bool
        /// Nil when the lane has no timestamps (imported v1 orchestrate-logs).
        /// Never invented as 0.
        var wallClockSeconds: Double?
        var stallEvents: Int
        var costByProvider: [String: Double]
        var unreportedTurnsByProvider: [String: Int]
    }

    /// One lane row as the round/cost computers see it. `at` is nil for imported
    /// orchestrate-logs, which have no timestamps.
    struct LaneFact: Equatable, Sendable {
        var provider: String
        var role: String
        var title: String
        var text: String
        var costUSD: Double?
        var editedFileCount: Int = 0
        var at: Date?
        var endedAt: Date?

        init(provider: String, role: String, title: String, text: String,
             costUSD: Double?, editedFileCount: Int = 0, at: Date?, endedAt: Date? = nil) {
            self.provider = provider
            self.role = role
            self.title = title
            self.text = text
            self.costUSD = costUSD
            self.editedFileCount = editedFileCount
            self.at = at
            self.endedAt = endedAt
        }

        init(_ entry: LaneEntry) {
            self.init(provider: entry.provider.rawValue, role: entry.role,
                      title: entry.title, text: entry.text, costUSD: entry.costUSD,
                      editedFileCount: entry.editedFileCount,
                      at: entry.at, endedAt: entry.endedAt)
        }
    }

    /// Reported lane dollars split by role. Nil on v1 lines (unrecorded, not zero).
    struct RoleSpend: Codable, Equatable, Sendable {
        var authorUSD: Double
        var reviewerUSD: Double
        var orchestratorUSD: Double
        var systemUSD: Double
    }

    struct ItemOutcome: Equatable, Sendable {
        var title: String
        var authorProvider: String
        var authorModel: String
        var authorEffort: String
        var reviewerProvider: String
        var reviewerModel: String
        var reviewerEffort: String
        var state: String
        var rounds: Int
        /// Decimal string of the item's budget, or `"unrecorded"` when the source
        /// (an old orchestrate-log) did not include one. Never invented as 0.
        var roundBudget: String
        var findings: [FindingRecord]
        var findingsLeftStanding: Bool
        var gate: ItemGate
        var costUSD: Double
        var turns: Int
        var unreportedTurns: Int
        var stalled: Bool
        var failed: Bool
        /// v3: why the loop stopped early, when it did (nil = it did not).
        var nonConvergenceNote: String?
        /// v3: non-blocking reviewer advisories from scoped grant re-reviews.
        var advisoryNotes: [String]?
        /// v3: the analytics' retry suggestion after a non-convergence stop.
        var reassignAdvice: String?
        /// Per review round. Empty on v1 lines — not a claim that zero rounds ran;
        /// `rounds` still holds the count. The spec said `rounds: [RoundRecord]`,
        /// but `rounds: Int` was already load-bearing, so this array is `roundRecords`.
        var roundRecords: [RoundRecord]
        /// Lane-derived per-role spend. Nil on v1 lines (unrecorded, not a $0 claim).
        var roleSpend: RoleSpend?

        init(title: String, authorProvider: String, authorModel: String,
             authorEffort: String, reviewerProvider: String, reviewerModel: String,
             reviewerEffort: String, state: String, rounds: Int, roundBudget: String,
             findings: [FindingRecord], findingsLeftStanding: Bool, gate: ItemGate,
             costUSD: Double, turns: Int, unreportedTurns: Int, stalled: Bool,
             failed: Bool, nonConvergenceNote: String? = nil,
             advisoryNotes: [String]? = nil, reassignAdvice: String? = nil,
             roundRecords: [RoundRecord] = [], roleSpend: RoleSpend? = nil) {
            self.title = title
            self.authorProvider = authorProvider
            self.authorModel = authorModel
            self.authorEffort = authorEffort
            self.reviewerProvider = reviewerProvider
            self.reviewerModel = reviewerModel
            self.reviewerEffort = reviewerEffort
            self.state = state
            self.rounds = rounds
            self.roundBudget = roundBudget
            self.findings = findings
            self.findingsLeftStanding = findingsLeftStanding
            self.gate = gate
            self.costUSD = costUSD
            self.turns = turns
            self.unreportedTurns = unreportedTurns
            self.stalled = stalled
            self.failed = failed
            self.nonConvergenceNote = nonConvergenceNote
            self.advisoryNotes = advisoryNotes
            self.reassignAdvice = reassignAdvice
            self.roundRecords = roundRecords
            self.roleSpend = roleSpend
        }
    }

    /// One finished orchestrator run — done, cancelled, or failed.
    struct RunOutcome: Equatable, Sendable {
        var date: Date
        var orchestratorProvider: String
        var orchestratorModel: String
        var orchestratorEffort: String
        var items: [ItemOutcome]
        /// SHA-256 of an imported `--orchestrate-log` file's bytes. Nil for live records.
        var importFingerprint: String?
        /// Absent on v1 lines ⇒ 1. New records write `currentSchemaVersion`.
        var schemaVersion: Int
        /// Reported dollars for the planning turn. Nil on v1 (unrecorded) and when
        /// this record has no planning figure (resume, or a turn that reported none).
        /// Never invented as 0.
        var planCostUSD: Double?
        /// True when this record includes a planning turn that reported no cost.
        /// False when a figure was reported, or when no planning turn ran (resume).
        /// Nil on v1 (unrecorded).
        var planUnreported: Bool?
        /// `"run"` or `"calibration"`. Absent on v1 lines ⇒ `"run"` (a real run).
        /// The seven backfilled Application Support records have no `kind` and
        /// must keep counting as real. Calibration records are excluded from
        /// `aggregate` and `recommendSeats`.
        var kind: String
        /// `{provider: version}` stamped from the toolchain sweep at run start.
        /// Nil / absent on v1 and v2 lines ⇒ unrecorded. Never an empty map
        /// presented as a measured fact.
        var cliVersions: [String: String]?

        var isCalibration: Bool { kind == TeamStats.kindCalibration }

        init(date: Date, orchestratorProvider: String, orchestratorModel: String,
             orchestratorEffort: String, items: [ItemOutcome],
             importFingerprint: String?,
             schemaVersion: Int = TeamStats.currentSchemaVersion,
             planCostUSD: Double? = nil, planUnreported: Bool? = nil,
             kind: String = TeamStats.kindRun,
             cliVersions: [String: String]? = nil) {
            self.date = date
            self.orchestratorProvider = orchestratorProvider
            self.orchestratorModel = orchestratorModel
            self.orchestratorEffort = orchestratorEffort
            self.items = items
            self.importFingerprint = importFingerprint
            self.schemaVersion = schemaVersion
            self.planCostUSD = planCostUSD
            self.planUnreported = planUnreported
            self.kind = kind
            self.cliVersions = cliVersions
        }
    }

    struct SeatKey: Hashable, Codable {
        let provider: String
        let role: String
        let model: String
    }

    struct SeatStats: Equatable {
        var items: Int = 0
        var cleanAccepts: Int = 0
        var acceptedWithObjections: Int = 0
        var failures: Int = 0
        var averageRounds: Double = 0
        var findingsRaisedWhileReviewing: Int = 0
        var findingsLeftStandingWhileAuthoring: Int = 0
        var gateFailures: Int = 0
        var totalCostUSD: Double = 0
        var turns: Int = 0
        /// Lane-derived author-role dollars on this seat. 0 when the row has no
        /// attributed author spend — including v1 rows, whose item-level cost is
        /// not a per-role claim (see `unattributableCostUSD`).
        var authorSpend: Double = 0
        /// Lane-derived reviewer-role dollars on this seat.
        var reviewSpend: Double = 0
        /// Dollars that are not a per-role claim: v1 item-level cost, plus
        /// orchestrator and system lane spend from v2 records. Parked on the
        /// author row so they are not dropped and not guessed onto a seat.
        var unattributableCostUSD: Double = 0
        /// Most common effort recorded on this seat. Ties break lexicographically
        /// ascending. `unrecorded` when nothing was stored — never a guessed default.
        var modalEffort: String = unrecorded
    }

    // MARK: Encoding

    /// Seconds-since-1970, set explicitly so a written record round-trips to an equal
    /// `Date` for whole-second (and binary64-exact) values. Never the encoder default.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private static let lock = NSLock()

    // MARK: Store

    /// Creates the directory and file if missing. Append-only: exactly one JSON line
    /// per run, newline-terminated. Never truncates, never rewrites, never throws.
    static func append(_ record: RunOutcome, to url: URL = storeURL) {
        lock.lock()
        defer { lock.unlock() }
        appendUnlocked(record, to: url)
    }

    private static func appendUnlocked(_ record: RunOutcome, to url: URL) {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            guard var line = try? encoder().encode(record) else { return }
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: line)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Recording must never throw into the run.
        }
    }

    /// Missing file → `([], 0)`. Blank lines are skipped without counting as corrupt
    /// so a trailing newline after a valid record is not an error. Non-empty lines
    /// that do not decode increment `corruptLines`. Never throws.
    static func load(from url: URL = storeURL) -> (records: [RunOutcome], corruptLines: Int) {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked(from: url)
    }

    private static func loadUnlocked(from url: URL) -> (records: [RunOutcome], corruptLines: Int) {
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        if data.isEmpty { return ([], 0) }
        var records: [RunOutcome] = []
        var corrupt = 0
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            var slice = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
            if slice.last == 0x0D { slice = slice.dropLast() }
            if slice.isEmpty || slice.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
            if let record = try? decoder().decode(RunOutcome.self, from: Data(slice)) {
                records.append(record)
            } else {
                corrupt += 1
            }
        }
        return (records, corrupt)
    }

    // MARK: Snapshot from a live engine

    /// Models and efforts are the values stamped when each session was preconfigured,
    /// not a fresh `resolvedModel` call at run end (overrides may have changed since).
    @MainActor
    static func outcome(from engine: Orchestrator, at date: Date = Date(),
                        importFingerprint: String? = nil) -> RunOutcome {
        let items: [ItemOutcome]
        let isResume = engine.teamStatsResumeBaseline != nil
        if let baseline = engine.teamStatsResumeBaseline {
            items = engine.items.filter { $0.id == baseline.itemID }.map {
                itemOutcome($0, resume: baseline)
            }
        } else {
            items = engine.items.map { itemOutcome($0, resume: nil) }
        }
        // Resume does not re-plan; copying engine.planCostUSD would double-count
        // the original run's planning spend. A planning turn that reported no
        // figure is planUnreported, not $0.
        let planCost: Double?
        let planUnreported: Bool?
        if isResume {
            planCost = nil
            planUnreported = false
        } else {
            planCost = engine.planCostUSD
            planUnreported = !engine.planRaw.isEmpty && engine.planCostUSD == nil
        }
        return RunOutcome(
            date: date,
            orchestratorProvider: recorded(engine.capturedOrchestratorProvider),
            orchestratorModel: recorded(engine.capturedOrchestratorModel),
            orchestratorEffort: recorded(engine.capturedOrchestratorEffort),
            items: items,
            importFingerprint: importFingerprint,
            planCostUSD: planCost,
            planUnreported: planUnreported,
            kind: engine.teamStatsKind,
            cliVersions: engine.capturedCLIVersions)
    }

    @MainActor
    private static func itemOutcome(_ item: WorkItem,
                                    resume: Orchestrator.TeamStatsResumeBaseline?) -> ItemOutcome {
        let findings: [FindingRecord]
        let rounds: Int
        let roundBudget: String
        let costUSD: Double
        let turns: Int
        let unreportedTurns: Int
        let stalled: Bool
        let gate: ItemGate
        let laneSlice: [LaneEntry]
        let fromRound: Int
        if let resume {
            findings = item.findings.filter { $0.round > resume.round }.map(findingRecord)
            rounds = max(0, item.round - resume.round)
            roundBudget = String(resume.extraRounds)
            costUSD = max(0, item.costUSD - resume.costUSD)
            turns = max(0, item.turns - resume.turns)
            unreportedTurns = max(0, item.unreportedTurns - resume.unreportedTurns)
            laneSlice = Array(item.lane.dropFirst(resume.laneCount))
            stalled = laneSlice.contains { $0.text.contains("[stalled") }
            gate = item.gate == resume.gate ? .notRun : ItemGate.from(item.gate)
            fromRound = resume.round + 1
        } else {
            findings = item.findings.map(findingRecord)
            rounds = item.round
            roundBudget = String(item.roundBudget)
            costUSD = item.costUSD
            turns = item.turns
            unreportedTurns = item.unreportedTurns
            laneSlice = item.lane
            stalled = laneSlice.contains { $0.text.contains("[stalled") }
            gate = ItemGate.from(item.gate)
            fromRound = 1
        }
        // Standing is "are findings still open on the item when the record is
        // taken". Resume used to also require `item.round > resume.round`, which
        // dropped the very objections that caused the resume when no new review
        // round had run. Rounds/cost/turns/lane/gate stay deltas against the
        // baseline. Matching for roundRecords uses the full finding list so a
        // new round can still see the previous round's objections.
        let standing = !item.openFindings.isEmpty
        let facts = laneSlice.map { LaneFact($0) }
        let records = roundRecords(
            findings: item.findings.map(findingRecord),
            lane: facts,
            fromRound: fromRound,
            throughRound: item.round)
        return ItemOutcome(
            title: item.title,
            authorProvider: item.author.rawValue,
            authorModel: recorded(item.authorModel),
            authorEffort: recorded(item.authorEffort),
            reviewerProvider: item.reviewer.rawValue,
            reviewerModel: recorded(item.reviewerModel),
            reviewerEffort: recorded(item.reviewerEffort),
            state: item.state.rawValue,
            rounds: rounds,
            roundBudget: roundBudget,
            findings: findings,
            findingsLeftStanding: standing,
            gate: gate,
            costUSD: costUSD,
            turns: turns,
            unreportedTurns: unreportedTurns,
            stalled: stalled,
            failed: item.state == .failed,
            nonConvergenceNote: item.nonConvergenceNote,
            advisoryNotes: item.advisoryNotes.isEmpty ? nil : item.advisoryNotes,
            reassignAdvice: item.reassignAdvice,
            roundRecords: records,
            roleSpend: roleSpend(from: facts))
    }

    private static func findingRecord(_ finding: ReviewFinding) -> FindingRecord {
        FindingRecord(round: finding.round, severity: finding.severity,
                      file: finding.file, line: finding.line, message: finding.message)
    }

    // MARK: Import from --orchestrate-log

    /// SHA-256 hex of the log file's bytes — the identity of an imported record.
    static func fingerprint(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Convert one `writeRunLog()` JSON object into a `RunOutcome`. Old logs have no
    /// session models, so every model and effort is `"unrecorded"` — never inferred.
    static func outcome(fromRunLog data: Data, fingerprint: String,
                        date: Date = Date()) -> RunOutcome? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = orchestrateLogItems(in: object) else { return nil }
        let items = rows.map { itemOutcome(fromRunLog: $0) }
        let planCost = double(object["planCostUSD"])
        let planRaw = string(object["planRaw"]) ?? ""
        return RunOutcome(
            date: date,
            orchestratorProvider: orchestratorProvider(in: rows),
            orchestratorModel: unrecorded,
            orchestratorEffort: unrecorded,
            items: items,
            importFingerprint: fingerprint,
            planCostUSD: planCost,
            planUnreported: !planRaw.isEmpty && planCost == nil)
    }

    /// Exact `writeRunLog()` shape. A phase plus a minimally named item is not enough:
    /// missing round / cost / turns / findings / lane (or the run-level totals) is
    /// rejected rather than filled in as zero.
    static func orchestrateLogItems(in data: Data) -> [[String: Any]]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return orchestrateLogItems(in: object)
    }

    private static func orchestrateLogItems(in object: [String: Any]) -> [[String: Any]]? {
        guard let phase = object["phase"] as? String, !phase.isEmpty else { return nil }
        guard object["planRaw"] is String else { return nil }
        guard object["planCostUSD"] != nil else { return nil }
        guard double(object["totalCostUSD"]) != nil else { return nil }
        guard int(object["totalTurns"]) != nil else { return nil }
        guard int(object["unreportedTurns"]) != nil else { return nil }
        guard let rows = object["items"] as? [[String: Any]] else { return nil }
        for row in rows {
            guard let title = string(row["title"]), !title.isEmpty,
                  let author = string(row["author"]), !author.isEmpty,
                  let reviewer = string(row["reviewer"]), !reviewer.isEmpty,
                  let state = string(row["state"]), !state.isEmpty,
                  int(row["round"]) != nil,
                  double(row["costUSD"]) != nil,
                  int(row["turns"]) != nil,
                  int(row["unreportedTurns"]) != nil,
                  jsonObjectArray(row["findings"]) != nil,
                  jsonObjectArray(row["lane"]) != nil,
                  jsonStringArray(row["filesTouched"]) != nil else {
                return nil
            }
        }
        return rows
    }

    private static func itemOutcome(fromRunLog row: [String: Any]) -> ItemOutcome {
        let rounds = int(row["round"]) ?? 0
        let findings = findings(from: row["findings"])
        let state = string(row["state"]) ?? unrecorded
        let standing = findings.contains { $0.round == rounds } && state != WorkItemState.accepted.rawValue
        let gate: ItemGate
        if let gateObject = row["gate"] as? [String: Any] {
            gate = ItemGate.fromRunLog(gateObject)
        } else {
            gate = .notRun
        }
        let facts = laneFacts(fromJSON: row["lane"])
        return ItemOutcome(
            title: string(row["title"]) ?? "",
            authorProvider: recorded(string(row["author"])),
            authorModel: unrecorded,
            authorEffort: unrecorded,
            reviewerProvider: recorded(string(row["reviewer"])),
            reviewerModel: unrecorded,
            reviewerEffort: unrecorded,
            state: state,
            rounds: rounds,
            roundBudget: int(row["roundBudget"]).map { String($0) } ?? unrecorded,
            findings: findings,
            findingsLeftStanding: standing,
            gate: gate,
            costUSD: double(row["costUSD"]) ?? 0,
            turns: int(row["turns"]) ?? 0,
            unreportedTurns: int(row["unreportedTurns"]) ?? 0,
            stalled: laneStalled(row["lane"]),
            failed: state == WorkItemState.failed.rawValue,
            roundRecords: roundRecords(findings: findings, lane: facts,
                                       fromRound: 1, throughRound: rounds),
            roleSpend: roleSpend(from: facts))
    }

    private static func orchestratorProvider(in items: [[String: Any]]) -> String {
        for item in items {
            guard let lane = item["lane"] as? [[String: Any]] else { continue }
            if let entry = lane.first(where: { string($0["role"]) == "orchestrator" }),
               let provider = string(entry["provider"]), !provider.isEmpty {
                return provider
            }
        }
        return unrecorded
    }

    private static func findings(from raw: Any?) -> [FindingRecord] {
        guard let rows = jsonObjectArray(raw) else { return [] }
        return rows.map { row in
            FindingRecord(round: int(row["round"]) ?? 0,
                          severity: string(row["severity"]) ?? "issue",
                          file: string(row["file"]) ?? "",
                          line: int(row["line"]),
                          message: string(row["message"]) ?? "")
        }
    }

    private static func laneStalled(_ raw: Any?) -> Bool {
        guard let lane = raw as? [[String: Any]] else { return false }
        return lane.contains { string($0["text"])?.contains("[stalled") == true }
    }

    /// Read one orchestrate-log JSON file, convert, append. Repeatable: the same bytes
    /// are not appended twice. Returns the one summary line the flag prints.
    static func importRunLog(from logURL: URL, into storeURL: URL = storeURL) -> String {
        let path = logURL.path
        guard let data = try? Data(contentsOf: logURL) else {
            return "import-run-log: file not found: \(path)"
        }
        let fingerprint = fingerprint(data)
        lock.lock()
        defer { lock.unlock() }
        let existing = loadUnlocked(from: storeURL).records
        if existing.contains(where: { $0.importFingerprint == fingerprint }) {
            return "already imported \(path)"
        }
        guard let outcome = outcome(fromRunLog: data, fingerprint: fingerprint) else {
            return "import-run-log: not an orchestrate-log: \(path)"
        }
        appendUnlocked(outcome, to: storeURL)
        let n = outcome.items.count
        return "imported 1 run, \(n) item\(n == 1 ? "" : "s") from \(path)"
    }

    // MARK: Aggregation

    private struct Acc {
        var stats = SeatStats()
        var roundsSum = 0
        var efforts: [String: Int] = [:]
    }

    /// Keyed by (provider, role, model). The same item contributes one author seat and
    /// one reviewer seat. `totalCostUSD` still accrues the item-level total to the
    /// author seat (v1 continuity). `authorSpend` / `reviewSpend` are the lane-derived
    /// per-role split; v1 rows have no split, so that money lands in
    /// `unattributableCostUSD` rather than being guessed onto a seat.
    /// `findingsRaisedWhileReviewing` accrues to the reviewer;
    /// `findingsLeftStandingWhileAuthoring` accrues to the author. Cancelled items
    /// count in `items` but as neither a clean accept nor a failure.
    /// Calibration records (`kind == "calibration"`) are excluded — they must not
    /// move real-world rates, recommendations, or drift. v1 lines with no `kind`
    /// count as real.
    static func aggregate(records: [RunOutcome]) -> [SeatKey: SeatStats] {
        aggregateUnfiltered(records.filter { !$0.isCalibration })
    }

    /// The calibration table only. Real-world records are excluded.
    static func aggregateCalibration(records: [RunOutcome]) -> [SeatKey: SeatStats] {
        aggregateUnfiltered(records.filter(\.isCalibration))
    }

    private static func aggregateUnfiltered(_ records: [RunOutcome]) -> [SeatKey: SeatStats] {
        var acc: [SeatKey: Acc] = [:]
        for record in records {
            for item in record.items {
                bump(item, role: "author", provider: item.authorProvider,
                     model: item.authorModel, into: &acc)
                bump(item, role: "reviewer", provider: item.reviewerProvider,
                     model: item.reviewerModel, into: &acc)
            }
            // Planning is a run-level orchestrator turn, not an item lane row.
            // v1 (both fields nil) is unrecorded — do not invent a $0 turn.
            // Resume records set planUnreported = false and planCostUSD = nil.
            if record.planCostUSD != nil || record.planUnreported == true {
                let key = SeatKey(provider: record.orchestratorProvider,
                                  role: "orchestrator",
                                  model: record.orchestratorModel)
                var entry = acc[key] ?? Acc()
                entry.stats.turns += 1
                entry.efforts[record.orchestratorEffort, default: 0] += 1
                if let cost = record.planCostUSD {
                    // Not author/reviewer spend. Visible on the orchestrator
                    // seat; items is not incremented — this is not a work item.
                    entry.stats.totalCostUSD += cost
                    entry.stats.unattributableCostUSD += cost
                }
                acc[key] = entry
            }
        }
        var result: [SeatKey: SeatStats] = [:]
        result.reserveCapacity(acc.count)
        for (key, value) in acc {
            var stats = value.stats
            stats.averageRounds = stats.items == 0
                ? 0 : Double(value.roundsSum) / Double(stats.items)
            stats.modalEffort = modalEffort(from: value.efforts)
            result[key] = stats
        }
        return result
    }

    /// Highest count wins; a count tie picks the lexicographically smaller effort
    /// string so the result is deterministic. Empty → `unrecorded`.
    private static func modalEffort(from counts: [String: Int]) -> String {
        guard let best = counts.max(by: { a, b in
            if a.value != b.value { return a.value < b.value }
            return a.key > b.key
        }) else { return unrecorded }
        return best.key
    }

    private static func bump(_ item: ItemOutcome, role: String, provider: String,
                             model: String, into acc: inout [SeatKey: Acc]) {
        let key = SeatKey(provider: provider, role: role, model: model)
        var entry = acc[key] ?? Acc()
        entry.stats.items += 1
        entry.roundsSum += item.rounds
        switch item.state {
        case WorkItemState.accepted.rawValue:
            entry.stats.cleanAccepts += 1
        case WorkItemState.acceptedWithObjections.rawValue:
            entry.stats.acceptedWithObjections += 1
        case WorkItemState.failed.rawValue:
            entry.stats.failures += 1
        default:
            break
        }
        if role == "reviewer" {
            entry.stats.findingsRaisedWhileReviewing +=
                item.findings.filter { $0.severity != "gate" }.count
        }
        if role == "author" {
            if item.findingsLeftStanding {
                // openFindings is `round == current absolute round`. Resume
                // records keep those absolute numbers on FindingRecord.round
                // while ItemOutcome.rounds is the delta, so comparing against
                // `item.rounds` drops every standing finding from a resumed
                // round (e.g. round 3 on a 1-round delta). The current round
                // of a record that still has objections is the highest round
                // present on its findings.
                let standingRound = item.findings.map(\.round).max() ?? item.rounds
                entry.stats.findingsLeftStandingWhileAuthoring +=
                    item.findings.filter { $0.round == standingRound }.count
            }
            if item.gate.hasFailure || item.gate.status == "fail" {
                entry.stats.gateFailures += 1
            }
            entry.stats.totalCostUSD += item.costUSD
            entry.stats.turns += item.turns
            if let spend = item.roleSpend {
                entry.stats.authorSpend += spend.authorUSD
                // Orchestrator and system turns belong to neither seat. Park
                // their reported dollars here so they are not dropped and are
                // not claimed as author or reviewer spend.
                entry.stats.unattributableCostUSD += spend.orchestratorUSD + spend.systemUSD
            } else {
                // v1: the item-level cost is unattributable per role.
                entry.stats.unattributableCostUSD += item.costUSD
            }
        }
        if role == "reviewer", let spend = item.roleSpend {
            entry.stats.reviewSpend += spend.reviewerUSD
        }
        let effort = role == "author" ? item.authorEffort : item.reviewerEffort
        entry.efforts[effort, default: 0] += 1
        acc[key] = entry
    }

    static func sortedSeats(_ aggregated: [SeatKey: SeatStats]) -> [(SeatKey, SeatStats)] {
        aggregated.sorted { a, b in
            let rateA = a.value.items == 0 ? 0.0
                : Double(a.value.cleanAccepts) / Double(a.value.items)
            let rateB = b.value.items == 0 ? 0.0
                : Double(b.value.cleanAccepts) / Double(b.value.items)
            if rateA != rateB { return rateA > rateB }
            if a.value.items != b.value.items { return a.value.items > b.value.items }
            if a.key.provider != b.key.provider { return a.key.provider < b.key.provider }
            if a.key.role != b.key.role { return a.key.role < b.key.role }
            return a.key.model < b.key.model
        }
    }

    /// Exact shape the Team stats UI renders, one space around the em dash and the
    /// middle dots. Provider is `Provider.displayName`; rounds to one decimal; cost
    /// to two decimals with a leading `$`.
    static func rowText(seat: SeatKey, stats: SeatStats) -> String {
        let name = Provider(rawValue: seat.provider)?.displayName ?? seat.provider
        let avg = String(format: "%.1f", stats.averageRounds)
        let cost = String(format: "$%.2f", stats.totalCostUSD)
        return "\(name) · \(seat.role) · \(seat.model) — \(stats.items) items, "
            + "\(stats.cleanAccepts) clean, avg \(avg) rounds, \(cost)"
    }

    /// One call for the pane: records loaded, aggregated, sorted, with the store's health.
    struct DisplayData {
        var seats: [(SeatKey, SeatStats)] = []
        var trends: [SeatKey: SeatTrend] = [:]
        /// Real-world runs only. Calibration records have their own count.
        var recordCount = 0
        var skippedLines = 0
        var calibrationSeats: [(SeatKey, SeatStats)] = []
        var calibrationRecordCount = 0
        /// Latest real run's CLI versions, or `unrecorded` when the field is absent.
        var latestCLIVersions: String = unrecorded

        func trend(for seat: SeatKey) -> SeatTrend {
            trends[seat] ?? .blank
        }
    }

    /// Nil or empty ⇒ `unrecorded`. Never presents `{}` as a measured fact.
    static func cliVersionsText(_ versions: [String: String]?) -> String {
        guard let versions, !versions.isEmpty else { return unrecorded }
        let text = Provider.allCases.compactMap { provider -> String? in
            guard let version = versions[provider.rawValue], !version.isEmpty else { return nil }
            return "\(provider.displayName) \(version)"
        }.joined(separator: " · ")
        return text.isEmpty ? unrecorded : text
    }

    static let calibrationHeader =
        "Calibration — isolated runs, not counted in real-world seats"

    static func calibrationFooter(_ count: Int) -> String {
        "\(count) calibration run(s) — excluded from seat recommendations and real-world totals"
    }

    static func loadForDisplay(from url: URL = storeURL) -> DisplayData {
        let (records, corrupt) = load(from: url)
        let real = records.filter { !$0.isCalibration }
        let cal = records.filter(\.isCalibration)
        let aggregated = aggregate(records: real)
        return DisplayData(seats: sortedSeats(aggregated),
                           trends: trends(records: real, aggregated: aggregated),
                           recordCount: real.count,
                           skippedLines: corrupt,
                           calibrationSeats: sortedSeats(aggregateCalibration(records: cal)),
                           calibrationRecordCount: cal.count,
                           latestCLIVersions: cliVersionsText(real.last?.cliVersions))
    }

    // MARK: Seat recommendations, trial seats, drift

    /// Eligible for a recommendation only with this many recorded items on the seat.
    /// Orchestrator planning turns do not increment `items`, so that role almost
    /// always lands in `needsData` rather than a guessed planning seat.
    static let recommendationItemFloor = 3

    /// Newest this many runs form the recent window compared against lifetime.
    static let recentRunWindow = 5

    /// A seat is judgeable only when it appears in at least this many of the
    /// last `recentRunWindow` runs. One run is not a trend.
    static let trendMinimumRecentRuns = 2

    /// Percentage-point gap between recent and lifetime clean-accept rates.
    /// Improving: recent − lifetime ≥ 0.10; declining: lifetime − recent ≥ 0.10;
    /// inside that band, with enough data: steady. Compared as rationals so
    /// 5/5 vs 9/10 is exactly 0.10 (not a binary-fraction near-miss).
    static let trendDeltaThreshold = 0.10

    /// One catalog (provider, model) pair actually available on this machine.
    struct CatalogSeat: Hashable, Equatable, Sendable {
        var provider: String
        var model: String
    }

    /// A concrete (provider, model, effort) pick plus how many items produced it.
    struct SeatPick: Equatable, Sendable {
        var provider: String
        var model: String
        var effort: String
        var sampleSize: Int
    }

    enum RoleAdvice: Equatable, Sendable {
        case recommended(SeatPick)
        /// No eligible seat for this role. `untested` is the installed+enabled
        /// catalog seats with fewer than `recommendationItemFloor` items on
        /// this role — including those with zero records. Never a guess.
        case needsData(untested: [CatalogSeat])
    }

    struct SeatRecommendations: Equatable, Sendable {
        var author: RoleAdvice
        var reviewer: RoleAdvice
        var orchestrator: RoleAdvice

        var hasAnyRecommendation: Bool {
            if case .recommended = author { return true }
            if case .recommended = reviewer { return true }
            if case .recommended = orchestrator { return true }
            return false
        }
    }

    /// Provider ids that a connected backend has actually listed. Empty for a
    /// provider that has not reported models — never filled from a static catalog.
    static func catalogSeats(reportedModels: [String: [String]]) -> Set<CatalogSeat> {
        var seats: Set<CatalogSeat> = []
        for (provider, models) in reportedModels {
            for model in models where !model.isEmpty {
                seats.insert(CatalogSeat(provider: provider, model: model))
            }
        }
        return seats
    }

    enum TrendKind: String, Equatable, Sendable {
        case improving, steady, declining, insufficient
    }

    struct SeatTrend: Equatable, Sendable {
        var kind: TrendKind
        var recentCleanAccepts: Int
        var recentItems: Int
        var lifetimeCleanAccepts: Int
        var lifetimeItems: Int

        static let blank = SeatTrend(kind: .insufficient,
                                     recentCleanAccepts: 0, recentItems: 0,
                                     lifetimeCleanAccepts: 0, lifetimeItems: 0)
    }

    /// Pure. Ranks eligible seats per role by (1) clean-accept rate descending,
    /// (2) average rounds ascending, (3) item count descending, (4) provider
    /// ascending, (5) model ascending. Effort is the seat's modal recorded
    /// effort, not a ranking key. Seats below `recommendationItemFloor` items,
    /// or whose (provider, model) is not in `installed`, are never recommended.
    /// `enabledWorkers` is the author worker pool. The orchestrator provider is
    /// eligible for reviewer and orchestrator roles only — it cannot author
    /// this run, so it is never an author suggestion.
    static func recommendSeats(stats: [SeatKey: SeatStats],
                               installed: Set<CatalogSeat>,
                               enabledWorkers: Set<String>,
                               orchestratorProvider: String? = nil) -> SeatRecommendations {
        SeatRecommendations(
            author: advise(role: "author", stats: stats, installed: installed,
                           enabledWorkers: enabledWorkers,
                           orchestratorProvider: orchestratorProvider),
            reviewer: advise(role: "reviewer", stats: stats, installed: installed,
                             enabledWorkers: enabledWorkers,
                             orchestratorProvider: orchestratorProvider),
            orchestrator: advise(role: "orchestrator", stats: stats,
                                 installed: installed, enabledWorkers: enabledWorkers,
                                 orchestratorProvider: orchestratorProvider))
    }

    /// Author: worker pool only. Reviewer / orchestrator: worker pool plus the
    /// current orchestrator (who can review and is already in that seat).
    static func providerAllowed(_ provider: String, role: String,
                                enabledWorkers: Set<String>,
                                orchestratorProvider: String?) -> Bool {
        if role == "author" {
            return enabledWorkers.contains(provider) && provider != orchestratorProvider
        }
        return enabledWorkers.contains(provider) || provider == orchestratorProvider
    }

    private static func advise(role: String,
                               stats: [SeatKey: SeatStats],
                               installed: Set<CatalogSeat>,
                               enabledWorkers: Set<String>,
                               orchestratorProvider: String?) -> RoleAdvice {
        let eligible = stats.filter { key, value in
            key.role == role
                && value.items >= recommendationItemFloor
                && providerAllowed(key.provider, role: role,
                                   enabledWorkers: enabledWorkers,
                                   orchestratorProvider: orchestratorProvider)
                && installed.contains(CatalogSeat(provider: key.provider, model: key.model))
        }
        if let winner = eligible.sorted(by: { a, b in
            seatOutranks(a.key, a.value, b.key, b.value)
        }).first {
            return .recommended(SeatPick(provider: winner.key.provider,
                                         model: winner.key.model,
                                         effort: winner.value.modalEffort,
                                         sampleSize: winner.value.items))
        }
        return .needsData(untested: untestedCatalogSeats(
            role: role, stats: stats, installed: installed,
            enabledWorkers: enabledWorkers, orchestratorProvider: orchestratorProvider))
    }

    /// true when `a` should rank above `b`.
    private static func seatOutranks(_ keyA: SeatKey, _ statsA: SeatStats,
                                     _ keyB: SeatKey, _ statsB: SeatStats) -> Bool {
        let rateA = statsA.items == 0 ? 0.0 : Double(statsA.cleanAccepts) / Double(statsA.items)
        let rateB = statsB.items == 0 ? 0.0 : Double(statsB.cleanAccepts) / Double(statsB.items)
        if rateA != rateB { return rateA > rateB }
        if statsA.averageRounds != statsB.averageRounds {
            return statsA.averageRounds < statsB.averageRounds
        }
        if statsA.items != statsB.items { return statsA.items > statsB.items }
        if keyA.provider != keyB.provider { return keyA.provider < keyB.provider }
        return keyA.model < keyB.model
    }

    private static func untestedCatalogSeats(role: String,
                                             stats: [SeatKey: SeatStats],
                                             installed: Set<CatalogSeat>,
                                             enabledWorkers: Set<String>,
                                             orchestratorProvider: String?) -> [CatalogSeat] {
        installed.filter { seat in
            guard providerAllowed(seat.provider, role: role,
                                  enabledWorkers: enabledWorkers,
                                  orchestratorProvider: orchestratorProvider)
            else { return false }
            let items = stats[SeatKey(provider: seat.provider, role: role,
                                      model: seat.model)]?.items ?? 0
            return items < recommendationItemFloor
        }
        .sorted { a, b in
            if a.provider != b.provider { return a.provider < b.provider }
            return a.model < b.model
        }
    }

    /// Catalog seats that are installed and enabled and have zero records on
    /// any role (items and turns both 0 / absent). Sorted provider, then model.
    static func untestedTrialSeats(stats: [SeatKey: SeatStats],
                                   installed: Set<CatalogSeat>,
                                   enabledWorkers: Set<String>,
                                   orchestratorProvider: String? = nil) -> [CatalogSeat] {
        installed.filter { seat in
            guard providerAllowed(seat.provider, role: "author",
                                  enabledWorkers: enabledWorkers,
                                  orchestratorProvider: orchestratorProvider)
            else { return false }
            return !stats.contains { key, value in
                key.provider == seat.provider && key.model == seat.model
                    && (value.items > 0 || value.turns > 0)
            }
        }
        .sorted { a, b in
            if a.provider != b.provider { return a.provider < b.provider }
            return a.model < b.model
        }
    }

    static func suggestionLine(_ rec: SeatRecommendations) -> String {
        "Suggested from your history: "
            + "author \(roleAdviceText(rec.author)); "
            + "reviewer \(roleAdviceText(rec.reviewer)); "
            + "orchestrator \(roleAdviceText(rec.orchestrator))"
    }

    static func trialLine(seat: CatalogSeat) -> String {
        let name = Provider(rawValue: seat.provider)?.displayName ?? seat.provider
        return "untested: \(name) · \(seat.model) as author — trial it this run?"
    }

    private static func roleAdviceText(_ advice: RoleAdvice) -> String {
        switch advice {
        case .recommended(let pick):
            let name = Provider(rawValue: pick.provider)?.displayName ?? pick.provider
            return "\(name) · \(pick.model) · \(pick.effort) (\(pick.sampleSize) items)"
        case .needsData(let untested):
            if untested.isEmpty {
                return "needs data (untested: none)"
            }
            let list = untested.map { seat -> String in
                let name = Provider(rawValue: seat.provider)?.displayName ?? seat.provider
                return "\(name) · \(seat.model)"
            }.joined(separator: ", ")
            return "needs data (untested: \(list))"
        }
    }

    /// Last `recentRunWindow` runs (newest by date; equal dates break by later
    /// file order) versus lifetime, per seat. A seat missing from the aggregate
    /// is omitted.
    static func trends(records: [RunOutcome],
                       aggregated: [SeatKey: SeatStats]? = nil) -> [SeatKey: SeatTrend] {
        // Calibration runs must not occupy the recent-5 window or the lifetime
        // rates. Filter first so a calibration stamp cannot look like drift.
        let records = records.filter { !$0.isCalibration }
        let lifetime = aggregated ?? aggregate(records: records)
        let ranked = records.enumerated().sorted { a, b in
            if a.element.date != b.element.date { return a.element.date > b.element.date }
            return a.offset > b.offset
        }
        let recentIdx = Set(ranked.prefix(recentRunWindow).map(\.offset))
        let recentRecords = records.enumerated().compactMap { recentIdx.contains($0.offset) ? $0.element : nil }
        let olderRecords = records.enumerated().compactMap { recentIdx.contains($0.offset) ? nil : $0.element }
        let recentStats = aggregate(records: recentRecords)
        var result: [SeatKey: SeatTrend] = [:]
        for (key, life) in lifetime {
            let recent = recentStats[key] ?? SeatStats()
            let recentRuns = recentRecords.filter { seat($0, includes: key) }.count
            let olderRuns = olderRecords.filter { seat($0, includes: key) }.count
            let kind = classifyTrend(recentCleanAccepts: recent.cleanAccepts,
                                     recentItems: recent.items,
                                     recentRuns: recentRuns,
                                     lifetimeCleanAccepts: life.cleanAccepts,
                                     lifetimeItems: life.items,
                                     olderRuns: olderRuns)
            result[key] = SeatTrend(kind: kind,
                                    recentCleanAccepts: recent.cleanAccepts,
                                    recentItems: recent.items,
                                    lifetimeCleanAccepts: life.cleanAccepts,
                                    lifetimeItems: life.items)
        }
        return result
    }

    /// Boundaries (audited): delta == 0.10 is improving, delta == −0.10 is
    /// declining, |delta| < 0.10 with enough data is steady. Fewer than
    /// `trendMinimumRecentRuns` recent runs, no older-window run, or a
    /// zero-item rate is insufficient — never labelled steady.
    static func classifyTrend(recentCleanAccepts: Int, recentItems: Int, recentRuns: Int,
                              lifetimeCleanAccepts: Int, lifetimeItems: Int,
                              olderRuns: Int) -> TrendKind {
        if recentRuns < trendMinimumRecentRuns || olderRuns < 1
            || recentItems < 1 || lifetimeItems < 1 {
            return .insufficient
        }
        // (recent − life) ≥ 1/10  ⇔  10·(rc·li − lc·ri) ≥ ri·li
        let num = recentCleanAccepts * lifetimeItems - lifetimeCleanAccepts * recentItems
        let den = recentItems * lifetimeItems
        if 10 * num >= den { return .improving }
        if 10 * num <= -den { return .declining }
        return .steady
    }

    private static func seat(_ record: RunOutcome, includes key: SeatKey) -> Bool {
        switch key.role {
        case "author":
            return record.items.contains {
                $0.authorProvider == key.provider && $0.authorModel == key.model
            }
        case "reviewer":
            return record.items.contains {
                $0.reviewerProvider == key.provider && $0.reviewerModel == key.model
            }
        case "orchestrator":
            return (record.planCostUSD != nil || record.planUnreported == true)
                && record.orchestratorProvider == key.provider
                && record.orchestratorModel == key.model
        default:
            return false
        }
    }

    /// `rowText` plus the trend marker and both windows that produced it.
    static func trendRowText(seat: SeatKey, stats: SeatStats, trend: SeatTrend) -> String {
        let base = rowText(seat: seat, stats: stats)
        let marker: String
        switch trend.kind {
        case .improving: marker = "improving"
        case .steady: marker = "steady"
        case .declining: marker = "declining"
        case .insufficient: marker = "insufficient recent data"
        }
        return "\(base) · \(marker) (recent \(trend.recentCleanAccepts)/\(trend.recentItems)"
            + " / life \(trend.lifetimeCleanAccepts)/\(trend.lifetimeItems))"
    }

    // MARK: Round records and role spend

    /// Matching rule for previous-round delta: a finding from round N−1 is still
    /// standing when some not-yet-matched finding in round N has the same `file`,
    /// `line`, and `message` (severity is not identity — a restated bug that
    /// changed severity is the same objection). Walk previous findings in stored
    /// order; each current finding matches at most once (greedy). Unmatched
    /// previous findings are resolved. Round 1 has no previous round, so both
    /// counts are 0.
    static func roundRecords(findings: [FindingRecord], lane: [LaneFact],
                             fromRound: Int, throughRound: Int) -> [RoundRecord] {
        guard throughRound >= fromRound, fromRound >= 1 else { return [] }
        var current = fromRound
        var revisionAt: Set<Int> = []
        var buckets: [Int: [LaneFact]] = [:]
        for fact in lane {
            if let n = trailingInt(after: "Review round ", in: fact.title) {
                current = n
                buckets[n, default: []].append(fact)
            } else if let k = trailingInt(after: "Revision after round ", in: fact.title) {
                let n = k + 1
                current = n
                revisionAt.insert(n)
                buckets[n, default: []].append(fact)
            } else {
                buckets[current, default: []].append(fact)
            }
        }
        return (fromRound...throughRound).map { index in
            let raised = findings.filter { $0.round == index }
            let previous = findings.filter { $0.round == index - 1 }
            // Round one has no previous round: everything raised is standing, nothing was
            // resolved, and no revision can be claimed — reviewer finding, run 12.
            let delta = index == fromRound
                ? (resolved: 0, standing: raised.count)
                : previousRoundDelta(previous: previous, current: raised)
            var severities: [String: Int] = [:]
            for finding in raised { severities[finding.severity, default: 0] += 1 }
            let facts = buckets[index] ?? []
            return RoundRecord(
                index: index,
                findingsRaised: raised.count,
                severities: severities,
                previousResolved: delta.resolved,
                previousStillStanding: delta.standing,
                // A revision only counts when the author actually touched files that turn —
                // a no-op reply with the right lane title is not a revision.
                authorRevisionPresent: revisionAt.contains(index)
                    && facts.contains { $0.role == "author" && $0.editedFileCount > 0 },
                wallClockSeconds: wallClockSeconds(facts),
                stallEvents: facts.filter { $0.text.contains("[stalled") }.count,
                costByProvider: costByProvider(facts),
                unreportedTurnsByProvider: unreportedTurnsByProvider(facts))
        }
    }

    static func roleSpend(from lane: [LaneFact]) -> RoleSpend {
        var spend = RoleSpend(authorUSD: 0, reviewerUSD: 0,
                              orchestratorUSD: 0, systemUSD: 0)
        for fact in lane {
            let dollars = fact.costUSD ?? 0
            switch fact.role {
            case "author": spend.authorUSD += dollars
            case "reviewer": spend.reviewerUSD += dollars
            case "orchestrator": spend.orchestratorUSD += dollars
            default: spend.systemUSD += dollars
            }
        }
        return spend
    }

    private static func previousRoundDelta(previous: [FindingRecord],
                                           current: [FindingRecord])
        -> (resolved: Int, standing: Int) {
        var used = Array(repeating: false, count: current.count)
        var standing = 0
        for prev in previous {
            if let idx = current.indices.first(where: { i in
                !used[i] && findingsMatch(prev, current[i])
            }) {
                used[idx] = true
                standing += 1
            }
        }
        return (previous.count - standing, standing)
    }

    private static func findingsMatch(_ a: FindingRecord, _ b: FindingRecord) -> Bool {
        a.file == b.file && a.line == b.line && a.message == b.message
    }

    private static func trailingInt(after prefix: String, in title: String) -> Int? {
        guard title.hasPrefix(prefix) else { return nil }
        let rest = title.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(rest)
    }

    private static func wallClockSeconds(_ facts: [LaneFact]) -> Double? {
        // Span is first turn start → last turn end. `at` alone at finish time
        // would start the next round after its author revision had already
        // ended. Missing timestamps (imported logs) ⇒ unrecorded, never 0.
        let starts = facts.compactMap(\.at)
        guard !facts.isEmpty, starts.count == facts.count,
              let first = starts.min() else { return nil }
        let ends = facts.map { $0.endedAt ?? $0.at! }
        guard let last = ends.max() else { return nil }
        return last.timeIntervalSince(first)
    }

    private static func costByProvider(_ facts: [LaneFact]) -> [String: Double] {
        var costs: [String: Double] = [:]
        for fact in facts {
            if let cost = fact.costUSD {
                costs[fact.provider, default: 0] += cost
            }
        }
        return costs
    }

    private static func unreportedTurnsByProvider(_ facts: [LaneFact]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for fact in facts where fact.costUSD == nil && isTurn(role: fact.role, title: fact.title) {
            counts[fact.provider, default: 0] += 1
        }
        return counts
    }

    /// Brief and system notes are lane rows, not turns. Unreported-turn counts
    /// follow the same distinction the engine already draws.
    private static func isTurn(role: String, title: String) -> Bool {
        switch role {
        case "author", "reviewer": return true
        case "orchestrator": return title != "Brief"
        default: return false
        }
    }

    private static func laneFacts(fromJSON raw: Any?) -> [LaneFact] {
        guard let rows = jsonObjectArray(raw) else { return [] }
        return rows.map { row in
            LaneFact(provider: string(row["provider"]) ?? unrecorded,
                     role: string(row["role"]) ?? unrecorded,
                     title: string(row["title"]) ?? "",
                     text: string(row["text"]) ?? "",
                     costUSD: double(row["costUSD"]),
                     at: nil, endedAt: nil)
        }
    }

    // MARK: JSON object helpers (run-log import)

    /// Array of JSON objects, or nil when the value is missing, not an array,
    /// or contains a non-object element. Empty arrays are valid.
    private static func jsonObjectArray(_ value: Any?) -> [[String: Any]]? {
        guard let items = value as? [Any] else { return nil }
        var rows: [[String: Any]] = []
        rows.reserveCapacity(items.count)
        for item in items {
            guard let row = item as? [String: Any] else { return nil }
            rows.append(row)
        }
        return rows
    }

    /// Array of JSON strings, or nil when the value is missing, not an array,
    /// or contains a non-string element. Empty arrays are valid.
    private static func jsonStringArray(_ value: Any?) -> [String]? {
        guard let items = value as? [Any] else { return nil }
        var rows: [String] = []
        rows.reserveCapacity(items.count)
        for item in items {
            guard let row = item as? String else { return nil }
            rows.append(row)
        }
        return rows
    }

    private static func string(_ value: Any?) -> String? {
        if value == nil || value is NSNull { return nil }
        return value as? String
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if value == nil || value is NSNull { return nil }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.intValue
        }
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func int32(_ value: Any?) -> Int32? {
        guard let value = int(value) else { return nil }
        return Int32(value)
    }

    private static func double(_ value: Any?) -> Double? {
        if value == nil || value is NSNull { return nil }
        if let d = value as? Double { return d }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.doubleValue
        }
        return nil
    }
}

extension TeamStats.ItemOutcome: Codable {
    enum CodingKeys: String, CodingKey {
        case title, authorProvider, authorModel, authorEffort
        case reviewerProvider, reviewerModel, reviewerEffort
        case state, rounds, roundBudget, findings, findingsLeftStanding
        case gate, costUSD, turns, unreportedTurns, stalled, failed
        case roundRecords, roleSpend
        case nonConvergenceNote, advisoryNotes, reassignAdvice
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        authorProvider = try c.decode(String.self, forKey: .authorProvider)
        authorModel = try c.decode(String.self, forKey: .authorModel)
        authorEffort = try c.decode(String.self, forKey: .authorEffort)
        reviewerProvider = try c.decode(String.self, forKey: .reviewerProvider)
        reviewerModel = try c.decode(String.self, forKey: .reviewerModel)
        reviewerEffort = try c.decode(String.self, forKey: .reviewerEffort)
        state = try c.decode(String.self, forKey: .state)
        rounds = try c.decode(Int.self, forKey: .rounds)
        roundBudget = try c.decode(String.self, forKey: .roundBudget)
        findings = try c.decode([TeamStats.FindingRecord].self, forKey: .findings)
        findingsLeftStanding = try c.decode(Bool.self, forKey: .findingsLeftStanding)
        gate = try c.decode(TeamStats.ItemGate.self, forKey: .gate)
        costUSD = try c.decode(Double.self, forKey: .costUSD)
        turns = try c.decode(Int.self, forKey: .turns)
        unreportedTurns = try c.decode(Int.self, forKey: .unreportedTurns)
        stalled = try c.decode(Bool.self, forKey: .stalled)
        failed = try c.decode(Bool.self, forKey: .failed)
        // v1 lines omit these; empty / nil is unrecorded, never an invented zero.
        roundRecords = try c.decodeIfPresent([TeamStats.RoundRecord].self,
                                             forKey: .roundRecords) ?? []
        roleSpend = try c.decodeIfPresent(TeamStats.RoleSpend.self, forKey: .roleSpend)
        nonConvergenceNote = try c.decodeIfPresent(String.self, forKey: .nonConvergenceNote)
        advisoryNotes = try c.decodeIfPresent([String].self, forKey: .advisoryNotes)
        reassignAdvice = try c.decodeIfPresent(String.self, forKey: .reassignAdvice)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(authorProvider, forKey: .authorProvider)
        try c.encode(authorModel, forKey: .authorModel)
        try c.encode(authorEffort, forKey: .authorEffort)
        try c.encode(reviewerProvider, forKey: .reviewerProvider)
        try c.encode(reviewerModel, forKey: .reviewerModel)
        try c.encode(reviewerEffort, forKey: .reviewerEffort)
        try c.encode(state, forKey: .state)
        try c.encode(rounds, forKey: .rounds)
        try c.encode(roundBudget, forKey: .roundBudget)
        try c.encode(findings, forKey: .findings)
        try c.encode(findingsLeftStanding, forKey: .findingsLeftStanding)
        try c.encode(gate, forKey: .gate)
        try c.encode(costUSD, forKey: .costUSD)
        try c.encode(turns, forKey: .turns)
        try c.encode(unreportedTurns, forKey: .unreportedTurns)
        try c.encode(stalled, forKey: .stalled)
        try c.encode(failed, forKey: .failed)
        try c.encode(roundRecords, forKey: .roundRecords)
        try c.encodeIfPresent(roleSpend, forKey: .roleSpend)
        try c.encodeIfPresent(nonConvergenceNote, forKey: .nonConvergenceNote)
        try c.encodeIfPresent(advisoryNotes, forKey: .advisoryNotes)
        try c.encodeIfPresent(reassignAdvice, forKey: .reassignAdvice)
    }
}

extension TeamStats.RunOutcome: Codable {
    enum CodingKeys: String, CodingKey {
        case date, orchestratorProvider, orchestratorModel, orchestratorEffort
        case items, importFingerprint, schemaVersion, planCostUSD, planUnreported
        case kind, cliVersions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        orchestratorProvider = try c.decode(String.self, forKey: .orchestratorProvider)
        orchestratorModel = try c.decode(String.self, forKey: .orchestratorModel)
        orchestratorEffort = try c.decode(String.self, forKey: .orchestratorEffort)
        items = try c.decode([TeamStats.ItemOutcome].self, forKey: .items)
        importFingerprint = try c.decodeIfPresent(String.self, forKey: .importFingerprint)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        planCostUSD = try c.decodeIfPresent(Double.self, forKey: .planCostUSD)
        planUnreported = try c.decodeIfPresent(Bool.self, forKey: .planUnreported)
        // v1 lines omit kind ⇒ a real run, never a guessed calibration.
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? TeamStats.kindRun
        // v1/v2 omit cliVersions ⇒ unrecorded, never an empty map as fact.
        cliVersions = try c.decodeIfPresent([String: String].self, forKey: .cliVersions)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(orchestratorProvider, forKey: .orchestratorProvider)
        try c.encode(orchestratorModel, forKey: .orchestratorModel)
        try c.encode(orchestratorEffort, forKey: .orchestratorEffort)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(importFingerprint, forKey: .importFingerprint)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(planCostUSD, forKey: .planCostUSD)
        try c.encodeIfPresent(planUnreported, forKey: .planUnreported)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(cliVersions, forKey: .cliVersions)
    }
}

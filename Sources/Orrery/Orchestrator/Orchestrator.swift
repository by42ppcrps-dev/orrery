import Foundation
import Observation

// MARK: - Work items

/// One reported problem from a review round. `file` is what the reviewer wrote — resolved
/// against the project when clicked.
struct ReviewFinding: Identifiable, Equatable {
    let id = UUID()
    var file: String
    var line: Int?
    var severity: String
    var message: String
    var round: Int
}

/// One attributed exchange inside a work item's lane, so the whole conversation is readable
/// per item, not interleaved across the run.
struct LaneEntry: Identifiable, Equatable {
    let id = UUID()
    var provider: Provider
    var role: String          // "orchestrator", "author", "reviewer", "system"
    var title: String
    var text: String
    var costUSD: Double?
    /// Files this turn actually edited — 0 for notes, reviews, and no-op "revisions".
    var editedFileCount: Int = 0
    /// When this turn started. Default is append time, which is correct for
    /// instantaneous notes (brief, gate). Recorded turns pass the send() start
    /// so a later round's wall-clock includes the author revision, not just
    /// the gap after it finished.
    var at: Date = Date()
    /// When this turn ended. Nil means a point-in-time row (`at`). Recorded
    /// turns pass `Date()` at record time.
    var endedAt: Date? = nil
}

/// What an in-flight turn is doing right now — streamed into the pane so a long authoring
/// turn is watchable, not a black box until it lands.
struct LiveTurn: Equatable {
    var provider: Provider
    var role: String
    var startedAt = Date()
    var lastEventAt = Date()
    /// Tail of the streamed reply text.
    var text = ""
    /// Rolling list of the most recent tool calls, latest last.
    var tools: [String] = []
    var thinkingCharacters = 0
    /// Latest streamed `FileDiff` this turn. Nil together with a nil `editedPath` means no
    /// edit has arrived yet.
    var diff: FileDiff?
    /// Path of the latest edit this turn, when one has been seen.
    var editedPath: String?
    /// True only after an edit tool *finished* without a FileDiff. An in-progress status
    /// update with no patch yet is not this — Grok streams the diff on a later event.
    var diffUnavailable = false
}

/// Line-level unified diff for the live turn view. Prefix/suffix trim on the whole file,
/// then LCS on a bounded window of the changed middle, so a large file cannot turn into
/// a quadratic pause — and an edit past the first few thousand lines is still found.
enum LiveDiff {
    static let renderedLineCap = 40
    private static let lcsCellCap = 40_000
    private static let lcsSideLimit = 200
    private static let contextLines = 2

    static func render(_ diff: FileDiff, maxLines: Int = renderedLineCap) -> [String] {
        let built = build(old: diff.oldText, new: diff.newText)
        if built.total <= maxLines { return built.lines }
        let kept = Array(built.lines.prefix(maxLines))
        return kept + ["… \(built.total - kept.count) more lines"]
    }

    static func lines(old: String, new: String) -> [String] {
        build(old: old, new: new).lines
    }

    private struct Built {
        var lines: [String]
        var total: Int
    }

    private static func build(old: String, new: String) -> Built {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)
        if oldLines == newLines { return Built(lines: [], total: 0) }

        var prefix = 0
        let shared = min(oldLines.count, newLines.count)
        while prefix < shared && oldLines[prefix] == newLines[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < (oldLines.count - prefix) && suffix < (newLines.count - prefix)
                && oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        let oldMidRaw = Array(oldLines[prefix..<(oldLines.count - suffix)])
        let newMidRaw = Array(newLines[prefix..<(newLines.count - suffix)])
        let truncated = oldMidRaw.count * newMidRaw.count > lcsCellCap
        let oldMid: [String]
        let newMid: [String]
        if truncated {
            // Keep the DP off huge middles: first-difference window only.
            oldMid = Array(oldMidRaw.prefix(lcsSideLimit))
            newMid = Array(newMidRaw.prefix(lcsSideLimit))
        } else {
            oldMid = oldMidRaw
            newMid = newMidRaw
        }

        let ctx = contextLines
        let prefixFrom = max(0, prefix - ctx)
        let prefixContext = Array(oldLines[prefixFrom..<prefix])
        let suffixContext: [String]
        if truncated || suffix == 0 {
            suffixContext = []
        } else {
            let suffixStart = oldLines.count - suffix
            suffixContext = Array(oldLines[suffixStart..<(suffixStart + min(ctx, suffix))])
        }

        let oldStart = prefixFrom + 1
        let newStart = prefixFrom + 1
        let oldCount = prefixContext.count + oldMid.count + suffixContext.count
        let newCount = prefixContext.count + newMid.count + suffixContext.count

        var out: [String] = []
        out.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
        for line in prefixContext { out.append(" \(line)") }
        for op in lcsOps(old: oldMid, new: newMid) {
            switch op {
            case let .equal(line): out.append(" \(line)")
            case let .delete(line): out.append("-\(line)")
            case let .insert(line): out.append("+\(line)")
            }
        }
        for line in suffixContext { out.append(" \(line)") }
        // Remainder is against the real middle, not the LCS window: a 600-line rewrite
        // is ~1200 changed lines even though we only LCS the first 200 of each side.
        let total = truncated
            ? 1 + prefixContext.count + oldMidRaw.count + newMidRaw.count
            : out.count
        return Built(lines: out, total: total)
    }

    private enum Op { case equal(String), insert(String), delete(String) }

    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.last == "\r" ? String(line.dropLast()) : String(line)
        }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func lcsOps(old: [String], new: [String]) -> [Op] {
        let n = old.count, m = new.count
        if n == 0 { return new.map { .insert($0) } }
        if m == 0 { return old.map { .delete($0) } }
        if n * m > lcsCellCap {
            return old.map { .delete($0) } + new.map { .insert($0) }
        }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                if old[i - 1] == new[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, old[i - 1] == new[j - 1] {
                ops.append(.equal(old[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || dp[i][j - 1] >= dp[i - 1][j] {
                ops.append(.insert(new[j - 1]))
                j -= 1
            } else {
                ops.append(.delete(old[i - 1]))
                i -= 1
            }
        }
        return ops.reversed()
    }
}

/// Which seat a session is opened for — model/effort can differ per seat.
enum SessionRole: String, CaseIterable {
    case orchestrator, author, reviewer
}

enum WorkItemState: String {
    case pending, authoring, reviewing, revising
    case accepted                   // reviewer had nothing left
    case acceptedWithObjections     // round cap hit; the reviewer's objections stand, visibly
    case notConverging              // identical rounds: the author is spending budget on nothing
    case failed, cancelled

    var isTerminal: Bool {
        switch self {
        case .accepted, .acceptedWithObjections, .notConverging, .failed, .cancelled:
            return true
        default: return false
        }
    }
}

/// Colour the work-item card badge consults. Shared by the view and the audit so a red
/// gate can never be presented as a green accept.
enum WorkItemBadgeKind: Equatable {
    case secondary, orange, green, yellow, red
}

/// One diagnostic parsed from a gate task's output. Paths are stored as strings so the
/// card can resolve them the same way it resolves findings.
struct GateDiagnostic: Equatable {
    var file: String
    var line: Int?
    var column: Int?
    var severity: String
    var message: String
}

/// One build or test task the acceptance gate ran — or skipped, honestly.
struct GateTaskResult: Identifiable, Equatable {
    let id = UUID()
    var taskID: String
    var title: String
    var passed: Bool
    var exitCode: Int32?
    var timedOut: Bool
    var skippedMissingTool: Bool
    var missingTool: String?
    var outputTail: String
    /// Taken from the full output (or a parsed diagnostic), never from the truncated tail.
    var firstErrorLine: String = ""
    var diagnostics: [GateDiagnostic]
}

/// The acceptance gate's record on a work item. `passed` is true only when at least one
/// task actually ran and every executed task exited 0. A skip is never a pass.
struct GateResult: Equatable {
    static let outputTailLimit = 4_000
    static let diagnosticCap = 20

    var tasks: [GateTaskResult]

    var hasExecuted: Bool { tasks.contains { !$0.skippedMissingTool } }
    var hasFailure: Bool { tasks.contains { !$0.skippedMissingTool && !$0.passed } }
    var passed: Bool { hasExecuted && !hasFailure }

    var jsonObject: [String: Any] {
        [
            "passed": passed,
            "tasks": tasks.map { task -> [String: Any] in
                [
                    "id": task.taskID,
                    "title": task.title,
                    "passed": task.passed,
                    "exitCode": task.exitCode.map { Int($0) as Any } ?? NSNull(),
                    "timedOut": task.timedOut,
                    "skippedMissingTool": task.skippedMissingTool,
                    "missingTool": task.missingTool.map { $0 as Any } ?? NSNull(),
                    "outputTail": task.outputTail,
                    "firstErrorLine": task.firstErrorLine,
                    "diagnostics": task.diagnostics.map { diag -> [String: Any] in
                        ["file": diag.file,
                         "line": diag.line.map { $0 as Any } ?? NSNull(),
                         "column": diag.column.map { $0 as Any } ?? NSNull(),
                         "severity": diag.severity,
                         "message": diag.message]
                    },
                ]
            },
        ]
    }

    static func tail(of output: String) -> String {
        if output.count <= outputTailLimit { return output }
        var slice = String(output.suffix(outputTailLimit))
        // Drop a mid-line fragment at the cut so the stored tail is whole lines.
        if let newline = slice.firstIndex(of: "\n") {
            slice = String(slice[slice.index(after: newline)...])
        }
        return slice
    }

    /// Parse diagnostics, first-error line, and a bounded tail. Not MainActor: a 50 k-line
    /// build log must not hitch the window. Call from a detached task.
    static func scan(_ output: String, directory: URL)
        -> (tail: String, firstErrorLine: String, diagnostics: [GateDiagnostic]) {
        var diagnostics: [GateDiagnostic] = []
        var firstNonEmpty: String?
        var firstErrorLike: String?
        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return }
            if firstNonEmpty == nil { firstNonEmpty = trimmed }
            if firstErrorLike == nil, looksLikeError(trimmed) { firstErrorLike = trimmed }
            if diagnostics.count < diagnosticCap,
               let diagnostic = TaskOutputParser.diagnostic(for: line, directory: directory) {
                diagnostics.append(GateDiagnostic(
                    file: diagnostic.file.path, line: diagnostic.line,
                    column: diagnostic.column, severity: diagnostic.severity.rawValue,
                    message: diagnostic.message))
            }
        }
        let firstError = (diagnostics.first { $0.severity == "error" } ?? diagnostics.first)
            .map(\.message)
            ?? firstErrorLike
            ?? firstNonEmpty
            ?? ""
        return (tail(of: output), firstError, diagnostics)
    }

    private static func looksLikeError(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("error:") || lower.contains("fatal error")
            || lower.hasPrefix("fail") || lower.contains("undefined reference")
    }
}

@MainActor
@Observable
final class WorkItem: Identifiable {
    let id = UUID()
    var title: String
    var brief: String
    var author: Provider
    var reviewer: Provider
    var state: WorkItemState = .pending
    /// Completed review passes. Round 1 is the first review of the fresh work.
    var round = 0
    var filesTouched: [String] = []
    var findings: [ReviewFinding] = []
    var lane: [LaneEntry] = []
    var costUSD: Double = 0
    var turns = 0
    /// Turns whose backend reported no cost — shown, never silently folded into $0.
    var unreportedTurns = 0
    /// Review passes this item is budgeted for. From the plan's `rounds` when present
    /// (clamped 1...5), otherwise the engine's `maxRounds` at plan time.
    var roundBudget = 2
    /// Parsed extra-round count from `RECOMMEND: <N> more rounds:`. 0 is 0, not accept.
    /// Nil when the reply was accept, or did not parse — never invented.
    var recommendedExtraRounds: Int?
    /// True only when the reply was `RECOMMEND: accept:` — a different form from 0 more rounds.
    var recommendationAccepts = false
    /// Parsed why-line, or the verbatim unparseable reply.
    var recommendationReason: String?
    /// User chose to live with the standing objections rather than grant more rounds.
    var objectionsDismissedByUser = false
    /// Set while a turn for this item is in flight; the card renders it live.
    var live: LiveTurn?
    /// Why the loop stopped early, when it did — shown on the card, recorded to the store.
    var nonConvergenceNote: String?
    /// Non-blocking reviewer notes from scoped grant re-reviews. Visible, never gating.
    var advisoryNotes: [String] = []
    /// The seat the orchestrator (or the analytics) suggests retrying with after a
    /// non-convergence stop.
    var reassignAdvice: String?
    /// Last acceptance-gate record. Nil when the gate was switched off or has not run.
    var gate: GateResult?
    /// True while build/test processes for this item are in flight.
    var isGating = false
    /// Model/effort the author session was actually `preconfigure`d with — captured
    /// at session open, not re-resolved at run end.
    var authorModel = TeamStats.unrecorded
    var authorEffort = TeamStats.unrecorded
    /// Same stamp for the reviewer session.
    var reviewerModel = TeamStats.unrecorded
    var reviewerEffort = TeamStats.unrecorded

    init(title: String, brief: String, author: Provider, reviewer: Provider,
         roundBudget: Int = 2) {
        self.title = title
        self.brief = brief
        self.author = author
        self.reviewer = reviewer
        self.roundBudget = roundBudget
    }

    var openFindings: [ReviewFinding] { findings.filter { $0.round == round } }

    /// Review passes still allowed before the lifetime cap. 0 means no further grants.
    var remainingLifetimeRounds: Int {
        max(0, Orchestrator.lifetimeReviewRoundCap - round)
    }
    /// Stepper upper bound: at most 5, and never more than the lifetime remainder.
    var grantableExtraRounds: Int {
        min(5, remainingLifetimeRounds)
    }

    /// The words the card shows for the orchestrator's recommendation. Accept and
    /// "0 more rounds" are different sentences; neither is rewritten as the other.
    var recommendationLineText: String? {
        if recommendationAccepts {
            return "Recommendation: accept: \(recommendationReason ?? "")"
        }
        if let n = recommendedExtraRounds {
            return "Recommendation: \(n) more rounds: \(recommendationReason ?? "")"
        }
        if let reason = recommendationReason {
            return "Unparseable recommendation (verbatim): \(reason)"
        }
        return nil
    }

    /// Words the card badge shows. A red gate is never presented as a green accept,
    /// but an in-flight or stopped item is not frozen on "gate failed".
    var cardStateText: String {
        if isGating { return "running build & tests…" }
        switch state {
        case .pending: return "waiting"
        case .authoring: return "\(author.displayName) is writing…"
        case .reviewing: return "\(reviewer.displayName) is reviewing…"
        case .revising: return "\(author.displayName) is revising…"
        case .accepted:
            if gate?.hasFailure == true { return "gate failed" }
            if gate?.passed == true { return "gate passed" }
            return "accepted — reviewer had nothing left"
        case .acceptedWithObjections:
            if gate?.hasFailure == true { return "gate failed" }
            if objectionsDismissedByUser {
                return "accepted by you — objections noted"
            }
            return "round cap hit — the reviewer's objections stand below"
        case .notConverging:
            if gate?.hasFailure == true { return "gate failed" }
            return nonConvergenceNote ?? "stopped — author not converging"
        case .failed: return "failed"
        case .cancelled: return "stopped"
        }
    }

    /// Colour the card badge uses. Consulted by the view and the audit together.
    var cardBadgeKind: WorkItemBadgeKind {
        if isGating { return .orange }
        switch state {
        case .pending: return .secondary
        case .authoring, .reviewing, .revising: return .orange
        case .accepted:
            return gate?.hasFailure == true ? .red : .green
        case .acceptedWithObjections:
            return gate?.hasFailure == true ? .red : .yellow
        case .notConverging: return .red
        case .failed, .cancelled: return .red
        }
    }
}

// MARK: - Turn collection

/// Wraps one backend session and turns its event stream into awaitable turns: send a prompt,
/// get back the reply text, the files its edit tools touched, and the cost.
@MainActor
final class TurnCollector {
    struct TurnResult {
        var text = ""
        var editedFiles: [String] = []
        var costUSD: Double?
        var stopReason: String?
        var failureMessage: String?
        var timedOut = false
        var autoApprovals: [String] = []
        var startedAt = Date()
        var failed: Bool { failureMessage != nil || timedOut }
    }

    let backend: any AgentBackend
    let provider: Provider
    /// The provider's own session id, once connected; what a later collector can resume.
    private(set) var sessionID: String?
    /// True when the backend reported that a session it was asked to resume is gone.
    private(set) var sessionDropped = false
    /// Every backend event, as it arrives — the live view taps this.
    var onActivity: ((BackendEvent) -> Void)?
    var hasReceivedTaskContext = false
    private var current = TurnResult()
    private var continuation: CheckedContinuation<TurnResult, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var lastActivity = Date()
    private var stallLimit: TimeInterval = 300
    var autoApprove = false
    var onPermission: ((PermissionRequest, Provider) -> Void)?
    var onPermissionEnded: ((UUID) -> Void)?
    private var waitingPermissions: Set<UUID> = []

    init(backend: any AgentBackend, provider: Provider) {
        self.backend = backend
        self.provider = provider
        backend.onEvent = { [weak self] event in self?.handle(event) }
    }

    func start(project: URL) async {
        await backend.start(project: project, autoApprove: autoApprove)
    }

    func stop() {
        for id in waitingPermissions { onPermissionEnded?(id) }
        waitingPermissions.removeAll()
        backend.cancel()
        backend.stop()
        finish()   // anyone awaiting gets what was collected, marked failed
    }

    /// `stallTimeout` is a silence deadline, not a total one: a turn that keeps producing
    /// events — tool calls, edits, streamed text or thinking — runs for as long as it needs.
    /// Only an agent that has gone completely quiet for this long is declared stalled. Found
    /// by use: a wall-clock cap killed a Grok turn that had just finished writing a whole
    /// feature.
    func send(_ prompt: String, stallTimeout: TimeInterval) async -> TurnResult {
        current = TurnResult()
        lastActivity = Date()
        stallLimit = stallTimeout
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                while true {
                    let pause = max(0.05, stallTimeout / 8)
                    try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                    guard let self, self.continuation != nil, !Task.isCancelled else { return }
                    if self.waitingPermissions.isEmpty && Date().timeIntervalSince(self.lastActivity) > stallTimeout {
                        self.current.timedOut = true
                        self.backend.cancel()
                        self.finish()
                        return
                    }
                }
            }
            Task { await self.backend.send(prompt) }
        }
    }

    private func finish() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let continuation {
            self.continuation = nil
            if current.failureMessage == nil && current.timedOut {
                current.failureMessage = "went silent — no activity for "
                    + "\(Int(stallLimit))s, so the stall deadline ended the turn"
            }
            continuation.resume(returning: current)
        }
    }

    private func handle(_ event: BackendEvent) {
        lastActivity = Date()
        onActivity?(event)
        switch event {
        case let .connected(id):
            sessionID = id
        case .sessionDropped:
            sessionDropped = true
            sessionID = nil
        case let .assistantDelta(text):
            current.text += text
        case let .toolStarted(_, _, kind, input):
            if kind == "edit", let path = Self.filePath(inToolInput: input) {
                if !current.editedFiles.contains(path) { current.editedFiles.append(path) }
            }
        case let .toolUpdated(_, _, _, diff):
            if let path = diff?.path, !current.editedFiles.contains(path) {
                current.editedFiles.append(path)
            }
        case let .turnFinished(stopReason, cost):
            current.stopReason = stopReason
            current.costUSD = cost
            UsageLedger.shared.record(turn: provider, costUSD: cost)
            finish()
        case let .failure(message):
            current.failureMessage = message
        case let .disconnected(reason):
            current.failureMessage = current.failureMessage ?? "disconnected: \(reason)"
            finish()
        case let .permission(request):
            if !autoApprove || !request.questions.isEmpty {
                guard let onPermission else {
                    request.reply(nil)
                    current.failureMessage = "A user decision was required but no approval UI was available."
                    return
                }
                waitingPermissions.insert(request.id)
                let queued = PermissionRequest(id: request.id, title: request.title,
                    detail: request.detail, options: request.options, questions: request.questions,
                    answer: request.answer.map { answer in { [weak self] answers in
                        guard let self, self.waitingPermissions.remove(request.id) != nil else { return }
                        self.lastActivity = Date()
                        answer(answers)
                    } },
                    reply: { [weak self] choice in
                        guard let self, self.waitingPermissions.remove(request.id) != nil else { return }
                        self.lastActivity = Date()
                        request.reply(choice)
                    }
                )
                onPermission(queued, provider)
                return
            }
            // Orchestrator sessions run hands-off; approvals are answered allow and recorded.
            let allow = (request.options.first { $0.kind == "allow_once" }
                         ?? request.options.first { $0.kind.hasPrefix("allow") })?.id
            current.autoApprovals.append(request.title)
            request.reply(allow)
        default:
            break
        }
    }

    /// Pulls a file path out of a tool call's JSON-ish input without caring which CLI sent it.
    static func filePath(inToolInput input: String) -> String? {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["file_path", "path", "target_file", "filePath", "file"] {
            if let path = object[key] as? String, !path.isEmpty { return path }
        }
        return nil
    }
}

// MARK: - Orchestrator

/// One agent plans, the others write, and whoever did NOT write a file reviews it — findings go
/// back to the author for a bounded number of rounds. Every session is fresh (never the chat
/// panes), every spend is shown, and one Stop cancels everything.
@MainActor
@Observable
final class Orchestrator {
    var canExecute: () -> Bool = { true }
    var autoApprove = false
    var onPermission: ((PermissionRequest, Provider) -> Void)?
    var onPermissionEnded: ((UUID) -> Void)?

    enum Phase: Equatable {
        case idle, planning, working, done, cancelled
        case failed(String)
    }

    private(set) var phase = Phase.idle {
        didSet { recordTeamStatsIfNeeded() }
    }
    private(set) var items: [WorkItem] = []
    /// The orchestrator's raw plan reply — always kept, because when parsing fails the honest
    /// thing to show is what it actually said.
    private(set) var planRaw = ""
    private(set) var planCostUSD: Double?
    private(set) var log: [String] = []
    /// Live view of the planning turn, before any item exists.
    private(set) var planningLive: LiveTurn?
    /// True only when `seedDemo()` populated this state: canned data, no sessions, no spend.
    /// The pane shows an unmissable banner, because a frozen fake "working…" item reads as a
    /// hung real run (it did, once).
    private(set) var isDemo = false

    var orchestratorProvider: Provider = .grok
    /// Header chip — names the planning provider so it is never confused with the
    /// per-item author→reviewer chips.
    var orchestratorChipText: String { "orchestrator: \(orchestratorProvider.displayName)" }
    /// Review passes per item when the plan omits `rounds`. 1 = review once, no revising.
    /// One review round by default: a second pass costs a whole extra set of turns and rarely
    /// changes the outcome. Raise it per run when a task warrants it.
    var maxRounds = 1
    /// Hard ceiling on review passes an item may ever receive, grants included.
    static let lifetimeReviewRoundCap = 10
    /// Workers the user has switched off — a provider whose quota is spent, or one they do not
    /// want billed. Never assigned work; never chosen as reviewer.
    var disabledWorkers: Set<Provider> = []
    /// One subscription, whole team: the orchestrator's provider plans, writes and reviews,
    /// each seat on its own model. The review is still a fresh session on a different model,
    /// never the author's own session; `startBlocker` insists the two models differ.
    var singleProviderTeam = false {
        didSet { if singleProviderTeam != oldValue { persistPreference?("team.singleProvider.v1", singleProviderTeam) } }
    }
    var persistPreference: ((String, Bool) -> Void)?

    /// In single-provider mode a review by the same provider counts only when the reviewer's
    /// resolved model differs from the author's.
    func sameProviderReviewAllowed(_ provider: Provider) -> Bool {
        resolvedModel(for: provider, role: .reviewer) != resolvedModel(for: provider, role: .author)
    }
    /// Per-provider model/effort for THIS run's sessions only. Efficiency is choosing where
    /// the expensive settings go; nothing here ever touches the chat defaults.
    var modelOverrides: [Provider: String] = [:]
    var effortOverrides: [Provider: String] = [:]
    /// Role-scoped settings: one provider can author as one model and review as another in the
    /// same run. Resolution: explicit role override > provider-wide override > baked default.
    var roleModelOverrides: [SessionRole: [Provider: String]] = [:]
    var roleEffortOverrides: [SessionRole: [Provider: String]] = [:]
    /// Default role allocation, verified against live turns: Terra writes, Sol reviews and
    /// orchestrates. Explicit overrides always beat these.
    static let bakedModelDefaults: [SessionRole: [Provider: String]] = [
        .author: [.codex: "gpt-5.6-terra"],
        .reviewer: [.codex: "gpt-5.6-sol"],
        .orchestrator: [.codex: "gpt-5.6-sol"],
    ]

    func resolvedModel(for provider: Provider, role: SessionRole) -> String? {
        roleModelOverrides[role]?[provider] ?? modelOverrides[provider]
            ?? Self.bakedModelDefaults[role]?[provider]
    }

    func resolvedEffort(for provider: Provider, role: SessionRole) -> String? {
        roleEffortOverrides[role]?[provider] ?? effortOverrides[provider]
    }

    /// Fill this run's role pickers from a measured recommendation. Writes
    /// `roleModelOverrides` / `roleEffortOverrides` (the same dictionaries the
    /// setup pickers bind to) and, for an orchestrator pick, `orchestratorProvider`
    /// — but never switches the orchestrator onto the author pick's provider,
    /// which would hide that author picker and waste the author recommendation.
    /// Never writes UserDefaults chat keys, never writes provider-wide
    /// `modelOverrides` / `effortOverrides`.
    func applySeatRecommendations(_ rec: TeamStats.SeatRecommendations) {
        applyAdvice(rec.reviewer, role: .reviewer)
        let authorProvider = Self.recommendedProvider(rec.author)
        let orchProvider = Self.recommendedProvider(rec.orchestrator)
        let switchOrchestrator = orchProvider != nil && orchProvider != authorProvider
        applyAdvice(rec.orchestrator, role: .orchestrator,
                    switchOrchestrator: switchOrchestrator)
        if let authorProvider, let provider = Provider(rawValue: authorProvider),
           workerPool.contains(provider) {
            applyAdvice(rec.author, role: .author)
        }
    }

    /// Assign `seat.model` to exactly one author picker for this run. Nothing
    /// else is touched — not reviewer, not orchestrator, not effort, not chat
    /// defaults. Opt-in: calling this is the only way a trial seat is used.
    /// Refused when the provider is not in the worker pool (the orchestrator
    /// cannot author this run).
    func acceptTrialAuthorSeat(_ seat: TeamStats.CatalogSeat) {
        guard let provider = Provider(rawValue: seat.provider),
              workerPool.contains(provider) else { return }
        roleModelOverrides[.author, default: [:]][provider] = seat.model
    }

    private static func recommendedProvider(_ advice: TeamStats.RoleAdvice) -> String? {
        if case .recommended(let pick) = advice { return pick.provider }
        return nil
    }

    private func applyAdvice(_ advice: TeamStats.RoleAdvice, role: SessionRole,
                             switchOrchestrator: Bool = true) {
        guard case .recommended(let pick) = advice,
              let provider = Provider(rawValue: pick.provider),
              pick.model != TeamStats.unrecorded else { return }
        if role == .orchestrator, switchOrchestrator {
            orchestratorProvider = provider
        }
        roleModelOverrides[role, default: [:]][provider] = pick.model
        if pick.effort != TeamStats.unrecorded {
            roleEffortOverrides[role, default: [:]][provider] = pick.effort
        }
    }

    var totalCostUSD: Double { items.reduce(planCostUSD ?? 0) { $0 + $1.costUSD } }
    var totalTurns: Int { items.reduce(planRaw.isEmpty ? 0 : 1) { $0 + $1.turns } }
    var totalUnreportedTurns: Int {
        items.reduce(planRaw.isEmpty || planCostUSD != nil ? 0 : 1) { $0 + $1.unreportedTurns }
    }
    var isRunning: Bool { phase == .planning || phase == .working }

    /// Injection seams so `--audit` drives the whole machine with scripted backends and no
    /// quota. Production uses the real CLIs and a 10-minute turn deadline.
    var makeBackend: (Provider) -> any AgentBackend = { provider in
        switch provider {
        case .grok: return GrokBackend()
        case .claude: return ClaudeBackend()
        case .codex: return CodexBackend()
        }
    }
    var installedProviders: [Provider] = Provider.allCases.filter {
        switch $0 {
        case .grok: return GrokBackend.locate() != nil
        case .claude: return ClaudeBackend.locate() != nil
        case .codex: return CodexBackend.locate() != nil
        }
    }
    /// The SILENCE deadline per turn — no cap on total time. An author that is visibly
    /// working keeps its session for hours if it needs them; only a turn with no events at
    /// all for this long fails. Stop remains the manual way out.
    var turnTimeout: TimeInterval = 300
    /// Fired after each work item reaches a terminal state and once more when the run ends —
    /// the app reloads clean tabs and refreshes diffs, same as after a chat turn.
    var onWorkSettled: (@MainActor () -> Void)?
    /// When true, each edit event also fires `onFileEdited` so the editor can follow along.
    var followEdits = true
    /// When true, accepted work is proven by the project's own build and test tasks.
    /// Local processes, no tokens. Off: nothing is resolved, nothing runs, no gate record.
    var followGate = true
    /// Audit seam: when set, these tasks are used instead of `TaskCatalog` resolution.
    var gateTasksOverride: [RunTask]?
    /// Build/test can be slow; a timeout is a gate failure, stated as such. Audit shortens it.
    var gateTimeout: TimeInterval = 600
    /// Absolute path of a file the in-flight turn just edited. Relative paths are resolved
    /// against the run's project directory before this is called.
    var onFileEdited: (@MainActor (String) -> Void)?
    /// When set (by --orchestrate-log), a JSON record of the finished run is written here.
    var runLogURL: URL?
    /// Team-stats JSONL destination. Production writes to `TeamStats.storeURL`. `--audit`
    /// defaults this to nil so scripted runs never touch the user's Application Support
    /// file; audits that want a record point it at a temp path.
    var teamStatsURL: URL? = CommandLine.arguments.contains("--audit") ? nil : TeamStats.storeURL
    /// `"run"` (default) or `"calibration"`. Stamped onto the `RunOutcome` so
    /// calibration records can be excluded from real-world aggregates.
    var teamStatsKind: String = TeamStats.kindRun
    /// True once `start` / `resume` actually began a run. Start-blocker failures and
    /// `seedDemo` are not runs and must not write a record.
    private var teamStatsRunStarted = false
    /// Guards against a duplicate append when both `onWorkSettled` and a later phase
    /// assignment would otherwise both look like "the run ended".
    private var teamStatsRecordedForRun = false
    /// Planning-session provider/model/effort, captured at that session's `preconfigure`.
    private(set) var capturedOrchestratorProvider = TeamStats.unrecorded
    private(set) var capturedOrchestratorModel = TeamStats.unrecorded
    private(set) var capturedOrchestratorEffort = TeamStats.unrecorded
    /// CLI versions from the toolchain sweep at run start. Nil when nothing
    /// has been swept — displayed as `unrecorded`, never as an empty map.
    private(set) var capturedCLIVersions: [String: String]?
    /// When set, the in-flight recording is a resume: only this item, and only the
    /// increment since these baselines, so aggregation cannot double-count the original run.
    private(set) var teamStatsResumeBaseline: TeamStatsResumeBaseline?

    struct TeamStatsResumeBaseline {
        let itemID: UUID
        let costUSD: Double
        let turns: Int
        let unreportedTurns: Int
        let round: Int
        let extraRounds: Int
        let laneCount: Int
        let gate: GateResult?
    }

    private var collectors: [TurnCollector] = []
    /// One live session per provider and role, reused across work items: the author that just
    /// wrote item 1 already knows the project when item 2 arrives, and nothing is re-read.
    /// After `sessionItemCap` items a role starts a fresh session so context stays bounded.
    private var pool: [String: TurnCollector] = [:]
    private var pooledItems: [String: Int] = [:]
    static let sessionItemCap = 4
    /// Reuse author and reviewer sessions across work items (planner and recommendation turns
    /// keep their own). Off, every item opens fresh sessions — the old, costlier behaviour.
    var reuseSessions = true
    /// Sessions opened this run, for the audit: fewer is cheaper.
    private(set) var sessionsOpened = 0
    private var runTask: Task<Void, Never>?

    /// The pool the orchestrator assigns work from: every installed, enabled provider except
    /// its own. (A pool with only the orchestrator in it could never satisfy
    /// reviewer-is-not-author, so there is no fallback — an empty pool blocks the start.)
    var workerPool: [Provider] {
        if singleProviderTeam {
            return installedProviders.contains(orchestratorProvider) && !disabledWorkers.contains(orchestratorProvider) ? [orchestratorProvider] : []
        }
        return installedProviders.filter { !disabledWorkers.contains($0) && $0 != orchestratorProvider }
    }

    /// The one who did not write it. Prefer a worker that is not the author; fall back to the
    /// orchestrator's provider (a fresh session, still a different mind than the author).
    func reviewer(forAuthor author: Provider) -> Provider? {
        if singleProviderTeam { return sameProviderReviewAllowed(author) ? author : nil }
        if let other = workerPool.first(where: { $0 != author }) { return other }
        if orchestratorProvider != author, !disabledWorkers.contains(orchestratorProvider) {
            return orchestratorProvider
        }
        return installedProviders.first { $0 != author && !disabledWorkers.contains($0) }
    }

    var startBlocker: String? {
        if !canExecute() { return "Trust this project to enable the orchestrator." }
        if singleProviderTeam {
            guard installedProviders.contains(orchestratorProvider) else {
                return "\(orchestratorProvider.displayName) is not installed; pick an installed agent for the single-agent team."
            }
            if disabledWorkers.contains(orchestratorProvider) { return "\(orchestratorProvider.displayName) is switched off as a worker — enable it." }
            if reviewer(forAuthor: orchestratorProvider) == nil {
                return "Single-agent Team needs the reviewer on a different model than the author, so the review is a second opinion. "
                    + "Set both under Models per agent for this run."
            }
            return nil
        }
        if installedProviders.count < 2 {
            let installed = installedProviders.map(\.displayName).joined(separator: ", ")
            return "Orchestrator mode needs at least two installed agent CLIs so the reviewer "
                + "is never the author. Installed: \(installed.isEmpty ? "none" : installed)."
        }
        if workerPool.isEmpty {
            return "Every worker is switched off — enable at least one."
        }
        if workerPool.allSatisfy({ reviewer(forAuthor: $0) == nil }) {
            return "No possible reviewer is left: with these switches every review would fall "
                + "to the author itself, which is never allowed."
        }
        return nil
    }

    // MARK: Run

    /// A remembered planner that is no longer installed must not block Team: the first
    /// installed CLI plans instead, and the picker shows the substitution.
    func adoptInstalledOrchestrator() {
        if !installedProviders.contains(orchestratorProvider), let fallback = installedProviders.first {
            orchestratorProvider = fallback
        }
    }

    private var taskContext = ""

    func start(task: String, project: URL, attachments: [MessageAttachment] = [], useExistingPlan: Bool = false) {
        guard !isRunning else { return }
        do { try TeamContext.validate(attachments) }
        catch { phase = .failed(error.localizedDescription); return }
        adoptInstalledOrchestrator()
        if let blocker = startBlocker {
            phase = .failed(blocker)
            return
        }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if useExistingPlan, let author = workerPool.first, let reviewer = reviewer(forAuthor: author) {
            startPreparedItem(title: String(trimmed.prefix(80)), brief: trimmed, author: author,
                              reviewer: reviewer, roundBudget: maxRounds, project: project, attachments: attachments)
            return
        }
        taskContext = TeamContext.prompt(attachments)
        isDemo = false
        items = []
        planRaw = ""
        planCostUSD = nil
        log = []
        teamStatsRunStarted = true
        teamStatsRecordedForRun = false
        teamStatsResumeBaseline = nil
        teamStatsKind = TeamStats.kindRun
        capturedOrchestratorProvider = TeamStats.unrecorded
        capturedOrchestratorModel = TeamStats.unrecorded
        capturedOrchestratorEffort = TeamStats.unrecorded
        capturedCLIVersions = ToolchainWatch.latestParsedVersions()
        phase = .planning
        runTask = Task { [weak self] in
            await self?.run(task: trimmed, project: project)
        }
    }

    /// One already-assigned work item, no planner. Calibration uses this so the
    /// author seat, the fixed reviewer, and the round budget are the ones the
    /// flag named — never planner-invented extras, never reviewer == author.
    func startPreparedItem(title: String, brief: String, author: Provider,
                           reviewer: Provider, roundBudget: Int, project: URL, attachments: [MessageAttachment] = []) {
        guard !isRunning else { return }
        do { try TeamContext.validate(attachments) }
        catch { phase = .failed(error.localizedDescription); return }
        if let blocker = startBlocker {
            phase = .failed(blocker)
            return
        }
        if reviewer == author, !(singleProviderTeam && sameProviderReviewAllowed(author)) {
            phase = .failed("Refusing a prepared item whose reviewer is the author, "
                            + "which is never allowed.")
            return
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBrief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedBrief.isEmpty else { return }
        taskContext = TeamContext.prompt(attachments)
        isDemo = false
        items = [WorkItem(title: trimmedTitle, brief: trimmedBrief,
                          author: author, reviewer: reviewer,
                          roundBudget: max(1, min(5, roundBudget)))]
        planRaw = ""
        planCostUSD = nil
        log = []
        teamStatsRunStarted = true
        teamStatsRecordedForRun = false
        teamStatsResumeBaseline = nil
        capturedOrchestratorProvider = TeamStats.unrecorded
        capturedOrchestratorModel = TeamStats.unrecorded
        capturedOrchestratorEffort = TeamStats.unrecorded
        capturedCLIVersions = ToolchainWatch.latestParsedVersions()
        phase = .working
        runTask = Task { [weak self] in
            await self?.runPrepared(project: project)
        }
    }

    private func runPrepared(project: URL) async {
        guard let item = items.first else {
            phase = .failed("No prepared work item.")
            return
        }
        await process(item, project: project)
        onWorkSettled?()
        phase = Task.isCancelled ? .cancelled : .done
        onWorkSettled?()
        closeAllCollectors()
        writeRunLog()
    }

    func stop() {
        guard isRunning else { return }
        note("Stop — cancelling every in-flight session.")
        runTask?.cancel()
        closeAllCollectors()
        for item in items where !item.state.isTerminal {
            item.state = .cancelled
        }
        phase = .cancelled
    }

    /// Grant more review rounds to an item that finished with objections. Fresh author
    /// and reviewer sessions, same providers as the original pass (reviewer is still
    /// never the author). Costs accrue on this item. Refuses in words when a run is
    /// already in flight, or when the grant would push the item past the lifetime cap.
    func resume(_ item: WorkItem, extraRounds: Int, project: URL) {
        guard canExecute() else { note("Trust this project before resuming work."); return }
        guard !isRunning else {
            note("Cannot resume \"\(item.title)\" while the orchestrator is already running.")
            return
        }
        guard item.state == .acceptedWithObjections || item.state == .notConverging else {
            note("Can only resume an item that finished with objections standing "
                 + "or stopped for non-convergence.")
            return
        }
        guard extraRounds >= 1 else { return }
        if item.reviewer == item.author, !(singleProviderTeam && sameProviderReviewAllowed(item.author)) {
            note("Refusing resume of \"\(item.title)\": the reviewer would be the author, "
                 + "which is never allowed.")
            return
        }
        let projected = item.round + extraRounds
        if projected > Self.lifetimeReviewRoundCap {
            let message = "Cannot grant \(extraRounds) more review "
                + "round\(extraRounds == 1 ? "" : "s") for \"\(item.title)\": it has already "
                + "had \(item.round) and no combination of grants may exceed the lifetime "
                + "cap of \(Self.lifetimeReviewRoundCap)."
            note(message)
            item.lane.append(LaneEntry(provider: orchestratorProvider, role: "system",
                                       title: "Resume refused", text: message, costUSD: nil))
            return
        }
        item.objectionsDismissedByUser = false
        teamStatsResumeBaseline = TeamStatsResumeBaseline(
            itemID: item.id, costUSD: item.costUSD, turns: item.turns,
            unreportedTurns: item.unreportedTurns, round: item.round,
            extraRounds: extraRounds, laneCount: item.lane.count, gate: item.gate)
        // A resume is a new team-stats record and does not re-plan. Clear the
        // planning stamp so a recommendation session (the only orchestrator
        // turn a resume can make) can record itself; if none runs, the
        // orchestrator fields stay the honest "unrecorded".
        capturedOrchestratorProvider = TeamStats.unrecorded
        capturedOrchestratorModel = TeamStats.unrecorded
        capturedOrchestratorEffort = TeamStats.unrecorded
        capturedCLIVersions = ToolchainWatch.latestParsedVersions()
        item.roundBudget = item.round + extraRounds
        teamStatsRunStarted = true
        teamStatsRecordedForRun = false
        teamStatsKind = TeamStats.kindRun
        phase = .working
        runTask = Task { [weak self] in
            await self?.runResume(item, extraRounds: extraRounds, project: project)
        }
    }

    /// What the objections card's grant controls should do right now — pure and testable, so
    /// the view stays a one-liner. Controls are always VISIBLE on an objections card; they
    /// disable (with the caption) while a run is in flight or after the user accepted as-is.
    struct GrantControlState: Equatable {
        var enabled: Bool
        var caption: String?
    }

    func grantControlState(for item: WorkItem) -> GrantControlState {
        if item.objectionsDismissedByUser {
            return GrantControlState(enabled: false, caption: "accepted by you — objections noted")
        }
        if isRunning {
            return GrantControlState(enabled: false,
                                     caption: "available when the current run finishes")
        }
        if item.remainingLifetimeRounds <= 0 {
            return GrantControlState(enabled: false, caption: "lifetime round cap reached")
        }
        return GrantControlState(enabled: true, caption: nil)
    }

    private func note(_ text: String) {
        log.append(text)
    }

    private func openCollector(_ provider: Provider, role: SessionRole,
                               project: URL, item: WorkItem? = nil) async -> TurnCollector {
        let model = resolvedModel(for: provider, role: role)
        let effort = resolvedEffort(for: provider, role: role)
        let key = provider.rawValue + "/" + role.rawValue
        let pooled = reuseSessions && (role == .author || role == .reviewer)
        if pooled, let existing = pool[key], existing.backend.isRunning, pooledItems[key, default: 0] < Self.sessionItemCap {
            pooledItems[key, default: 0] += 1
            rememberPreconfigure(provider: provider, role: role, item: item,
                                 model: TeamStats.recorded(model), effort: TeamStats.recorded(effort))
            return existing
        }
        if let stale = pool.removeValue(forKey: key) { stale.stop(); collectors.removeAll { $0 === stale } }
        let backend = makeBackend(provider)
        backend.persistsSelection = false
        backend.preconfigure(model: model, effort: effort)
        rememberPreconfigure(provider: provider, role: role, item: item,
                             model: TeamStats.recorded(model),
                             effort: TeamStats.recorded(effort))
        let collector = TurnCollector(backend: backend, provider: provider)
        collector.autoApprove = autoApprove
        collector.onPermission = onPermission
        collector.onPermissionEnded = onPermissionEnded
        collectors.append(collector)
        if pooled { pool[key] = collector; pooledItems[key] = 1 }
        sessionsOpened += 1
        await collector.start(project: project)
        return collector
    }

    /// Stamp the values this session was preconfigured with. Later override edits
    /// must not rewrite a session that has already started. The first orchestrator
    /// session to preconfigure owns the run-level stamp — planning when it runs,
    /// or a recommendation turn when nothing has been stamped yet (a resume).
    /// A later recommendation must never overwrite a planning stamp.
    private func rememberPreconfigure(provider: Provider, role: SessionRole, item: WorkItem?,
                                      model: String, effort: String) {
        switch role {
        case .orchestrator:
            if item == nil || capturedOrchestratorProvider == TeamStats.unrecorded {
                capturedOrchestratorProvider = provider.rawValue
                capturedOrchestratorModel = model
                capturedOrchestratorEffort = effort
            }
        case .author:
            item?.authorModel = model
            item?.authorEffort = effort
        case .reviewer:
            item?.reviewerModel = model
            item?.reviewerEffort = effort
        }
    }

    /// Pooled sessions stay open for the next item; everything is closed when the run ends.
    private func closeCollector(_ collector: TurnCollector) {
        guard !pool.values.contains(where: { $0 === collector }) else { return }
        collector.backend.stop()
        collectors.removeAll { $0 === collector }
    }

    private func closeAllCollectors() {
        for collector in collectors { collector.stop() }
        collectors.removeAll()
        pool.removeAll()
        pooledItems.removeAll()
    }

    private func run(task: String, project: URL) async {
        // 1. Plan.
        let planner = await openCollector(orchestratorProvider, role: .orchestrator, project: project)
        note("Planning with \(orchestratorProvider.displayName)…")
        let plan = await performTurn(planner,
                                     prompt: Prompts.plan(task: task, project: project,
                                                          workers: workerPool,
                                                          seatHistory: authorSeatHistory()),
                                     role: "orchestrator", item: nil, project: project)
        closeCollector(planner)
        guard !Task.isCancelled else { return }
        planRaw = plan.text
        planCostUSD = plan.costUSD
        if plan.failed {
            phase = .failed("The orchestrator did not deliver a plan: "
                            + (plan.failureMessage ?? "timed out"))
            return
        }

        switch Self.parsePlan(plan.text, allowed: workerPool) {
        case let .failure(reason):
            // Show the raw reply rather than inventing work items.
            phase = .failed("The plan could not be parsed: \(reason)")
            return
        case let .success(parsed):
            items = parsed.map { entry in
                let reviewer = self.reviewer(forAuthor: entry.author) ?? entry.author
                return WorkItem(title: entry.title, brief: entry.brief,
                                author: entry.author, reviewer: reviewer,
                                roundBudget: entry.rounds ?? maxRounds)
            }
            // The invariant the whole feature is named for: a different mind reviews. In
            // single-provider mode that mind is the same provider on a different model.
            items.removeAll { $0.reviewer == $0.author && !(singleProviderTeam && sameProviderReviewAllowed($0.author)) }
        }
        guard !items.isEmpty else {
            phase = .failed("The plan parsed but contained no usable work items.")
            return
        }
        note("\(items.count) work item(s) planned.")

        // 2. Author → review → revise, one item at a time, every step attributable.
        phase = .working
        for item in items {
            guard !Task.isCancelled else { return }
            await process(item, project: project)
            onWorkSettled?()
        }
        phase = Task.isCancelled ? .cancelled : .done
        onWorkSettled?()
        closeAllCollectors()
        writeRunLog()
    }

    /// The honest record of what happened, for scripting and reporting. Only written when a
    /// destination was explicitly given.
    private func writeRunLog() {
        guard let runLogURL else { return }
        let record: [String: Any] = [
            "phase": String(describing: phase),
            "totalCostUSD": totalCostUSD,
            "totalTurns": totalTurns,
            "unreportedTurns": totalUnreportedTurns,
            "planCostUSD": planCostUSD as Any,
            "planRaw": planRaw,
            "items": items.map { item -> [String: Any] in
                var row: [String: Any] = [
                    "title": item.title,
                    "author": item.author.rawValue,
                    "reviewer": item.reviewer.rawValue,
                    "state": item.state.rawValue,
                    "round": item.round,
                    "filesTouched": item.filesTouched,
                    "costUSD": item.costUSD,
                    "turns": item.turns,
                    "unreportedTurns": item.unreportedTurns,
                    "findings": item.findings.map {
                        ["file": $0.file, "line": $0.line as Any, "severity": $0.severity,
                         "message": $0.message, "round": $0.round]
                    },
                    "lane": item.lane.map {
                        ["role": $0.role, "provider": $0.provider.rawValue, "title": $0.title,
                         "costUSD": $0.costUSD as Any, "text": $0.text]
                    },
                ]
                if let gate = item.gate { row["gate"] = gate.jsonObject }
                return row
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: runLogURL)
        }
    }

    private func process(_ item: WorkItem, project: URL) async {
        item.state = .authoring
        item.lane.append(LaneEntry(provider: orchestratorProvider, role: "orchestrator",
                                   title: "Brief", text: item.brief, costUSD: nil))
        let author = await openCollector(item.author, role: .author, project: project, item: item)
        defer { closeCollector(author) }

        let authored = await performTurn(author,
                                         prompt: Prompts.author(item: item, project: project),
                                         role: "author", item: item, project: project)
        record(authored, in: item, provider: item.author, role: "author", title: "Wrote it")
        if authored.failed {
            item.state = Task.isCancelled ? .cancelled : .failed
            return
        }
        for path in authored.editedFiles where !item.filesTouched.contains(path) {
            item.filesTouched.append(path)
        }

        let reviewer = await openCollector(item.reviewer, role: .reviewer, project: project, item: item)
        defer { closeCollector(reviewer) }

        await reviewLoop(item, author: author, reviewer: reviewer, project: project)
    }

    private func runResume(_ item: WorkItem, extraRounds: Int, project: URL) async {
        note("Resuming \(item.title) for \(extraRounds) more review "
             + "round\(extraRounds == 1 ? "" : "s").")
        let author = await openCollector(item.author, role: .author, project: project, item: item)
        defer { closeCollector(author) }
        let reviewer = await openCollector(item.reviewer, role: .reviewer, project: project, item: item)
        defer { closeCollector(reviewer) }

        let standing = item.openFindings
        item.state = .revising
        let revision = await performTurn(author,
                                         prompt: Prompts.revise(item: item,
                                                                findings: standing),
                                         role: "author", item: item, project: project)
        record(revision, in: item, provider: item.author, role: "author",
               title: "Revision after round \(item.round)")
        if revision.failed {
            item.state = Task.isCancelled ? .cancelled : .failed
            finishResume()
            return
        }
        for path in revision.editedFiles where !item.filesTouched.contains(path) {
            item.filesTouched.append(path)
        }

        await grantedReviewLoop(item, author: author, reviewer: reviewer,
                                standing: standing, project: project)
        finishResume()
    }

    /// The scoped loop for GRANTED rounds. Field data showed fresh post-grant reviewers
    /// hunting new nits instead of verifying the standing ones, so an item could never
    /// close. Here the reviewer must verdict each standing finding — RESOLVED or NOT — may
    /// flag REGRESSIONs in the touched files, and anything else lands as a visible,
    /// non-blocking ADVISORY. All standing resolved + no regressions ⇒ accepted.
    private func grantedReviewLoop(_ item: WorkItem, author: TurnCollector,
                                   reviewer: TurnCollector,
                                   standing initial: [ReviewFinding], project: URL) async {
        var standing = initial
        while !Task.isCancelled {
            item.state = .reviewing
            let pass = item.round + 1
            let review = await performTurn(
                reviewer,
                prompt: Prompts.grantReReview(item: item, standing: standing),
                role: "reviewer", item: item, project: project)
            record(review, in: item, provider: item.reviewer, role: "reviewer",
                   title: "Review round \(pass)")
            if review.failed {
                if Task.isCancelled { item.state = .cancelled; return }
                _ = await runAcceptanceGate(item, project: project)
                item.state = .failed
                return
            }
            item.round = pass
            let verdict = Self.parseGrantReview(review.text, standing: standing, round: pass)
            item.advisoryNotes.append(contentsOf: verdict.advisories)

            if !verdict.parsed {
                // Same honesty path as always: keep the reply verbatim, keep the item open.
                item.findings.append(ReviewFinding(
                    file: "", line: nil, severity: "unparsed",
                    message: String(review.text.prefix(600)), round: pass))
                _ = await runAcceptanceGate(item, project: project)
                if Task.isCancelled { item.state = .cancelled; return }
                item.state = .acceptedWithObjections
                note("\(item.title): grant review was unstructured — surfaced verbatim.")
                await requestRecommendation(item, project: project)
                return
            }

            var remaining: [ReviewFinding] = []
            for (index, finding) in standing.enumerated()
            where !verdict.resolvedIndices.contains(index) {
                var kept = finding
                kept.round = pass
                if let why = verdict.notResolvedReasons[index], !why.isEmpty {
                    kept.message = finding.message + " — still open: " + why
                }
                remaining.append(kept)
            }
            var regressions = verdict.regressions
            for i in regressions.indices { regressions[i].round = pass }
            item.findings.append(contentsOf: remaining + regressions)

            if remaining.isEmpty && regressions.isEmpty {
                let gatePassed = await runAcceptanceGate(item, project: project)
                if Task.isCancelled { item.state = .cancelled; return }
                if gatePassed {
                    item.state = .accepted
                    if !item.advisoryNotes.isEmpty {
                        note("\(item.title): accepted with "
                             + "\(item.advisoryNotes.count) non-blocking advisory note(s).")
                    }
                    return
                }
                item.findings.append(contentsOf: findingsFromGate(item.gate, round: pass))
                // fall through into the budget check with the gate findings standing
                standing = item.openFindings
            } else {
                standing = remaining + regressions
            }

            let atCap = pass >= item.roundBudget || pass >= Self.lifetimeReviewRoundCap
            if atCap {
                _ = await runAcceptanceGate(item, project: project)
                if Task.isCancelled { item.state = .cancelled; return }
                item.state = .acceptedWithObjections
                note("\(item.title): granted rounds exhausted with "
                     + "\(standing.count) finding(s) still open.")
                await requestRecommendation(item, project: project)
                return
            }
            await revise(item, author: author, findings: standing, afterRound: pass,
                         project: project)
            if item.state == .failed || item.state == .cancelled { return }
        }
        if Task.isCancelled { item.state = .cancelled }
    }

    /// Verdict forms for a scoped grant review. `parsed` is false when none of the
    /// required forms appear — the caller falls back to the verbatim honesty path.
    struct GrantVerdict {
        var resolvedIndices: Set<Int> = []
        var notResolvedReasons: [Int: String] = [:]
        var regressions: [ReviewFinding] = []
        var advisories: [String] = []
        var parsed = false
    }

    static func parseGrantReview(_ text: String, standing: [ReviewFinding],
                                 round: Int) -> GrantVerdict {
        var verdict = GrantVerdict()
        // Every other review in this system answers "NO FINDINGS" when it is satisfied —
        // that is the dialect the plain review prompt teaches, and reviewers keep using it
        // in granted rounds. Treating it as unparseable made a finished item impossible to
        // close: the user granted rounds repeatedly and nothing ever completed.
        let upper = text.uppercased()
        let blanketClean = upper.contains("NO FINDINGS") || upper.contains("ALL RESOLVED")
            || upper.contains("ALL STANDING FINDINGS RESOLVED")
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            func findingIndex(after prefix: String) -> Int? {
                let body = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                guard body.hasPrefix("F"),
                      let number = Int(body.dropFirst().prefix { $0.isNumber }),
                      number >= 1, number <= standing.count else { return nil }
                return number - 1
            }
            if line.uppercased().hasPrefix("RESOLVED:") {
                if let index = findingIndex(after: "RESOLVED:") {
                    verdict.resolvedIndices.insert(index)
                    verdict.parsed = true
                }
            } else if line.uppercased().hasPrefix("NOT RESOLVED:") {
                if let index = findingIndex(after: "NOT RESOLVED:") {
                    let rest = line.dropFirst("NOT RESOLVED:".count)
                    let why = rest.drop { $0 != ":" }.dropFirst()
                        .trimmingCharacters(in: .whitespaces)
                    verdict.notResolvedReasons[index] = String(why)
                    verdict.parsed = true
                }
            } else if line.uppercased().hasPrefix("REGRESSION:") {
                let body = String(line.dropFirst("REGRESSION:".count))
                    .trimmingCharacters(in: .whitespaces)
                let parsedFindings = parseFindings("FINDING: " + body, round: round)
                if let finding = parsedFindings.first, finding.severity != "unparsed" {
                    var regression = finding
                    regression.severity = "regression"
                    verdict.regressions.append(regression)
                } else {
                    verdict.regressions.append(ReviewFinding(
                        file: "", line: nil, severity: "regression", message: body,
                        round: round))
                }
                verdict.parsed = true
            } else if line.uppercased().hasPrefix("ADVISORY:") {
                verdict.advisories.append(String(line.dropFirst("ADVISORY:".count))
                    .trimmingCharacters(in: .whitespaces))
                verdict.parsed = true
            } else if line.uppercased().hasPrefix("FINDING:") {
                // The open-review dialect inside a scoped round: never dropped, but it is
                // out of scope for closing THIS grant, so it lands as a visible advisory.
                verdict.advisories.append("raised outside the grant scope — "
                    + String(line.dropFirst("FINDING:".count))
                        .trimmingCharacters(in: .whitespaces))
                verdict.parsed = true
            }
        }
        // A blanket clean verdict resolves everything, but only when the reviewer did not
        // also say something was still open or broken.
        if blanketClean, verdict.notResolvedReasons.isEmpty, verdict.regressions.isEmpty {
            verdict.resolvedIndices = Set(standing.indices)
            verdict.parsed = true
        }
        // A finding the reviewer never mentioned stays open — silence is not resolution.
        return verdict
    }

    private func finishResume() {
        phase = Task.isCancelled ? .cancelled : .done
        onWorkSettled?()
        closeAllCollectors()
        writeRunLog()
    }

    /// Review → (revise → review)* until the item's remaining budget is spent or
    /// the reviewer has nothing left. After a clean review *or* budget exhaustion,
    /// the acceptance gate runs the project's build and test tasks. A failing gate
    /// with budget left becomes a revise round; with none left the card shows it.
    private func reviewLoop(_ item: WorkItem, author: TurnCollector, reviewer: TurnCollector,
                            project: URL) async {
        while !Task.isCancelled {
            item.state = .reviewing
            let pass = item.round + 1
            let reviewPrompt = pass == 1
                ? Prompts.review(item: item, project: project)
                : Prompts.reReview(item: item, project: project)
            let review = await performTurn(reviewer, prompt: reviewPrompt,
                                           role: "reviewer", item: item, project: project)
            record(review, in: item, provider: item.reviewer, role: "reviewer",
                   title: "Review round \(pass)")
            if review.failed {
                if Task.isCancelled { item.state = .cancelled; return }
                _ = await runAcceptanceGate(item, project: project)
                item.state = .failed
                return
            }
            item.round = pass
            let found = Self.parseFindings(review.text, round: pass)
            item.findings.append(contentsOf: found)
            let atCap = pass >= item.roundBudget || pass >= Self.lifetimeReviewRoundCap

            // Measured in the field: one author repeated three zero-change rounds while the
            // reviewer restated four findings verbatim, burning the user's granted budget.
            // Identical consecutive rounds mean nobody is moving — stop, keep the budget,
            // and say whose fault it is.
            let previous = item.findings.filter { $0.round == pass - 1 }
            if pass >= 2, !found.isEmpty,
               Self.normalizedFindingSet(found) == Self.normalizedFindingSet(previous) {
                _ = await runAcceptanceGate(item, project: project)
                if Task.isCancelled { item.state = .cancelled; return }
                let unspent = max(0, item.roundBudget - pass)
                item.state = .notConverging
                item.nonConvergenceNote = "author not converging — round \(pass) repeated "
                    + "round \(pass - 1)'s findings verbatim; \(unspent) budgeted "
                    + "round\(unspent == 1 ? "" : "s") left unspent"
                item.reassignAdvice = reassignmentAdvice(avoiding: item.author)
                note("\(item.title): stopped — \(item.nonConvergenceNote ?? "")")
                await requestRecommendation(item, project: project)
                return
            }

            if found.isEmpty {
                let gatePassed = await runAcceptanceGate(item, project: project)
                if Task.isCancelled { item.state = .cancelled; return }
                if gatePassed {
                    item.state = .accepted
                    return
                }
                let gateFindings = findingsFromGate(item.gate, round: pass)
                item.findings.append(contentsOf: gateFindings)
                if atCap {
                    // Gate objections are still objections: land where resume and the
                    // grant stepper can see them, plus one recommendation turn.
                    item.state = .acceptedWithObjections
                    note("\(item.title): round cap (\(item.roundBudget)) reached with "
                         + "the acceptance gate still failing.")
                    await requestRecommendation(item, project: project)
                    return
                }
                await revise(item, author: author, findings: gateFindings, afterRound: pass,
                             project: project)
                if item.state == .failed || item.state == .cancelled { return }
                continue
            }
            if atCap {
                // Bounded: surface the disagreement instead of looping. The gate still
                // runs so a red build is never shown as a clean accept-with-objections.
                _ = await runAcceptanceGate(item, project: project)
                if Task.isCancelled { item.state = .cancelled; return }
                item.state = .acceptedWithObjections
                note("\(item.title): round cap (\(item.roundBudget)) reached with "
                     + "\(found.count) finding(s) standing.")
                await requestRecommendation(item, project: project)
                return
            }

            await revise(item, author: author, findings: found, afterRound: pass,
                         project: project)
            if item.state == .failed || item.state == .cancelled { return }
        }
        if Task.isCancelled { item.state = .cancelled }
    }

    private func revise(_ item: WorkItem, author: TurnCollector, findings: [ReviewFinding],
                        afterRound pass: Int, project: URL) async {
        item.state = .revising
        let revision = await performTurn(author,
                                         prompt: Prompts.revise(item: item,
                                                                findings: findings),
                                         role: "author", item: item, project: project)
        record(revision, in: item, provider: item.author, role: "author",
               title: "Revision after round \(pass)")
        if revision.failed {
            item.state = Task.isCancelled ? .cancelled : .failed
            return
        }
        for path in revision.editedFiles where !item.filesTouched.contains(path) {
            item.filesTouched.append(path)
        }
    }

    /// One orchestrator turn after the budget is spent. The run does not wait on the
    /// user: the item stays `acceptedWithObjections` and the next item proceeds.
    private func requestRecommendation(_ item: WorkItem, project: URL) async {
        guard !Task.isCancelled else { return }
        let collector = await openCollector(orchestratorProvider, role: .orchestrator,
                                            project: project, item: item)
        defer { closeCollector(collector) }
        let reply = await performTurn(collector,
                                      prompt: Prompts.recommend(item: item),
                                      role: "orchestrator", item: item, project: project)
        record(reply, in: item, provider: orchestratorProvider, role: "orchestrator",
               title: "Round-budget recommendation")
        let raw = reply.text.isEmpty
            ? (reply.failureMessage ?? "(no reply text)") : reply.text
        let parsed = Self.parseRecommendation(raw)
        item.recommendedExtraRounds = parsed.extraRounds
        item.recommendationAccepts = parsed.accept
        item.recommendationReason = parsed.reason
    }

    /// Resolve and run every build/test task. Returns true when nothing executed failed
    /// (including: switched off, no tasks, all skipped). A skip is never counted as a pass
    /// on the record itself; `GateResult.passed` requires at least one executed success.
    @discardableResult
    /// `.orrery-gate.json` at the project root adds gate commands the task catalog cannot
    /// infer — this repo's real test suite is `--audit`, which is neither a build nor a test
    /// task, and a red audit slid through a green gate once (run 10) before this existed.
    static func repoGateTasks(project: URL) -> [RunTask] {
        let url = project.appendingPathComponent(".orrery-gate.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commands = object["commands"] as? [[String: Any]] else { return [] }
        return commands.prefix(4).compactMap { command in
            guard let title = command["title"] as? String,
                  let executable = command["executable"] as? String else { return nil }
            let arguments = (command["arguments"] as? [String]) ?? []
            let resolved = executable.hasPrefix("/")
                ? executable : project.appendingPathComponent(executable).path
            return RunTask(id: "gate-\(title)", title: title, executable: resolved,
                           arguments: arguments, directory: project, kind: .test,
                           source: ".orrery-gate.json",
                           missingTool: FileManager.default.isExecutableFile(atPath: resolved)
                               ? nil : title)
        }
    }

    private func runAcceptanceGate(_ item: WorkItem, project: URL) async -> Bool {
        guard followGate else { return true }
        guard !Task.isCancelled else { return true }

        let tasks = gateTasksOverride
            ?? (TaskCatalog.tasks(project: project, activeFile: nil, language: nil)
                    .filter { $0.kind == .build || $0.kind == .test }
                + Self.repoGateTasks(project: project))

        item.isGating = true
        defer { item.isGating = false }

        var results: [GateTaskResult] = []
        for task in tasks {
            if Task.isCancelled { break }
            if task.missingTool != nil || task.executable == nil {
                results.append(GateTaskResult(
                    taskID: task.id, title: task.title, passed: false, exitCode: nil,
                    timedOut: false, skippedMissingTool: true,
                    missingTool: task.missingTool ?? "executable",
                    outputTail: "", firstErrorLine: "", diagnostics: []))
                continue
            }
            let executable = task.executable!
            do {
                let run = try await ProcessRunner.run(
                    executable, task.arguments, cwd: task.directory,
                    timeout: gateTimeout)
                if Task.isCancelled || run.cancelled { break }
                let stdout = run.standardOutput
                let stderr = run.standardError
                let directory = task.directory
                let scan = await Task.detached {
                    let combined = stdout + (stdout.isEmpty ? "" : "\n") + stderr
                    return GateResult.scan(combined, directory: directory)
                }.value
                let passed = !run.timedOut && run.status == 0
                results.append(GateTaskResult(
                    taskID: task.id, title: task.title, passed: passed,
                    exitCode: run.status, timedOut: run.timedOut,
                    skippedMissingTool: false, missingTool: nil,
                    outputTail: scan.tail, firstErrorLine: scan.firstErrorLine,
                    diagnostics: scan.diagnostics))
            } catch {
                results.append(GateTaskResult(
                    taskID: task.id, title: task.title, passed: false, exitCode: nil,
                    timedOut: false, skippedMissingTool: false, missingTool: nil,
                    outputTail: error.localizedDescription,
                    firstErrorLine: error.localizedDescription, diagnostics: []))
            }
        }

        let gate = GateResult(tasks: results)
        item.gate = gate
        let summary: String
        if results.isEmpty {
            summary = "No build or test task in this project."
        } else {
            summary = results.map { task -> String in
                if task.skippedMissingTool {
                    return "\(task.title) skipped — \(task.missingTool ?? "a tool") not installed"
                }
                if task.timedOut {
                    return "\(task.title) timed out after \(Int(gateTimeout))s"
                }
                if let code = task.exitCode {
                    return "\(task.title) exited \(code)"
                }
                return "\(task.title) failed"
            }.joined(separator: "\n")
        }
        item.lane.append(LaneEntry(provider: orchestratorProvider, role: "system",
                                   title: "Acceptance gate", text: summary, costUSD: nil))
        if gate.hasFailure {
            note("\(item.title): acceptance gate failed.")
        }
        return !gate.hasFailure
    }

    private func findingsFromGate(_ gate: GateResult?, round: Int) -> [ReviewFinding] {
        guard let gate else { return [] }
        return gate.tasks.compactMap { task -> ReviewFinding? in
            guard !task.skippedMissingTool, !task.passed else { return nil }
            let diag = task.diagnostics.first { $0.severity == "error" } ?? task.diagnostics.first
            let errorLine: String
            if task.timedOut {
                errorLine = "timed out after \(Int(gateTimeout))s"
            } else if !task.firstErrorLine.isEmpty {
                errorLine = task.firstErrorLine
            } else {
                errorLine = "(no output)"
            }
            let code = task.exitCode.map { String($0) } ?? "?"
            return ReviewFinding(
                file: diag?.file ?? "",
                line: diag?.line,
                severity: "gate",
                message: "GATE: \(task.title) exited \(code) — \(errorLine)",
                round: round)
        }
    }

    /// One turn with the live view wired: activity streams into the item's card (or the
    /// planning slot), files are captured as they are edited, and the slot clears when the
    /// turn lands.
    private func performTurn(_ collector: TurnCollector, prompt: String, role: String,
                             item: WorkItem?, project: URL) async -> TurnCollector.TurnResult {
        var live = LiveTurn(provider: collector.provider, role: role)
        var editToolPath: [String: String] = [:]
        var toolsThatStreamedDiffs: Set<String> = []
        let publish: (LiveTurn?) -> Void = { [weak self, weak item] value in
            if let item { item.live = value } else { self?.planningLive = value }
        }
        let notifyEdit: (String) -> Void = { [weak self] path in
            guard let self, self.followEdits, !path.isEmpty else { return }
            let resolved = path.hasPrefix("/")
                ? URL(fileURLWithPath: path).standardizedFileURL.path
                : project.appendingPathComponent(path).standardizedFileURL.path
            self.onFileEdited?(resolved)
        }
        publish(live)
        collector.onActivity = { [weak item] event in
            live.lastEventAt = Date()
            switch event {
            case let .assistantDelta(text):
                live.text = String((live.text + text).suffix(1_500))
            case let .thoughtDelta(text):
                live.thinkingCharacters += text.count
            case let .toolStarted(id, title, kind, input):
                live.tools.append(title)
                if live.tools.count > 8 { live.tools.removeFirst(live.tools.count - 8) }
                if kind == "edit" {
                    let path = TurnCollector.filePath(inToolInput: input) ?? ""
                    if !path.isEmpty {
                        editToolPath[id] = path
                        live.editedPath = path
                        if live.diff == nil { live.diffUnavailable = false }
                    }
                    if let item, !path.isEmpty, !item.filesTouched.contains(path) {
                        item.filesTouched.append(path)
                    }
                    notifyEdit(path)
                }
            case let .toolUpdated(id, status, _, diff):
                if let diff {
                    toolsThatStreamedDiffs.insert(id)
                    live.diff = diff
                    live.editedPath = diff.path
                    live.diffUnavailable = false
                    if let item, !item.filesTouched.contains(diff.path) {
                        item.filesTouched.append(diff.path)
                    }
                    notifyEdit(diff.path)
                } else if let path = editToolPath[id], !path.isEmpty {
                    live.editedPath = path
                    // Only THIS tool's history decides: a finished edit whose own tool never
                    // streamed a patch gets the no-diff note, even when an earlier tool in
                    // the same turn did stream one (the guard used to be turn-scoped, and a
                    // review probe showed the mixed case being swallowed).
                    if Self.toolHasFinished(status) && !toolsThatStreamedDiffs.contains(id) {
                        live.diffUnavailable = true
                    }
                }
            default:
                break
            }
            publish(live)
        }
        // A pooled session already has this snapshot. A replacement or reviewer session
        // receives it independently, even when the planner omitted it from the brief.
        let context = collector.hasReceivedTaskContext ? "" : taskContext
        collector.hasReceivedTaskContext = true
        let result = await collector.send(context + prompt, stallTimeout: turnTimeout)
        collector.onActivity = nil
        publish(nil)
        return result
    }

    private static func toolHasFinished(_ status: String?) -> Bool {
        guard let status else { return false }
        switch status.lowercased() {
        case "completed", "failed", "success", "error": return true
        default: return false
        }
    }

    private func record(_ turn: TurnCollector.TurnResult, in item: WorkItem,
                        provider: Provider, role: String, title: String) {
        item.turns += 1
        if let cost = turn.costUSD {
            item.costUSD += cost
        } else {
            item.unreportedTurns += 1
        }
        var text = turn.text.isEmpty
            ? (turn.failureMessage ?? "(no reply text)") : turn.text
        if turn.timedOut { text += "\n[stalled — no activity for \(Int(turnTimeout))s]" }
        let ended = Date()
        for approval in turn.autoApprovals {
            item.lane.append(LaneEntry(provider: provider, role: "system",
                                       title: "Auto-approved", text: approval, costUSD: nil,
                                       at: turn.startedAt, endedAt: ended))
        }
        item.lane.append(LaneEntry(provider: provider, role: role, title: title,
                                   text: text, costUSD: turn.costUSD,
                                   editedFileCount: turn.editedFiles.count,
                                   at: turn.startedAt, endedAt: ended))
    }

    /// Append exactly one `RunOutcome` when a real run reaches done / cancelled / failed.
    /// Swallows every error; never called for demo data or a start-blocker.
    private func recordTeamStatsIfNeeded() {
        switch phase {
        case .done, .cancelled, .failed: break
        default: return
        }
        guard !isDemo, teamStatsRunStarted, !teamStatsRecordedForRun else { return }
        guard let url = teamStatsURL else { return }
        teamStatsRecordedForRun = true
        // Snapshot on this actor (WorkItem is MainActor); encode and append elsewhere
        // so a stalling disk cannot hitch the window.
        let outcome = TeamStats.outcome(from: self)
        Task.detached {
            TeamStats.append(outcome, to: url)
        }
    }

    /// `--orchestrate-demo`: a no-spend collage so the live turn view and the
    /// finished-with-objections grant UI can both be inspected. Phase is `.done`
    /// (nothing is actually running) so the grant stepper and buttons render.
    func seedDemo() {
        isDemo = true
        teamStatsRunStarted = false
        phase = .done
        planRaw = "```json\n{\"items\": ["
            + "{\"title\": \"Wire the parser\", \"author\": \"grok\", \"brief\": \"…\", \"rounds\": 2}, "
            + "{\"title\": \"Rewrite the bound check\", \"author\": \"grok\", \"brief\": \"…\", \"rounds\": 2}, "
            + "{\"title\": \"Cover the empty case\", \"author\": \"claude\", \"brief\": \"…\"}"
            + "]}\n```"
        planCostUSD = 0.0113
        let writing = WorkItem(title: "Wire the parser", brief: "Connect the tokenizer output.",
                               author: .grok, reviewer: .claude)
        writing.state = .authoring
        writing.turns = 1
        writing.unreportedTurns = 1
        writing.filesTouched = ["Sources/Parser/Tokenizer.swift"]
        var live = LiveTurn(provider: .grok, role: "author")
        live.startedAt = Date().addingTimeInterval(-754)
        live.lastEventAt = Date().addingTimeInterval(-2)
        live.thinkingCharacters = 18_402
        live.tools = ["Read · Tokenizer.swift", "Edit · Tokenizer.swift",
                      "Bash · swift build 2>&1 | tail -5", "Edit · Tokenizer.swift"]
        live.text = "The bound check was wrong for the empty case — fixing the guard and "
            + "re-running the build to confirm before I touch the tests."
        live.editedPath = "Sources/Parser/Tokenizer.swift"
        live.diff = FileDiff(
            path: "Sources/Parser/Tokenizer.swift",
            oldText: """
            func nextToken() -> Token {
                guard cursor < source.count else { return .eof }
                return scan()
            }
            """,
            newText: """
            func nextToken() -> Token {
                guard cursor < source.count else { return .eof }
                if source.isEmpty { return .eof }
                return scan()
            }
            """)
        writing.live = live
        let done = WorkItem(title: "Cover the empty case", brief: "Add the missing tests.",
                            author: .claude, reviewer: .grok)
        done.state = .accepted
        done.round = 1
        done.turns = 2
        done.costUSD = 0.0891
        done.filesTouched = ["Tests/ParserTests.swift"]
        done.lane = [LaneEntry(provider: .claude, role: "author", title: "Wrote it",
                               text: "Added four cases. FILES: Tests/ParserTests.swift",
                               costUSD: 0.0891),
                     LaneEntry(provider: .grok, role: "reviewer", title: "Review round 1",
                               text: "NO FINDINGS", costUSD: nil),
                     LaneEntry(provider: .grok, role: "system", title: "Acceptance gate",
                               text: "swift build exited 0\nswift test exited 0", costUSD: nil)]
        done.gate = GateResult(tasks: [
            GateTaskResult(taskID: "swift-build", title: "swift build", passed: true,
                           exitCode: 0, timedOut: false, skippedMissingTool: false,
                           missingTool: nil, outputTail: "Build complete!", diagnostics: []),
            GateTaskResult(taskID: "swift-test", title: "swift test", passed: true,
                           exitCode: 0, timedOut: false, skippedMissingTool: false,
                           missingTool: nil, outputTail: "Test Suite passed.", diagnostics: []),
        ])
        let stuck = WorkItem(title: "Rewrite the bound check",
                             brief: "Fix the empty-input case.",
                             author: .grok, reviewer: .claude, roundBudget: 2)
        stuck.state = .acceptedWithObjections
        stuck.round = 2
        stuck.turns = 4
        stuck.unreportedTurns = 1
        stuck.costUSD = 0.0412
        stuck.filesTouched = ["Sources/Parser/Tokenizer.swift"]
        stuck.findings = [ReviewFinding(file: "Sources/Parser/Tokenizer.swift", line: 12,
                                        severity: "bug",
                                        message: "empty input still traps", round: 2)]
        stuck.recommendedExtraRounds = 2
        stuck.recommendationReason = "the empty-input trap is still real"
        stuck.lane = [
            LaneEntry(provider: .grok, role: "author", title: "Wrote it",
                      text: "Tightened the guard. FILES: Sources/Parser/Tokenizer.swift",
                      costUSD: 0.02),
            LaneEntry(provider: .claude, role: "reviewer", title: "Review round 2",
                      text: "FINDING: Sources/Parser/Tokenizer.swift:12: bug: empty input still traps",
                      costUSD: nil),
            LaneEntry(provider: .grok, role: "orchestrator",
                      title: "Round-budget recommendation",
                      text: "RECOMMEND: 2 more rounds: the empty-input trap is still real",
                      costUSD: 0.003),
            LaneEntry(provider: .grok, role: "system", title: "Acceptance gate",
                      text: "swift test exited 1", costUSD: nil),
        ]
        stuck.gate = GateResult(tasks: [
            GateTaskResult(taskID: "swift-test", title: "swift test", passed: false,
                           exitCode: 1, timedOut: false, skippedMissingTool: false,
                           missingTool: nil,
                           outputTail: "Tests/ParserTests.swift:12:1: error: empty input still traps",
                           diagnostics: [
                               GateDiagnostic(file: "Tests/ParserTests.swift", line: 12,
                                              column: 1, severity: "error",
                                              message: "empty input still traps"),
                           ]),
        ])
        items = [done, stuck, writing]
        log = ["Planning with Grok…", "3 work item(s) planned.",
               "Rewrite the bound check: round cap (2) reached with 1 finding(s) standing."]
    }

    // MARK: Plan parsing

    struct PlannedItem: Equatable {
        var title: String
        var author: Provider
        var brief: String
        /// Nil when the plan omitted `rounds` — the engine fills in `maxRounds`.
        var rounds: Int? = nil
    }

    struct RecommendationParse: Equatable {
        /// Set only for `RECOMMEND: <N> more rounds:` — 0 is 0, not accept.
        var extraRounds: Int?
        /// Set only for `RECOMMEND: accept:`. Distinct from extraRounds == 0.
        var accept: Bool = false
        var reason: String
    }

    enum PlanParse: Equatable {
        case success([PlannedItem])
        case failure(String)
    }

    /// Strict: a JSON object with an `items` array of {title, author, brief}. The JSON may be
    /// fenced or bare, but nothing is guessed — a plan that does not parse is shown raw.
    static func parsePlan(_ text: String, allowed: [Provider]) -> PlanParse {
        guard let json = extractJSONObject(from: text) else {
            return .failure("no JSON object found in the reply")
        }
        guard let rows = json["items"] as? [[String: Any]] else {
            return .failure("the JSON has no \"items\" array")
        }
        guard !rows.isEmpty else { return .failure("the \"items\" array is empty") }
        guard rows.count <= 6 else {
            return .failure("\(rows.count) items is past the cap of 6 — refusing a runaway plan")
        }
        var parsed: [PlannedItem] = []
        for (index, row) in rows.enumerated() {
            guard let title = row["title"] as? String, !title.isEmpty,
                  let brief = row["brief"] as? String, !brief.isEmpty,
                  let authorName = row["author"] as? String else {
                return .failure("item \(index + 1) is missing title, author, or brief")
            }
            guard let author = Provider(rawValue: authorName.lowercased()) else {
                return .failure("item \(index + 1) names an unknown author \"\(authorName)\"")
            }
            guard allowed.contains(author) else {
                return .failure("item \(index + 1) assigns \(author.displayName), "
                                + "which is not an enabled worker here")
            }
            var rounds: Int? = nil
            if let raw = Self.jsonInt(row["rounds"]) {
                rounds = min(5, max(1, raw))
            }
            parsed.append(PlannedItem(title: title, author: author, brief: brief,
                                      rounds: rounds))
        }
        return .success(parsed)
    }

    /// JSONSerialization boxes numbers as NSNumber. Boolean NSNumbers are skipped
    /// (`rounds: true` is not a round count); every NSNumber `is Bool` under
    /// bridging, so the CFBoolean type id is the real test.
    private static func jsonInt(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.intValue
        }
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    private static func extractJSONObject(from text: String) -> [String: Any]? {
        // Prefer a fenced block; fall back to the outermost braces.
        var candidates: [String] = []
        var scanning = text[...]
        while let fenceStart = scanning.range(of: "```") {
            let afterFence = scanning[fenceStart.upperBound...]
            guard let fenceEnd = afterFence.range(of: "```") else { break }
            var block = String(afterFence[..<fenceEnd.lowerBound])
            if let newline = block.firstIndex(of: "\n"), block.hasPrefix("json") {
                block = String(block[block.index(after: newline)...])
            }
            candidates.append(block)
            scanning = afterFence[fenceEnd.upperBound...]
        }
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"),
           open < close {
            candidates.append(String(text[open...close]))
        }
        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
        }
        return nil
    }

    /// Line numbers drift between rounds even when nothing changed; the identity of a
    /// finding for convergence purposes is where it points and what it says.
    static func normalizedFindingSet(_ findings: [ReviewFinding]) -> Set<String> {
        Set(findings.map { finding in
            let file = (finding.file as NSString).lastPathComponent.lowercased()
            let message = finding.message.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return "\(file)|\(finding.severity.lowercased())|\(message)"
        })
    }

    /// One line per measured author seat, for the planner. Nil with no usable data.
    func authorSeatHistory() -> String? {
        guard let url = teamStatsURL else { return nil }
        let stats = TeamStats.aggregate(records: TeamStats.load(from: url).records)
        let lines = stats
            .filter { $0.key.role == "author" && $0.value.items >= 2 }
            .sorted { $0.value.items > $1.value.items }
            .prefix(6)
            .map { key, value in
                "- \(key.provider) · \(key.model): \(value.cleanAccepts)/\(value.items) clean accepts"
            }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The best measured author seat that is not the one that just failed to move — or an
    /// honest "no measured alternative" when the store cannot justify a name.
    func reassignmentAdvice(avoiding failed: Provider) -> String {
        guard let url = teamStatsURL else { return "no seat data available in audit mode" }
        let stats = TeamStats.aggregate(records: TeamStats.load(from: url).records)
        let candidates = stats.filter { key, value in
            key.role == "author" && key.provider != failed.rawValue && value.items >= 2
        }
        guard let best = candidates.max(by: { a, b in
            let ra = Double(a.value.cleanAccepts) / Double(max(1, a.value.items))
            let rb = Double(b.value.cleanAccepts) / Double(max(1, b.value.items))
            return ra < rb
        }) else {
            return "no measured alternative author seat yet (need 2+ recorded items)"
        }
        let rate = "\(best.value.cleanAccepts)/\(best.value.items) clean"
        let provider = Provider(rawValue: best.key.provider)?.displayName ?? best.key.provider
        return "retry with \(provider) · \(best.key.model) as author (\(rate))"
    }

    // MARK: Findings parsing

    /// `FINDING: path:line: severity: message`, one per line; `NO FINDINGS` means clean. A
    /// reply that matches neither is kept verbatim as a single unparsed finding — surfaced,
    /// never dropped, never invented into structure it does not have.
    static func parseFindings(_ text: String, round: Int) -> [ReviewFinding] {
        var findings: [ReviewFinding] = []
        var sawStructure = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("NO FINDINGS") { sawStructure = true; continue }
            guard line.hasPrefix("FINDING:") else { continue }
            sawStructure = true
            let body = String(line.dropFirst("FINDING:".count))
                .trimmingCharacters(in: .whitespaces)
            // path:line: severity: message — but the path may itself contain colons rarely;
            // scan for the first ":<digits>:" split.
            var file = body
            var lineNumber: Int?
            var severity = "issue"
            var message = ""
            let parts = body.components(separatedBy: ":")
            if parts.count >= 2 {
                var index = 1
                var found = false
                while index < parts.count - 1 {
                    if let number = Int(parts[index].trimmingCharacters(in: .whitespaces)) {
                        file = parts[..<index].joined(separator: ":")
                            .trimmingCharacters(in: .whitespaces)
                        lineNumber = number
                        let rest = parts[(index + 1)...].joined(separator: ":")
                        let restParts = rest.components(separatedBy: ":")
                        severity = restParts.first?.trimmingCharacters(in: .whitespaces) ?? "issue"
                        message = restParts.dropFirst().joined(separator: ":")
                            .trimmingCharacters(in: .whitespaces)
                        found = true
                        break
                    }
                    index += 1
                }
                if !found {
                    file = parts[0].trimmingCharacters(in: .whitespaces)
                    severity = parts.count > 2
                        ? parts[1].trimmingCharacters(in: .whitespaces) : "issue"
                    message = parts.dropFirst(parts.count > 2 ? 2 : 1).joined(separator: ":")
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            if message.isEmpty { message = body }
            findings.append(ReviewFinding(file: file, line: lineNumber, severity: severity,
                                          message: message, round: round))
        }
        // Reviewers write prose around the verdict — "…confirmed working. NO FINDINGS" glued
        // to a sentence is still a clean verdict (seen live from Grok). Only a reply with
        // neither the phrase nor any FINDING: line is surfaced as unparsed.
        if !sawStructure && findings.isEmpty && text.uppercased().contains("NO FINDINGS") {
            return []
        }
        if !sawStructure && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(ReviewFinding(
                file: "", line: nil, severity: "unparsed",
                message: String(text.prefix(600)), round: round))
        }
        return findings
    }

    /// Strict: the trimmed reply must be exactly `RECOMMEND: accept: <why>` or
    /// `RECOMMEND: <N> more rounds: <why>`. Anything else is unparseable — the
    /// raw text is returned as `reason` and `extraRounds` stays nil. Accept and
    /// "0 more rounds" are different forms; neither is stored as the other.
    static func parseRecommendation(_ text: String) -> RecommendationParse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let acceptPrefix = "RECOMMEND: accept:"
        if trimmed.hasPrefix(acceptPrefix) {
            let why = trimmed.dropFirst(acceptPrefix.count)
                .trimmingCharacters(in: .whitespaces)
            return RecommendationParse(extraRounds: nil, accept: true, reason: String(why))
        }
        let head = "RECOMMEND: "
        guard trimmed.hasPrefix(head) else {
            return RecommendationParse(extraRounds: nil, reason: trimmed)
        }
        let rest = trimmed.dropFirst(head.count)
        var digits = ""
        var idx = rest.startIndex
        while idx < rest.endIndex, rest[idx].isASCII, rest[idx].isNumber {
            digits.append(rest[idx])
            idx = rest.index(after: idx)
        }
        let mid = " more rounds:"
        if !digits.isEmpty, rest[idx...].hasPrefix(mid), let n = Int(digits) {
            let why = rest[rest.index(idx, offsetBy: mid.count)...]
                .trimmingCharacters(in: .whitespaces)
            return RecommendationParse(extraRounds: n, reason: String(why))
        }
        return RecommendationParse(extraRounds: nil, reason: trimmed)
    }
}

// MARK: - Prompts

/// The exact words each role receives. Strict formats, because the other end is parsed — and
/// when parsing fails the raw reply is shown, so these ask for as little prose as possible.
@MainActor
enum Prompts {

    static func plan(task: String, project: URL, workers: [Provider],
                     seatHistory: String? = nil) -> String {
        let names = workers.map(\.rawValue).joined(separator: ", ")
        let history = seatHistory.map {
            "\nMeasured author records from previous runs (weigh assignments accordingly; "
            + "a seat with repeated zero-progress rounds should not get engine-critical "
            + "work):\n\($0)\n"
        } ?? ""
        return """
        You are the orchestrator of a team of coding agents working in the project at \
        \(project.path). Your workers: \(names). You do not write code yourself — you split \
        the task into work items and assign each to one worker.
        \(history)

        The user's task:
        \(task)

        Reply with ONLY a fenced JSON block, no other prose:
        ```json
        {"items": [{"title": "short name", "author": "\(workers.first?.rawValue ?? "claude")", \
        "brief": "complete, self-contained instructions for that worker", "rounds": 2}]}
        ```
        Rules: 1 to 4 items; "author" must be one of: \(names); each brief must stand alone \
        (the worker sees nothing else); prefer fewer, larger items; "rounds" is a recommended \
        number of review rounds based on the item's complexity, an integer from 1 to 5.
        """
    }

    static func author(item: WorkItem, project: URL) -> String {
        """
        You are the author of work item "\(item.title)" in the project at \(project.path). \
        Make the changes directly in the project files with your tools.

        The brief:
        \(item.brief)

        When you are done, reply with a short summary of what you changed and one final line:
        FILES: comma-separated paths of every file you created or modified
        """
    }

    static func review(item: WorkItem, project: URL) -> String {
        """
        You are the reviewer of work item "\(item.title)". You did NOT write it — review it \
        adversarially for real bugs and real gaps against the brief. Read the files in the \
        project; do not modify anything.

        The brief the author worked from:
        \(item.brief)

        \(filesSection(item))

        Report one finding per line, EXACTLY this format, nothing else:
        FINDING: <path>:<line>: <bug|gap>: <one-line description>
        Use line 0 when a finding has no single line. If the work is correct and complete, \
        reply with exactly:
        NO FINDINGS
        """
    }

    /// The scoped form used after a user grants rounds: verdict every standing finding,
    /// flag real regressions, park everything else as advisory. No new scope hunting.
    static func grantReReview(item: WorkItem, standing: [ReviewFinding]) -> String {
        let list = standing.enumerated().map { index, finding in
            "F\(index + 1): \(finding.file)\(finding.line.map { ":\($0)" } ?? "") "
            + "[\(finding.severity)] \(finding.message)"
        }.joined(separator: "\n")
        return """
        The author has revised work item "\(item.title)" to address the standing findings \
        below. Your job is ONLY to verify these findings and check the touched files for \
        regressions — do not expand the review to new topics.

        Standing findings:
        \(list)

        Reply with one line per standing finding, EXACTLY:
        RESOLVED: F<n>
        NOT RESOLVED: F<n>: <one line why>
        Plus, only if the revision broke something in the touched files:
        REGRESSION: <path>:<line>: <one line description>
        Anything else worth saying goes on ADVISORY: lines and will be recorded as \
        non-blocking notes. A finding you do not mention counts as NOT resolved. If every \
        standing finding is fixed and you found no regression, you may simply reply \
        NO FINDINGS.
        """
    }

    static func reReview(item: WorkItem, project: URL) -> String {
        let afterGate = !item.openFindings.isEmpty
            && item.openFindings.allSatisfy { $0.severity == "gate" }
        let why = afterGate
            ? "after the acceptance gate failed"
            : "after your findings"
        return """
        The author has revised work item "\(item.title)" \(why). Re-read the \
        files and check both the fixes and anything new the revision broke.

        \(filesSection(item))

        Same format as before — FINDING: <path>:<line>: <bug|gap>: <description> lines, \
        or exactly NO FINDINGS.
        """
    }

    static func revise(item: WorkItem, findings: [ReviewFinding]) -> String {
        let lines = findings.map(findingLine).joined(separator: "\n")
        let gateOnly = !findings.isEmpty && findings.allSatisfy { $0.severity == "gate" }
        let intro = gateOnly
            ? "The acceptance gate for work item \"\(item.title)\" failed:"
            : "The reviewer examined your work on \"\(item.title)\" and found these problems:"
        return """
        \(intro)

        \(lines)

        Fix them in the project files. If a finding is wrong, say why in one line instead of \
        changing code. Then reply with a short summary and the final line:
        FILES: comma-separated paths of every file you touched
        """
    }

    static func recommend(item: WorkItem) -> String {
        let standing = item.openFindings
        let lines: String
        if standing.isEmpty {
            lines = "(none listed)"
        } else {
            lines = standing.map(findingLine).joined(separator: "\n")
        }
        let gateOnly = !standing.isEmpty && standing.allSatisfy { $0.severity == "gate" }
        let why = gateOnly
            ? "the acceptance gate is still failing"
            : "the reviewer still has findings standing"
        let heading = gateOnly ? "Standing gate failures:" : "Standing findings:"
        return """
        You are the orchestrator. Work item "\(item.title)" has used its full review-round \
        budget of \(item.roundBudget) and \(why).

        \(heading)
        \(lines)

        Reply with EXACTLY one of these two forms, nothing else:
        RECOMMEND: accept: <one line why>
        RECOMMEND: <N> more rounds: <one line why>
        """
    }

    /// Gate findings already carry the `GATE: …` sentence; do not wrap them as
    /// `- : gate: GATE: …` or attribute them to the reviewer.
    private static func findingLine(_ finding: ReviewFinding) -> String {
        if finding.severity == "unparsed" {
            return "The reviewer replied unstructured: \(finding.message)"
        }
        if finding.severity == "gate" {
            if finding.file.isEmpty { return "- \(finding.message)" }
            return "- \(finding.file)\(finding.line.map { ":\($0)" } ?? ""): \(finding.message)"
        }
        return "- \(finding.file)\(finding.line.map { ":\($0)" } ?? ""): "
            + "\(finding.severity): \(finding.message)"
    }

    /// What the reviewer is told about scope — honest when file capture came up empty.
    private static func filesSection(_ item: WorkItem) -> String {
        if item.filesTouched.isEmpty {
            return "No file edits were captured from the author's tool stream, so the change "
                + "set is unknown — start from the author's summary below and inspect the "
                + "project yourself.\nAuthor's last reply:\n"
                + String((item.lane.last { $0.role == "author" }?.text ?? "").prefix(2_000))
        }
        return "Files the author touched:\n"
            + item.filesTouched.map { "- \($0)" }.joined(separator: "\n")
    }
}

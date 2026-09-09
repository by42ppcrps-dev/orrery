import Foundation

/// One thread, every agent, and you. A human message goes to every enabled agent at once (or
/// to the ones named with @Grok, @Claude, @Codex); each answers from its own session, then,
/// when replies are set to more than one, each answers the others. Agents see the whole
/// transcript, including each other.
///
/// Two modes. **Discuss**: sessions are discussion sessions — tool approvals are refused, so
/// nothing is written; reading the project stays possible where the CLI allows it without
/// asking. **Work**: every agent runs in one shared, isolated working copy of the project, may
/// edit it, run its tasks and use the IDE, browser and computer tools it has been given; tool
/// approvals follow the project's rule (ask, or run without asking) exactly as in Solo and
/// Team, agents take turns inside a round so their edits do not collide, and nothing reaches
/// the project until the user applies it from Changes.
///
/// Replies are capped (1–3) or unlimited: unlimited rounds continue until every agent in a
/// round says it has nothing further, the user presses Stop, or a hard ceiling is reached.
@MainActor @Observable
final class Roundtable {
    struct Entry: Identifiable, Codable, Equatable {
        var id = UUID()
        /// "human" or a provider's raw value.
        var speaker: String
        var text: String
        var costUSD: Double?
        var round = 0
        var createdAt = Date()
        var failed = false
        /// Files the agent edited during this turn (Work mode), as the backend reported them.
        var editedFiles: [String]? = nil
        /// The model and reasoning effort that produced this reply.
        var model: String? = nil
        var effort: String? = nil

        var provider: Provider? { Provider(rawValue: speaker) }
        var displayName: String { provider?.displayName ?? "You" }
    }

    enum Mode: String, Codable, CaseIterable, Identifiable {
        case discuss, work
        var id: String { rawValue }
        var title: String { self == .discuss ? "Discuss" : "Work" }
    }

    /// What the per-project store holds. Older stores held a bare `[Entry]`.
    struct State: Codable {
        var entries: [Entry] = []
        var mode: Mode = .discuss
        var unlimitedReplies = false
        var rounds = 2
        var workspaceID: UUID?
        /// Per-seat choices keyed by provider; absent means "inherit the provider's setting".
        var seatModels: [String: String]? = nil
        var seatEfforts: [String: String]? = nil
        /// The agent that goes first each round and runs the plan; nil for no leader.
        var leader: String? = nil
        /// Each agent's own session id and how much of the transcript that session has seen, so
        /// a later message resumes the session instead of re-sending a recap.
        var sessionIDs: [String: String]? = nil
        var seen: [String: Int]? = nil
    }

    static let entryLimit = 300
    static let promptEntryCharacters = 6_000
    static let recapEntries = 12
    static let storeName = "Roundtable"
    static let passPhrase = "Nothing further."

    var participants: Set<Provider> = Set(Provider.allCases)
    var rounds = 2 { didSet { if !loading { save() } } }
    var unlimitedReplies = false { didSet { if !loading { save() } } }
    /// Unlimited replies still end somewhere: this many reply rounds at most, stated in the UI.
    var unlimitedCeiling = 50
    var mode: Mode = .discuss {
        didSet {
            guard mode != oldValue, !loading else { return }
            // A discussion session refuses tools and runs in the project; a work session runs
            // in the working copy with real approvals. Neither can be turned into the other.
            if !isRunning { releaseSessions() }
            save()
        }
    }
    var installed: [Provider] = []
    /// Each seat's model and reasoning effort for this roundtable; "" or absent inherits the
    /// provider's own setting. A change applies from that agent's next session.
    private(set) var seatModels: [Provider: String] = [:]
    private(set) var seatEfforts: [Provider: String] = [:]
    /// The agent that speaks first in every round and is told to run the plan. Without one the
    /// order is fixed (Grok, Claude, Codex), which made Grok the de-facto leader whatever you said.
    private(set) var leader: Provider?
    var makeBackend: (Provider) -> any AgentBackend = { AppModel.newBackend($0) }
    /// Fires whenever the transcript or the run state changes (the remote pushes on it).
    var onChange: (() -> Void)?
    var onAuthenticationFailure: ((Provider) -> Void)?
    var toolContext: () -> String = { "" }
    var stallTimeout: TimeInterval = 300
    var idleReleaseDelay: TimeInterval = 180
    /// The project's "run tools without asking" rule, applied in Work mode only.
    var autoApprove = false
    /// Work mode approvals go here (the app's permission sheet); Discuss mode refuses them.
    var permissionHandler: ((PermissionRequest, Provider) -> Void)?
    var permissionEnded: ((UUID) -> Void)?
    /// Working-copy plumbing, injected by the app (audits inject their own).
    var makeWorkspace: ((URL) async throws -> TaskWorkspace)?
    var loadWorkspace: ((UUID) async -> TaskWorkspace?)?
    var removeWorkspace: ((UUID) async -> Void)?

    private(set) var entries: [Entry] = []
    private(set) var isRunning = false
    private(set) var thinking: Set<Provider> = []
    private(set) var live: [Provider: String] = [:]
    private(set) var notice: String?
    private(set) var project: URL?
    private(set) var workspace: TaskWorkspace?
    private(set) var activeSessions: Set<Provider> = []
    /// Agents whose last turn failed because the subscription ran out for that model.
    private(set) var usageLimited: Set<Provider> = []
    /// Reply rounds completed in the current or last run (round 1 is the answer round).
    private(set) var lastRoundCount = 0

    /// A message the user typed while a run was in progress, waiting for the next round to
    /// carry it. The message itself is already in the transcript.
    @ObservationIgnored private var pendingSteer = false

    /// Seats whose model or effort changed while a run was in progress. Their session is
    /// replaced before that agent's next turn, so the change applies from its next message
    /// without disturbing the turn it is in.
    @ObservationIgnored private var restartedSeats: Set<Provider> = []

    @ObservationIgnored private var sessions: [Provider: TurnCollector] = [:]
    @ObservationIgnored private var seenCount: [Provider: Int] = [:]
    /// Session ids kept across releases and relaunches; the next turn resumes them.
    @ObservationIgnored private var sessionIDs: [Provider: String] = [:]
    /// Providers whose last turn was resumed rather than started fresh — the audit reads this.
    private(set) var resumedProviders: Set<Provider> = []
    @ObservationIgnored private var store: PrivateProjectFile?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var restoringWorkspace: Task<Void, Never>?

    var enabledTargets: [Provider] { Provider.allCases.filter { participants.contains($0) && installed.contains($0) } }

    // MARK: Project attachment and persistence

    func attach(project: URL?, storeDirectory: URL? = nil) {
        stop()
        sessions = [:]; seenCount = [:]; activeSessions = []
        self.project = project
        entries = []
        workspace = nil
        store = project.map { PrivateProjectFile(project: $0, directory: storeDirectory ?? PrivateProjectFile.defaultDirectory(Self.storeName), byteLimit: 2 * 1024 * 1024) }
        loading = true
        defer { loading = false }
        seatModels = [:]; seatEfforts = [:]; leader = nil; sessionIDs = [:]
        if let saved = try? store?.load(State.self) {
            leader = saved.leader.flatMap(Provider.init(rawValue:))
            for (key, value) in saved.sessionIDs ?? [:] { if let provider = Provider(rawValue: key), AppModel.isResumableSession(value) { sessionIDs[provider] = value } }
            for (key, value) in saved.seen ?? [:] { if let provider = Provider(rawValue: key), sessionIDs[provider] != nil { seenCount[provider] = min(value, saved.entries.suffix(Self.entryLimit).count) } }
            entries = Array(saved.entries.suffix(Self.entryLimit))
            mode = saved.mode
            unlimitedReplies = saved.unlimitedReplies
            rounds = min(max(saved.rounds, 1), 3)
            for (key, value) in saved.seatModels ?? [:] { if let provider = Provider(rawValue: key), !value.isEmpty { seatModels[provider] = value } }
            for (key, value) in saved.seatEfforts ?? [:] { if let provider = Provider(rawValue: key), !value.isEmpty { seatEfforts[provider] = value } }
            if mode == .work, let id = saved.workspaceID {
                restoringWorkspace?.cancel()
                restoringWorkspace = Task { [weak self] in
                    guard let self, let loadWorkspace = self.loadWorkspace else { return }
                    let found = await loadWorkspace(id)
                    guard !Task.isCancelled, self.project == project else { return }
                    self.workspace = found
                    if found == nil { self.notice = "The roundtable's working copy is gone; the next message starts a new one." }
                }
            }
        } else if let saved = try? store?.load([Entry].self) {
            entries = Array(saved.suffix(Self.entryLimit))
        }
    }

    private func save() {
        onChange?()
        guard let store else { return }
        let state = State(entries: Array(entries.suffix(Self.entryLimit)), mode: mode, unlimitedReplies: unlimitedReplies, rounds: rounds, workspaceID: workspace?.id,
                          seatModels: Dictionary(uniqueKeysWithValues: seatModels.map { ($0.key.rawValue, $0.value) }),
                          seatEfforts: Dictionary(uniqueKeysWithValues: seatEfforts.map { ($0.key.rawValue, $0.value) }),
                          leader: leader?.rawValue,
                          sessionIDs: Dictionary(uniqueKeysWithValues: currentSessionIDs.map { ($0.key.rawValue, $0.value) }),
                          seen: Dictionary(uniqueKeysWithValues: seenCount.map { ($0.key.rawValue, max(0, $0.value - max(0, entries.count - Self.entryLimit))) }))
        do { try store.save(state) } catch { notice = "The roundtable could not be saved: \(error.localizedDescription)" }
    }

    /// The ids worth saving: live collectors first, then what earlier sessions left behind.
    private var currentSessionIDs: [Provider: String] {
        var ids = sessionIDs
        for (provider, collector) in sessions { if let id = collector.sessionID, AppModel.isResumableSession(id) { ids[provider] = id } }
        return ids
    }

    /// Forgets the transcript and, in Work mode, the working copy (its files are removed).
    func clear() {
        guard !isRunning else { return }
        entries = []
        seenCount = [:]
        sessionIDs = [:]
        if let workspace, let removeWorkspace {
            let id = workspace.id
            Task { await removeWorkspace(id) }
        }
        workspace = nil
        releaseSessions()
        save()
    }

    // MARK: Seats

    /// Sets a seat's model ("" inherits). The agent's session is replaced so its next turn
    /// starts on the new model. This works during a run too — an agent that runs out of credits
    /// mid-run can be moved to another model without stopping the roundtable — and the turn it
    /// is in finishes on the old session.
    func setSeat(model: String, for provider: Provider) {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        guard (seatModels[provider] ?? "") != trimmed else { return }
        if trimmed.isEmpty { seatModels.removeValue(forKey: provider) } else { seatModels[provider] = trimmed }
        seatChanged(provider)
        save()
    }

    func setSeat(effort: String, for provider: Provider) {
        let trimmed = effort.trimmingCharacters(in: .whitespaces)
        guard (seatEfforts[provider] ?? "") != trimmed else { return }
        if trimmed.isEmpty { seatEfforts.removeValue(forKey: provider) } else { seatEfforts[provider] = trimmed }
        seatChanged(provider)
        save()
    }

    private func seatChanged(_ provider: Provider) {
        // The seat that ran out of credits was just moved: the warning about it is spent.
        if usageLimited.remove(provider) != nil { notice = nil }
        if isRunning { restartedSeats.insert(provider) } else { releaseSession(provider) }
    }

    /// Makes one agent the leader (nil for none). Applies from the next round; saved per project.
    func setLeader(_ provider: Provider?) {
        guard leader != provider else { return }
        leader = provider
        save()
    }

    /// The leader first, then the others in their usual order.
    func ordered(_ targets: [Provider]) -> [Provider] {
        guard let leader, targets.contains(leader) else { return targets }
        return [leader] + targets.filter { $0 != leader }
    }

    /// "Claude, you lead", "let Codex take the lead", "Grok leads", "@Claude lead this",
    /// "Codex is in charge": the one agent the message puts in charge, nil when none or several.
    static func leaderMention(in text: String) -> Provider? {
        let lowered = text.lowercased()
        var found: [Provider] = []
        for provider in Provider.allCases {
            let n = provider.rawValue
            let patterns = [
                #"\b@?"# + n + #"\b,?\s+(?:you\s+)?(?:lead|leads|takes?\s+(?:the\s+)?lead|will\s+lead|should\s+lead|is\s+leading|is\s+the\s+leader|is\s+in\s+charge|runs?\s+(?:this|the)\s+(?:show|session|table|roundtable)|runs?\s+point|drives?\s+this|coordinates?)\b"#,
                #"\b(?:let|have|make|want|need)\s+"# + n + #"\s+(?:to\s+)?(?:lead|take\s+the\s+lead|run\s+(?:this|the\s+show|point)|be\s+(?:the\s+)?(?:leader|lead)|coordinate|drive)\b"#,
                #"\b(?:leader|lead)\s*[:=]\s*@?"# + n + #"\b"#,
                #"\b"# + n + #"\s+as\s+(?:the\s+)?(?:leader|lead)\b"#,
                #"\b"# + n + #"(?:'s|\s+is)\s+(?:the\s+)?(?:leader|lead)\b"#,
            ]
            if patterns.contains(where: { lowered.range(of: $0, options: .regularExpression) != nil }) { found.append(provider) }
        }
        return found.count == 1 ? found[0] : nil
    }

    /// Ends one agent's session. Its id is kept so the next turn resumes it — the provider then
    /// holds the whole conversation and only the new messages are sent. Without a resumable id
    /// the next turn starts fresh with a recap.
    private func releaseSession(_ provider: Provider) {
        if let collector = sessions.removeValue(forKey: provider) {
            if let id = collector.sessionID, AppModel.isResumableSession(id) { sessionIDs[provider] = id }
            collector.stop()
        }
        activeSessions.remove(provider)
        if sessionIDs[provider] == nil { seenCount.removeValue(forKey: provider) }
    }

    // MARK: Addressing

    /// `@Claude what do you think` → [.claude]; several mentions may be combined; no mention → everyone enabled.
    static func targets(in text: String, among enabled: [Provider]) -> [Provider] {
        let lowered = text.lowercased()
        let mentioned = Provider.allCases.filter { provider in
            lowered.contains("@" + provider.rawValue) || lowered.contains("@" + provider.displayName.lowercased())
        }
        let chosen = mentioned.filter { enabled.contains($0) }
        return chosen.isEmpty ? enabled : chosen
    }

    /// Who still has something to say after `previousRound`: everyone who contributed, plus
    /// anyone who passed (or failed) but was named in another agent's contribution. An agent
    /// that has not spoken yet is kept.
    static func stillTalking(_ targets: [Provider], entries: [Entry], previousRound: Int) -> [Provider] {
        let spoken = entries.enumerated().filter { ($0.element.round ?? 0) <= previousRound && $0.element.speaker != "human" }
        return targets.filter { provider in
            // The agent's latest word, in any round so far — a skipped round is still a pass.
            guard let own = spoken.last(where: { $0.element.speaker == provider.rawValue }) else { return true }
            if !own.element.failed && !isPass(own.element.text) { return true }
            // Passed: it comes back only if someone has named it since.
            return spoken.contains { index, entry in
                index > own.offset && entry.speaker != provider.rawValue && !entry.failed && !isPass(entry.text)
                    && entry.text.lowercased().contains(provider.displayName.lowercased())
            }
        }
    }

    /// "Nothing further." and its close relatives, as a whole reply. A long reply that merely
    /// contains the words is a contribution, not a pass.
    static func isPass(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!…*_\"'`"))
        guard normalized.count <= 60 else { return false }
        return ["nothing further", "nothing to add", "nothing more to add", "no further comment", "nothing else to add"]
            .contains { normalized.contains($0) }
    }

    // MARK: Prompts

    static func name(_ provider: Provider) -> String { provider.displayName }

    func prompt(for provider: Provider, humanMessage: String?, round: Int, steered: Bool = false, others: [Provider]) -> String {
        var text = ""
        let firstTime = seenCount[provider] == nil
        let seen = seenCount[provider] ?? max(0, entries.count - Self.recapEntries)
        if firstTime {
            let names = others.isEmpty ? "the user" : others.map(Self.name).joined(separator: ", ") + " and the user"
            text += "You are \(Self.name(provider)) in a roundtable with \(names), inside the Orrery IDE. Everyone reads the same transcript. "
                + "Speak for yourself, keep replies to a few short paragraphs at most, address others by name when you build on or disagree with them"
            switch mode {
            case .discuss:
                text += ", and do not modify files: this is a discussion.\n\n"
            case .work:
                text += ". This is a working session: you all share one working copy of the project, the folder you are running in. "
                    + "You may read and edit its files, run its build, test and run tasks, and use the IDE, browser and computer tools you have been given; "
                    + "the user's approval rules apply. Agents take turns, so say in one sentence what you are about to do, do one thing at a time, "
                    + "and end every reply with a line `FILES:` naming the files you changed, or `FILES: none`. "
                    + "Nothing reaches the user's project until they review and apply the changes.\n\n"
            }
        }
        if mode == .work { text += toolContext() + "\n\n" }
        let unseen = entries[min(seen, entries.count)...].filter { $0.speaker != provider.rawValue }
        if !unseen.isEmpty {
            text += (firstTime ? "Recent transcript:\n" : "New messages since you last spoke:\n")
            for entry in unseen {
                let body = entry.text.count > Self.promptEntryCharacters ? String(entry.text.prefix(Self.promptEntryCharacters)) + " […]" : entry.text
                let files = (entry.editedFiles ?? []).isEmpty ? "" : " (edited: \(entry.editedFiles!.joined(separator: ", ")))"
                text += "[\(entry.displayName)]\(files) \(body)\n\n"
            }
        }
        if let leader, others.contains(leader) || leader == provider {
            text += leader == provider
                ? "You lead this roundtable: you speak first each round, set the plan, give the others their parts by name and keep everyone on it. "
                : "\(Self.name(leader)) leads this roundtable: follow \(Self.name(leader))'s plan, do your part and report back to \(Self.name(leader)) by name. "
        }
        if round <= 1 {
            text += "Reply to the user's latest message as \(Self.name(provider))."
        } else if steered {
            text += "The user has just added a message above, while you were working. Answer it as \(Self.name(provider)) and follow it in what you do next"
                + (mode == .work ? ", saying in one sentence what you will do." : ".")
        } else if unlimitedReplies {
            text += "Reply to the other agents' latest messages above: say where you agree, where you disagree and why, and what you would do"
                + (mode == .work ? " or do it" : "") + ". This continues until everyone has nothing further to add — when that is you, reply with exactly: \(Self.passPhrase)"
        } else {
            text += "Reply briefly to the other agents' answers above: say where you agree, where you disagree and why, and what you would do"
                + (mode == .work ? " or do it" : "") + ". If you have nothing to add, say so in one line."
        }
        return text
    }

    // MARK: Sending

    /// Says something while the agents are working. The message joins the transcript at once,
    /// every agent reads it in its next turn (in Work mode, from the next agent to speak in the
    /// round already under way), and the run continues for at least one more round so the
    /// message is answered — even when the reply rounds were used up or everyone had said
    /// "Nothing further." Returns false when there is no run to steer.
    @discardableResult
    func steer(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isRunning else { return false }
        entries.append(Entry(speaker: "human", text: text))
        pendingSteer = true
        notice = nil
        save()
        return true
    }

    private func takeSteer() -> Bool {
        defer { pendingSteer = false }
        return pendingSteer
    }

    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        guard let project else { notice = "Open a project first."; return }
        let targets = Self.targets(in: text, among: enabledTargets)
        guard !targets.isEmpty else { notice = "No agent is enabled and installed."; return }
        if let named = Self.leaderMention(in: text) { leader = named }
        notice = nil
        pendingSteer = false
        idleTask?.cancel()
        isRunning = true
        let runGeneration = UUID()
        generation = runGeneration
        lastRoundCount = 0
        let executionRoot: URL
        if mode == .work {
            await restoringWorkspace?.value
            guard generation == runGeneration else { return }
            if workspace == nil {
                guard let makeWorkspace else { notice = "Work mode needs a working copy and none can be made here."; isRunning = false; return }
                do { workspace = try await makeWorkspace(project) } catch {
                    notice = "Could not prepare the roundtable's working copy: \(error.localizedDescription)"
                    isRunning = false
                    return
                }
                guard generation == runGeneration else { return }
                save()
            }
            executionRoot = workspace!.executionRoot
        } else {
            executionRoot = project
        }
        entries.append(Entry(speaker: "human", text: text))
        save()
        _ = await runRound(1, targets: targets, humanMessage: text, executionRoot: executionRoot, generation: runGeneration)
        // Then the reply rounds — and a round for anything the user said while this run was
        // going, which is answered whether or not the reply rounds are used up.
        let cap = unlimitedReplies ? unlimitedCeiling + 1 : min(rounds, 3)
        var round = 2
        var everyonePassed = false
        var hitCeiling = false
        while generation == runGeneration {
            let steering = takeSteer()
            if !steering {
                guard targets.count >= 2, unlimitedReplies || rounds >= 2, !everyonePassed else { break }
                if round > cap { hitCeiling = unlimitedReplies; break }
            }
            // An agent that said "Nothing further." is not asked again until someone names it or
            // you steer: every skipped turn is a whole context window not spent.
            let speakers = steering ? targets : Self.stillTalking(targets, entries: entries, previousRound: round - 1)
            if speakers.isEmpty { everyonePassed = true; break }
            everyonePassed = await runRound(round, targets: speakers, humanMessage: nil, steered: steering,
                                            executionRoot: executionRoot, generation: runGeneration)
            round += 1
        }
        if generation == runGeneration, hitCeiling {
            notice = "Stopped after \(unlimitedCeiling) reply rounds, the hard stop for unlimited replies. Send another message to continue."
        }
        if generation == runGeneration {
            isRunning = false
            thinking = []
            live = [:]
            save()
            scheduleIdleRelease()
        }
    }

    /// Runs one round. Returns true when the round produced no contribution: every reply was a
    /// pass ("Nothing further.") or a failure — the signal that ends unlimited replies.
    private func runRound(_ round: Int, targets: [Provider], humanMessage: String?, steered: Bool = false,
                          executionRoot: URL, generation runGeneration: UUID) async -> Bool {
        var results: [(Provider, TurnCollector.TurnResult)] = []
        if mode == .work {
            // Turns are sequential: each agent sees what the previous ones just did and said,
            // and two agents never edit the working copy at the same time.
            for provider in ordered(targets) where generation == runGeneration {
                let result = await turn(provider, prompt: { [self] in
                    let text = prompt(for: provider, humanMessage: humanMessage, round: round, steered: steered, others: targets.filter { $0 != provider })
                    seenCount[provider] = entries.count
                    return text
                }, executionRoot: executionRoot)
                guard generation == runGeneration else { return false }
                results.append((provider, result))
                record(provider, result, round: round, executionRoot: executionRoot)
            }
        } else {
            // Everyone reads the same transcript state (nothing is recorded until the round
            // ends), then answers at the same time. Each prompt is built once its session is
            // up, so an agent whose session could not be resumed gets the recap it needs.
            await withTaskGroup(of: (Provider, TurnCollector.TurnResult).self) { group in
                for provider in targets {
                    group.addTask { @MainActor [weak self] in
                        guard let self else { return (provider, TurnCollector.TurnResult(failureMessage: "roundtable closed")) }
                        return (provider, await self.turn(provider, prompt: { [self] in
                            let text = self.prompt(for: provider, humanMessage: humanMessage, round: round, steered: steered, others: targets.filter { $0 != provider })
                            self.seenCount[provider] = self.entries.count
                            return text
                        }, executionRoot: executionRoot))
                    }
                }
                for await result in group { results.append(result) }
            }
            guard generation == runGeneration else { return false }
            let order = ordered(targets)
            for (provider, result) in results.sorted(by: { order.firstIndex(of: $0.0)! < order.firstIndex(of: $1.0)! }) {
                record(provider, result, round: round, executionRoot: executionRoot)
                // Each agent's "seen" mark stays where its prompt was built, so the next prompt
                // shows every other reply from this round; its own reply is filtered by speaker.
            }
        }
        lastRoundCount = round
        if entries.count > Self.entryLimit { entries.removeFirst(entries.count - Self.entryLimit) }
        save()
        return round >= 2 && results.allSatisfy { $0.1.failed || Self.isPass($0.1.text) }
    }

    /// Edited paths are shown relative to the working copy: the agent reports absolute paths
    /// inside it, and the user thinks in project paths.
    static func relativePaths(_ paths: [String], root: URL) -> [String] {
        let prefix = root.standardizedFileURL.path + "/"
        let realPrefix = root.resolvingSymlinksInPath().path + "/"
        return paths.map { path in
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
            if path.hasPrefix(realPrefix) { return String(path.dropFirst(realPrefix.count)) }
            return path
        }
    }

    private func record(_ provider: Provider, _ result: TurnCollector.TurnResult, round: Int, executionRoot: URL) {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let edited = result.editedFiles.isEmpty ? nil : Self.relativePaths(result.editedFiles, root: executionRoot)
        let backend = sessions[provider]?.backend
        let model = backend?.currentModel.isEmpty == false ? backend?.currentModel : nil
        let effort = backend?.currentEffort.isEmpty == false ? backend?.currentEffort : nil
        if result.failed || text.isEmpty {
            let message = result.failureMessage ?? (result.timedOut ? "went silent" : "replied with nothing")
            if AppModel.looksLikeAuthFailure(message) {
                // A process that cached an expired token must not poison every later turn,
                // even after the CLI refreshes its saved login outside this session.
                releaseSession(provider)
                onAuthenticationFailure?(provider)
            }
            if Self.isUsageLimit(message) {
                usageLimited.insert(provider)
                notice = "\(provider.displayName) is out of usage credits\(model.map { " on \(ModelCatalog.name(provider, of: $0))" } ?? ""). Pick another model for its seat above — it applies from \(provider.displayName)'s next message, no need to stop — or untick it."
            }
            entries.append(Entry(speaker: provider.rawValue, text: message,
                                 costUSD: result.costUSD, round: round, failed: true, editedFiles: edited, model: model, effort: effort))
        } else {
            entries.append(Entry(speaker: provider.rawValue, text: text, costUSD: result.costUSD, round: round, editedFiles: edited, model: model, effort: effort))
        }
    }

    private func turn(_ provider: Provider, prompt makePrompt: @MainActor () -> String, executionRoot: URL) async -> TurnCollector.TurnResult {
        thinking.insert(provider)
        live[provider] = ""
        defer { thinking.remove(provider); live[provider] = nil }
        // A seat changed mid-run: start this agent's next turn on a session with the new model.
        if restartedSeats.remove(provider) != nil { releaseSession(provider) }
        let collector: TurnCollector
        if let existing = sessions[provider], existing.backend.isRunning {
            collector = existing
        } else {
            let backend = makeBackend(provider)
            backend.persistsSelection = false
            let seatModel = seatModels[provider] ?? "", seatEffort = seatEfforts[provider] ?? ""
            if !seatModel.isEmpty || !seatEffort.isEmpty {
                backend.preconfigure(model: seatModel.isEmpty ? nil : seatModel, effort: seatEffort.isEmpty ? nil : seatEffort)
            }
            // Resume the agent's own session when there is one: the provider then holds the
            // conversation and only the new messages travel — no recap, far fewer tokens.
            var resuming = false
            if let id = sessionIDs[provider], AppModel.isResumableSession(id) {
                var settings = backend.sessionSettings
                settings.resumeSession = id
                backend.sessionSettings = settings
                resuming = true
            }
            collector = TurnCollector(backend: backend, provider: provider)
            switch mode {
            case .discuss:
                collector.autoApprove = false
                collector.onPermission = { request, _ in request.reply(request.options.first { $0.kind.hasPrefix("reject") }?.id) }
            case .work:
                collector.autoApprove = autoApprove
                if let permissionHandler {
                    collector.onPermission = permissionHandler
                    collector.onPermissionEnded = permissionEnded
                } else {
                    collector.onPermission = { request, _ in request.reply(request.options.first { $0.kind.hasPrefix("reject") }?.id) }
                }
            }
            collector.onActivity = { [weak self] event in
                if case let .assistantDelta(delta) = event { self?.live[provider, default: ""] += delta }
            }
            sessions[provider] = collector
            activeSessions.insert(provider)
            await collector.start(project: executionRoot)
            if resuming, collector.sessionDropped {
                // The provider no longer has that session: fall back to a fresh start with a recap.
                sessionIDs.removeValue(forKey: provider)
                seenCount.removeValue(forKey: provider)
                resuming = false
            }
            if resuming { resumedProviders.insert(provider) } else { resumedProviders.remove(provider) }
        }
        return await collector.send(makePrompt(), stallTimeout: stallTimeout)
    }

    func stop() {
        generation = UUID()
        for collector in sessions.values { collector.stop() }
        sessions = [:]
        activeSessions = []
        seenCount = seenCount.mapValues { min($0, entries.count) }
        if isRunning {
            entries.append(Entry(speaker: "human", text: "(stopped)", failed: true))
            save()
        }
        isRunning = false
        thinking = []
        live = [:]
        idleTask?.cancel()
    }

    // MARK: Idle release

    private func scheduleIdleRelease() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, self?.idleReleaseDelay ?? 180) * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isRunning else { return }
            self.releaseIdle()
        }
    }

    private func releaseSessions() {
        for provider in Array(sessions.keys) { releaseSession(provider) }
        sessions = [:]
        activeSessions = []
        restartedSeats = []
    }

    /// "You\'re out of usage credits", "usage limit reached", "rate limit" and the like: the
    /// subscription, not the request, is what failed, so another model may still answer.
    static func isUsageLimit(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["out of usage credits", "usage limit", "usage_limit", "quota", "insufficient credits", "out of credits",
                "rate limit", "rate_limit", "429", "too many requests", "upgrade to continue", "credit balance"].contains { lowered.contains($0) }
    }

    /// Provider CLIs cache MCP catalogs at startup. Changed grants apply on the next turn
    /// without interrupting a current response or discarding the shared working copy.
    func refreshToolsForNextTurn() {
        if isRunning { restartedSeats.formUnion(activeSessions) }
        else { releaseSessions() }
    }

    /// Ends the sessions but keeps the transcript; the next message starts fresh sessions with a recap.
    func releaseIdle() {
        guard !isRunning else { return }
        releaseSessions()
        notice = entries.isEmpty ? nil : "Idle — sessions released; the next message resumes them."
    }
}

extension AppModel {
    func attachRoundtable() {
        roundtable.installed = Provider.allCases.filter { installed[$0] == true }
        roundtable.makeBackend = { [weak self] provider in self?.makeOneShotBackend(provider) ?? Self.newBackend(provider) }
        roundtable.autoApprove = autoApprove
        roundtable.toolContext = { [weak self] in
            guard let control = self?.computerControl, control.isEnabled else { return "The Orrery tool service is unavailable. Report a connection failure rather than inventing tool access." }
            var text = "Orrery supplies the studio_computer MCP server. Use its ide_status tool to check the live connection."
            if control.groups.contains(.browser) { text += " Its browser_open, browser_inspect, browser_type, browser_click and browser_capture tools operate the embedded IDE browser; no external Chrome tab or browser connector is required. Navigation remains restricted to the allowed sites and local servers." }
            if control.desktopEnabled { text += " Its desktop tools are Orrery's shared controls. Follow your provider's native-control preference for desktop work; these shared tools do not establish native-provider access. Grok uses this shared desktop service. Computer actions still require macOS permissions." }
            return text
        }
        roundtable.makeWorkspace = { project in try await TaskWorkspaceStore.shared.create(taskID: UUID(), project: project, isolated: true) }
        roundtable.loadWorkspace = { id in try? await TaskWorkspaceStore.shared.workspace(taskID: id) }
        roundtable.removeWorkspace = { id in try? await TaskWorkspaceStore.shared.remove(taskID: id) }
        roundtable.permissionHandler = { [weak self] request, provider in self?.handle(.permission(request), from: provider) }
        roundtable.permissionEnded = { [weak self] id in self?.permissionQueue.first(where: { $0.id == id })?.reply(nil) }
        roundtable.onChange = { [weak self] in self?.remote.noteChange() }
        roundtable.onAuthenticationFailure = { [weak self] provider in self?.needsSignIn.insert(provider) }
        roundtable.attach(project: projectURL)
    }
}

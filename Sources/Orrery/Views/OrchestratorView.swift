import SwiftUI

/// Orchestrator mode: one agent plans and hands work to the others; whoever did not write a
/// file reviews it. One lane per work item — author, reviewer, round, findings, and what every
/// turn cost. One Stop cancels the lot.
struct OrchestratorView: View {
    @Bindable var model: AppModel
    @State private var advancedSetup = false
    @State private var modelsOpen = false

    private var engine: Orchestrator { model.orchestrator }

    var body: some View {
        VStack(spacing: 0) {
            if engine.isDemo {
                Text("DEMO DATA — no agents are running and nothing is being spent. "
                     + "Start a real run to replace this.")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color.purple.opacity(0.25))
            }
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let notice = model.taskNotice {
                        HStack(alignment: .top) {
                            Text(notice).font(.callout).foregroundStyle(.orange)
                            Spacer(minLength: 4)
                            Button { model.dismissNotices() } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("Dismiss Team notice")
                        }
                    }
                    if !engine.isRunning { setup }
                    phaseBanner
                    if let live = engine.planningLive {
                        LiveTurnView(live: live)
                    }
                    planSection
                    ForEach(engine.items) { item in
                        WorkItemCard(model: model, item: item)
                    }
                    if !engine.log.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(engine.log.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    teamStatsSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: engine.orchestratorProvider) { _, _ in model.scheduleTaskSave() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Label("Team", systemImage: "person.3.sequence")
                .font(.headline)
            Text(engine.orchestratorChipText)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())
                .help("The agent that plans and assigns work — not an item's author or reviewer")
            phaseChip
            Spacer()
            if engine.totalTurns > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "$%.4f", engine.totalCostUSD))
                        .font(.system(.caption, design: .monospaced))
                    Text("\(engine.totalTurns) turns"
                         + (engine.totalUnreportedTurns > 0
                            ? " · \(engine.totalUnreportedTurns) with no cost reported" : ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help("Token cost at API rates as reported by each CLI per turn. "
                      + "Subscription turns that report no figure are counted separately "
                      + "as \"no cost reported\".")
            }
            if engine.isRunning {
                Button(role: .destructive) {
                    engine.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Cancel every in-flight agent session")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var phaseChip: some View {
        let (text, color): (String, Color) = {
            switch engine.phase {
            case .idle: return ("idle", .secondary)
            case .planning: return ("planning…", .orange)
            case .working: return ("working…", .orange)
            case .done: return ("done", .green)
            case .cancelled: return ("stopped", .red)
            case .failed: return ("failed", .red)
            }
        }()
        return Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    @State private var showOptions = false

    /// One line that says what Start will do, so the options can stay folded.
    private var optionsSummary: String {
        let workers = engine.installedProviders.filter { $0 != engine.orchestratorProvider && !engine.disabledWorkers.contains($0) }
        let who = engine.singleProviderTeam ? "\(engine.orchestratorProvider.displayName) alone"
            : "\(engine.orchestratorProvider.displayName) leads" + (workers.isEmpty ? "" : ", " + workers.map(\.displayName).joined(separator: " & ") + " build")
        let rounds = engine.maxRounds == 1 ? "1 review round" : "\(engine.maxRounds) review rounds"
        return "Options: \(who), \(rounds)"
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Orchestrator", selection: Bindable(engine).orchestratorProvider) {
                    ForEach(engine.installedProviders) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .accessibilityLabel("Team orchestrator")
                .help("The lead agent plans the task and assigns work. Each worker's code is reviewed separately.")
                .disabled(engine.isRunning || model.teamPreparing || engine.installedProviders.isEmpty)
                Spacer(minLength: 0)
                Button("Agent setup") { model.showSetup = true }.controlSize(.small)
                    .help("Install or sign in to the agents you want on this team")
            }
            Text(engine.singleProviderTeam ? "One agent, separate author and reviewer models." : "Workers: " + engine.workerPool.map(\.displayName).joined(separator: " & "))
                .font(.caption).foregroundStyle(.secondary)
            Picker("Planning", selection: $model.teamUseExistingPlan) {
                Text("Let the orchestrator plan").tag(false)
                Text("Use my plan · skip the planner turn").tag(true)
            }.disabled(model.teamPreparing)
                .help("Let the lead plan, or supply your own plan to save the planning turn")
            if model.teamUseExistingPlan, let author = engine.workerPool.first {
                Text("Paste a plan from ChatGPT or your own notes below. \(author.displayName) builds; \(engine.reviewer(forAuthor: author)?.displayName ?? "a reviewer") checks the result. Agent work still uses your provider allowance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let blocker = engine.startBlocker {
                Text(blocker)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Text("What should your team build?").font(.headline)
            TextEditor(text: $model.orchestratorDraft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 100, maxHeight: 150)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Team task")
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.3)))
                .overlay(alignment: .topLeading) {
                    if model.orchestratorDraft.isEmpty {
                        Text("Describe the task. The orchestrator splits it into work items "
                             + "and assigns each to a worker.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                }
            TeamContextView(model: model).padding(.vertical, 4)
            HStack {
                if let workspace = model.teamWorkspace {
                    Button("Changes") { model.reviewingWorkspace = workspace }
                        .disabled(model.teamPreparing)
                    Button("Continue saved task") { Task { await model.startTeamTask(continuing: true) } }
                        .disabled(engine.isRunning || model.teamPreparing || model.taskMutationBusy)
                }
                Button {
                    Task { await model.startTeamTask() }
                } label: {
                    Label(model.teamPreparing ? "Preparing…" : "Start team", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Start in an isolated working copy, with the selected skills and context")
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.orchestratorDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || engine.startBlocker != nil || model.projectURL == nil || !model.isProjectTrusted
                          || model.teamPreparing || model.taskMutationBusy)
                if model.projectURL == nil {
                    Text("Open a project first.").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
            ApprovalMenu(model: model) {
                Text(model.blanketApproval ? "Every approval bypassed" : model.autoApprove ? "Tools run automatically" : "Ask before running tools")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(engine.isRunning)
            DisclosureGroup(isExpanded: $showOptions) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 10) {
                        Stepper("Default review rounds: \(engine.maxRounds)",
                                value: Bindable(engine).maxRounds, in: 1...5)
                            .fixedSize()
                            .help("Used when the plan does not budget an item itself — the orchestrator "
                                  + "may set 1–5 rounds per item by complexity. Every item is hard-capped "
                                  + "at 10 lifetime rounds, extensions included.")
                        Spacer()
                    }
                    HStack(alignment: .center, spacing: 8) {
                        Text("Workers:").font(.caption).foregroundStyle(.secondary)
                        ForEach(engine.installedProviders.filter { $0 != engine.orchestratorProvider }) {
                            provider in
                            Toggle(isOn: Binding(
                                get: { !engine.disabledWorkers.contains(provider) },
                                set: { on in
                                    if on { engine.disabledWorkers.remove(provider) }
                                    else { engine.disabledWorkers.insert(provider) }
                                })) {
                                Text(provider.displayName).font(.caption)
                            }
                            .toggleStyle(.checkbox)
                            .disabled(engine.isRunning)
                            .help("Uncheck to keep \(provider.displayName) unbilled and unassigned "
                                  + "this run")
                        }

                    }
                    Toggle(isOn: Bindable(engine).followEdits) {
                        Text("Follow edits in the editor").font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .help("Open and reload each file as the author writes it. "
                          + "A tab with unsaved edits is never replaced, and never loses focus.")
                    Toggle(isOn: Bindable(engine).followGate) {
                        Text("Run build & tests as an acceptance gate").font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .help("Gate runs are LOCAL PROCESSES and COST NO TOKENS.")
                    Toggle("Single agent: \(engine.orchestratorProvider.displayName) plans, writes and reviews, each seat on its own model", isOn: Binding(get: { engine.singleProviderTeam }, set: { engine.singleProviderTeam = $0 }))
                        .font(.caption)
                        .disabled(engine.isRunning)
                    if engine.singleProviderTeam {
                        Text("For one subscription. The review is still a fresh session, on a different model than the author's; pick both below.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Uses separate agent sessions and this project’s tool settings. Each agent’s model and effort for this run are chosen below, per role; Solo chat defaults are never changed. Every reported cost is shown.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }.padding(.top, 6)
            } label: {
                Text(optionsSummary).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Models per agent for this run", isExpanded: $modelsOpen) {
                sessionSettings.padding(.top, 10)
            }
            .font(.callout)
            DisclosureGroup("Seat advice and toolchain", isExpanded: $advancedSetup) {
                VStack(alignment: .leading, spacing: 14) {
                    seatAdvice
                    ToolchainStatusView(watch: ToolchainWatch.shared)
                }.padding(.top, 10)
            }
            .font(.callout)
        }
        .padding(18)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Model and effort per provider, for this run's sessions only — where the money goes.
    private var sessionSettings: some View {
        let involved = ([engine.orchestratorProvider] + engine.workerPool)
            .reduce(into: [Provider]()) { if !$0.contains($1) { $0.append($1) } }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(involved) { provider in
                let roles: [SessionRole] = engine.singleProviderTeam ? SessionRole.allCases
                    : (provider == engine.orchestratorProvider ? [.orchestrator, .reviewer] : [.author, .reviewer])
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName).font(.caption.weight(.semibold))
                    // One line per role: role, model, effort — scannable at a glance.
                    ForEach(roles, id: \.self) { role in
                        HStack(spacing: 8) {
                            Text(role.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { engine.roleModelOverrides[role]?[provider] ?? "" },
                                set: { engine.roleModelOverrides[role, default: [:]][provider]
                                        = $0.isEmpty ? nil : $0 })) {
                                Text(Self.inheritedModelLabel(engine, provider, role)).tag("")
                                ForEach(model.modelChoices(for: provider)) { option in
                                    Text(option.name).tag(option.id)
                                }
                            }
                            .labelsHidden().controlSize(.small).frame(maxWidth: 230)
                            Picker("", selection: Binding(
                                get: { engine.roleEffortOverrides[role]?[provider] ?? "" },
                                set: { engine.roleEffortOverrides[role, default: [:]][provider]
                                        = $0.isEmpty ? nil : $0 })) {
                                Text("Inherit effort").tag("")
                                ForEach(Self.effortChoices(provider, model: engine.roleModelOverrides[role]?[provider]), id: \.self) { effort in
                                    Text(effort).tag(effort)
                                }
                            }
                            .labelsHidden().controlSize(.small).frame(maxWidth: 150)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            Text("Per role, this run only — chat defaults are never changed. Unset roles "
                 + "inherit the provider-wide setting, then the baked defaults "
                 + "(Codex: Terra writes, Sol reviews and orchestrates).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Suggestion + opt-in trial. Every string is a TeamStats helper; Apply and
    /// Accept write only this run's role overrides.
    private var seatAdvice: some View {
        let loaded = TeamStats.load()
        let stats = TeamStats.aggregate(records: loaded.records)
        let installed = catalogSeats
        let workers = Set(engine.workerPool.map(\.rawValue))
        let rec = TeamStats.recommendSeats(
            stats: stats, installed: installed, enabledWorkers: workers,
            orchestratorProvider: engine.orchestratorProvider.rawValue)
        let trial = TeamStats.untestedTrialSeats(
            stats: stats, installed: installed, enabledWorkers: workers,
            orchestratorProvider: engine.orchestratorProvider.rawValue).first
        return VStack(alignment: .leading, spacing: 4) {
            Text(TeamStats.suggestionLine(rec))
                .font(.caption)
                .textSelection(.enabled)
            Button("Apply") { engine.applySeatRecommendations(rec) }
                .controlSize(.small)
                .disabled(!rec.hasAnyRecommendation)
                .help("Fill this run's role pickers from the measured seats. "
                      + "Chat defaults are not changed.")
            if let trial {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(TeamStats.trialLine(seat: trial))
                        .font(.caption)
                        .textSelection(.enabled)
                    Button("Accept") { engine.acceptTrialAuthorSeat(trial) }
                        .controlSize(.small)
                        .help("Assign this untested model to one author seat for this run only.")
                }
            }
        }
    }

    private var catalogSeats: Set<TeamStats.CatalogSeat> {
        TeamStats.catalogSeats(reportedModels: model.reportedModels(
            installed: engine.installedProviders))
    }

    /// What an unset role picker will actually use, so "inherit" is never a mystery.
    private static func inheritedModelLabel(_ engine: Orchestrator, _ provider: Provider,
                                            _ role: SessionRole) -> String {
        if let inherited = engine.resolvedModel(for: provider, role: role) {
            let name = modelChoices(provider).first { $0.id == inherited }?.name ?? inherited
            return "Inherit (\(name))"
        }
        return "Inherit (backend default)"
    }

    /// The shared catalog: the CLI's own cache first (a model that shipped this morning is
    /// there), then the known aliases; free-typed ids still work via --models on the command line.
    static func modelChoices(_ provider: Provider) -> [ModelOption] { ModelCatalog.choices(provider) }

    static func effortChoices(_ provider: Provider, model: String? = nil) -> [String] { ModelCatalog.efforts(provider, model: model) }

    // MARK: Team stats

    /// Every recorded run, aggregated per seat — the measured answer to "who is the most
    /// efficient team". Reads the store on each expand so freshly finished runs show up.
    @State private var statsOpen = false

    @ViewBuilder
    private var teamStatsSection: some View {
        DisclosureGroup(isExpanded: $statsOpen) {
            let loaded = TeamStats.loadForDisplay()
            VStack(alignment: .leading, spacing: 3) {
                if loaded.seats.isEmpty {
                    Text("No recorded runs yet — every orchestrator run records itself here, "
                         + "and --import-run-log backfills old logs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(loaded.seats.enumerated()), id: \.offset) { _, entry in
                        Text(TeamStats.trendRowText(seat: entry.0, stats: entry.1,
                                                    trend: loaded.trend(for: entry.0)))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("\(loaded.recordCount) run(s) on file"
                         + (loaded.skippedLines > 0
                            ? " · \(loaded.skippedLines) corrupt line(s) skipped" : "")
                         + " · \(TeamStats.storeURL.path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Dollar figures are reported token cost only; subscription turns "
                         + "report none and are counted, not priced.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("CLI versions (latest run): \(loaded.latestCLIVersions)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !loaded.calibrationSeats.isEmpty {
                    Text(TeamStats.calibrationHeader)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    ForEach(Array(loaded.calibrationSeats.enumerated()), id: \.offset) { _, entry in
                        Text(TeamStats.rowText(seat: entry.0, stats: entry.1))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text(TeamStats.calibrationFooter(loaded.calibrationRecordCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Team stats — every run, every seat, measured")
                .font(.caption)
        }
    }

    // MARK: Plan

    @ViewBuilder
    private var phaseBanner: some View {
        if case let .failed(reason) = engine.phase {
            Text(reason)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var planSection: some View {
        if !engine.planRaw.isEmpty {
            DisclosureGroup {
                Text(engine.planRaw)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } label: {
                HStack(spacing: 6) {
                    Text("Plan — \(engine.orchestratorProvider.displayName)'s reply, verbatim")
                        .font(.caption)
                    if let cost = engine.planCostUSD {
                        Text(String(format: "$%.4f", cost))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Work item card

struct WorkItemCard: View {
    @Bindable var model: AppModel
    let item: WorkItem
    @State private var laneOpen = false
    @State private var extraRoundsGrant = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                stateDot
                Text(item.title).font(.headline)
                Spacer()
                costLabel
            }
            HStack(spacing: 6) {
                roleChip("author", item.author)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                roleChip("reviewer", item.reviewer)
                Text("round \(item.round)/\(item.roundBudget)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.cardStateText)
                    .font(.caption)
                    .foregroundStyle(stateColor)
            }
            if let live = item.live {
                LiveTurnView(live: live)
            }
            if !item.filesTouched.isEmpty {
                Text("Files: " + item.filesTouched.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            findings
            gateSection
            extensionControls
            lane
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { extraRoundsGrant = stepperDefault }
        .onChange(of: item.recommendedExtraRounds) { _, _ in extraRoundsGrant = stepperDefault }
    }

    private var stateDot: some View {
        Circle().fill(stateColor).frame(width: 9, height: 9)
    }

    private var stateColor: Color {
        switch item.cardBadgeKind {
        case .secondary: return .secondary
        case .orange: return .orange
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }

    private var costLabel: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(String(format: "$%.4f", item.costUSD))
                .font(.system(.caption, design: .monospaced))
            Text("\(item.turns) turns"
                 + (item.unreportedTurns > 0 ? " · \(item.unreportedTurns) no cost" : ""))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func roleChip(_ role: String, _ provider: Provider) -> some View {
        HStack(spacing: 3) {
            Image(systemName: provider.symbol).font(.caption2)
            Text("\(provider.displayName)")
                .font(.caption)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(Capsule())
        .help("\(role): \(provider.displayName)")
    }

    private var grantUpperBound: Int { max(1, item.grantableExtraRounds) }

    private var clampedGrant: Int {
        min(max(1, extraRoundsGrant), grantUpperBound)
    }

    private var stepperDefault: Int {
        let upper = item.grantableExtraRounds
        guard upper >= 1 else { return 1 }
        if let n = item.recommendedExtraRounds, n >= 1 { return min(upper, n) }
        return 1
    }

    private var extraRoundsLabel: String {
        if let n = item.recommendedExtraRounds, n >= 1 {
            return "More rounds: \(clampedGrant)"
        }
        return "More rounds: \(clampedGrant) (default — no parsed extra-round count)"
    }

    @ViewBuilder
    private var extensionControls: some View {
        if item.state == .notConverging {
            VStack(alignment: .leading, spacing: 4) {
                if let advice = item.reassignAdvice {
                    Text("Advice: \(advice)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                recommendationLine
            }
        }
        if !item.advisoryNotes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(item.advisoryNotes.enumerated()), id: \.offset) { _, advisory in
                    Label(advisory, systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if item.state == .acceptedWithObjections {
            let controls = model.orchestrator.grantControlState(for: item)
            VStack(alignment: .leading, spacing: 6) {
                recommendationLine
                Text("\(item.remainingLifetimeRounds) of "
                     + "\(Orchestrator.lifetimeReviewRoundCap) lifetime review rounds remaining")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if item.grantableExtraRounds >= 1 {
                    // Never hidden: a control that vanishes mid-run reads as a bug (it did).
                    HStack(spacing: 8) {
                        Stepper(extraRoundsLabel, value: grantBinding,
                                in: 1...item.grantableExtraRounds)
                            .fixedSize()
                        Button("Run \(clampedGrant) more "
                               + "round\(clampedGrant == 1 ? "" : "s")") {
                            guard let project = model.teamWorkspace?.executionRoot ?? model.projectURL else { return }
                            model.orchestrator.resume(item, extraRounds: clampedGrant,
                                                      project: project)
                        }
                        .disabled(model.projectURL == nil || !controls.enabled)
                        Button("Accept as-is") {
                            item.objectionsDismissedByUser = true
                        }
                        .disabled(!controls.enabled)
                    }
                    .disabled(!controls.enabled)
                    if let caption = controls.caption {
                        Text(caption).font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("Lifetime cap of \(Orchestrator.lifetimeReviewRoundCap) "
                             + "review rounds reached — no further grants.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Accept as-is") {
                            item.objectionsDismissedByUser = true
                        }
                        .disabled(!controls.enabled)
                    }
                }
            }
        }
    }

    private var grantBinding: Binding<Int> {
        Binding(get: { clampedGrant }, set: { extraRoundsGrant = $0 })
    }

    @ViewBuilder
    private var recommendationLine: some View {
        if let text = item.recommendationLineText {
            Text(text)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var findings: some View {
        let shown = item.state.isTerminal ? item.openFindings : item.findings
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(shown) { finding in
                    findingRow(finding)
                }
            }
        }
    }

    @ViewBuilder
    private var gateSection: some View {
        if let gate = item.gate {
            let notable = gate.tasks.filter { !$0.passed || $0.skippedMissingTool }
            VStack(alignment: .leading, spacing: 4) {
                if notable.isEmpty && gate.hasExecuted {
                    Text("Gate: "
                         + gate.tasks.map { "\($0.title) exited \($0.exitCode ?? 0)" }
                            .joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(notable) { task in
                    gateTaskRow(task)
                }
            }
        }
    }

    @ViewBuilder
    private func gateTaskRow(_ task: GateTaskResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: task.skippedMissingTool
                      ? "questionmark.circle.fill" : "xmark.octagon.fill")
                    .font(.caption2)
                    .foregroundStyle(task.skippedMissingTool ? Color.orange : .red)
                if task.skippedMissingTool {
                    Text("\(task.title) skipped — \(task.missingTool ?? "a tool") not installed")
                        .font(.caption)
                } else {
                    Text("\(task.title) exited \(task.exitCode.map { String($0) } ?? "?")"
                         + (task.timedOut ? " (timed out)" : ""))
                        .font(.system(.caption, design: .monospaced))
                }
                Spacer()
            }
            if !task.outputTail.isEmpty, !task.skippedMissingTool {
                Text(task.outputTail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            ForEach(Array(task.diagnostics.enumerated()), id: \.offset) { _, diag in
                gateDiagnosticRow(diag)
            }
        }
    }

    private func gateDiagnosticRow(_ diag: GateDiagnostic) -> some View {
        let resolved = resolve(diag.file)
        return Button {
            if let url = resolved {
                model.open(file: url, atLine: diag.line ?? 1)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(diag.file)\(diag.line.map { ":\($0)" } ?? "")")
                    .font(.system(.caption, design: .monospaced))
                    .underline(resolved != nil)
                Text(diag.message)
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resolved == nil)
        .help(resolved == nil
              ? "The gate did not name a file that exists here"
              : "Open \(diag.file) at line \(diag.line ?? 1)")
    }

    private func findingRow(_ finding: ReviewFinding) -> some View {
        let resolved = resolve(finding.file)
        return Button {
            if let url = resolved {
                model.open(file: url, atLine: finding.line ?? 1)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: finding.severity == "gap"
                      ? "questionmark.circle.fill" : "ladybug.fill")
                    .font(.caption2)
                    .foregroundStyle(finding.severity == "gap" ? Color.orange : .red)
                if finding.file.isEmpty {
                    Text(finding.message)
                        .font(.caption)
                } else {
                    Text("\(finding.file)\(finding.line.map { ":\($0)" } ?? "")")
                        .font(.system(.caption, design: .monospaced))
                        .underline(resolved != nil)
                    Text(finding.message)
                        .font(.caption)
                        .lineLimit(2)
                }
                Spacer()
                Text("r\(finding.round)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resolved == nil)
        .help(resolved == nil
              ? "The reviewer did not name a file that exists here"
              : "Open \(finding.file) at line \(finding.line ?? 1)")
    }

    private func resolve(_ path: String) -> URL? {
        guard !path.isEmpty, let project = model.projectURL else { return nil }
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : project.appendingPathComponent(path).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var lane: some View {
        DisclosureGroup(isExpanded: $laneOpen) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(item.lane) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("\(entry.role) · \(entry.provider.displayName)")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(entry.role == "reviewer" ? Color.purple
                                                 : entry.role == "author" ? .blue : .secondary)
                            Text(entry.title).font(.caption2).foregroundStyle(.secondary)
                            if let cost = entry.costUSD {
                                Text(String(format: "$%.4f", cost))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(entry.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(Color.secondary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        } label: {
            Text("Lane — every exchange, attributed")
                .font(.caption)
        }
    }
}


// MARK: - Live turn

/// What the agent is doing right now: elapsed and silence clocks, the most recent tool calls,
/// and the tail of the streamed reply. This is the difference between "working…" and watching
/// the work.
struct LiveTurnView: View {
    let live: LiveTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let quiet = Int(context.date.timeIntervalSince(live.lastEventAt))
                let elapsed = Int(context.date.timeIntervalSince(live.startedAt))
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("\(live.provider.displayName) \(live.role) — \(clock(elapsed)) in, "
                         + (quiet <= 2 ? "streaming now" : "last activity \(quiet)s ago"))
                        .font(.caption)
                        .foregroundStyle(quiet > 60 ? Color.orange : .secondary)
                    if live.thinkingCharacters > 0 {
                        Text("· thinking \(live.thinkingCharacters) chars")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            ForEach(Array(live.tools.suffix(5).enumerated()), id: \.offset) { _, tool in
                Label(tool, systemImage: "wrench.adjustable")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let diff = live.diff {
                liveDiffBlock(path: diff.path, lines: LiveDiff.render(diff))
            } else if let path = live.editedPath {
                VStack(alignment: .leading, spacing: 2) {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if live.diffUnavailable {
                        Text("This CLI does not stream diffs, so no diff can be shown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !live.text.isEmpty {
                Text(live.text)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.orange.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(6)
        .background(Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func clock(_ seconds: Int) -> String {
        seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }

    private func liveDiffBlock(path: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1)
                    .background(diffBackground(for: line))
                    .foregroundStyle(diffForeground(for: line))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func diffBackground(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color.green.opacity(0.12) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color.red.opacity(0.12) }
        if line.hasPrefix("@@") { return Color.accentColor.opacity(0.10) }
        return .clear
    }

    private func diffForeground(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .accentColor }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("…") {
            return .secondary
        }
        return .primary
    }
}

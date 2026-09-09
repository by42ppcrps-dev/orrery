import Foundation

/// Single-agent Team: one provider fills every seat, the review runs as a separate session on
/// a different model, and the mode refuses to start when the two models would be the same.
@MainActor
enum AuditTeamSingle {
    static func run(_ audit: Auditor) async {
        audit.section("Team — one subscription can plan, write and review on different models")
        let engine = Orchestrator()
        engine.canExecute = { true }
        engine.installedProviders = [.claude]
        engine.orchestratorProvider = .claude
        audit.check("with one CLI the classic mode is blocked and says why", engine.startBlocker?.contains("two installed") == true, engine.startBlocker ?? "nil")
        var persisted: [String: Bool] = [:]
        engine.persistPreference = { persisted[$0] = $1 }
        engine.singleProviderTeam = true
        audit.equal("the choice is persisted under its key", persisted["team.singleProvider.v1"], true)
        audit.equal("the provider becomes its own worker", engine.workerPool, [.claude])
        audit.check("without distinct models the start is blocked with the reason", engine.startBlocker?.contains("different model") == true, engine.startBlocker ?? "nil")
        audit.check("…and no reviewer is offered", engine.reviewer(forAuthor: .claude) == nil)
        engine.roleModelOverrides[.author, default: [:]][.claude] = "claude-sonnet-5"
        engine.roleModelOverrides[.reviewer, default: [:]][.claude] = "claude-sonnet-5"
        audit.check("the same model for author and reviewer is still blocked", engine.startBlocker?.contains("different model") == true)
        engine.roleModelOverrides[.reviewer, default: [:]][.claude] = "claude-opus-5"
        audit.check("distinct models unblock the run", engine.startBlocker == nil, engine.startBlocker ?? "nil")
        audit.equal("the reviewer is the same provider", engine.reviewer(forAuthor: .claude), .claude)
        audit.check("a review by the same provider is allowed only with a different model", engine.sameProviderReviewAllowed(.claude))
        engine.disabledWorkers = [.claude]
        audit.check("switching the provider off as a worker is named", engine.startBlocker?.contains("switched off") == true)
        engine.disabledWorkers = []
        engine.orchestratorProvider = .grok
        audit.check("an uninstalled provider is named", engine.startBlocker?.contains("not installed") == true, engine.startBlocker ?? "nil")
        engine.orchestratorProvider = .claude
        engine.singleProviderTeam = false
        audit.check("turning the mode off restores the classic rule", engine.startBlocker?.contains("two installed") == true)
        engine.singleProviderTeam = true

        await Auditor.withTemporaryDirectory { project in
            var created: [ScriptedBackend] = []
            engine.makeBackend = { provider in
                let backend = ScriptedBackend(provider: provider, scripts: created.isEmpty
                    ? [[.assistantDelta("Implemented the item.\nFILES: none\n"), .turnFinished(stopReason: "end_turn", costUSD: nil)]] : [])
                created.append(backend)
                return backend
            }
            engine.startPreparedItem(title: "Add a greeting", brief: "Print hello.", author: .claude, reviewer: .claude, roundBudget: 1, project: project)
            let phaseText = "\(engine.phase)"
            audit.check("a prepared same-provider item is accepted in single-agent mode", !phaseText.contains("failed"), phaseText)
            let deadline = Date().addingTimeInterval(6)
            while created.count < 2 && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            audit.equal("two sessions were opened, both on the provider", created.map(\.provider), [.claude, .claude])
            audit.equal("the author session was preconfigured with the author model", created.first?.configuredModel, "claude-sonnet-5")
            audit.equal("the review session was preconfigured with the reviewer model", created.dropFirst().first?.configuredModel, "claude-opus-5")
            audit.check("the two sessions are distinct backends", created.count >= 2 && created[0] !== created[1])
            engine.stop()
        }
    }
}

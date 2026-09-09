import Foundation

/// The rename from Grok Studio: data moves once, preferences merge without overwriting, and a
/// second run is a no-op. Everything runs in temporary folders and private suites.
@MainActor
enum AuditMigration {
    static func run(_ audit: Auditor) async {
        audit.section("Migration — the Grok Studio data folder and preferences carry over once")
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orrery-audit-migration-\(UUID().uuidString)")
        let legacyFolder = base.appendingPathComponent("GrokStudio/ProjectSettings")
        try? FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try? "{}".write(to: legacyFolder.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("GrokStudio/TaskHistory"), withIntermediateDirectories: true)
        try? "real".write(to: base.appendingPathComponent("GrokStudio/TaskHistory/real.json"), atomically: true, encoding: .utf8)
        try? "old".write(to: base.appendingPathComponent("GrokStudio/team-stats.jsonl"), atomically: true, encoding: .utf8)
        // A headless run or an earlier launch may already have created the new folder.
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("Orrery/TaskHistory"), withIntermediateDirectories: true)
        try? "audit".write(to: base.appendingPathComponent("Orrery/TaskHistory/audit.json"), atomically: true, encoding: .utf8)
        try? "new".write(to: base.appendingPathComponent("Orrery/team-stats.jsonl"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: base) }
        let legacyName = "local.orrery.audit-legacy-\(UUID().uuidString)"
        let newName = "local.orrery.audit-new-\(UUID().uuidString)"
        let legacy = UserDefaults(suiteName: legacyName)!
        let new = UserDefaults(suiteName: newName)!
        defer { legacy.removePersistentDomain(forName: legacyName); new.removePersistentDomain(forName: newName) }
        legacy.set("/Users/someone/project", forKey: "lastProject")
        legacy.set("codex", forKey: "provider")
        legacy.set(["/Users/someone/project": "identity"], forKey: "trustedProjects")
        new.set("grok", forKey: "provider")

        let first = LegacyMigration.run(applicationSupport: base, legacyDefaults: legacy, legacyDomainName: legacyName, defaults: new)
        func text(_ path: String) -> String { (try? String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)) ?? "" }
        audit.check("entries move into the new folder, merging with what is already there",
                    first.movedEntries == 2 && text("Orrery/ProjectSettings/settings.json") == "{}" && text("Orrery/TaskHistory/real.json") == "real"
                    && text("Orrery/TaskHistory/audit.json") == "audit", "\(first)")
        audit.check("a file that exists on both sides is left behind and reported",
                    first.leftBehind == 1 && text("Orrery/team-stats.jsonl") == "new" && text("GrokStudio/team-stats.jsonl") == "old")
        audit.check("emptied legacy folders are removed, the conflicting one stays",
                    !FileManager.default.fileExists(atPath: base.appendingPathComponent("GrokStudio/TaskHistory").path)
                    && FileManager.default.fileExists(atPath: base.appendingPathComponent("GrokStudio").path))
        audit.equal("legacy keys that were not set yet are copied", first.copiedKeys, 2)
        audit.equal("the last project carries over", new.string(forKey: "lastProject"), "/Users/someone/project")
        audit.equal("project trust carries over", (new.dictionary(forKey: "trustedProjects") as? [String: String])?["/Users/someone/project"], "identity")
        audit.equal("a value already set in the new domain is not overwritten", new.string(forKey: "provider"), "grok")
        audit.check("the marker is set", new.bool(forKey: LegacyMigration.marker))
        legacy.set("late", forKey: "lateKey")
        let second = LegacyMigration.run(applicationSupport: base, legacyDefaults: legacy, legacyDomainName: legacyName, defaults: new)
        audit.equal("a second run moves nothing and copies nothing", second, LegacyMigration.Outcome(movedEntries: 0, leftBehind: 1, copiedKeys: 0))
        audit.check("…and does not pick up keys written later", new.object(forKey: "lateKey") == nil)
        let none = LegacyMigration.run(applicationSupport: base, legacyDefaults: nil, legacyDomainName: legacyName, defaults: UserDefaults(suiteName: newName + ".b")!)
        UserDefaults(suiteName: newName + ".b")!.removePersistentDomain(forName: newName + ".b")
        audit.equal("no legacy domain means nothing to copy", none.copiedKeys, 0)

        audit.section("Migration — a moved working-copy store rebases its manifests once")
        let oldStore = base.appendingPathComponent("old-store")
        let project = base.appendingPathComponent("proj")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try? "print(1)\n".write(to: project.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let store = TaskWorkspaceStore(directory: oldStore)
        let taskID = UUID()
        if let created = try? await store.create(taskID: taskID, project: project) {
            audit.check("the working copy is created under the old store", created.executionRoot.path.hasPrefix(oldStore.path))
            let newStore = base.appendingPathComponent("new-store")
            try? FileManager.default.moveItem(at: oldStore, to: newStore)
            let moved = TaskWorkspaceStore(directory: newStore)
            let reopened = try? await moved.workspace(taskID: taskID)
            audit.check("after the move the workspace opens with its root rebased onto the new store",
                        reopened != nil && reopened!.executionRoot.path.hasPrefix(newStore.path) && FileManager.default.fileExists(atPath: reopened!.executionRoot.path),
                        reopened.map { $0.executionRoot.path } ?? "failed to open")
            let changes = try? await moved.changes(taskID: taskID)
            audit.check("…and its checkpoint still reads", changes != nil)
        } else { audit.check("the working copy is created under the old store", false) }

        AppModel.preferences.set("claude-fable-5-1", forKey: "claudeModel")
        let model = AppModel(trust: .forAudit)
        audit.equal("before any session starts the toolbar names the saved model", model.modelToolbarLabel(for: .claude), "Fable 5.1")
        AppModel.preferences.removeObject(forKey: "claudeModel")
        audit.equal("without a saved model it says Model", model.modelToolbarLabel(for: .claude), "Model")
        model.shutdown()
        try? FileManager.default.removeItem(at: base.appendingPathComponent("GrokStudio"))
        let nothing = LegacyMigration.run(applicationSupport: base, legacyDefaults: nil, legacyDomainName: legacyName, defaults: new)
        audit.equal("without a legacy folder nothing moves", nothing.movedEntries + nothing.leftBehind, 0)
    }
}

import Foundation

/// CLI updates: Grok's JSON check is parsed honestly, npm versions compare correctly, the bundled
/// Codex is never touched, the updater runs through the CLI's own command, and the automatic
/// switch persists. Seams replace every network call and process.
@MainActor
enum AuditUpdates {
    static func run(_ audit: Auditor) async {
        audit.section("Updates — each CLI's own updater, checked honestly, installed only when asked or switched on")
        let release = Data("{\"tag_name\":\"v1.9.0\",\"draft\":false,\"prerelease\":false}".utf8)
        audit.equal("Orrery update feed reads the public stable release", OrreryUpdates.releaseVersion(release), "1.9.0")
        audit.check("draft and malformed release feeds are refused", OrreryUpdates.releaseVersion(Data("{\"tag_name\":\"v99.0.0\",\"draft\":true,\"prerelease\":false}".utf8)) == nil && OrreryUpdates.releaseVersion(Data("{}".utf8)) == nil)
        audit.check("release links always point to the public repository", OrreryUpdates.releasesURL.host == "github.com" && OrreryUpdates.releasesURL.path == "/by42ppcrps-dev/orrery/releases/latest")
        let grok = ToolchainWatch.grokUpdateStatus(fromJSON: "{\"currentVersion\":\"1.0.13\",\"latestVersion\":\"1.0.14\",\"updateAvailable\":true,\"installer\":\"internal\",\"channel\":\"stable\",\"autoUpdate\":true,\"error\":null}", installed: "1.0.13")
        audit.check("grok's check reports the available version, its channel and its own auto-update", grok.available && grok.latest == "1.0.14" && grok.updatable && grok.note.contains("updates itself") && grok.note.contains("stable"), grok.line)
        audit.check("…and the line reads for a person", grok.line == "1.0.13 installed · 1.0.14 available", grok.line)
        let same = ToolchainWatch.grokUpdateStatus(fromJSON: "{\"currentVersion\":\"1.0.13\",\"latestVersion\":\"1.0.13\",\"updateAvailable\":false,\"channel\":\"stable\",\"autoUpdate\":true}", installed: "1.0.13")
        audit.check("up to date is said plainly", !same.available && same.line.hasPrefix("1.0.13 · up to date"), same.line)
        audit.check("an error from the check is shown, not hidden", ToolchainWatch.grokUpdateStatus(fromJSON: "{\"error\":\"offline\"}", installed: "1.0.13").note.contains("offline"))
        audit.check("garbage from the check is named", ToolchainWatch.grokUpdateStatus(fromJSON: "not json", installed: "1.0.13").note.contains("no JSON"))
        audit.check("version compare orders dotted numbers", ToolchainWatch.compareVersions("2.1.262", "2.1.261") > 0 && ToolchainWatch.compareVersions("0.153.4", "0.153.1") > 0 && ToolchainWatch.compareVersions("1.0.13", "1.0.13") == 0 && ToolchainWatch.compareVersions("1.0.9", "1.0.13") < 0)
        audit.check("a pre-release sorts below its release", ToolchainWatch.compareVersions("0.151.0-alpha.7", "0.151.0") < 0)
        audit.check("empty versions cannot crash the update check", ToolchainWatch.compareVersions("", "1.0.0") < 0)
        audit.check("prerelease numbers compare numerically", ToolchainWatch.compareVersions("1.0.0-alpha.10", "1.0.0-alpha.9") > 0)
        audit.check("build metadata does not change version precedence", ToolchainWatch.compareVersions("1.0.0+build.42", "1.0.0") == 0)
        let incomplete = ToolchainWatch.grokUpdateStatus(fromJSON: "{\"currentVersion\":\"1.0.0\",\"latestVersion\":\"\"}", installed: "1.0.0")
        audit.check("incomplete update checks never claim up to date or offer an updater", !incomplete.updatable && !incomplete.line.contains("up to date") && incomplete.line.contains("incomplete"))
        let claude = ToolchainWatch.npmStatus(provider: .claude, installed: "2.1.261", latest: "2.1.262", bundled: false)
        audit.check("Claude with a newer npm version is updatable through its own command", claude.available && claude.updatable && claude.command == ["update"] && claude.note.contains("updates itself"))
        let codex = ToolchainWatch.npmStatus(provider: .codex, installed: "0.153.1", latest: "0.153.4", bundled: true)
        audit.check("the bundled Codex is reported but never updatable here", codex.available && !codex.updatable && codex.note.contains("ChatGPT"))
        let standalone = ToolchainWatch.npmStatus(provider: .codex, installed: "0.153.1", latest: "0.153.4", bundled: false)
        audit.check("a standalone Codex is updatable", standalone.updatable && standalone.command == ["update"])
        audit.check("no registry answer is named", ToolchainWatch.npmStatus(provider: .claude, installed: "2.1.261", latest: nil, bundled: false).note.contains("unreachable"))
        audit.check("not installed is named", ToolchainWatch.npmStatus(provider: .grok, installed: nil, latest: "1.0.14", bundled: false).note == "not installed")

        let watch = ToolchainWatch()
        let previousStore = ToolchainWatch.storeURL
        let tempStore = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orrery-audit-updates-\(UUID().uuidString).jsonl")
        ToolchainWatch.storeURL = tempStore
        defer { ToolchainWatch.storeURL = previousStore; ToolchainWatch.restoreProductionSeams(); ToolchainWatch.grokUpdateCheckOverride = nil; ToolchainWatch.npmLatestOverride = nil; ToolchainWatch.updateRunnerOverride = nil; try? FileManager.default.removeItem(at: tempStore) }
        ToolchainWatch.locateOverride = { _ in "/usr/bin/true" }
        ToolchainWatch.versionOutputOverride = { provider in
            switch provider { case .grok: return "grok 1.0.13"; case .claude: return "2.1.261 (Claude Code)"; case .codex: return "codex-cli 0.153.1" }
        }
        ToolchainWatch.handshakeOverride = { provider, _ in
            SelfTest.HandshakeResult(provider: provider, locatedPath: "/usr/bin/true", sessionID: "audit", failure: nil, modelNames: [], effortInfo: nil)
        }
        ToolchainWatch.npmFetch = { (200, "{\"version\":\"2.1.261\"}") }
        ToolchainWatch.grokUpdateCheckOverride = { "{\"currentVersion\":\"1.0.13\",\"latestVersion\":\"1.0.14\",\"updateAvailable\":true,\"channel\":\"stable\",\"autoUpdate\":false}" }
        ToolchainWatch.npmLatestOverride = { package in package.contains("claude") ? "2.1.262" : "0.153.4" }
        var runs: [(Provider, [String])] = []
        ToolchainWatch.updateRunnerOverride = { provider, _, arguments in
            runs.append((provider, arguments))
            ToolchainWatch.versionOutputOverride = { provider in
                switch provider { case .grok: return "grok 1.0.14"; case .claude: return "2.1.262 (Claude Code)"; case .codex: return "codex-cli 0.153.1" }
            }
            return (0, "Updated \(provider.rawValue)")
        }
        AppModel.preferences.removeObject(forKey: ToolchainWatch.autoUpdateKey)
        await watch.sweepAndCheckUpdates()
        audit.equal("after a check, updates are known for every provider", Set(watch.updates.keys), Set(Provider.allCases))
        audit.equal("the available list names Grok, Claude and the standalone Codex", watch.availableUpdates, [.grok, .claude, .codex])
        audit.check("the rows' update lines carry the result", watch.row(for: .grok).updateLine.contains("1.0.14 available") && watch.row(for: .claude).updateLine.contains("2.1.262 available"))
        audit.check("nothing was installed while automatic updates are off", runs.isEmpty)
        let ok = await watch.runUpdate(.claude)
        audit.check("Update runs the CLI's own updater once", ok && runs.map(\.0) == [.claude] && runs.first?.1 == ["update"])
        audit.check("the log is kept and the version re-read", watch.updateLogs[.claude]?.contains("Updated claude") == true && watch.updates[.claude]?.installed == "2.1.262" && watch.updates[.claude]?.available == false)
        runs.removeAll()
        watch.autoUpdate = true
        audit.check("the automatic switch persists", AppModel.preferences.bool(forKey: ToolchainWatch.autoUpdateKey))
        await watch.checkUpdates()
        audit.equal("with the switch on, a check installs what is updatable and skips what is not", runs.map(\.0), [.grok, .codex])
        watch.autoUpdate = false
        AppModel.preferences.removeObject(forKey: ToolchainWatch.autoUpdateKey)
        ToolchainWatch.locateOverride = { provider in provider == .codex ? "/Applications/ChatGPT.app/Contents/Resources/codex" : "/usr/bin/true" }
        runs.removeAll()
        await watch.sweepAndCheckUpdates()
        audit.check("a bundled Codex is reported as updating with ChatGPT and is not run", watch.updates[.codex]?.updatable == false && watch.updates[.codex]?.note.contains("ChatGPT") == true)
        let refused = await watch.runUpdate(.codex)
        audit.check("Update refuses the bundled Codex", !refused && runs.isEmpty)
        ToolchainWatch.updateRunnerOverride = { _, _, _ in (1, "fixture updater failed") }
        let failed = await watch.runUpdate(.claude)
        audit.check("failed updater is visible in the status row", !failed && watch.updates[.claude]?.line.contains("Update failed") == true && watch.updateLogs[.claude]?.contains("fixture updater failed") == true)
    }
}

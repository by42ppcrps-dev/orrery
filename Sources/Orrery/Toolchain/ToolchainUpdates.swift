import Foundation
import SwiftUI

/// Update checks for the three CLIs, using each CLI's own updater: `grok update --check --json`
/// (Grok also updates itself when its `autoUpdate` is on), the npm registry for Claude Code and
/// Codex, and `claude update` / `codex update` to install. The Codex bundled inside ChatGPT.app
/// updates with that app and is never touched. Automatic installs are off until you turn them on.
extension ToolchainWatch {
    struct UpdateStatus: Equatable {
        var installed: String?
        var latest: String?
        var available = false
        var updatable = false
        var note: String
        var command: [String] = []
        var failure: String?

        var line: String {
            if let failure { return failure }
            if let installed, let latest {
                if available { return "\(installed) installed · \(latest) available" + (updatable ? "" : " · \(note)") }
                return "\(installed) · up to date" + (note.isEmpty ? "" : " · \(note)")
            }
            return note
        }
    }

    static let autoUpdateKey = "toolchain.autoUpdate.v1"
    static let updateTimeout: TimeInterval = 300
    /// Test seam: JSON text as `grok update --check --json` prints it. nil means run the CLI.
    nonisolated(unsafe) static var grokUpdateCheckOverride: (() async -> String?)?
    /// Test seam: the npm registry document for a package. nil means fetch it.
    nonisolated(unsafe) static var npmLatestOverride: ((String) async -> String?)?
    /// Test seam: runs an updater. nil means run the CLI's update command.
    nonisolated(unsafe) static var updateRunnerOverride: ((Provider, String, [String]) async -> (status: Int32, output: String))?

    var autoUpdate: Bool {
        get { AppModel.preferences.bool(forKey: Self.autoUpdateKey) }
        set { AppModel.preferences.set(newValue, forKey: Self.autoUpdateKey); autoUpdateRevision += 1 }
    }

    var availableUpdates: [Provider] { Provider.allCases.filter { updates[$0]?.available == true } }

    // MARK: Parsing

    /// `{"currentVersion":"1.0.13","latestVersion":"1.0.14","updateAvailable":true,"channel":"stable","autoUpdate":true,"error":null}`
    static func grokUpdateStatus(fromJSON text: String?, installed: String?) -> UpdateStatus {
        guard let text, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return UpdateStatus(installed: installed, note: "update check unavailable (grok update --check gave no JSON)")
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return UpdateStatus(installed: installed, note: "update check failed: \(error)")
        }
        guard let current = ((object["currentVersion"] as? String) ?? installed).flatMap(parseVersion),
              let latest = (object["latestVersion"] as? String).flatMap(parseVersion),
              let reportedAvailable = object["updateAvailable"] as? Bool else {
            return UpdateStatus(installed: installed, note: "update check incomplete; no verified latest version")
        }
        let available = reportedAvailable && compareVersions(latest, current) > 0
        let channel = (object["channel"] as? String).map { " · \($0) channel" } ?? ""
        let selfUpdates = object["autoUpdate"] as? Bool ?? false
        return UpdateStatus(installed: current, latest: latest, available: available, updatable: true,
                            note: (selfUpdates ? "Grok updates itself" : "Grok's own updater is off") + channel,
                            command: ["update"])
    }

    /// Dotted numeric compare; a pre-release suffix sorts below the plain version.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> ([Int], String) {
            let version = v.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
            let main = version.split(separator: "-", maxSplits: 1)
            let numbers = (main.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (numbers, main.count > 1 ? String(main[1]) : "")
        }
        let (na, sa) = parts(a), (nb, sb) = parts(b)
        for index in 0..<max(na.count, nb.count) {
            let x = index < na.count ? na[index] : 0, y = index < nb.count ? nb[index] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        if sa.isEmpty != sb.isEmpty { return sa.isEmpty ? 1 : -1 }
        let pa = sa.split(separator: "."), pb = sb.split(separator: ".")
        for (x, y) in zip(pa, pb) where x != y {
            if let nx = Int(x), let ny = Int(y) { return nx < ny ? -1 : 1 }
            if Int(x) != nil { return -1 }
            if Int(y) != nil { return 1 }
            return x < y ? -1 : 1
        }
        return pa.count == pb.count ? 0 : (pa.count < pb.count ? -1 : 1)
    }

    static func npmStatus(provider: Provider, installed: String?, latest: String?, bundled: Bool) -> UpdateStatus {
        guard let installed else { return UpdateStatus(installed: nil, latest: latest, note: "not installed") }
        guard let latest else { return UpdateStatus(installed: installed, note: "npm registry unreachable") }
        let available = compareVersions(latest, installed) > 0
        if provider == .codex && bundled {
            return UpdateStatus(installed: installed, latest: latest, available: available, updatable: false,
                                note: "bundled in ChatGPT.app; updates with the ChatGPT app")
        }
        return UpdateStatus(installed: installed, latest: latest, available: available, updatable: true,
                            note: provider == .claude ? "Claude Code updates itself by default" : "standalone CLI",
                            command: ["update"])
    }

    static func fetchNPMLatest(_ package: String) async -> String? {
        if let npmLatestOverride { return await npmLatestOverride(package) }
        guard let url = URL(string: "https://registry.npmjs.org/\(package)/latest") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: npmTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["version"] as? String).flatMap(parseVersion)
    }

    // MARK: Checking and installing

    func checkUpdates() async {
        var results: [Provider: UpdateStatus] = [:]
        for provider in Provider.allCases {
            let installed = Self.lastParsedVersion(provider)
            let path = Self.locate(provider)
            switch provider {
            case .grok:
                guard path != nil else { results[.grok] = UpdateStatus(installed: nil, note: "not installed"); continue }
                var json: String?
                if let override = Self.grokUpdateCheckOverride { json = await override() }
                else if let path, let result = try? await ProcessRunner.run(path, ["update", "--check", "--json"], environment: Self.updateEnvironment, timeout: 20) {
                    json = result.standardOutput
                }
                results[.grok] = Self.grokUpdateStatus(fromJSON: json, installed: installed)
            case .claude:
                let latest = path == nil ? nil : await Self.fetchNPMLatest("@anthropic-ai/claude-code")
                results[.claude] = Self.npmStatus(provider: .claude, installed: path == nil ? nil : installed, latest: latest, bundled: false)
            case .codex:
                let latest = path == nil ? nil : await Self.fetchNPMLatest("@openai/codex")
                results[.codex] = Self.npmStatus(provider: .codex, installed: path == nil ? nil : installed, latest: latest, bundled: path.map(Self.isBundledCodexPath) ?? false)
            }
        }
        updates = results
        rebuildUpdateLines()
        if autoUpdate {
            for provider in Provider.allCases where results[provider]?.available == true && results[provider]?.updatable == true {
                _ = await runUpdate(provider)
            }
        }
    }

    static var updateEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/.grok/bin",
         "HOME": NSHomeDirectory(), "TERM": "dumb", "CI": "1"]
    }

    /// Runs the CLI's own updater and re-reads versions afterwards.
    @discardableResult
    func runUpdate(_ provider: Provider) async -> Bool {
        guard let status = updates[provider], status.updatable, !status.command.isEmpty, let path = Self.locate(provider) else { return false }
        guard !isUpdating.contains(provider) else { return false }
        isUpdating.insert(provider)
        defer { isUpdating.remove(provider) }
        let outcome: (status: Int32, output: String)
        if let override = Self.updateRunnerOverride {
            outcome = await override(provider, path, status.command)
        } else if let result = try? await ProcessRunner.run(path, status.command, environment: Self.updateEnvironment, timeout: Self.updateTimeout) {
            outcome = (result.status, result.combined)
        } else {
            outcome = (-1, "The updater could not be started.")
        }
        updateLogs[provider] = String(outcome.output.suffix(4_000))
        await sweepNow(forceNetwork: false)
        if let installed = Self.lastParsedVersion(provider), var refreshed = updates[provider] {
            refreshed.installed = installed
            refreshed.available = refreshed.latest.map { Self.compareVersions($0, installed) > 0 } ?? false
            refreshed.failure = outcome.status == 0 ? nil : "Update failed. See the toolchain details for the updater's message."
            updates[provider] = refreshed
            rebuildUpdateLines()
        }
        return outcome.status == 0
    }

    func rebuildUpdateLines() {
        rows = rows.map { row in
            var row = row
            if let status = updates[row.provider] { row.updateLine = status.line }
            return row
        }
    }
}

/// The banner and controls non-experts see: which CLI has an update, one button to install it,
/// and one switch to make it automatic.
struct ToolchainUpdateBanner: View {
    @Bindable var watch: ToolchainWatch

    var body: some View {
        // Only what can be installed from here; the bundled Codex's note stays in the Toolchain status.
        let available = watch.availableUpdates.filter { watch.updates[$0]?.updatable == true }
        if !available.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(available) { provider in
                    HStack(spacing: 8) {
                        Label("\(provider.displayName) \(watch.updates[provider]?.latest ?? "") available", systemImage: "arrow.down.circle").font(.caption)
                        Spacer(minLength: 4)
                        Button(watch.isUpdating.contains(provider) ? "Updating…" : "Update") {
                            Task { await watch.runUpdate(provider) }
                        }.controlSize(.small).disabled(watch.isUpdating.contains(provider))
                            .accessibilityLabel("Update \(provider.displayName)")
                    }
                    if let failure = watch.updates[provider]?.failure { Text(failure).font(.caption).foregroundStyle(.red) }
                }
                Toggle("Update automatically", isOn: Binding(get: { watch.autoUpdate }, set: { watch.autoUpdate = $0 }))
                    .toggleStyle(.checkbox).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(Color.blue.opacity(0.10))
        }
    }
}

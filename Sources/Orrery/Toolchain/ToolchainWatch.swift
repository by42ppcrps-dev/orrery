import Foundation
import Observation
import SwiftUI

/// Watches the three agent CLIs: version sweep, change-triggered free handshake,
/// and honest update-channel status. Not a LaunchAgent, not a background daemon —
/// a `Task` owned by the running app, fired on launch and every 24 hours.
@MainActor
@Observable
final class ToolchainWatch {
    static let shared = ToolchainWatch()

    static let kindSweep = "sweep"
    static let kindChange = "change"
    static let stateParsed = "parsed"
    static let stateUnparsed = "unparsed"
    static let stateNotInstalled = "notInstalled"
    /// Codex located outside ChatGPT.app — not the bundled binary, so it must
    /// not pose as a bundled version.
    static let stateStandaloneCLI = "standaloneCLI"

    static let period: TimeInterval = 24 * 60 * 60
    static let npmTimeout: TimeInterval = 4
    static let npmCacheTTL: TimeInterval = 24 * 60 * 60
    static let versionTimeout: TimeInterval = 8

    static let seededBaseline: [(Provider, String)] = [
        (.grok, "1.0.13"),
        (.claude, "2.1.233"),
        (.codex, "0.151.0-alpha.7.2"),
    ]

    static let grokUpdateLine = "update not checked yet"
    static let uiTitle = "Toolchain"
    static let moreMenuTitle = "Toolchain…"
    static let checkNowTitle = "Check now"

    /// `~/Library/Application Support/Orrery/toolchain.jsonl`. A `var` so `--audit`
    /// can redirect to a temp directory and never touch the user's store.
    static var storeURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Orrery/toolchain.jsonl")

    static var now: () -> Date = { Date() }

    /// Test seam. Production is nil, which means `SelfTest.handshake`.
    static var handshakeOverride: ((Provider, URL) async -> SelfTest.HandshakeResult)?
    /// Test seam. Production is nil, which means `ProcessRunner` ` --version`.
    static var versionOutputOverride: ((Provider) async -> String?)?
    /// Test seam. Production is nil, which means `GrokBackend`/`ClaudeBackend`/`CodexBackend.locate()`.
    static var locateOverride: ((Provider) -> String?)?
    /// Test seam. Production hits the npm registry with a short timeout.
    static var npmFetch: () async -> (status: Int, body: String)? = defaultNPMFetch

    var rows: [Row] = Provider.allCases.map { Row.unknown($0) }
    var updates: [Provider: UpdateStatus] = [:]
    var updateLogs: [Provider: String] = [:]
    var isUpdating: Set<Provider> = []
    var autoUpdateRevision = 0
    var isSweeping = false
    var lastSweepAt: Date?
    var claudeChannel: ClaudeChannel = .notChecked

    private var periodic: Task<Void, Never>?
    private var npmCached: (at: Date, channel: ClaudeChannel)?

    init() {
        rebuildRows(claude: .notChecked)
    }

    struct Row: Equatable, Identifiable {
        var id: String { provider.rawValue }
        var provider: Provider
        var versionLine: String
        var lastCheckedLine: String
        var handshakeLine: String
        var updateLine: String

        var summaryLine: String {
            "\(versionLine) · \(lastCheckedLine) · \(handshakeLine)"
        }

        var changeHistoryLine: String

        static func unknown(_ provider: Provider) -> Row {
            Row(provider: provider,
                versionLine: "unknown",
                lastCheckedLine: "never checked",
                handshakeLine: "handshake not run",
                updateLine: "unknown",
                changeHistoryLine: "no change recorded for \(provider.displayName)")
        }
    }

    enum ClaudeChannel: Equatable, Sendable {
        case latest(String)
        case unreachable
        case notChecked
    }

    struct Record: Equatable, Sendable {
        var kind: String
        var provider: String
        var version: String?
        var versionState: String
        var rawOutput: String?
        var checkedAt: Date
        var locatedPath: String?
        var previousVersion: String?
        var handshakeOK: Bool?
        var handshakeReason: String?
        var sessionID: String?
        var modelNames: [String]?
        var effortInfo: String?
        /// Unknown keys from the JSON line. Re-emitted on encode so a future
        /// field survives load-then-append. Canonical JSON object; `"{}"` if none.
        var extraJSON: String = "{}"
    }

    private static let lock = NSLock()

    private static let checkedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    fileprivate static func encoder() -> JSONEncoder {
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

    static var defaultStoreURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Orrery/toolchain.jsonl")
    }

    static var isProductionStore: Bool {
        storeURL.standardizedFileURL.path == defaultStoreURL.standardizedFileURL.path
    }

    /// `--audit` must never write (or read-as-fact) the user's Application Support file.
    static var writesAllowed: Bool {
        !(CommandLine.arguments.contains("--audit") && isProductionStore)
    }

    // MARK: Version parsing

    /// Lenient token: prefixes (`grok `, `codex-cli `, `v`), suffixes (` (Claude Code)`),
    /// and pre-release segments (`-alpha.7.2`) are tolerated. Returns nil rather than
    /// inventing a version when nothing matches.
    static func parseVersion(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let regex = try? NSRegularExpression(
            pattern: #"[0-9]+\.[0-9]+(?:\.[0-9]+)*(?:-[0-9A-Za-z.]+)?"#) else { return nil }
        let ns = trimmed as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              match.range.location != NSNotFound else { return nil }
        let token = ns.substring(with: match.range)
        return token.isEmpty ? nil : token
    }

    /// A version string we can compare across sweeps — bundled parsed or the
    /// standalone-CLI fallback. Unparsed / not-installed are not versions.
    static func isResolvedVersion(_ state: String) -> Bool {
        state == stateParsed || state == stateStandaloneCLI
    }

    static func versionDisplay(state: String, version: String?) -> String {
        switch state {
        case stateParsed:
            if let version, !version.isEmpty { return version }
            return "unparsed"
        case stateStandaloneCLI:
            if let version, !version.isEmpty { return "\(version) (standalone CLI)" }
            return "standalone CLI"
        case stateUnparsed:
            return "unparsed"
        case stateNotInstalled:
            return "not installed"
        default:
            return "unknown"
        }
    }

    static func handshakeDisplay(ok: Bool?, reason: String?) -> String {
        guard let ok else { return "handshake not run" }
        if ok { return "handshake ok" }
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "handshake failed" : "handshake failed: \(trimmed)"
    }

    /// Handshake copy for a toolchain row. A later unparsed or not-installed
    /// sweep must not keep a historical "handshake ok" or an obsolete failure.
    static func handshakeDisplay(sweep: Record?, change: Record?) -> String {
        guard let state = sweep?.versionState, isResolvedVersion(state) else {
            return handshakeDisplay(ok: nil, reason: nil)
        }
        return handshakeDisplay(ok: change?.handshakeOK, reason: change?.handshakeReason)
    }

    static func formatChecked(_ date: Date?) -> String {
        guard let date else { return "never checked" }
        return checkedFormatter.string(from: date)
    }

    static func claudeUpdateLine(_ channel: ClaudeChannel) -> String {
        switch channel {
        case let .latest(version):
            return "npm latest \(version) · Claude CLI self-updates"
        case .unreachable:
            return "unreachable · Claude CLI self-updates"
        case .notChecked:
            return "npm not checked · Claude CLI self-updates"
        }
    }

    static func grokUpdateText() -> String { grokUpdateLine }

    static func isBundledCodexPath(_ path: String) -> Bool {
        path.contains("/ChatGPT.app/Contents/Resources/codex")
    }

    static func versionState(provider: Provider, parsed: String?, path: String) -> String {
        guard parsed != nil else { return stateUnparsed }
        if provider == .codex && !isBundledCodexPath(path) {
            return stateStandaloneCLI
        }
        return stateParsed
    }

    static func codexUpdateLine(version: String?, modified: Date?,
                                versionState: String = "parsed") -> String {
        if versionState == stateStandaloneCLI {
            let ver = (version?.isEmpty == false) ? version! : "unknown"
            return "standalone CLI \(ver) · not the ChatGPT.app bundle · no public channel"
        }
        let bundled: String
        if let version, !version.isEmpty {
            bundled = "bundled \(version)"
        } else {
            bundled = "bundled version unknown"
        }
        let stamp: String
        if let modified {
            stamp = "ChatGPT.app modified \(formatChecked(modified))"
        } else {
            stamp = "ChatGPT.app modification date unknown"
        }
        return "\(bundled) · \(stamp) · no public channel"
    }

    static func defaultUpdateLine(_ provider: Provider, version: String?,
                                  claude: ClaudeChannel,
                                  versionState: String = "") -> String {
        switch provider {
        case .grok: return grokUpdateText()
        case .claude: return claudeUpdateLine(claude)
        case .codex: return codexUpdateLine(version: version, modified: chatgptModifiedAt(),
                                            versionState: versionState)
        }
    }

    /// Last change for `provider` only. Never falls back to another provider's
    /// entry. No recorded change is named as such.
    static func changeHistoryLine(for provider: Provider, change: Record?) -> String {
        guard let change else {
            return "no change recorded for \(provider.displayName)"
        }
        let from: String
        if let previous = change.previousVersion, !previous.isEmpty {
            from = previous
        } else {
            from = "unrecorded"
        }
        let to: String
        if let version = change.version, !version.isEmpty {
            to = version
        } else {
            to = "unrecorded"
        }
        return "\(provider.displayName) \(from) → \(to)"
    }

    static func changeHistoryLine(for provider: Provider, from url: URL? = nil) -> String {
        changeHistoryLine(for: provider, change: lastChange(provider, from: url))
    }

    static func chatgptAppURL() -> URL? {
        let paths = [
            "/Applications/ChatGPT.app",
            NSHomeDirectory() + "/Applications/ChatGPT.app",
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func chatgptModifiedAt() -> Date? {
        guard let url = chatgptAppURL() else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    // MARK: Locate / --version

    static func locate(_ provider: Provider) -> String? {
        if let locateOverride { return locateOverride(provider) }
        switch provider {
        case .grok: return GrokBackend.locate()
        case .claude: return ClaudeBackend.locate()
        case .codex: return CodexBackend.locate()
        }
    }

    static func readVersion(provider: Provider, path: String) async -> String? {
        if let versionOutputOverride { return await versionOutputOverride(provider) }
        do {
            let result = try await ProcessRunner.run(path, ["--version"],
                                                     timeout: versionTimeout)
            let text = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    // MARK: Store

    static func append(_ record: Record, to url: URL? = nil) {
        append([record], to: url)
    }

    /// One locked write of every record. A version-change sweep and its
    /// handshake must not be two appends: if the sweep lands alone,
    /// `lastParsedVersion` treats the new version as already verified.
    static func append(_ records: [Record], to url: URL? = nil) {
        guard !records.isEmpty else { return }
        let url = url ?? storeURL
        guard writesAllowed || url.standardizedFileURL.path != defaultStoreURL.standardizedFileURL.path else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        appendUnlocked(records, to: url)
    }

    private static func appendUnlocked(_ records: [Record], to url: URL) {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            var payload = Data()
            for record in records {
                guard let line = record.jsonLine() else { return }
                payload.append(line)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: payload)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            // A valid JSONL file may still lack a trailing newline (hand edit,
            // truncated write). Writing the next record against that glues two
            // objects into one corrupt line.
            if let last = (try? Data(contentsOf: url))?.last, last != 0x0A {
                try handle.write(contentsOf: Data([0x0A]))
            }
            try handle.write(contentsOf: payload)
        } catch {
            // Recording must never throw into the app.
        }
    }

    static func load(from url: URL? = nil) -> (records: [Record], corruptLines: Int) {
        let url = url ?? storeURL
        if CommandLine.arguments.contains("--audit"),
           url.standardizedFileURL.path == defaultStoreURL.standardizedFileURL.path {
            return ([], 0)
        }
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked(from: url)
    }

    private static func loadUnlocked(from url: URL) -> (records: [Record], corruptLines: Int) {
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        if data.isEmpty { return ([], 0) }
        var records: [Record] = []
        var corrupt = 0
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            var slice = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
            if slice.last == 0x0D { slice = slice.dropLast() }
            if slice.isEmpty || slice.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
            let payload = Data(slice)
            if var record = try? decoder().decode(Record.self, from: payload) {
                if let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] {
                    record.captureExtra(from: object)
                }
                records.append(record)
            } else {
                corrupt += 1
            }
        }
        return (records, corrupt)
    }

    static func lastSweep(_ provider: Provider, from url: URL? = nil) -> Record? {
        load(from: url).records.last {
            $0.kind == kindSweep && $0.provider == provider.rawValue
        }
    }

    static func lastChange(_ provider: Provider, from url: URL? = nil) -> Record? {
        load(from: url).records.last {
            $0.kind == kindChange && $0.provider == provider.rawValue
        }
    }

    static func lastParsedVersion(_ provider: Provider, from url: URL? = nil) -> String? {
        load(from: url).records.last {
            $0.kind == kindSweep
                && $0.provider == provider.rawValue
                && isResolvedVersion($0.versionState)
                && $0.version != nil
        }?.version
    }

    /// A resolved sweep of `version` is already in the store after an earlier
    /// different version, but no change/handshake record exists for this visit.
    /// An older change for the same version — the CLI cycled back — does not
    /// count: that is still the split-persist leftover (the latest sweep
    /// landed, its change did not).
    static func handshakeMissingAfterVersionChange(_ provider: Provider, version: String,
                                                   from url: URL? = nil) -> Bool {
        let records = load(from: url).records.filter { $0.provider == provider.rawValue }
        let parsedSweeps = records.filter {
            $0.kind == kindSweep
                && isResolvedVersion($0.versionState)
                && $0.version != nil
        }
        guard let latest = parsedSweeps.last, latest.version == version else { return false }
        guard let lastDifferentIndex = records.lastIndex(where: {
            $0.kind == kindSweep
                && isResolvedVersion($0.versionState)
                && $0.version != nil
                && $0.version != version
        }) else { return false }
        return !records[(lastDifferentIndex + 1)...].contains {
            $0.kind == kindChange && $0.version == version
        }
    }

    static func lastDifferentParsedVersion(_ provider: Provider, than version: String,
                                           from url: URL? = nil) -> String? {
        load(from: url).records.last {
            $0.kind == kindSweep
                && $0.provider == provider.rawValue
                && isResolvedVersion($0.versionState)
                && $0.version != nil
                && $0.version != version
        }?.version
    }

    /// Parsed CLI versions from each provider's most recent sweep, or nil when
    /// nothing has been swept. Never an empty map. An unparsed or not-installed
    /// latest sweep is omitted — never a stale historical or seeded version.
    /// Change detection still uses `lastParsedVersion`, which walks back.
    static func latestParsedVersions(from url: URL? = nil) -> [String: String]? {
        let url = url ?? storeURL
        if CommandLine.arguments.contains("--audit"), isProductionStore,
           url.standardizedFileURL.path == defaultStoreURL.standardizedFileURL.path {
            return nil
        }
        var map: [String: String] = [:]
        for provider in Provider.allCases {
            guard let sweep = lastSweep(provider, from: url),
                  isResolvedVersion(sweep.versionState),
                  let version = sweep.version, !version.isEmpty else { continue }
            map[provider.rawValue] = version
        }
        return map.isEmpty ? nil : map
    }

    static func seedBaselineIfEmpty(at url: URL? = nil) {
        let url = url ?? storeURL
        guard writesAllowed || url.standardizedFileURL.path != defaultStoreURL.standardizedFileURL.path else {
            return
        }
        let loaded = load(from: url)
        guard loaded.records.isEmpty, loaded.corruptLines == 0 else { return }
        let at = now()
        for (provider, version) in seededBaseline {
            append(Record(kind: kindSweep,
                          provider: provider.rawValue,
                          version: version,
                          versionState: stateParsed,
                          rawOutput: "seeded baseline",
                          checkedAt: at,
                          locatedPath: nil), to: url)
        }
    }

    /// In-memory only. A first sweep against an empty store uses this as the
    /// previous version so a match is not a change — it is not written as a
    /// parsed sweep, which would look verified if the check is interrupted.
    static func seededVersion(for provider: Provider) -> String? {
        seededBaseline.first { $0.0 == provider }?.1
    }

    static func storeIsEmpty(at url: URL? = nil) -> Bool {
        let loaded = load(from: url)
        return loaded.records.isEmpty && loaded.corruptLines == 0
    }

    // MARK: Update channels

    static func claudeChannel(from fetched: (status: Int, body: String)?) -> ClaudeChannel {
        guard let fetched, fetched.status == 200 else { return .unreachable }
        guard let data = fetched.body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreachable
        }
        let version = (object["version"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let parsed = parseVersion(version) else { return .unreachable }
        return .latest(parsed)
    }

    nonisolated static func defaultNPMFetch() async -> (status: Int, body: String)? {
        guard let url = URL(string: "https://registry.npmjs.org/@anthropic-ai/claude-code/latest") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            return (status, body)
        } catch {
            return nil
        }
    }

    func resolveClaudeChannel(force: Bool) async -> ClaudeChannel {
        if !force, let npmCached,
           Self.now().timeIntervalSince(npmCached.at) < Self.npmCacheTTL {
            return npmCached.channel
        }
        let fetched = await Self.npmFetch()
        let channel = Self.claudeChannel(from: fetched)
        npmCached = (Self.now(), channel)
        claudeChannel = channel
        return channel
    }

    // MARK: Sweep

    static var periodicSleepNanoseconds: UInt64 {
        UInt64(period * 1_000_000_000)
    }

    var isPeriodicSweepRunning: Bool { periodic != nil }

    func startPeriodicSweep() {
        guard periodic == nil else { return }
        guard WindowLaunch.shouldStartWatchdog() else { return }
        periodic = Task { [weak self] in
            await self?.sweepNow(forceNetwork: false)
            await self?.checkUpdates()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.periodicSleepNanoseconds)
                if Task.isCancelled { break }
                await self?.sweepNow(forceNetwork: false)
                await self?.checkUpdates()
            }
        }
    }

    func stopPeriodicSweep() {
        periodic?.cancel()
        periodic = nil
    }

    /// A sweep plus the update check; the periodic task calls this at launch and daily.
    func sweepAndCheckUpdates(project: URL? = nil) async {
        await sweepNow(forceNetwork: true, project: project)
        await checkUpdates()
    }

    func checkNow(project: URL? = nil) async {
        await sweepNow(forceNetwork: true, project: project)
        await checkUpdates()
    }

    func reloadFromStore() {
        rebuildRows(claude: claudeChannel)
    }

    func row(for provider: Provider) -> Row {
        rows.first { $0.provider == provider } ?? Row.unknown(provider)
    }

    func sweepNow(forceNetwork: Bool = true, project: URL? = nil) async {
        guard !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }
        // Do not persist the seeded baseline before handshakes. An empty-store
        // sweep consults it in memory so a matching version is not a change;
        // a quit mid-handshake must leave the store empty, not three parsed
        // records that look verified.
        let consultSeededBaseline = Self.storeIsEmpty()
        // Version probes must never initialize agents in whichever untrusted folder launched
        // the app. An empty private directory keeps project hooks/configuration out of probes.
        let scratch = project == nil ? FileManager.default.temporaryDirectory
            .appendingPathComponent("orrery-toolchain-\(UUID().uuidString)") : nil
        if let scratch {
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            } catch { return }
        }
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        guard let project = project ?? scratch else { return }
        let at = Self.now()
        for provider in Provider.allCases {
            if Task.isCancelled { break }
            await sweepProvider(provider, at: at, project: project,
                                consultSeededBaseline: consultSeededBaseline)
        }
        if Task.isCancelled {
            rebuildRows(claude: claudeChannel)
            return
        }
        lastSweepAt = at
        let channel = await resolveClaudeChannel(force: forceNetwork)
        rebuildRows(claude: channel)
        rebuildUpdateLines()
    }

    /// Change detection + handshake. Isolated so an audit can re-break just this path.
    /// Persistence of the matching sweep happens in `sweepProvider` only after
    /// this handshake returns — a cancelled handshake writes nothing.
    func recordChangeIfNeeded(provider: Provider, previous: String?, current: String?,
                              locatedPath: String, project: URL, at: Date,
                              versionState: String = "parsed") async {
        // Only a newly parsed version is a change. Unparsed output is not a
        // version, so it must not handshake against a prior parsed value.
        guard let current else { return }
        guard previous != current else { return }
        let result = await runHandshake(provider: provider, project: project)
        if Task.isCancelled { return }
        persistChange(provider: provider, current: current, previous: previous,
                      locatedPath: locatedPath, at: at, versionState: versionState,
                      result: result)
    }

    private func persistChange(provider: Provider, current: String, previous: String?,
                               locatedPath: String, at: Date, versionState: String,
                               result: SelfTest.HandshakeResult) {
        Self.append(makeChangeRecord(provider: provider, current: current, previous: previous,
                                     locatedPath: locatedPath, at: at, versionState: versionState,
                                     result: result))
    }

    private func makeChangeRecord(provider: Provider, current: String, previous: String?,
                                  locatedPath: String, at: Date, versionState: String,
                                  result: SelfTest.HandshakeResult) -> Record {
        let reason: String?
        if result.ok {
            reason = nil
        } else {
            reason = result.failure
                ?? (result.locatedPath == nil ? "not installed" : "handshake failed")
        }
        return Record(
            kind: Self.kindChange,
            provider: provider.rawValue,
            version: current,
            versionState: versionState,
            rawOutput: nil,
            checkedAt: at,
            locatedPath: result.locatedPath ?? locatedPath,
            previousVersion: previous,
            handshakeOK: result.ok,
            handshakeReason: reason,
            sessionID: result.sessionID,
            modelNames: result.modelNames,
            effortInfo: result.effortInfo)
    }

    private func runHandshake(provider: Provider, project: URL) async -> SelfTest.HandshakeResult {
        if let handshakeOverride = Self.handshakeOverride {
            return await handshakeOverride(provider, project)
        }
        return await SelfTest.handshake(provider: provider, project: project)
    }

    private func sweepProvider(_ provider: Provider, at: Date, project: URL,
                               consultSeededBaseline: Bool = false) async {
        if Task.isCancelled { return }
        let path = Self.locate(provider)
        guard let path else {
            Self.append(Record(
                kind: Self.kindSweep,
                provider: provider.rawValue,
                version: nil,
                versionState: Self.stateNotInstalled,
                rawOutput: nil,
                checkedAt: at,
                locatedPath: nil))
            return
        }
        let raw = await Self.readVersion(provider: provider, path: path)
        if Task.isCancelled { return }
        let parsed = raw.flatMap { Self.parseVersion($0) }
        let state = Self.versionState(provider: provider, parsed: parsed, path: path)
        let previous = Self.lastParsedVersion(provider)
            ?? (consultSeededBaseline ? Self.seededVersion(for: provider) : nil)
        if let current = parsed {
            let versionChanged = previous != current
            let missingHandshake = Self.handshakeMissingAfterVersionChange(provider, version: current)
            if versionChanged || missingHandshake {
                // Handshake first. Persist the sweep and the change in one write:
                // a sweep-only append would make lastParsedVersion skip the
                // handshake forever on the next run.
                let result = await runHandshake(provider: provider, project: project)
                if Task.isCancelled { return }
                let previousForChange = versionChanged
                    ? previous
                    : Self.lastDifferentParsedVersion(provider, than: current)
                let sweepRecord = Record(
                    kind: Self.kindSweep,
                    provider: provider.rawValue,
                    version: current,
                    versionState: state,
                    rawOutput: raw,
                    checkedAt: at,
                    locatedPath: path)
                let changeRecord = makeChangeRecord(provider: provider, current: current,
                                                    previous: previousForChange, locatedPath: path,
                                                    at: at, versionState: state, result: result)
                Self.append([sweepRecord, changeRecord])
                return
            }
        }
        Self.append(Record(
            kind: Self.kindSweep,
            provider: provider.rawValue,
            version: parsed,
            versionState: state,
            rawOutput: raw,
            checkedAt: at,
            locatedPath: path))
    }

    private func rebuildRows(claude: ClaudeChannel) {
        claudeChannel = claude
        rows = Provider.allCases.map { provider in
            let sweep = Self.lastSweep(provider)
            let change = Self.lastChange(provider)
            let version = Self.versionDisplay(state: sweep?.versionState ?? "",
                                              version: sweep?.version)
            let checked = Self.formatChecked(sweep?.checkedAt)
            let handshake = Self.handshakeDisplay(sweep: sweep, change: change)
            let update = Self.defaultUpdateLine(provider, version: sweep?.version,
                                                claude: claude,
                                                versionState: sweep?.versionState ?? "")
            return Row(provider: provider,
                       versionLine: sweep == nil ? "unknown" : version,
                       lastCheckedLine: sweep == nil ? "never checked" : checked,
                       handshakeLine: handshake,
                       updateLine: update,
                       changeHistoryLine: Self.changeHistoryLine(for: provider, change: change))
        }
    }

    static func restoreProductionSeams() {
        handshakeOverride = nil
        versionOutputOverride = nil
        locateOverride = nil
        npmFetch = defaultNPMFetch
        now = { Date() }
    }
}

extension ToolchainWatch.Record: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, provider, version, versionState, rawOutput, checkedAt, locatedPath
        case previousVersion, handshakeOK, handshakeReason, sessionID, modelNames, effortInfo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        provider = try c.decode(String.self, forKey: .provider)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        versionState = try c.decodeIfPresent(String.self, forKey: .versionState) ?? ""
        rawOutput = try c.decodeIfPresent(String.self, forKey: .rawOutput)
        checkedAt = try c.decode(Date.self, forKey: .checkedAt)
        locatedPath = try c.decodeIfPresent(String.self, forKey: .locatedPath)
        previousVersion = try c.decodeIfPresent(String.self, forKey: .previousVersion)
        handshakeOK = try c.decodeIfPresent(Bool.self, forKey: .handshakeOK)
        handshakeReason = try c.decodeIfPresent(String.self, forKey: .handshakeReason)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        modelNames = try c.decodeIfPresent([String].self, forKey: .modelNames)
        effortInfo = try c.decodeIfPresent(String.self, forKey: .effortInfo)
        extraJSON = "{}"
    }

    mutating func captureExtra(from object: [String: Any]) {
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        var extra: [String: Any] = [:]
        for (key, value) in object where !known.contains(key) {
            extra[key] = value
        }
        extraJSON = Self.canonicalJSON(extra)
    }

    func jsonLine() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(self) else { return nil }
        if extraJSON != "{}",
           let extraObject = (try? JSONSerialization.jsonObject(with: Data(extraJSON.utf8))) as? [String: Any],
           !extraObject.isEmpty,
           var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (key, value) in extraObject where object[key] == nil {
                object[key] = value
            }
            if let merged = try? JSONSerialization.data(withJSONObject: object,
                                                        options: [.sortedKeys]) {
                data = merged
            }
        }
        data.append(0x0A)
        return data
    }

    private static func canonicalJSON(_ object: [String: Any]) -> String {
        guard !object.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encode(versionState, forKey: .versionState)
        try c.encodeIfPresent(rawOutput, forKey: .rawOutput)
        try c.encode(checkedAt, forKey: .checkedAt)
        try c.encodeIfPresent(locatedPath, forKey: .locatedPath)
        try c.encodeIfPresent(previousVersion, forKey: .previousVersion)
        try c.encodeIfPresent(handshakeOK, forKey: .handshakeOK)
        try c.encodeIfPresent(handshakeReason, forKey: .handshakeReason)
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(modelNames, forKey: .modelNames)
        try c.encodeIfPresent(effortInfo, forKey: .effortInfo)
    }
}

// MARK: - UI

struct ToolchainSheet: View {
    @Bindable var watch: ToolchainWatch
    @Binding var isPresented: Bool
    @State private var selectedProvider: Provider = .grok

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ToolchainWatch.uiTitle).font(.headline)
                Spacer()
                Button(ToolchainWatch.checkNowTitle) {
                    Task { await watch.checkNow() }
                }
                .disabled(watch.isSweeping)
                Button("Close") { isPresented = false }
            }
            Text("Swept on launch and every 24 hours while this app is open — not a background daemon. "
                 + "Unknown and unverified states are named as such.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if watch.isSweeping {
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Provider.allCases) { provider in
                let row = watch.row(for: provider)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.subheadline.weight(.semibold))
                    Text(row.summaryLine)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text(row.updateLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(row.changeHistoryLine)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Change history").font(.caption).foregroundStyle(.secondary)
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(Provider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(watch.row(for: selectedProvider).changeHistoryLine)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(width: 680, height: 520)
        .task { watch.reloadFromStore() }
    }
}

struct ToolchainStatusView: View {
    @Bindable var watch: ToolchainWatch

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(ToolchainWatch.uiTitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(ToolchainWatch.checkNowTitle) {
                    Task { await watch.checkNow() }
                }
                .controlSize(.small)
                .disabled(watch.isSweeping)
            }
            if watch.isSweeping {
                Text("Checking…").font(.caption2).foregroundStyle(.secondary)
            }
            Toggle("Update the CLIs automatically at launch and daily (Grok, Claude Code, standalone Codex)", isOn: Binding(get: { watch.autoUpdate }, set: { watch.autoUpdate = $0 }))
                .toggleStyle(.checkbox).font(.caption2)
            ForEach(Provider.allCases) { provider in
                let row = watch.row(for: provider)
                if let status = watch.updates[provider], status.available, status.updatable {
                    Button(watch.isUpdating.contains(provider) ? "Updating \(provider.displayName)…" : "Update \(provider.displayName) to \(status.latest ?? "latest")") {
                        Task { await watch.runUpdate(provider) }
                    }.controlSize(.small).disabled(watch.isUpdating.contains(provider))
                }
                if let log = watch.updateLogs[provider], !log.isEmpty {
                    Text(log.split(separator: "\n").suffix(2).joined(separator: " ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("\(provider.displayName) · \(row.summaryLine)")
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                Text(row.updateLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Text(row.changeHistoryLine)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }
}

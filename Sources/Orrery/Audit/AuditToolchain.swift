import Foundation

/// Toolchain watchdog: version parse against real CLIs, change-detection handshake
/// via an injectable seam, npm unreachable state machine (offline-safe), JSONL
/// round-trip, and cliVersions stamped on team-stats records. Temp directories,
/// no quota, no network dependency.
@MainActor
enum AuditToolchain {

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

    private static func waitForRecords(_ url: URL, count: Int, timeout: Double = 2)
        async -> [TeamStats.RunOutcome] {
        _ = await waitUntil(timeout) { TeamStats.load(from: url).records.count == count }
        return TeamStats.load(from: url).records
    }

    private static func stubHandshake(provider: Provider, ok: Bool,
                                      reason: String? = nil) -> SelfTest.HandshakeResult {
        SelfTest.HandshakeResult(
            provider: provider,
            locatedPath: "/usr/bin/true",
            sessionID: ok ? "sess-\(provider.rawValue)" : nil,
            failure: ok ? nil : (reason ?? "scripted fail"),
            modelNames: ok ? ["stub-model"] : [],
            effortInfo: ok ? "high" : nil)
    }

    private static func sweepRecord(provider: Provider, version: String?,
                                    state: String, at: Date,
                                    raw: String? = nil) -> ToolchainWatch.Record {
        ToolchainWatch.Record(
            kind: ToolchainWatch.kindSweep,
            provider: provider.rawValue,
            version: version,
            versionState: state,
            rawOutput: raw,
            checkedAt: at,
            locatedPath: version == nil ? nil : "/usr/bin/true")
    }

    static func run(_ audit: Auditor) async {
        ToolchainWatch.restoreProductionSeams()
        rails(audit)
        parseFixtures(audit)
        await realBinaries(audit)

        let previousStore = ToolchainWatch.storeURL
        await Auditor.withTemporaryDirectory { dir in
            ToolchainWatch.storeURL = dir.appendingPathComponent("toolchain.jsonl")
            ToolchainWatch.npmFetch = { nil }
            ToolchainWatch.handshakeOverride = { provider, _ in
                stubHandshake(provider: provider, ok: false, reason: "unexpected handshake")
            }
            defer {
                ToolchainWatch.storeURL = previousStore
                ToolchainWatch.restoreProductionSeams()
            }
            seedBaseline(audit)
            await changeDetection(audit, dir: dir)
            await handshakePersistence(audit, dir: dir)
            await standaloneCodexVersionState(audit, dir: dir)
            npmStates(audit)
            await npmOffline(audit)
            jsonlRoundTrip(audit)
            await handshakeDisconnect(audit, dir: dir)
            await launchWatchdog(audit, dir: dir)
            await uiRowsAndCheckNow(audit, dir: dir)
            changeHistoryRow(audit)
            await cliVersionsStamp(audit, dir: dir)
        }
        ToolchainWatch.restoreProductionSeams()
        ToolchainWatch.storeURL = previousStore
    }

    // MARK: - Rails

    private static func rails(_ audit: Auditor) {
        audit.section("Toolchain — store URL, period, honest channels")
        let path = ToolchainWatch.defaultStoreURL.path
        audit.check("the default store URL is Application Support/Orrery/toolchain.jsonl",
                    path.hasSuffix("Library/Application Support/Orrery/toolchain.jsonl"),
                    path)
        audit.equal("the watchdog period is 24 hours", ToolchainWatch.period, 24 * 60 * 60)
        audit.equal("the periodic wait is 24 hours in nanoseconds",
                    ToolchainWatch.periodicSleepNanoseconds,
                    UInt64(24 * 60 * 60) * 1_000_000_000)
        audit.equal("grok's update line before any check says so",
                    ToolchainWatch.grokUpdateLine, "update not checked yet")
        let codexLine = ToolchainWatch.codexUpdateLine(
            version: "0.151.0-alpha.7.2",
            modified: Date(timeIntervalSince1970: 1_700_000_000))
        audit.check("codex update line never displays a latest figure",
                    !codexLine.lowercased().contains("latest"), codexLine)
        audit.check("codex update line names the bundled version",
                    codexLine.contains("bundled 0.151.0-alpha.7.2"), codexLine)
        audit.check("codex update line names that there is no public channel",
                    codexLine.contains("no public channel"), codexLine)
        audit.check("audit does not read the user's toolchain store",
                    ToolchainWatch.latestParsedVersions() == nil)
        audit.check("claude unreachable copy includes the word unreachable",
                    ToolchainWatch.claudeUpdateLine(.unreachable).contains("unreachable"))
        audit.check("claude copy notes that the CLI self-updates",
                    ToolchainWatch.claudeUpdateLine(.unreachable)
                        .localizedCaseInsensitiveContains("self-update"))
    }

    // MARK: - Parse

    private static func parseFixtures(_ audit: Auditor) {
        audit.section("Toolchain — version parsing")
        audit.equal("grok 1.0.13 with hash suffix parses",
                    ToolchainWatch.parseVersion("grok 1.0.13 (5e9a58528b76) [stable]"),
                    Optional("1.0.13"))
        audit.equal("bare 1.0.13 parses",
                    ToolchainWatch.parseVersion("1.0.13"), Optional("1.0.13"))
        audit.equal("claude 2.1.233 with suffix parses",
                    ToolchainWatch.parseVersion("2.1.233 (Claude Code)"),
                    Optional("2.1.233"))
        audit.equal("codex-cli pre-release parses",
                    ToolchainWatch.parseVersion("codex-cli 0.151.0-alpha.7.2"),
                    Optional("0.151.0-alpha.7.2"))
        audit.equal("a v-prefix is tolerated",
                    ToolchainWatch.parseVersion("v1.0.13"), Optional("1.0.13"))
        audit.check("empty output does not invent a version",
                    ToolchainWatch.parseVersion("") == nil)
        audit.check("non-version output is unparsed, not fabricated",
                    ToolchainWatch.parseVersion("not a version string at all") == nil)
        audit.equal("unparsed state displays as unparsed",
                    ToolchainWatch.versionDisplay(state: ToolchainWatch.stateUnparsed,
                                                  version: nil),
                    "unparsed")
        audit.equal("not-installed state displays as not installed",
                    ToolchainWatch.versionDisplay(state: ToolchainWatch.stateNotInstalled,
                                                  version: nil),
                    "not installed")
        audit.equal("standalone CLI versionState is distinct from parsed",
                    ToolchainWatch.stateStandaloneCLI, "standaloneCLI")
        audit.check("standalone CLI versionState is not the bundled parsed state",
                    ToolchainWatch.stateStandaloneCLI != ToolchainWatch.stateParsed)
        audit.equal("standalone CLI version display names standalone CLI",
                    ToolchainWatch.versionDisplay(state: ToolchainWatch.stateStandaloneCLI,
                                                  version: "0.151.0-alpha.7.2"),
                    "0.151.0-alpha.7.2 (standalone CLI)")
        audit.check("standalone CLI version display does not say bundled",
                    !ToolchainWatch.versionDisplay(state: ToolchainWatch.stateStandaloneCLI,
                                                   version: "0.151.0-alpha.7.2")
                        .localizedCaseInsensitiveContains("bundled"))
        audit.equal("handshake absence displays as not run",
                    ToolchainWatch.handshakeDisplay(ok: nil, reason: nil),
                    "handshake not run")
        audit.equal("handshake ok displays as handshake ok",
                    ToolchainWatch.handshakeDisplay(ok: true, reason: nil),
                    "handshake ok")
        audit.equal("handshake failure names the reason",
                    ToolchainWatch.handshakeDisplay(ok: false, reason: "scripted fail"),
                    "handshake failed: scripted fail")
        let parsedSweep = sweepRecord(provider: .grok, version: "1.0.13",
                                      state: ToolchainWatch.stateParsed,
                                      at: Date(timeIntervalSince1970: 1_700_000_000))
        let okChange = ToolchainWatch.Record(
            kind: ToolchainWatch.kindChange,
            provider: "grok",
            version: "1.0.13",
            versionState: ToolchainWatch.stateParsed,
            rawOutput: nil,
            checkedAt: Date(timeIntervalSince1970: 1_700_000_000),
            locatedPath: "/usr/bin/true",
            previousVersion: "0.0.1",
            handshakeOK: true)
        let failedChange = ToolchainWatch.Record(
            kind: ToolchainWatch.kindChange,
            provider: "grok",
            version: "1.0.13",
            versionState: ToolchainWatch.stateParsed,
            rawOutput: nil,
            checkedAt: Date(timeIntervalSince1970: 1_700_000_000),
            locatedPath: "/usr/bin/true",
            previousVersion: "0.0.1",
            handshakeOK: false,
            handshakeReason: "scripted fail")
        audit.equal("a parsed sweep still displays the last handshake",
                    ToolchainWatch.handshakeDisplay(sweep: parsedSweep, change: okChange),
                    "handshake ok")
        audit.equal("an unparsed sweep does not keep handshake ok",
                    ToolchainWatch.handshakeDisplay(
                        sweep: sweepRecord(provider: .grok, version: nil,
                                           state: ToolchainWatch.stateUnparsed,
                                           at: Date(timeIntervalSince1970: 1_700_000_000),
                                           raw: "not a version"),
                        change: okChange),
                    "handshake not run")
        audit.equal("a not-installed sweep does not keep an obsolete handshake failure",
                    ToolchainWatch.handshakeDisplay(
                        sweep: sweepRecord(provider: .grok, version: nil,
                                           state: ToolchainWatch.stateNotInstalled,
                                           at: Date(timeIntervalSince1970: 1_700_000_000)),
                        change: failedChange),
                    "handshake not run")
        let standaloneSweep = sweepRecord(provider: .codex, version: "0.151.0-alpha.7.2",
                                          state: ToolchainWatch.stateStandaloneCLI,
                                          at: Date(timeIntervalSince1970: 1_700_000_000))
        audit.equal("a standalone CLI sweep still displays the last handshake",
                    ToolchainWatch.handshakeDisplay(sweep: standaloneSweep, change: okChange),
                    "handshake ok")
        let standaloneUpdate = ToolchainWatch.codexUpdateLine(
            version: "0.151.0-alpha.7.2",
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            versionState: ToolchainWatch.stateStandaloneCLI)
        audit.check("standalone Codex update line does not pose as bundled",
                    standaloneUpdate.contains("standalone CLI")
                    && !standaloneUpdate.localizedCaseInsensitiveContains("bundled"),
                    standaloneUpdate)
    }

    // MARK: - Real binaries

    private static func realBinaries(_ audit: Auditor) async {
        audit.section("Toolchain — real installed CLIs")
        ToolchainWatch.locateOverride = nil
        ToolchainWatch.versionOutputOverride = nil
        for provider in Provider.allCases {
            let path: String?
            switch provider {
            case .grok: path = GrokBackend.locate()
            case .claude: path = ClaudeBackend.locate()
            case .codex: path = CodexBackend.locate()
            }
            guard let path else { continue }
            let output = await ToolchainWatch.readVersion(provider: provider, path: path)
            let text = output ?? ""
            audit.check("\(provider.rawValue) --version produced output",
                        !text.isEmpty, "path=\(path)")
            let parsed = ToolchainWatch.parseVersion(text)
            audit.check("\(provider.rawValue) --version parsed",
                        parsed != nil, "output=\(String(reflecting: text))")
        }
    }

    // MARK: - Seed

    private static func seedBaseline(_ audit: Auditor) {
        audit.section("Toolchain — seeded baseline")
        let store = ToolchainWatch.storeURL
        try? FileManager.default.removeItem(at: store)
        ToolchainWatch.seedBaselineIfEmpty()
        let loaded = ToolchainWatch.load(from: store)
        audit.equal("an empty store seeds three baseline sweep records",
                    loaded.records.count, 3)
        audit.equal("seeded grok version",
                    ToolchainWatch.lastParsedVersion(.grok), Optional("1.0.13"))
        audit.equal("seeded claude version",
                    ToolchainWatch.lastParsedVersion(.claude), Optional("2.1.233"))
        audit.equal("seeded codex version",
                    ToolchainWatch.lastParsedVersion(.codex), Optional("0.151.0-alpha.7.2"))
        let before = loaded.records.count
        ToolchainWatch.seedBaselineIfEmpty()
        audit.equal("seeding is a no-op when the store already has records",
                    ToolchainWatch.load(from: store).records.count, before)
        try? FileManager.default.removeItem(at: store)
    }

    // MARK: - Change detection

    private static func changeDetection(_ audit: Auditor, dir: URL) async {
        audit.section("Toolchain — change detection handshake seam")
        let store = ToolchainWatch.storeURL
        try? FileManager.default.removeItem(at: store)
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        ToolchainWatch.now = { at }
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "0.0.1",
                                          state: ToolchainWatch.stateParsed, at: at))
        var entered: [Provider] = []
        ToolchainWatch.locateOverride = { $0 == .grok ? "/usr/bin/true" : nil }
        ToolchainWatch.versionOutputOverride = { provider in
            provider == .grok ? "grok 1.0.13 (deadbeef) [stable]" : nil
        }
        ToolchainWatch.handshakeOverride = { provider, _ in
            entered.append(provider)
            return stubHandshake(provider: provider, ok: true)
        }
        await ToolchainWatch.shared.sweepNow(forceNetwork: false, project: dir)
        audit.check("a version change enters the handshake path",
                    entered == [.grok], "entered=\(entered.map(\.rawValue))")
        let change = ToolchainWatch.lastChange(.grok)
        audit.check("a version change appends a change event", change != nil)
        audit.equal("the change event records the new parsed version",
                    change?.version, Optional("1.0.13"))
        audit.equal("the change event records the previous version",
                    change?.previousVersion, Optional("0.0.1"))
        audit.equal("the change event records handshake ok", change?.handshakeOK, Optional(true))
        audit.equal("the change event records the scripted session id",
                    change?.sessionID, Optional("sess-grok"))

        try? FileManager.default.removeItem(at: store)
        entered = []
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "1.0.13",
                                          state: ToolchainWatch.stateParsed, at: at))
        await ToolchainWatch.shared.sweepNow(forceNetwork: false, project: dir)
        audit.check("an unchanged version does not enter the handshake path",
                    entered.isEmpty, "entered=\(entered.map(\.rawValue))")
        audit.check("an unchanged version does not append a change event",
                    ToolchainWatch.lastChange(.grok) == nil)

        try? FileManager.default.removeItem(at: store)
        entered = []
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "0.0.1",
                                          state: ToolchainWatch.stateParsed, at: at))
        ToolchainWatch.handshakeOverride = { provider, _ in
            entered.append(provider)
            return stubHandshake(provider: provider, ok: false, reason: "scripted fail")
        }
        await ToolchainWatch.shared.sweepNow(forceNetwork: false, project: dir)
        let failed = ToolchainWatch.lastChange(.grok)
        audit.check("a failed handshake still enters the handshake path",
                    entered == [.grok], "entered=\(entered.map(\.rawValue))")
        audit.equal("a failed handshake is recorded as not ok",
                    failed?.handshakeOK, Optional(false))
        audit.equal("a failed handshake records the reason",
                    failed?.handshakeReason, Optional("scripted fail"))

        try? FileManager.default.removeItem(at: store)
        entered = []
        ToolchainWatch.locateOverride = { $0 == .grok ? "/usr/bin/true" : nil }
        ToolchainWatch.versionOutputOverride = { provider in
            provider == .grok ? "not a version string at all" : nil
        }
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "1.0.13",
                                          state: ToolchainWatch.stateParsed, at: at))
        ToolchainWatch.handshakeOverride = { provider, _ in
            entered.append(provider)
            return stubHandshake(provider: provider, ok: true)
        }
        await ToolchainWatch.shared.sweepNow(forceNetwork: false, project: dir)
        audit.check("unparsed output does not enter the handshake path",
                    entered.isEmpty, "entered=\(entered.map(\.rawValue))")
        audit.check("unparsed output does not append a change event",
                    ToolchainWatch.lastChange(.grok) == nil)
        audit.equal("unparsed output is recorded as unparsed, not a version change",
                    ToolchainWatch.lastSweep(.grok)?.versionState,
                    Optional(ToolchainWatch.stateUnparsed))
        audit.equal("lastParsedVersion walks back past an unparsed sweep",
                    ToolchainWatch.lastParsedVersion(.grok), Optional("1.0.13"))

        entered = []
        ToolchainWatch.versionOutputOverride = { provider in
            provider == .grok ? "grok 1.0.13 (deadbeef) [stable]" : nil
        }
        ToolchainWatch.handshakeOverride = { provider, _ in
            entered.append(provider)
            return stubHandshake(provider: provider, ok: true)
        }
        await ToolchainWatch.shared.sweepNow(forceNetwork: false, project: dir)
        audit.check("recovery to the same parsed version after unparsed does not handshake",
                    entered.isEmpty, "entered=\(entered.map(\.rawValue))")
        audit.check("recovery to the same parsed version does not append a change event",
                    ToolchainWatch.lastChange(.grok) == nil)

        try? FileManager.default.removeItem(at: store)
        entered = []
        ToolchainWatch.locateOverride = { _ in nil }
        ToolchainWatch.versionOutputOverride = { _ in nil }
        ToolchainWatch.handshakeOverride = { provider, _ in
            entered.append(provider)
            return stubHandshake(provider: provider, ok: true)
        }
        await ToolchainWatch.shared.sweepNow(forceNetwork: false, project: dir)
        audit.check("a missing binary is skipped honestly and does not handshake",
                    entered.isEmpty
                    && ToolchainWatch.lastSweep(.grok)?.versionState
                        == ToolchainWatch.stateNotInstalled,
                    "entered=\(entered.map(\.rawValue)) state=\(ToolchainWatch.lastSweep(.grok)?.versionState ?? "nil")")

        ToolchainWatch.locateOverride = nil
        ToolchainWatch.versionOutputOverride = nil
        ToolchainWatch.handshakeOverride = { provider, _ in
            stubHandshake(provider: provider, ok: false, reason: "unexpected handshake")
        }
        try? FileManager.default.removeItem(at: store)
    }

    // MARK: - npm

    private static func npmStates(_ audit: Auditor) {
        audit.section("Toolchain — npm outcome states")
        audit.equal("a nil fetch is unreachable",
                    ToolchainWatch.claudeChannel(from: nil),
                    ToolchainWatch.ClaudeChannel.unreachable)
        audit.equal("a non-200 is unreachable",
                    ToolchainWatch.claudeChannel(from: (500, "{\"version\":\"9.9.9\"}")),
                    ToolchainWatch.ClaudeChannel.unreachable)
        audit.equal("unparseable 200 body is unreachable",
                    ToolchainWatch.claudeChannel(from: (200, "not-json")),
                    ToolchainWatch.ClaudeChannel.unreachable)
        audit.equal("empty version is unreachable",
                    ToolchainWatch.claudeChannel(from: (200, "{\"version\":\"\"}")),
                    ToolchainWatch.ClaudeChannel.unreachable)
        audit.equal("a nonempty unparseable npm version is unreachable",
                    ToolchainWatch.claudeChannel(from: (200, "{\"version\":\"unknown\"}")),
                    ToolchainWatch.ClaudeChannel.unreachable)
        audit.equal("200 with a version is latest",
                    ToolchainWatch.claudeChannel(from: (200, "{\"version\":\"2.1.300\"}")),
                    ToolchainWatch.ClaudeChannel.latest("2.1.300"))
        let unreachable = ToolchainWatch.claudeUpdateLine(.unreachable)
        audit.check("unreachable is a displayed state, not a guessed version",
                    unreachable.contains("unreachable") && !unreachable.contains("2.1."),
                    unreachable)
    }

    private static func npmOffline(_ audit: Auditor) async {
        audit.section("Toolchain — npm offline does not fail the audit")
        ToolchainWatch.npmFetch = { nil }
        let channel = await ToolchainWatch.shared.resolveClaudeChannel(force: true)
        audit.equal("a forced fetch that cannot reach the registry is unreachable",
                    channel, ToolchainWatch.ClaudeChannel.unreachable)
    }

    // MARK: - JSONL

    private static func jsonlRoundTrip(_ audit: Auditor) {
        audit.section("Toolchain — JSONL round-trip")
        let store = ToolchainWatch.storeURL
        try? FileManager.default.removeItem(at: store)
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let parsed = sweepRecord(provider: .grok, version: "1.0.13",
                                 state: ToolchainWatch.stateParsed, at: at,
                                 raw: "grok 1.0.13")
        let unparsed = ToolchainWatch.Record(
            kind: ToolchainWatch.kindSweep,
            provider: "claude",
            version: nil,
            versionState: ToolchainWatch.stateUnparsed,
            rawOutput: "not a version string at all",
            checkedAt: at,
            locatedPath: "/opt/homebrew/bin/claude")
        let change = ToolchainWatch.Record(
            kind: ToolchainWatch.kindChange,
            provider: "grok",
            version: "1.0.13",
            versionState: ToolchainWatch.stateParsed,
            rawOutput: nil,
            checkedAt: at,
            locatedPath: "/usr/bin/true",
            previousVersion: "0.0.1",
            handshakeOK: true,
            handshakeReason: nil,
            sessionID: "sess-grok",
            modelNames: ["stub-model"],
            effortInfo: "high")
        ToolchainWatch.append(parsed)
        ToolchainWatch.append(unparsed)
        ToolchainWatch.append(change)
        let loaded = ToolchainWatch.load(from: store)
        audit.equal("three toolchain records load back", loaded.records.count, 3)
        audit.equal("a well-formed toolchain store reports zero corrupt lines",
                    loaded.corruptLines, 0)
        if loaded.records.count == 3 {
            audit.equal("parsed sweep round-trips identically", loaded.records[0], parsed)
            audit.equal("unparsed sweep round-trips identically", loaded.records[1], unparsed)
            audit.equal("change event round-trips identically", loaded.records[2], change)
        } else {
            audit.check("parsed sweep round-trips identically", false,
                        "count=\(loaded.records.count)")
            audit.check("unparsed sweep round-trips identically", false)
            audit.check("change event round-trips identically", false)
        }
        audit.check("an unparsed record keeps version nil, not an empty string",
                    loaded.records.dropFirst().first?.version == nil
                    && loaded.records.dropFirst().first?.versionState
                        == ToolchainWatch.stateUnparsed)
        audit.check("an unparsed record keeps the raw output",
                    loaded.records.dropFirst().first?.rawOutput
                        == "not a version string at all")
        audit.check("a change event without handshakeReason keeps it absent",
                    loaded.records.last?.handshakeReason == nil)

        let extra = dirFile(store.deletingLastPathComponent(), "extra.jsonl")
        let extraLine = """
        {"checkedAt":1700000000,"futureField":"keep","kind":"sweep","provider":"codex","rawOutput":"codex-cli 0.151.0-alpha.7.2","version":"0.151.0-alpha.7.2","versionState":"parsed"}
        """
        try? (extraLine + "\n").write(to: extra, atomically: true, encoding: .utf8)
        let extraLoad = ToolchainWatch.load(from: extra)
        audit.equal("a line with an unknown future field still decodes",
                    extraLoad.records.count, 1)
        audit.equal("the unknown field does not invent a corrupt line",
                    extraLoad.corruptLines, 0)
        audit.equal("the known fields of a future-keyed line are preserved",
                    extraLoad.records.first?.version, Optional("0.151.0-alpha.7.2"))
        audit.check("an absent handshakeOK stays nil, not false",
                    extraLoad.records.first?.handshakeOK == nil)
        audit.check("a future field is captured on load, not dropped",
                    extraLoad.records.first?.extraJSON.contains("futureField") == true
                    && extraLoad.records.first?.extraJSON.contains("keep") == true,
                    extraLoad.records.first?.extraJSON ?? "nil")
        let round = dirFile(store.deletingLastPathComponent(), "extra-round.jsonl")
        if let rec = extraLoad.records.first {
            ToolchainWatch.append(rec, to: round)
        }
        let roundText = (try? String(contentsOf: round, encoding: .utf8)) ?? ""
        audit.check("a future field survives load-then-append",
                    roundText.contains("\"futureField\"") && roundText.contains("keep"),
                    roundText)
        audit.equal("known fields still round-trip after preserving extra",
                    ToolchainWatch.load(from: round).records.first?.version,
                    Optional("0.151.0-alpha.7.2"))

        let missingNL = dirFile(store.deletingLastPathComponent(), "missing-nl.jsonl")
        guard var firstLine = parsed.jsonLine() else {
            audit.check("jsonLine encodes a parsed sweep", false)
            try? FileManager.default.removeItem(at: store)
            return
        }
        if firstLine.last == 0x0A { firstLine.removeLast() }
        try? firstLine.write(to: missingNL)
        let beforeGlue = ToolchainWatch.load(from: missingNL)
        audit.equal("a JSONL file without a trailing newline still loads its last record",
                    beforeGlue.records.count, 1)
        ToolchainWatch.append(unparsed, to: missingNL)
        let afterGlue = ToolchainWatch.load(from: missingNL)
        audit.equal("appending after a missing trailing newline keeps both records",
                    afterGlue.records.count, 2)
        audit.equal("appending after a missing trailing newline does not corrupt a line",
                    afterGlue.corruptLines, 0)
        if afterGlue.records.count == 2 {
            audit.equal("the record before the missing newline is intact",
                        afterGlue.records[0], parsed)
            audit.equal("the record appended after the missing newline is intact",
                        afterGlue.records[1], unparsed)
        } else {
            audit.check("the record before the missing newline is intact", false,
                        "count=\(afterGlue.records.count) corrupt=\(afterGlue.corruptLines)")
            audit.check("the record appended after the missing newline is intact", false)
        }

        try? FileManager.default.removeItem(at: store)
    }

    private static func dirFile(_ dir: URL, _ name: String) -> URL {
        dir.appendingPathComponent(name)
    }

    // MARK: - Handshake disconnect

    @MainActor
    private final class HandshakeProbeBackend: AgentBackend {
        let provider: Provider
        var models: [ModelOption] = []
        var currentModel = ""
        var currentEffort = ""
        var persistsSelection = true
        var onEvent: ((BackendEvent) -> Void)?
        var isRunning = false
        var eventsOnStart: [BackendEvent]
        var stayRunning: Bool
        var hangSeconds: TimeInterval
        var startReturned = false
        /// When true, `start()` parks on a checked continuation until `stop()`
        /// resumes it — the Codex initialize-RPC shape.
        var hangOnContinuation: Bool
        private var pendingResume: (() -> Void)?

        init(provider: Provider = .grok, eventsOnStart: [BackendEvent], stayRunning: Bool,
             hangSeconds: TimeInterval = 0, hangOnContinuation: Bool = false) {
            self.provider = provider
            self.eventsOnStart = eventsOnStart
            self.stayRunning = stayRunning
            self.hangSeconds = hangSeconds
            self.hangOnContinuation = hangOnContinuation
        }

        static func locate() -> String? { "/usr/bin/true" }
        func start(project: URL, autoApprove: Bool) async {
            defer { startReturned = true }
            isRunning = stayRunning || hangSeconds > 0 || hangOnContinuation
            for event in eventsOnStart { emit(event) }
            if hangOnContinuation {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    pendingResume = { continuation.resume() }
                }
                return
            }
            guard hangSeconds > 0 else { return }
            let hangUntil = Date().addingTimeInterval(hangSeconds)
            while Date() < hangUntil, isRunning {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        func stop() {
            isRunning = false
            let resume = pendingResume
            pendingResume = nil
            resume?()
        }
        func send(_ text: String) async {}
        func cancel() {}
        func setModel(_ id: String) async {}
    }

    private static func handshakeDisconnect(_ audit: Auditor, dir: URL) async {
        audit.section("Toolchain — handshake treats disconnect as failure")
        audit.check("a still-running backend with no session is ok",
                    SelfTest.failureAfterWait(connected: nil, failure: nil,
                                              disconnected: nil, isRunning: true) == nil)
        audit.check("a connected session that is still running is ok",
                    SelfTest.failureAfterWait(connected: "s", failure: nil,
                                              disconnected: nil, isRunning: true) == nil)
        audit.check("a connect then immediate disconnect is a failure",
                    SelfTest.failureAfterWait(connected: "s", failure: nil,
                                              disconnected: "died after connect",
                                              isRunning: false) == "died after connect")
        audit.check("a connect then process exit is a failure",
                    SelfTest.failureAfterWait(connected: "s", failure: nil,
                                              disconnected: nil, isRunning: false)
                        == "exited after connecting")
        audit.check("a disconnect before a session is a failure",
                    SelfTest.failureAfterWait(connected: nil, failure: nil,
                                              disconnected: "exited immediately",
                                              isRunning: false) == "exited immediately")
        audit.check("an exit before a session with no disconnect event is a failure",
                    SelfTest.failureAfterWait(connected: nil, failure: nil,
                                              disconnected: nil, isRunning: false)
                        == "exited before a session was reported")

        let previous = SelfTest.backendFactory
        defer { SelfTest.backendFactory = previous }
        SelfTest.backendFactory = { _ in
            let backend = HandshakeProbeBackend(
                eventsOnStart: [.disconnected(reason: "exited immediately")],
                stayRunning: false)
            return ("/usr/bin/true", backend)
        }
        let dropped = await SelfTest.handshake(provider: .grok, project: dir,
                                               waitSeconds: 0.4)
        audit.check("an immediate disconnect is not handshake ok", !dropped.ok)
        audit.equal("an immediate disconnect records the disconnect reason",
                    dropped.failure, Optional("exited immediately"))

        SelfTest.backendFactory = { _ in
            let backend = HandshakeProbeBackend(eventsOnStart: [], stayRunning: true)
            return ("/usr/bin/true", backend)
        }
        let silent = await SelfTest.handshake(provider: .claude, project: dir,
                                              waitSeconds: 0.2)
        audit.check("a still-running backend with no session id is handshake ok",
                    silent.ok, silent.failure ?? "ok")

        SelfTest.backendFactory = { _ in
            let backend = HandshakeProbeBackend(
                eventsOnStart: [.connected(sessionID: "s1"),
                                .disconnected(reason: "died after connect")],
                stayRunning: false)
            return ("/usr/bin/true", backend)
        }
        let died = await SelfTest.handshake(provider: .grok, project: dir,
                                            waitSeconds: 0.4)
        audit.check("a connect then immediate death is not handshake ok", !died.ok)
        audit.equal("a connect then immediate death records the disconnect reason",
                    died.failure, Optional("died after connect"))

        var stalledBackend: HandshakeProbeBackend?
        SelfTest.backendFactory = { _ in
            let backend = HandshakeProbeBackend(eventsOnStart: [], stayRunning: true,
                                                hangSeconds: 30)
            stalledBackend = backend
            return ("/usr/bin/true", backend)
        }
        let t0 = Date()
        let stalled = await SelfTest.handshake(provider: .grok, project: dir,
                                               waitSeconds: 0.35)
        let elapsed = Date().timeIntervalSince(t0)
        audit.check("a stalled start returns within waitSeconds, not the hang",
                    elapsed < 2, String(format: "elapsed=%.2fs", elapsed))
        audit.check("a stalled start is not handshake ok", !stalled.ok)
        audit.equal("a stalled start records handshake timed out",
                    stalled.failure, Optional("handshake timed out"))
        audit.check("a stalled start's start() has returned before handshake returns",
                    stalledBackend?.startReturned == true)

        var continuationBackend: HandshakeProbeBackend?
        SelfTest.backendFactory = { _ in
            let backend = HandshakeProbeBackend(eventsOnStart: [], stayRunning: true,
                                                hangOnContinuation: true)
            continuationBackend = backend
            return ("/usr/bin/true", backend)
        }
        let c0 = Date()
        let parked = await SelfTest.handshake(provider: .codex, project: dir,
                                              waitSeconds: 0.35)
        let parkedElapsed = Date().timeIntervalSince(c0)
        audit.check("a start parked on a checked continuation returns within waitSeconds",
                    parkedElapsed < 2, String(format: "elapsed=%.2fs", parkedElapsed))
        audit.check("a start parked on a checked continuation is not handshake ok", !parked.ok)
        audit.equal("a start parked on a checked continuation records handshake timed out",
                    parked.failure, Optional("handshake timed out"))
        audit.check("stop() resumes the checked continuation so start() returns before handshake does",
                    continuationBackend?.startReturned == true)

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let codexSrc = (try? String(contentsOf: root.appendingPathComponent(
            "Sources/Orrery/Backends/CodexBackend.swift"), encoding: .utf8)) ?? ""
        audit.check("CodexBackend.stop resumes pending RPC continuations",
                    {
                        guard let start = codexSrc.range(of: "func stop() {") else { return false }
                        let fromStop = codexSrc[start.lowerBound...]
                        guard let end = fromStop.range(of: "\n    func ") else { return false }
                        let body = String(fromStop[..<end.lowerBound])
                        return body.contains("handler(")
                    }())
        SelfTest.backendFactory = nil
    }

    // MARK: - Launch-owned periodic sweep

    private static func launchWatchdog(_ audit: Auditor, dir: URL) async {
        audit.section("Toolchain — launch-owned 24h sweep")
        WindowLaunch.resetForTests()
        defer { WindowLaunch.resetForTests() }
        audit.check("a normal launch should start the watchdog",
                    {
                        WindowLaunch.arguments = { ["Orrery"] }
                        return WindowLaunch.shouldStartWatchdog()
                    }())
        audit.check("an --audit launch must not start the watchdog",
                    {
                        WindowLaunch.arguments = { ["Orrery", "--audit"] }
                        return !WindowLaunch.shouldStartWatchdog()
                    }())

        var starts = 0
        WindowLaunch.onStartWatchdog = { starts += 1 }
        WindowLaunch.arguments = { ["Orrery"] }
        WindowLaunch.consumedArguments = true
        let model = AppModel(trust: .forAudit)
        await WindowLaunch.prepare(model: model, initialProject: nil,
                                   restoreLastProject: false)
        audit.equal("prepare starts the watchdog when not under --audit", starts, 1)

        starts = 0
        WindowLaunch.arguments = { ["Orrery", "--audit"] }
        await WindowLaunch.prepare(model: model, initialProject: nil,
                                   restoreLastProject: false)
        audit.equal("prepare does not start the watchdog under --audit", starts, 0)

        WindowLaunch.arguments = { ["Orrery"] }
        ToolchainWatch.locateOverride = { _ in nil }
        ToolchainWatch.handshakeOverride = { provider, _ in
            stubHandshake(provider: provider, ok: false, reason: "unexpected handshake")
        }
        ToolchainWatch.shared.stopPeriodicSweep()
        ToolchainWatch.shared.startPeriodicSweep()
        audit.check("startPeriodicSweep owns a Task",
                    ToolchainWatch.shared.isPeriodicSweepRunning)
        ToolchainWatch.shared.stopPeriodicSweep()
        audit.check("the periodic Task can be cancelled",
                    !ToolchainWatch.shared.isPeriodicSweepRunning)
        WindowLaunch.arguments = { CommandLine.arguments }
    }

    // MARK: - UI rows and Check now

    private static func uiRowsAndCheckNow(_ audit: Auditor, dir: URL) async {
        audit.section("Toolchain — UI rows, honest copy, Check now")
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func source(_ relative: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(relative),
                         encoding: .utf8)) ?? ""
        }
        let content = source("Sources/Orrery/Views/ContentView.swift")
        let orch = source("Sources/Orrery/Views/OrchestratorView.swift")
        let watchSource = source("Sources/Orrery/Toolchain/ToolchainWatch.swift")
        audit.check("the More menu offers the Toolchain sheet",
                    content.contains("ToolchainWatch.moreMenuTitle")
                    && content.contains("ToolchainSheet")
                    && content.contains("showToolchain"),
                    "ContentView.swift missing Toolchain sheet wiring")
        audit.check("orchestrator setup embeds ToolchainStatusView",
                    orch.contains("ToolchainStatusView"),
                    "OrchestratorView.swift missing ToolchainStatusView")
        audit.check("Check now buttons call checkNow",
                    watchSource.contains("Button(ToolchainWatch.checkNowTitle)")
                    && watchSource.contains("watch.checkNow()"),
                    "ToolchainWatch.swift missing Check now → checkNow")
        audit.equal("the More menu title is Toolchain…",
                    ToolchainWatch.moreMenuTitle, "Toolchain…")
        audit.equal("the Check now title is Check now",
                    ToolchainWatch.checkNowTitle, "Check now")

        try? FileManager.default.removeItem(at: ToolchainWatch.storeURL)
        ToolchainWatch.shared.claudeChannel = .notChecked
        ToolchainWatch.shared.reloadFromStore()
        let empty = ToolchainWatch.shared.row(for: .grok)
        audit.equal("empty store version is unknown", empty.versionLine, "unknown")
        audit.equal("empty store last checked is never checked",
                    empty.lastCheckedLine, "never checked")
        audit.equal("empty store handshake is not run",
                    empty.handshakeLine, "handshake not run")
        audit.equal("empty store grok update line is not checked yet",
                    empty.updateLine, "update not checked yet")
        audit.equal("empty store claude update line is npm not checked",
                    ToolchainWatch.shared.row(for: .claude).updateLine,
                    ToolchainWatch.claudeUpdateLine(.notChecked))
        audit.check("empty store summary names unknown and never checked",
                    empty.summaryLine.contains("unknown")
                    && empty.summaryLine.contains("never checked")
                    && empty.summaryLine.contains("handshake not run"),
                    empty.summaryLine)

        let at = Date(timeIntervalSince1970: 1_700_000_000)
        ToolchainWatch.append(sweepRecord(provider: .claude, version: nil,
                                          state: ToolchainWatch.stateUnparsed, at: at,
                                          raw: "not a version"))
        ToolchainWatch.append(sweepRecord(provider: .codex, version: nil,
                                          state: ToolchainWatch.stateNotInstalled, at: at))
        ToolchainWatch.shared.reloadFromStore()
        audit.equal("unparsed row version line is unparsed",
                    ToolchainWatch.shared.row(for: .claude).versionLine, "unparsed")
        audit.equal("not-installed row version line is not installed",
                    ToolchainWatch.shared.row(for: .codex).versionLine, "not installed")

        try? FileManager.default.removeItem(at: ToolchainWatch.storeURL)
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "1.0.13",
                                          state: ToolchainWatch.stateParsed, at: at))
        ToolchainWatch.append(ToolchainWatch.Record(
            kind: ToolchainWatch.kindChange,
            provider: "grok",
            version: "1.0.13",
            versionState: ToolchainWatch.stateParsed,
            rawOutput: nil,
            checkedAt: at,
            locatedPath: "/usr/bin/true",
            previousVersion: "0.0.1",
            handshakeOK: true))
        ToolchainWatch.shared.reloadFromStore()
        audit.equal("a parsed sweep row still shows handshake ok",
                    ToolchainWatch.shared.row(for: .grok).handshakeLine, "handshake ok")
        ToolchainWatch.append(sweepRecord(provider: .grok, version: nil,
                                          state: ToolchainWatch.stateUnparsed, at: at,
                                          raw: "not a version"))
        ToolchainWatch.shared.reloadFromStore()
        audit.equal("a later unparsed sweep row does not keep handshake ok",
                    ToolchainWatch.shared.row(for: .grok).handshakeLine, "handshake not run")

        try? FileManager.default.removeItem(at: ToolchainWatch.storeURL)
        ToolchainWatch.append(sweepRecord(provider: .codex, version: "0.151.0",
                                          state: ToolchainWatch.stateParsed, at: at))
        ToolchainWatch.append(ToolchainWatch.Record(
            kind: ToolchainWatch.kindChange,
            provider: "codex",
            version: "0.151.0",
            versionState: ToolchainWatch.stateParsed,
            rawOutput: nil,
            checkedAt: at,
            locatedPath: "/usr/bin/true",
            previousVersion: "0.0.1",
            handshakeOK: false,
            handshakeReason: "scripted fail"))
        ToolchainWatch.shared.reloadFromStore()
        audit.equal("a parsed sweep row still shows a handshake failure",
                    ToolchainWatch.shared.row(for: .codex).handshakeLine,
                    "handshake failed: scripted fail")
        ToolchainWatch.append(sweepRecord(provider: .codex, version: nil,
                                          state: ToolchainWatch.stateNotInstalled, at: at))
        ToolchainWatch.shared.reloadFromStore()
        audit.equal("a later not-installed sweep row does not keep an obsolete handshake failure",
                    ToolchainWatch.shared.row(for: .codex).handshakeLine, "handshake not run")
        audit.check("codex update line never says latest",
                    !ToolchainWatch.shared.row(for: .codex).updateLine
                        .localizedCaseInsensitiveContains("latest"))

        ToolchainWatch.locateOverride = { $0 == .grok ? "/usr/bin/true" : nil }
        ToolchainWatch.versionOutputOverride = { provider in
            provider == .grok ? "1.0.13" : nil
        }
        ToolchainWatch.handshakeOverride = { provider, _ in
            stubHandshake(provider: provider, ok: false, reason: "unexpected handshake")
        }
        try? FileManager.default.removeItem(at: ToolchainWatch.storeURL)
        let before = ToolchainWatch.load().records.count
        await ToolchainWatch.shared.checkNow(project: dir)
        let after = ToolchainWatch.load().records.count
        audit.check("Check now appends a sweep", after > before,
                    "before=\(before) after=\(after)")
        audit.equal("Check now parsed grok 1.0.13",
                    ToolchainWatch.lastParsedVersion(.grok), Optional("1.0.13"))
        ToolchainWatch.shared.reloadFromStore()
        let grok = ToolchainWatch.shared.row(for: .grok)
        audit.equal("Check now row shows the parsed version", grok.versionLine, "1.0.13")
        audit.equal("Check now row handshake is not run when the version matched the seed",
                    grok.handshakeLine, "handshake not run")
        ToolchainWatch.locateOverride = nil
        ToolchainWatch.versionOutputOverride = nil
    }

    // MARK: - Handshake persistence

    private static func handshakePersistence(_ audit: Auditor, dir: URL) async {
        audit.section("Toolchain — a sweep is persisted only after its handshake concludes")
        let store = ToolchainWatch.storeURL
        try? FileManager.default.removeItem(at: store)
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        ToolchainWatch.now = { at }
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "0.0.1",
                                          state: ToolchainWatch.stateParsed, at: at))
        final class Park: @unchecked Sendable {
            var continuation: CheckedContinuation<Void, Never>?
        }
        let park = Park()
        ToolchainWatch.locateOverride = { $0 == .grok ? "/usr/bin/true" : nil }
        ToolchainWatch.versionOutputOverride = { provider in
            provider == .grok ? "grok 1.0.13 (deadbeef) [stable]" : nil
        }
        ToolchainWatch.handshakeOverride = { provider, _ in
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                park.continuation = cont
            }
            return stubHandshake(provider: provider, ok: true)
        }
        let sweep = Task { await ToolchainWatch.shared.sweepNow(forceNetwork: false, project: dir) }
        let parked = await waitUntil(2) { park.continuation != nil }
        audit.check("the handshake started and is still in flight", parked)
        let during = ToolchainWatch.load().records.count
        audit.equal("a sweep is not persisted while its handshake is still running",
                    during, 1)
        sweep.cancel()
        park.continuation?.resume()
        _ = await sweep.value
        audit.equal("an interrupted handshake persists no sweep",
                    ToolchainWatch.load().records.count, 1)
        audit.check("an interrupted handshake persists no change event",
                    ToolchainWatch.lastChange(.grok) == nil)

        ToolchainWatch.handshakeOverride = { provider, _ in
            stubHandshake(provider: provider, ok: true)
        }
        await ToolchainWatch.shared.sweepNow(forceNetwork: false, project: dir)
        audit.check("a completed handshake then persists the sweep",
                    ToolchainWatch.lastSweep(.grok)?.version == "1.0.13")
        audit.check("a completed handshake then persists the change event",
                    ToolchainWatch.lastChange(.grok) != nil)
        let completed = ToolchainWatch.load().records.filter { $0.provider == "grok" }
        audit.check("a version-change sweep and its handshake are consecutive records",
                    completed.suffix(2).map(\.kind)
                        == [ToolchainWatch.kindSweep, ToolchainWatch.kindChange],
                    completed.suffix(2).map(\.kind).joined(separator: ","))

        let watchSrcURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/Orrery/Toolchain/ToolchainWatch.swift")
        let watchSrc = (try? String(contentsOf: watchSrcURL, encoding: .utf8)) ?? ""
        audit.check("a version-change sweep and handshake persist as one append",
                    watchSrc.contains("append([sweepRecord, changeRecord])"))

        try? FileManager.default.removeItem(at: store)
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "0.0.1",
                                          state: ToolchainWatch.stateParsed, at: at))
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "1.0.13",
                                          state: ToolchainWatch.stateParsed, at: at))
        audit.check("a split persist is visible as a missing handshake after a version change",
                    ToolchainWatch.handshakeMissingAfterVersionChange(.grok, version: "1.0.13"))
        var recovered: [Provider] = []
        ToolchainWatch.locateOverride = { $0 == .grok ? "/usr/bin/true" : nil }
        ToolchainWatch.versionOutputOverride = { provider in
            provider == .grok ? "grok 1.0.13 (deadbeef) [stable]" : nil
        }
        ToolchainWatch.handshakeOverride = { provider, _ in
            recovered.append(provider)
            return stubHandshake(provider: provider, ok: true)
        }
        await ToolchainWatch.shared.sweepNow(forceNetwork: false, project: dir)
        audit.check("a version-change sweep without a change record still handshakes",
                    recovered == [.grok], "entered=\(recovered.map(\.rawValue))")
        audit.equal("the missing handshake is recorded on the next sweep",
                    ToolchainWatch.lastChange(.grok)?.version, Optional("1.0.13"))
        audit.equal("the recovered change records the version before the split sweep",
                    ToolchainWatch.lastChange(.grok)?.previousVersion, Optional("0.0.1"))

        try? FileManager.default.removeItem(at: store)
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "0.0.1",
                                          state: ToolchainWatch.stateParsed, at: at))
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "1.0.13",
                                          state: ToolchainWatch.stateParsed, at: at))
        ToolchainWatch.append(ToolchainWatch.Record(
            kind: ToolchainWatch.kindChange,
            provider: "grok",
            version: "1.0.13",
            versionState: ToolchainWatch.stateParsed,
            rawOutput: nil,
            checkedAt: at,
            locatedPath: "/usr/bin/true",
            previousVersion: "0.0.1",
            handshakeOK: true))
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "1.0.13",
                                          state: ToolchainWatch.stateParsed, at: at))
        audit.check("a later same-version sweep after this visit's change is not a missing handshake",
                    !ToolchainWatch.handshakeMissingAfterVersionChange(.grok, version: "1.0.13"))

        try? FileManager.default.removeItem(at: store)
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "0.0.1",
                                          state: ToolchainWatch.stateParsed, at: at))
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "1.0.13",
                                          state: ToolchainWatch.stateParsed, at: at))
        ToolchainWatch.append(ToolchainWatch.Record(
            kind: ToolchainWatch.kindChange,
            provider: "grok",
            version: "1.0.13",
            versionState: ToolchainWatch.stateParsed,
            rawOutput: nil,
            checkedAt: at,
            locatedPath: "/usr/bin/true",
            previousVersion: "0.0.1",
            handshakeOK: true))
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "0.0.1",
                                          state: ToolchainWatch.stateParsed, at: at))
        ToolchainWatch.append(ToolchainWatch.Record(
            kind: ToolchainWatch.kindChange,
            provider: "grok",
            version: "0.0.1",
            versionState: ToolchainWatch.stateParsed,
            rawOutput: nil,
            checkedAt: at,
            locatedPath: "/usr/bin/true",
            previousVersion: "1.0.13",
            handshakeOK: true))
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "1.0.13",
                                          state: ToolchainWatch.stateParsed, at: at))
        audit.check("cycling back to a version whose only change is from an earlier visit is still a missing handshake",
                    ToolchainWatch.handshakeMissingAfterVersionChange(.grok, version: "1.0.13"))
        var cycled: [Provider] = []
        ToolchainWatch.locateOverride = { $0 == .grok ? "/usr/bin/true" : nil }
        ToolchainWatch.versionOutputOverride = { provider in
            provider == .grok ? "grok 1.0.13 (deadbeef) [stable]" : nil
        }
        ToolchainWatch.handshakeOverride = { provider, _ in
            cycled.append(provider)
            return stubHandshake(provider: provider, ok: true)
        }
        await ToolchainWatch.shared.sweepNow(forceNetwork: false, project: dir)
        audit.check("cycling back to a version without this visit's change still handshakes",
                    cycled == [.grok], "entered=\(cycled.map(\.rawValue))")
        audit.equal("the cycled visit records a new change for the current version",
                    ToolchainWatch.lastChange(.grok)?.version, Optional("1.0.13"))
        audit.equal("the cycled visit's change records the version before this visit",
                    ToolchainWatch.lastChange(.grok)?.previousVersion, Optional("0.0.1"))

        try? FileManager.default.removeItem(at: store)
        park.continuation = nil
        ToolchainWatch.locateOverride = { $0 == .grok ? "/usr/bin/true" : nil }
        ToolchainWatch.versionOutputOverride = { provider in
            provider == .grok ? "grok 1.0.14 (deadbeef) [stable]" : nil
        }
        ToolchainWatch.handshakeOverride = { provider, _ in
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                park.continuation = cont
            }
            return stubHandshake(provider: provider, ok: true)
        }
        let emptySweep = Task {
            await ToolchainWatch.shared.sweepNow(forceNetwork: false, project: dir)
        }
        let emptyParked = await waitUntil(2) { park.continuation != nil }
        audit.check("an empty-store version change enters handshake without seeding first",
                    emptyParked)
        audit.equal("an empty-store sweep does not persist the seeded baseline while a handshake is in flight",
                    ToolchainWatch.load().records.count, 0)
        emptySweep.cancel()
        park.continuation?.resume()
        _ = await emptySweep.value
        audit.equal("an interrupted empty-store sweep persists no seeded baseline",
                    ToolchainWatch.load().records.count, 0)
        audit.check("an interrupted empty-store sweep persists no change event",
                    ToolchainWatch.lastChange(.grok) == nil)

        ToolchainWatch.locateOverride = nil
        ToolchainWatch.versionOutputOverride = nil
        ToolchainWatch.handshakeOverride = { provider, _ in
            stubHandshake(provider: provider, ok: false, reason: "unexpected handshake")
        }
        try? FileManager.default.removeItem(at: store)
    }

    // MARK: - Codex standalone CLI versionState

    private static func standaloneCodexVersionState(_ audit: Auditor, dir: URL) async {
        audit.section("Toolchain — standalone Codex CLI has its own versionState")
        let store = ToolchainWatch.storeURL
        try? FileManager.default.removeItem(at: store)
        ToolchainWatch.locateOverride = {
            $0 == .codex ? "/opt/homebrew/bin/codex" : nil
        }
        ToolchainWatch.versionOutputOverride = {
            $0 == .codex ? "codex-cli 0.151.0-alpha.7.2" : nil
        }
        ToolchainWatch.handshakeOverride = { provider, _ in
            stubHandshake(provider: provider, ok: false, reason: "unexpected handshake")
        }
        await ToolchainWatch.shared.sweepNow(forceNetwork: false, project: dir)
        audit.equal("standalone Codex CLI records versionState standaloneCLI",
                    ToolchainWatch.lastSweep(.codex)?.versionState,
                    Optional(ToolchainWatch.stateStandaloneCLI))
        ToolchainWatch.shared.reloadFromStore()
        let standaloneRow = ToolchainWatch.shared.row(for: .codex)
        audit.check("standalone Codex version line names standalone CLI",
                    standaloneRow.versionLine.contains("standalone CLI"),
                    standaloneRow.versionLine)
        audit.check("standalone Codex version line does not pose as bundled",
                    !standaloneRow.versionLine.localizedCaseInsensitiveContains("bundled"),
                    standaloneRow.versionLine)
        audit.check("standalone Codex update line does not pose as bundled",
                    standaloneRow.updateLine.contains("standalone CLI")
                    && !standaloneRow.updateLine.localizedCaseInsensitiveContains("bundled"),
                    standaloneRow.updateLine)

        try? FileManager.default.removeItem(at: store)
        ToolchainWatch.locateOverride = {
            $0 == .codex ? "/Applications/ChatGPT.app/Contents/Resources/codex" : nil
        }
        await ToolchainWatch.shared.sweepNow(forceNetwork: false, project: dir)
        audit.equal("bundled Codex records versionState parsed, not standaloneCLI",
                    ToolchainWatch.lastSweep(.codex)?.versionState,
                    Optional(ToolchainWatch.stateParsed))
        ToolchainWatch.shared.reloadFromStore()
        let bundledRow = ToolchainWatch.shared.row(for: .codex)
        audit.check("bundled Codex update line names the bundled version",
                    bundledRow.updateLine.contains("bundled"),
                    bundledRow.updateLine)
        audit.check("a ChatGPT.app path is classified as bundled Codex",
                    ToolchainWatch.isBundledCodexPath(
                        "/Applications/ChatGPT.app/Contents/Resources/codex"))
        audit.check("a Homebrew path is not classified as bundled Codex",
                    !ToolchainWatch.isBundledCodexPath("/opt/homebrew/bin/codex"))
        ToolchainWatch.locateOverride = nil
        ToolchainWatch.versionOutputOverride = nil
        try? FileManager.default.removeItem(at: store)
    }

    // MARK: - Change-history row

    private static func changeHistoryRow(_ audit: Auditor) {
        audit.section("Toolchain — change-history row matches the selected provider")
        let store = ToolchainWatch.storeURL
        try? FileManager.default.removeItem(at: store)
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        ToolchainWatch.append(sweepRecord(provider: .grok, version: "1.0.13",
                                          state: ToolchainWatch.stateParsed, at: at))
        ToolchainWatch.append(ToolchainWatch.Record(
            kind: ToolchainWatch.kindChange,
            provider: "grok",
            version: "1.0.13",
            versionState: ToolchainWatch.stateParsed,
            rawOutput: nil,
            checkedAt: at,
            locatedPath: "/usr/bin/true",
            previousVersion: "0.0.1",
            handshakeOK: true))
        ToolchainWatch.append(sweepRecord(provider: .claude, version: "2.1.233",
                                          state: ToolchainWatch.stateParsed, at: at))
        ToolchainWatch.append(ToolchainWatch.Record(
            kind: ToolchainWatch.kindChange,
            provider: "claude",
            version: "2.1.233",
            versionState: ToolchainWatch.stateParsed,
            rawOutput: nil,
            checkedAt: at,
            locatedPath: "/usr/bin/true",
            previousVersion: "1.0.0",
            handshakeOK: true))
        audit.equal("change-history row for Grok is Grok's entry, not the last overall (Claude)",
                    ToolchainWatch.changeHistoryLine(for: .grok),
                    "Grok 0.0.1 → 1.0.13")
        audit.equal("change-history row for Claude is Claude's entry",
                    ToolchainWatch.changeHistoryLine(for: .claude),
                    "Claude 1.0.0 → 2.1.233")
        audit.equal("change-history row for a provider with no entry says so honestly",
                    ToolchainWatch.changeHistoryLine(for: .codex),
                    "no change recorded for Codex")
        ToolchainWatch.shared.reloadFromStore()
        audit.equal("the Grok toolchain row change-history matches the selected provider",
                    ToolchainWatch.shared.row(for: .grok).changeHistoryLine,
                    "Grok 0.0.1 → 1.0.13")
        audit.equal("the Codex toolchain row does not fall back to another provider's change",
                    ToolchainWatch.shared.row(for: .codex).changeHistoryLine,
                    "no change recorded for Codex")
        let watchSource = (try? String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/Orrery/Toolchain/ToolchainWatch.swift"),
            encoding: .utf8)) ?? ""
        audit.check("the Toolchain sheet binds change history to a selected provider",
                    watchSource.contains("selectedProvider")
                    && watchSource.contains("changeHistoryLine"),
                    "ToolchainSheet missing selected-provider change-history row")
        try? FileManager.default.removeItem(at: store)
    }

    // MARK: - cliVersions stamp

    private static func cliVersionsStamp(_ audit: Auditor, dir: URL) async {
        audit.section("Toolchain — run recorder stamps cliVersions")
        audit.equal("nil cliVersions display as unrecorded",
                    TeamStats.cliVersionsText(nil), TeamStats.unrecorded)
        audit.equal("an empty cliVersions map displays as unrecorded",
                    TeamStats.cliVersionsText([:]), TeamStats.unrecorded)
        audit.equal("a stamped map displays provider versions",
                    TeamStats.cliVersionsText(["grok": "1.0.13", "claude": "2.1.233"]),
                    "Grok 1.0.13 · Claude 2.1.233")

        let v1 = """
        {"date":1700000000,"items":[{"authorEffort":"high","authorModel":"a-model","authorProvider":"claude","costUSD":1.5,"failed":false,"findings":[],"findingsLeftStanding":false,"gate":{"hasExecuted":false,"hasFailure":false,"passed":false,"status":"not run","tasks":[]},"reviewerEffort":"unrecorded","reviewerModel":"r-model","reviewerProvider":"grok","roundBudget":"2","rounds":1,"stalled":false,"state":"accepted","title":"Old","turns":1,"unreportedTurns":0}],"orchestratorEffort":"unrecorded","orchestratorModel":"unrecorded","orchestratorProvider":"grok"}
        """
        let v1URL = dir.appendingPathComponent("v1-cli.jsonl")
        try? (v1 + "\n").write(to: v1URL, atomically: true, encoding: .utf8)
        let v1Loaded = TeamStats.load(from: v1URL).records.first
        audit.equal("a v1 line without cliVersions decodes as version 1",
                    v1Loaded?.schemaVersion, 1)
        audit.check("a v1 line without cliVersions is nil, not an empty map",
                    v1Loaded?.cliVersions == nil)
        audit.equal("a v1 line without cliVersions reads unrecorded",
                    TeamStats.cliVersionsText(v1Loaded?.cliVersions), TeamStats.unrecorded)

        let v2URL = dir.appendingPathComponent("v2-cli.jsonl")
        let v2 = TeamStats.RunOutcome(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            orchestratorProvider: "grok",
            orchestratorModel: TeamStats.unrecorded,
            orchestratorEffort: TeamStats.unrecorded,
            items: [],
            importFingerprint: nil,
            schemaVersion: 2,
            kind: TeamStats.kindRun,
            cliVersions: nil)
        TeamStats.append(v2, to: v2URL)
        let v2Loaded = TeamStats.load(from: v2URL).records.first
        audit.equal("a v2 record without cliVersions keeps schema 2",
                    v2Loaded?.schemaVersion, 2)
        audit.check("a v2 record without cliVersions is nil, not an empty map",
                    v2Loaded?.cliVersions == nil)
        audit.equal("a v2 record without cliVersions reads unrecorded",
                    TeamStats.cliVersionsText(v2Loaded?.cliVersions), TeamStats.unrecorded)
        audit.equal("loadForDisplay reports unrecorded CLI versions for a v2 store",
                    TeamStats.loadForDisplay(from: v2URL).latestCLIVersions,
                    TeamStats.unrecorded)

        try? FileManager.default.removeItem(at: ToolchainWatch.storeURL)
        ToolchainWatch.seedBaselineIfEmpty()
        let expectedSeed: [String: String]? = [
            "claude": "2.1.233",
            "codex": "0.151.0-alpha.7.2",
            "grok": "1.0.13",
        ]
        audit.equal("latestParsedVersions returns the seeded map",
                    ToolchainWatch.latestParsedVersions(), expectedSeed)

        let staleAt = Date(timeIntervalSince1970: 1_800_000_000)
        ToolchainWatch.append(sweepRecord(provider: .grok, version: nil,
                                          state: ToolchainWatch.stateNotInstalled,
                                          at: staleAt))
        let afterGone = ToolchainWatch.latestParsedVersions()
        audit.check("latestParsedVersions omits a not-installed latest sweep",
                    afterGone?["grok"] == nil, "map=\(afterGone ?? [:])")
        audit.check("latestParsedVersions keeps providers whose latest sweep is still parsed",
                    afterGone?["claude"] == "2.1.233"
                    && afterGone?["codex"] == "0.151.0-alpha.7.2",
                    "map=\(afterGone ?? [:])")
        audit.equal("lastParsedVersion still walks back past not-installed for change detection",
                    ToolchainWatch.lastParsedVersion(.grok), Optional("1.0.13"))
        ToolchainWatch.append(sweepRecord(provider: .claude, version: nil,
                                          state: ToolchainWatch.stateUnparsed,
                                          at: staleAt, raw: "not a version"))
        let afterUnparsed = ToolchainWatch.latestParsedVersions()
        audit.check("latestParsedVersions omits an unparsed latest sweep",
                    afterUnparsed?["claude"] == nil, "map=\(afterUnparsed ?? [:])")

        try? FileManager.default.removeItem(at: ToolchainWatch.storeURL)
        ToolchainWatch.seedBaselineIfEmpty()
        let stamped = ToolchainWatch.latestParsedVersions()

        let statsStore = dir.appendingPathComponent("team-stats-cli.jsonl")
        let engine = Orchestrator()
        engine.installedProviders = [.grok, .claude]
        engine.orchestratorProvider = .grok
        engine.turnTimeout = 5
        engine.followGate = false
        engine.teamStatsURL = statsStore
        let plan = #"{"items":[{"title":"One","author":"claude","brief":"Do it."}]}"#
        var queues: [Provider: [[[BackendEvent]]]] = [
            .grok: [[ScriptedBackend.reply(plan, cost: 0.001)]],
            .claude: [[ScriptedBackend.reply("NO FINDINGS")]],
        ]
        engine.makeBackend = { provider in
            let scripts = queues[provider]?.isEmpty == false
                ? queues[provider]!.removeFirst() : []
            return ScriptedBackend(provider: provider, scripts: scripts)
        }
        engine.start(task: "Stamp the CLI versions.", project: dir)
        let finished = await waitUntil(10) { engine.phase == .done }
        audit.check("the cliVersions recording run completed", finished, "\(engine.phase)")
        let records = await waitForRecords(statsStore, count: 1)
        audit.equal("a finished run appends exactly one record for cliVersions",
                    records.count, 1)
        audit.equal("the run recorder stamps cliVersions from the latest sweep",
                    records.first?.cliVersions, stamped)
        audit.equal("a stamped record displays the CLI versions, not unrecorded",
                    TeamStats.cliVersionsText(records.first?.cliVersions),
                    "Grok 1.0.13 · Claude 2.1.233 · Codex 0.151.0-alpha.7.2")
        audit.equal("new team-stats records write schema version 3",
                    records.first?.schemaVersion, 3)

        try? FileManager.default.removeItem(at: ToolchainWatch.storeURL)
        let emptyEngine = Orchestrator()
        emptyEngine.installedProviders = [.grok, .claude]
        emptyEngine.orchestratorProvider = .grok
        emptyEngine.turnTimeout = 5
        emptyEngine.followGate = false
        let emptyStore = dir.appendingPathComponent("team-stats-empty-cli.jsonl")
        emptyEngine.teamStatsURL = emptyStore
        var emptyQueues: [Provider: [[[BackendEvent]]]] = [
            .grok: [[ScriptedBackend.reply(plan, cost: 0.001)]],
            .claude: [[ScriptedBackend.reply("NO FINDINGS")]],
        ]
        emptyEngine.makeBackend = { provider in
            let scripts = emptyQueues[provider]?.isEmpty == false
                ? emptyQueues[provider]!.removeFirst() : []
            return ScriptedBackend(provider: provider, scripts: scripts)
        }
        emptyEngine.start(task: "No sweep yet.", project: dir)
        _ = await waitUntil(10) { emptyEngine.phase == .done }
        let emptyRecords = await waitForRecords(emptyStore, count: 1)
        audit.check("a run with no sweep stamps nil cliVersions, not an empty map",
                    emptyRecords.first?.cliVersions == nil)
        audit.equal("a run with no sweep reads unrecorded",
                    TeamStats.cliVersionsText(emptyRecords.first?.cliVersions),
                    TeamStats.unrecorded)
    }
}

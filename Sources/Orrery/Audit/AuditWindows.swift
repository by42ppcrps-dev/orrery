import Foundation
import AppKit
import SwiftUI

/// Multi-window, multi-project: two live AppModels, recent-project persistence, and a
/// slash-command store that notifies every subscriber. Temp directories and an injectable
/// UserDefaults suite — never the user's real recents list.
@MainActor
enum AuditWindows {

    static func run(_ audit: Auditor) async {
        let standardBefore = UserDefaults.standard.stringArray(
            forKey: RecentProjects.defaultsKey) ?? []
        await twoModels(audit)
        recents(audit)
        slashSubscribers(audit)
        await twoModelsSeeSlashCommands(audit)
        await shutdownAndLaunch(audit)
        await restoreAutomaticToolsWithoutLaunching(audit)
        demoSeed(audit)
        let standardAfter = UserDefaults.standard.stringArray(
            forKey: RecentProjects.defaultsKey) ?? []
        audit.check("the audit did not write recentProjects to the user's defaults",
                    standardBefore == standardAfter,
                    "before=\(standardBefore) after=\(standardAfter)")
    }

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

    // MARK: Two live models

    private static func restoreAutomaticToolsWithoutLaunching(_ audit: Auditor) async {
        audit.section("Windows — restoring automatic tools cannot launch unmounted models")
        await Auditor.withTemporaryDirectory { root in
            let key = "studio.automaticTools." + AgentSettingsStore.location(root).lastPathComponent
            AppModel.preferences.set(true, forKey: key)
            defer { AppModel.preferences.removeObject(forKey: key) }
            let model = AppModel(trust: .forAudit)
            let backend = DelayedStartBackend(provider: model.provider)
            backend.startDelayNs = 0
            model.openProject(root)
            model.installed[model.provider] = true
            model.backends[model.provider] = backend
            defer { model.shutdown() }
            try? await Task.sleep(nanoseconds: 120_000_000)
            audit.check("restored automatic-tools preference is retained", model.autoApprove && model.orchestrator.autoApprove,
                        "autoApprove=\(model.autoApprove) orchestrator=\(model.orchestrator.autoApprove) stored=\(AppModel.preferences.bool(forKey: key)) suiteIsStandard=\(AppModel.preferences === UserDefaults.standard) key=\(key)")
            audit.check("restoring a project does not start a backend", !backend.started)
            await model.startIfNeeded()
            audit.check("explicit window preparation starts the restored backend", backend.started)
        }
    }

    private static func twoModels(_ audit: Auditor) async {
        audit.section("Windows — two AppModels, two projects")
        await Auditor.withTemporaryDirectory { dirA in
            await Auditor.withTemporaryDirectory { dirB in
                try? "print('a')\n".write(to: dirA.appendingPathComponent("alpha.py"),
                                          atomically: true, encoding: .utf8)
                try? "// swift-tools-version: 6.0\nimport PackageDescription\n"
                    .write(to: dirA.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)
                try? "beta\n".write(to: dirB.appendingPathComponent("beta.md"),
                                    atomically: true, encoding: .utf8)
                try? "build:\n\techo built\n".write(
                    to: dirB.appendingPathComponent("Makefile"),
                    atomically: true, encoding: .utf8)

                let a = AppModel(trust: .forAudit)
                let b = AppModel(trust: .forAudit)
                a.openProject(dirA)
                b.openProject(dirB)

                audit.check("A and B hold different project URLs",
                            a.projectURL != b.projectURL,
                            "A=\(a.projectURL?.path ?? "nil") B=\(b.projectURL?.path ?? "nil")")
                audit.equal("A opened dirA", a.projectURL?.path, dirA.path)
                audit.equal("B opened dirB", b.projectURL?.path, dirB.path)

                audit.check("distinct DocumentStore instances", a.documents !== b.documents)
                audit.check("distinct ProjectIndex instances", a.index !== b.index)
                audit.check("distinct TaskRunModel instances", a.taskRun !== b.taskRun)
                audit.check("distinct Orchestrator instances", a.orchestrator !== b.orchestrator)
                audit.check("distinct DiagnosticsEngine instances", a.diagnostics !== b.diagnostics)

                let aNames = Set((a.fileTree?.children ?? []).map(\.name))
                let bNames = Set((b.fileTree?.children ?? []).map(\.name))
                audit.check("A's file tree contains alpha.py", aNames.contains("alpha.py"),
                            aNames.sorted().joined(separator: ","))
                audit.check("B's file tree contains beta.md", bNames.contains("beta.md"),
                            bNames.sorted().joined(separator: ","))
                audit.check("A's file tree does not contain beta.md",
                            !aNames.contains("beta.md"))
                audit.check("B's file tree does not contain alpha.py",
                            !bNames.contains("alpha.py"))

                _ = await waitUntil(4) { !a.index.isScanning && !b.index.isScanning }
                let aIndexed = Set(a.index.files.map(\.lastPathComponent))
                let bIndexed = Set(b.index.files.map(\.lastPathComponent))
                audit.check("A's index lists alpha.py and not beta.md",
                            aIndexed.contains("alpha.py") && !aIndexed.contains("beta.md"),
                            aIndexed.sorted().joined(separator: ","))
                audit.check("B's index lists beta.md and not alpha.py",
                            bIndexed.contains("beta.md") && !bIndexed.contains("alpha.py"),
                            bIndexed.sorted().joined(separator: ","))

                audit.check("A's tasks come from Package.swift",
                            a.taskRun.tasks.contains { $0.id.hasPrefix("swift-") },
                            a.taskRun.tasks.map(\.id).joined(separator: ","))
                audit.check("B's tasks come from the Makefile",
                            b.taskRun.tasks.contains { $0.id.hasPrefix("make-") },
                            b.taskRun.tasks.map(\.id).joined(separator: ","))
                audit.check("A does not carry B's make tasks",
                            !a.taskRun.tasks.contains { $0.id.hasPrefix("make-") })
                audit.check("B does not carry A's swift tasks",
                            !b.taskRun.tasks.contains { $0.id.hasPrefix("swift-") })

                let alpha = dirA.appendingPathComponent("alpha.py")
                a.open(file: alpha)
                audit.check("a file opened in A is A's active tab",
                            a.documents.active?.url.path == alpha.path)
                audit.check("that file does not appear in B",
                            b.documents.documents.isEmpty)
                let beta = dirB.appendingPathComponent("beta.md")
                b.open(file: beta)
                audit.check("B opening a file does not change A's active tab",
                            a.documents.active?.url.path == alpha.path)
                audit.equal("A still has one tab", a.documents.documents.count, 1)
                audit.equal("B has one tab", b.documents.documents.count, 1)

                audit.check("both start with an empty terminal slot",
                            a.terminal == nil && b.terminal == nil)
                a.terminal = TerminalSession(directory: dirA)
                audit.check("A's terminal slot is occupied", a.terminal != nil)
                audit.check("B's terminal slot is unchanged", b.terminal == nil)

                let originalBProvider = b.orchestrator.orchestratorProvider
                a.orchestrator.orchestratorProvider = (originalBProvider == .grok) ? .claude : .grok
                audit.check("mutating A's orchestrator leaves B's",
                            b.orchestrator.orchestratorProvider == originalBProvider)
                a.showOrchestrator = true
                a.bottomPane = .terminal
                audit.check("mutating A's pane leaves B's hidden", b.bottomPane == .hidden)
                audit.check("mutating A's orchestrator toggle leaves B's",
                            b.showOrchestrator == false)
            }
        }
    }

    // MARK: Recents

    private static func recents(_ audit: Auditor) {
        audit.section("Windows — recentProjects")
        let suiteName = "app.orrery.studio.audit.recentProjects"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            audit.check("could create an isolated defaults suite", false)
            return
        }
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }

        let store = RecentProjects(defaults: suite)
        store.isScratchPath = { _ in false }

        func path(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path
        }

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-recents-\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var dirs: [URL] = []
        for i in 1...9 {
            let dir = root.appendingPathComponent("p\(i)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            dirs.append(dir)
        }

        store.record(dirs[0])
        store.record(dirs[0])
        audit.equal("opening the same project twice yields one entry", store.entries.count, 1)
        store.record(dirs[1])
        store.record(dirs[0])
        audit.equal("re-opening moves the project to the front",
                    store.entries.map(\.path),
                    [path(dirs[0]), path(dirs[1])])

        // Fresh store for the cap test so the two-entry list above does not leak in.
        suite.removePersistentDomain(forName: suiteName)
        let capped = RecentProjects(defaults: suite)
        capped.isScratchPath = { _ in false }
        for dir in dirs { capped.record(dir) }
        audit.equal("the list is capped at 8", capped.entries.count, 8)
        audit.equal("the 9th opening evicts the oldest",
                    capped.entries.map(\.path),
                    dirs.reversed().prefix(8).map(path))
        audit.check("the oldest of nine is gone",
                    !capped.entries.contains { $0.path == path(dirs[0]) })

        let scratch = RecentProjects(defaults: suite)
        scratch.isScratchPath = { AppModel.isScratchPath($0) }
        let beforeScratch = scratch.entries.map(\.path)
        scratch.record(root)
        audit.check("a temp/scratch path is never recorded",
                    scratch.entries.map(\.path) == beforeScratch,
                    scratch.entries.map(\.path).joined(separator: ","))

        let model = AppModel(trust: .forAudit)
        model.recentProjects = RecentProjects.shared
        let sharedBefore = RecentProjects.shared.entries.map(\.path)
        model.openProject(root)
        audit.check("openProject does not record a scratch path on the shared list",
                    RecentProjects.shared.entries.map(\.path) == sharedBefore)

        // Missing entry: record a real folder, then delete it. It stays, flagged missing.
        suite.removePersistentDomain(forName: suiteName)
        let missingStore = RecentProjects(defaults: suite)
        missingStore.isScratchPath = { _ in false }
        let vanished = root.appendingPathComponent("will-vanish")
        try? fm.createDirectory(at: vanished, withIntermediateDirectories: true)
        missingStore.record(vanished)
        let vanishedPath = path(vanished)
        try? fm.removeItem(at: vanished)
        audit.check("a deleted folder remains in the list",
                    missingStore.entries.contains { $0.path == vanishedPath })
        audit.check("…and is flagged missing, not dropped",
                    missingStore.entries.first { $0.path == vanishedPath }?.exists == false)

        let click = AppModel(trust: .forAudit)
        click.recentProjects = missingStore
        let missingEntry = RecentProject(path: vanishedPath)
        click.openRecent(missingEntry)
        audit.check("clicking a missing entry does not crash or switch project",
                    click.projectURL == nil)
        audit.check("…and names the problem",
                    click.recentOpenError?.contains("no longer there") == true,
                    click.recentOpenError ?? "")

        // Recording through AppModel.openProject covers every open path.
        suite.removePersistentDomain(forName: suiteName)
        let throughModel = RecentProjects(defaults: suite)
        throughModel.isScratchPath = { _ in false }
        let hosted = AppModel(trust: .forAudit)
        hosted.recentProjects = throughModel
        hosted.openProject(dirs[2])
        audit.equal("openProject records onto the injected store",
                    throughModel.entries.map(\.path), [path(dirs[2])])
    }

    // MARK: Slash commands

    private static func slashSubscribers(_ audit: Auditor) {
        audit.section("Windows — SlashCommandStore subscribers")
        let store = SlashCommandStore.shared
        var aFires = 0
        var bFires = 0
        let idA = store.addSubscriber { aFires += 1 }
        let idB = store.addSubscriber { bFires += 1 }
        store.set(["/one"], for: .grok)
        audit.check("both subscribers fire on set",
                    aFires == 1 && bFires == 1,
                    "a=\(aFires) b=\(bFires)")
        store.removeSubscriber(idA)
        store.set(["/two"], for: .grok)
        audit.check("removing one leaves the other working",
                    aFires == 1 && bFires == 2,
                    "a=\(aFires) b=\(bFires)")
        store.removeSubscriber(idB)
        let after = aFires
        store.set(["/three"], for: .grok)
        audit.check("removing the last subscriber fires nobody",
                    aFires == after && bFires == 2,
                    "a=\(aFires) b=\(bFires)")
    }

    private static func twoModelsSeeSlashCommands(_ audit: Auditor) async {
        audit.section("Windows — two AppModels both see slash commands")
        let a = AppModel(trust: .forAudit)
        let b = AppModel(trust: .forAudit)
        a.states.removeAll()
        b.states.removeAll()
        SlashCommandStore.shared.set(["/explain"], for: .grok)
        SlashCommandStore.shared.set(["/explain"], for: .claude)
        SlashCommandStore.shared.set(["/explain"], for: .codex)
        audit.check("A sees the new slash command",
                    a.slashCommands.contains("/explain"),
                    a.slashCommands.joined(separator: ","))
        audit.check("B sees the new slash command",
                    b.slashCommands.contains("/explain"),
                    b.slashCommands.joined(separator: ","))
        audit.check("A's subscriber refreshed UI state", a.states[a.provider] != nil)
        audit.check("B's subscriber refreshed UI state", b.states[b.provider] != nil)

        weak var dead: AppModel?
        do {
            let extra = AppModel(trust: .forAudit)
            let afterAdd = SlashCommandStore.shared.subscriberCount
            extra.shutdown()
            audit.equal("shutdown removes the model's slash-command subscriber",
                        SlashCommandStore.shared.subscriberCount, afterAdd - 1)
            dead = extra
        }
        _ = await waitUntil(1) { dead == nil }
        audit.check("a released window model deallocates", dead == nil)
        SlashCommandStore.shared.set(["/after-death"], for: .grok)
        audit.check("the surviving window still sees new commands",
                    a.slashCommands.contains("/after-death"))
    }

    private static func shutdownAndLaunch(_ audit: Auditor) async {
        audit.section("Windows — close tears down backends")
        let spy = StubBackend()
        let model = AppModel(trust: .forAudit)
        model.backends[.grok] = spy
        model.shutdown()
        audit.check("shutdown stops the window's backends", spy.stopped)
        audit.check("shutdown clears the backend table", model.backends.isEmpty)
        model.shutdown()
        audit.check("shutdown is idempotent", spy.stopped && model.backends.isEmpty)

        let windowSpy = StubBackend()
        let windowModel = AppModel(trust: .forAudit)
        windowModel.backends[.grok] = windowSpy
        ExtraWindowSupport.shared.open(project: nil, model: windowModel)
        ExtraWindowSupport.shared.closeAll()
        audit.check("closing an extra window stops its backends", windowSpy.stopped)

        await inFlightStart(audit)
        await windowGroupHook(audit)

        audit.section("Windows — WindowLaunch")
        WindowLaunch.resetForTests()
        defer { WindowLaunch.resetForTests() }
        var consumeCount = 0
        WindowLaunch.onConsumeLaunchArguments = { _ in consumeCount += 1 }

        await Auditor.withTemporaryDirectory { dir in
            let savedLast = AppModel.preferences.string(forKey: "lastProject")
            defer {
                if let savedLast {
                    AppModel.preferences.set(savedLast, forKey: "lastProject")
                } else {
                    AppModel.preferences.removeObject(forKey: "lastProject")
                }
            }
            AppModel.preferences.set(dir.path, forKey: "lastProject")

            let first = AppModel(trust: .forAudit)
            WindowLaunch.configure(model: first, initialProject: nil, restoreLastProject: true)
            audit.equal("the first window restores lastProject", first.projectURL?.path, dir.path)
            audit.equal("launch arguments are consumed once", consumeCount, 1)

            let extra = AppModel(trust: .forAudit)
            WindowLaunch.configure(model: extra, initialProject: nil, restoreLastProject: false)
            audit.check("a New Project Window does not clone lastProject", extra.projectURL == nil)
            audit.equal("flags do not re-fire in a second window", consumeCount, 1)

            let reopen = AppModel(trust: .forAudit)
            WindowLaunch.configure(model: reopen, initialProject: nil, restoreLastProject: true)
            audit.equal("a later empty WindowGroup restores lastProject",
                        reopen.projectURL?.path, dir.path)
            audit.equal("reopening still does not re-fire flags", consumeCount, 1)

            let nested = dir.appendingPathComponent("explicit")
            try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let targeted = AppModel(trust: .forAudit)
            WindowLaunch.configure(model: targeted, initialProject: nested,
                                   restoreLastProject: true)
            audit.equal("an explicit project wins over lastProject",
                        targeted.projectURL?.path, nested.path)
            audit.equal("opening onto a project still does not re-fire flags", consumeCount, 1)
        }
    }

    /// A start that sleeps so the audit can `shutdown()` while `start` is still in flight.
    @MainActor
    private final class DelayedStartBackend: AgentBackend {
        let provider: Provider
        var models: [ModelOption] = []
        var currentModel = ""
        var currentEffort = ""
        var persistsSelection = true
        var onEvent: ((BackendEvent) -> Void)?
        private(set) var isRunning = false
        var started = false
        var stopped = false
        var startDelayNs: UInt64 = 80_000_000

        init(provider: Provider = .grok) { self.provider = provider }
        static func locate() -> String? { "/bin/true" }
        func start(project: URL, autoApprove: Bool) async {
            try? await Task.sleep(nanoseconds: startDelayNs)
            started = true
            isRunning = true
        }
        func stop() {
            stopped = true
            isRunning = false
        }
        func send(_ text: String) async {}
        func cancel() {}
        func setModel(_ id: String) async {}
    }

    private static func primedModel(dir: URL, delay: UInt64 = 80_000_000) -> (AppModel, DelayedStartBackend) {
        let model = AppModel(trust: .forAudit)
        model.openProject(dir)
        let delayed = DelayedStartBackend(provider: model.provider)
        delayed.startDelayNs = delay
        model.installed[model.provider] = true
        model.backends[model.provider] = delayed
        return (model, delayed)
    }

    private static func inFlightStart(_ audit: Auditor) async {
        audit.section("Windows — a queued start cannot outlive the window")
        await Auditor.withTemporaryDirectory { dir in
            do {
                let (model, delayed) = primedModel(dir: dir)
                let start = Task { await model.startIfNeeded() }
                try? await Task.sleep(nanoseconds: 20_000_000)
                model.shutdown()
                await start.value
                audit.check("startIfNeeded in flight at close is stopped",
                            delayed.stopped && !delayed.isRunning,
                            "started=\(delayed.started) stopped=\(delayed.stopped) running=\(delayed.isRunning)")
                audit.check("…and does not keep the backend", model.backends.isEmpty)
            }
            do {
                let (model, delayed) = primedModel(dir: dir)
                let start = Task { await model.newSession() }
                try? await Task.sleep(nanoseconds: 20_000_000)
                model.shutdown()
                await start.value
                audit.check("newSession in flight at close is stopped",
                            delayed.stopped && !delayed.isRunning,
                            "started=\(delayed.started) stopped=\(delayed.stopped) running=\(delayed.isRunning)")
            }

            let closed = AppModel(trust: .forAudit)
            closed.openProject(dir)
            closed.shutdown()
            let probe = DelayedStartBackend(provider: closed.provider)
            closed.installed[closed.provider] = true
            closed.backends[closed.provider] = probe
            await closed.startIfNeeded()
            await closed.newSession()
            await closed.restartAll()
            audit.check("startIfNeeded after shutdown does not start", !probe.started)
            audit.check("newSession after shutdown does not start", !probe.started)
            audit.check("restartAll after shutdown does not start", !probe.started)
        }
    }

    /// Hosts `ContentView` in a plain `NSWindow` — ExtraWindowSupport is not the delegate —
    /// so the only reaper is `WindowShutdownHook` in ContentView's body.
    private static func windowGroupHook(_ audit: Auditor) async {
        audit.section("Windows — WindowGroup close hook")
        let spy = StubBackend()
        let model = AppModel(trust: .forAudit)
        model.backends[.grok] = spy
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model,
                                                                  restoreLastProject: false)
            .frame(minWidth: 1100, minHeight: 680))
        // The representable attaches on the next turn, sometimes via `DispatchQueue.main.async`.
        try? await Task.sleep(nanoseconds: 250_000_000)
        window.close()
        audit.check("closing a WindowGroup window stops its backends", spy.stopped)
    }

    private static func demoSeed(_ audit: Auditor) {
        audit.section("Windows — demo recents overlay")
        let demo = AppModel(trust: .forAudit)
        demo.seedDemoTranscript()
        let seeded = demo.demoRecentProjects ?? []
        audit.check("demo seeds recent projects", seeded.count >= 2,
                    "count=\(seeded.count)")
        audit.check("demo includes an existing project", seeded.contains(where: \.exists))
        audit.check("demo includes a missing project", seeded.contains { !$0.exists })
        audit.check("demo overlay is what the sidebar would show",
                    demo.displayedRecentProjects == seeded)
    }
}

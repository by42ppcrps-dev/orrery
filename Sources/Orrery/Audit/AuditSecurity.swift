import Foundation
import AppKit

@MainActor
enum AuditSecurity {
    static func run(_ audit: Auditor) async {
        await fileSafety(audit)
        await replacement(audit)
        await projectTabs(audit)
        approvals(audit)
        await trust(audit)
        await processes(audit)
    }

    private static func fileSafety(_ audit: Auditor) async {
        audit.section("Security — workspace boundaries and document safety")
        await Auditor.withTemporaryDirectory { root in
            await Auditor.withTemporaryDirectory { outside in
                let access = WorkspaceFileAccess(root: root)
                let secret = outside.appendingPathComponent("private.txt")
                try? Data("not public".utf8).write(to: secret)
                for path in ["../private.txt", "sub/../../private.txt", secret.path, "\0", ".", "/"] {
                    audit.check("reject unsafe path \(path.debugDescription)", (try? access.read(path)) == nil)
                }
                try? FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
                try? FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: secret)
                audit.check("directory symlinks cannot read outside the project", (try? access.read("escape/private.txt")) == nil)
                audit.check("file symlinks cannot read outside the project", (try? access.read("link.txt")) == nil)
                audit.check("directory symlinks cannot redirect writes", throwsError { try access.write(Data("bad".utf8), to: "escape/private.txt") })
                audit.check("file symlinks cannot redirect writes", throwsError { try access.write(Data("bad".utf8), to: "link.txt") })
                audit.equal("outside file was not touched", try? String(contentsOf: secret, encoding: .utf8), "not public")
                try? access.write(Data("safe".utf8), to: "nested/new.txt")
                audit.equal("nested workspace writes work", try? access.read("nested/new.txt"), Data("safe".utf8))
                audit.equal("canonical macOS paths remain inside the same workspace",
                    try? access.read(root.resolvingSymlinksInPath().appendingPathComponent("nested/new.txt").path), Data("safe".utf8))
                audit.equal("physical macOS paths from directory enumeration remain accessible",
                    try? access.read((WorkspaceFileAccess.canonicalPath(root) ?? "") + "/nested/new.txt"), Data("safe".utf8))
                audit.check("write refuses stale expected content", throwsError {
                    try access.write(Data("stale".utf8), to: "nested/new.txt", expected: Data("old".utf8))
                })
                let fifo = root.appendingPathComponent("pipe").path
                mkfifo(fifo, 0o600)
                audit.check("named pipe is refused without blocking", (try? access.read("pipe")) == nil)
                audit.check("oversized writes are refused", throwsError {
                    try access.write(Data(repeating: 1, count: WorkspaceFileAccess.limit + 1), to: "huge.txt")
                })
                for name in ["../escape", "a/b", ".", "..", "", "a\nname", "a\0name"] {
                    audit.check("file creation rejects invalid name \(name.debugDescription)",
                        (try? FileOperations.createFile(named: name, in: root)) == nil)
                }
                let file = root.appendingPathComponent("edit.sh")
                let original = Data([0xEF, 0xBB, 0xBF]) + Data("echo original\n".utf8)
                try? original.write(to: file)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
                let document = CodeDocument(url: file)
                let stamp = document.diskStamp!
                document.replaceAll(with: "echo mine\n")
                try? Data("echo theirs\n".utf8).write(to: file)
                try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
                audit.check("same-timestamp external rewrite refuses save", conflicted(document.save()))
                audit.equal("external work survives failed save", try? String(contentsOf: file, encoding: .utf8), "echo theirs\n")
                try? FileManager.default.removeItem(at: file)
                audit.check("deleted file is a save conflict", conflicted(document.save()))
                try? original.write(to: file)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
                document.reload()
                document.replaceAll(with: "echo saved\n")
                audit.check("normal edit saves", saved(document.save()))
                audit.check("UTF-8 BOM is preserved", (try? Data(contentsOf: file).starts(with: [0xEF, 0xBB, 0xBF])) == true)
                let mode = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int
                audit.equal("executable permissions are preserved", mode, 0o700)
                let store = DocumentStore()
                let tab = store.open(file)!
                tab.replaceAll(with: "unsaved")
                store.confirmClose = { _ in .cancel }
                audit.check("cancel close retains dirty tab", !store.close(tab) && store.active === tab)
                audit.check("cancel close-all retains dirty tab", !store.closeAll() && store.documents.count == 1)
                store.confirmClose = { _ in .save }
                audit.check("save-and-close writes and closes", store.close(tab) && store.documents.isEmpty)
                audit.check("saved content reached disk", (try? String(contentsOf: file, encoding: .utf8))?.contains("unsaved") == true)
            }
        }
    }

    private static func replacement(_ audit: Auditor) async {
        audit.section("Security — replacement preview and undo")
        await Auditor.withTemporaryDirectory { root in
            let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
            try? "needle one".write(to: a, atomically: true, encoding: .utf8)
            try? "needle two".write(to: b, atomically: true, encoding: .utf8)
            let search = ProjectSearch()
            @MainActor func scan() async {
                search.run(query: "needle", options: SearchOptions(), files: [a, b], root: root)
                for _ in 0..<200 where search.isSearching { try? await Task.sleep(nanoseconds: 10_000_000) }
            }
            await scan()
            audit.equal("search sees both fixtures", search.totalHits, 2)
            audit.check("query changes invalidate replacement", throwsError {
                try search.replaceAll(with: "pin", query: "one", options: SearchOptions())
            })
            audit.check("dirty tabs block all writes", throwsError {
                try search.replaceAll(with: "pin", query: "needle", options: SearchOptions(), protecting: [b])
            })
            try? "needle changed".write(to: b, atomically: true, encoding: .utf8)
            audit.check("stale preview blocks all writes", throwsError {
                try search.replaceAll(with: "pin", query: "needle", options: SearchOptions())
            })
            audit.equal("preflight kept earlier file intact", try? String(contentsOf: a, encoding: .utf8), "needle one")
            await scan()
            let replacement = try? search.replaceAll(with: "pin", query: "needle", options: SearchOptions())
            audit.equal("replacement writes both files", replacement?.files, 2)
            audit.check("replacement offers undo", search.canUndoReplacement)
            audit.equal("undo restores both", try? search.undoLastReplacement(), 2)
            audit.equal("undo restores exact bytes", try? String(contentsOf: b, encoding: .utf8), "needle changed")
            await scan()
            _ = try? search.replaceAll(with: "pin", query: "needle", options: SearchOptions())
            try? "new human edit".write(to: a, atomically: true, encoding: .utf8)
            audit.check("undo refuses newer edits", throwsError { try search.undoLastReplacement() })
            audit.equal("undo refusal preserves newer work", try? String(contentsOf: a, encoding: .utf8), "new human edit")
            audit.check("globstar slash matches root file", ProjectSearch.matches(glob: "**/*.txt", path: "a.txt"))
            audit.check("globstar respects path boundaries", !ProjectSearch.matches(glob: "a/**/b.txt", path: "a/xb.txt"))
        }
    }

    private static func projectTabs(_ audit: Auditor) async {
        audit.section("Workspace — multiple projects within one window")
        await Auditor.withTemporaryDirectory { a in
            await Auditor.withTemporaryDirectory { b in
                try? "alpha".write(to: a.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
                try? "beta".write(to: b.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
                let workspaces = ProjectWorkspaces(makeModel: { AppModel(trust: .forAudit) })
                workspaces.open(a)
                let first = workspaces.active!
                first.model.open(file: a.appendingPathComponent("a.txt"))
                first.model.documents.active?.replaceAll(with: "unsaved alpha")
                first.model.chatDraft = "draft for alpha"
                first.model.bottomPane = .terminal
                first.model.terminal = TerminalSession(directory: a)
                let terminal = first.model.terminal
                let agent = StubBackend()
                first.model.backends[first.model.provider] = agent
                workspaces.open(b)
                let second = workspaces.active!
                audit.equal("second project adds a tab, not a window", workspaces.tabs.count, 2)
                audit.check("projects have independent models", first.model !== second.model)
                audit.check("switching preserves unsaved buffer", first.model.documents.active?.text == "unsaved alpha")
                audit.check("switching keeps the first terminal", first.model.terminal === terminal)
                audit.check("switching keeps the first agent", first.model.backends[first.model.provider] === agent)
                audit.check("new project has its own empty editor", second.model.documents.documents.isEmpty)
                audit.equal("new project has its own composer", second.model.chatDraft, "")
                workspaces.select(first.id)
                audit.equal("switch restores composer", workspaces.active?.model.chatDraft, "draft for alpha")
                audit.check("switch restores active editor and pane", workspaces.active?.model.bottomPane == .terminal)
                workspaces.open(a)
                audit.equal("reopening same project selects existing tab", workspaces.tabs.count, 2)
                first.model.documents.confirmClose = { _ in .cancel }
                audit.check("cancel closing project keeps its tab", !workspaces.close(first.id) && workspaces.tabs.count == 2)
                first.model.documents.confirmClose = { _ in .discard }
                audit.check("closing one project leaves the other", workspaces.close(first.id) && workspaces.active?.id == second.id)
                audit.check("closing cleans up only its own backend", first.model.backends.isEmpty && second.model.projectURL == b)
                var redundantPrompts = 0
                first.model.documents.confirmClose = { _ in redundantPrompts += 1; return .cancel }
                StudioApplicationDelegate.register(first.model)
                _ = StudioApplicationDelegate().applicationShouldTerminate(NSApplication.shared)
                audit.equal("quit never re-prompts for an already closed project", redundantPrompts, 0)
                workspaces.close(second.id)
                audit.equal("closing last project leaves a usable welcome tab", workspaces.tabs.count, 1)
                for tab in workspaces.tabs { tab.model.shutdown() }
            }
        }
    }

    private static func approvals(_ audit: Auditor) {
        audit.section("Security — approval identity and real protocol mapping")
        let model = AppModel(trust: .forAudit)
        var answers: [String] = []
        func request(_ name: String) -> PermissionRequest {
            PermissionRequest(title: name, detail: "", options: [PermissionOption(id: "allow", name: "Allow", kind: "allow_once")],
                              reply: { choice in answers.append(name + ":" + (choice ?? "cancel")) })
        }
        model.handleForTest(.permission(request("first")), from: .grok)
        model.handleForTest(.permission(request("second")), from: .codex)
        let first = model.permissionQueue[0], second = model.permissionQueue[1]
        second.reply("allow")
        first.reply("invalid-choice")
        second.reply("allow")
        audit.equal("out-of-order replies answer exact request only once", answers, ["second:allow", "first:cancel"])
        audit.check("approval queue drains without a crash", model.permissionQueue.isEmpty)
        model.handleForTest(.permission(request("disconnect")), from: .grok)
        model.handleForTest(.disconnected(reason: "test"), from: .grok)
        audit.equal("disconnect resolves outstanding approval", answers.last, "disconnect:cancel")
        let claude = ClaudeBackend()
        var wire: [JSON] = []
        var prompt: PermissionRequest?
        claude.observeProtocolForTest { wire.append(JSON($0)) }
        claude.onEvent = { if case let .permission(request) = $0 { prompt = request } }
        claude.handleJSONForTest(JSON(["type": "control_request", "request_id": "permission-one",
            "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "echo safe"]]]))
        audit.check("Claude surfaces an interactive approval", prompt?.detail.contains("echo safe") == true)
        prompt?.reply(nil)
        audit.equal("Claude cancellation sends a protocol deny", wire.last?["response"]["response"]["behavior"].string, "deny")
        prompt?.reply("allow")
        audit.equal("Claude refuses duplicate approval replies", wire.count, 1)
        let codex = CodexBackend()
        wire = []
        codex.observeProtocolForTest { wire.append(JSON($0)) }
        codex.onEvent = { if case let .permission(request) = $0 { prompt = request } }
        codex.handleJSONForTest(JSON(["id": 42, "method": "item/tool/requestUserInput", "params": ["questions": [
            ["id": "choice", "header": "Choice", "question": "Which fixture?", "options": [["label": "A", "description": "First"]]]]]]))
        audit.equal("Codex input questions reach the UI", prompt?.questions.first?.title, "Which fixture?")
        prompt?.answer?(["choice": "A"])
        audit.equal("Codex answer uses installed protocol schema", wire.last?["result"]["answers"]["choice"]["answers"].array.first?.string, "A")
        codex.handleJSONForTest(JSON(["id": 43, "method": "unknown/securityAction", "params": [:]]))
        audit.equal("unknown server requests fail closed", wire.last?["error"]["code"].int, -32601)
        model.shutdown()
    }

    private static func trust(_ audit: Auditor) async {
        audit.section("Security — project trust and credential isolation")
        let name = "app.orrery.studio.audit.trust.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let trust = ProjectTrustStore(defaults: defaults)
        await Auditor.withTemporaryDirectory { root in
            let model = AppModel(trust: trust)
            model.openProject(root)
            audit.check("new projects start restricted", !model.isProjectTrusted)
            await model.startIfNeeded()
            audit.check("restricted projects do not start agent children", model.backends.isEmpty)
            model.showTerminal()
            audit.check("restricted projects do not start a shell", model.terminal == nil)
            let scratch = CodeDocument(name: "restricted.py", language: Languages.forFile(URL(fileURLWithPath: "restricted.py")), text: "print('safe')")
            await model.diagnostics.check(scratch)
            audit.check("manual diagnostic checks cannot bypass project trust",
                model.diagnostics.lastRun[scratch.url] == nil && model.diagnostics.notes[scratch.url]?.contains("Trust") == true)
            audit.check("restricted projects cannot start orchestrator", model.orchestrator.startBlocker?.contains("Trust") == true)
            audit.check("automatic approval is off by default", !model.autoApprove && !model.orchestrator.autoApprove)
            _ = model.fileTree?.children
            let created = root.appendingPathComponent("agent-created.txt")
            try? Data("created".utf8).write(to: created)
            model.handleForTest(.turnFinished(stopReason: "completed", costUSD: nil), from: .grok)
            audit.check("agent-created files appear in the sidebar after a turn",
                model.fileTree?.children?.contains(where: { $0.url.lastPathComponent == "agent-created.txt" }) == true)
            trust.setTrusted(root, true)
            audit.check("explicit exact-project trust persists", trust.contains(root))
            let child = root.appendingPathComponent("child")
            try? FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            audit.check("parent trust does not grant child projects", !trust.contains(child))
            let peer = AppModel(trust: trust)
            peer.openProject(root)
            let peerAgent = StubBackend()
            peer.backends[.grok] = peerAgent
            trust.setTrusted(root, false)
            audit.check("trust revocation persists", !trust.contains(root))
            audit.check("revoking trust stops other windows of the same project", peerAgent.stopped && peer.backends.isEmpty && !peer.isProjectTrusted)
            peer.shutdown()
            model.shutdown()
        }
        let clean = AgentEnvironment.sanitized(["HOME": "/home/test", "PATH": "/usr/bin", "OPENAI_API_KEY": "secret", "ANTHROPIC_API_KEY": "secret", "AWS_ACCESS_KEY_ID": "secret", "DYLD_INSERT_LIBRARIES": "bad", "NODE_OPTIONS": "bad", "GITHUB_TOKEN": "secret"])
        audit.equal("agent environments remove API keys and unrelated credentials", Set(clean.keys), Set(["HOME", "PATH"]))
    }

    private static func processes(_ audit: Auditor) async {
        audit.section("Security — child process restart isolation")
        let child = LineProcess()
        var lines: [String] = [], exits = 0
        child.onRawLine = { lines.append($0) }
        child.onExit = { _ in exits += 1 }
        try? child.start(executable: "/bin/sh", arguments: ["-c", "sleep 1; echo old"], cwd: nil)
        child.stop()
        await Auditor.withTemporaryDirectory { root in
            let model = AppModel(trust: .forAudit)
            model.projectURL = root
            model.provider = .grok
            let backend = StubBackend()
            model.backends[.grok] = backend
            model.handleForTest(.connected(sessionID: "old"), from: .grok)
            let previousGrace = AppModel.cancelGraceSeconds
            AppModel.cancelGraceSeconds = 0.05
            await model.send("first")
            model.cancel()
            await model.newSession()
            backend.stopped = false
            model.handleForTest(.connected(sessionID: "new"), from: .grok)
            await model.send("second")
            try? await Task.sleep(nanoseconds: 100_000_000)
            audit.check("old cancellation watchdog cannot stop a new session", !backend.stopped)
            AppModel.cancelGraceSeconds = previousGrace
            model.shutdown()
        }
        try? child.start(executable: "/bin/sh", arguments: ["-c", "echo new; sleep 2"], cwd: nil)
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        audit.equal("old child's exit cannot disconnect the replacement", exits, 0)
        audit.check("old child's output cannot contaminate the replacement", lines.contains("new") && !lines.contains("old"))
        child.stop()
    }

    private static func throwsError<T>(_ operation: () throws -> T) -> Bool {
        do { _ = try operation(); return false } catch { return true }
    }
    private static func saved(_ result: CodeDocument.SaveResult) -> Bool { if case .saved = result { return true }; return false }
    private static func conflicted(_ result: CodeDocument.SaveResult) -> Bool { if case .conflicted = result { return true }; return false }
}

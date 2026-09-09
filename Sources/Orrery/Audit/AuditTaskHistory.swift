import AppKit
import Darwin

@MainActor
enum AuditTaskHistory {
    static func run(_ audit: Auditor) async {
        await idleRelease(audit)
        await Auditor.withTemporaryDirectory { directory in
            await taskHistory(audit, directory)
            await documentRecovery(audit, directory)
            await contextAttachments(audit, directory)
            await codexSteering(audit, directory)
            await resumeFallbacks(audit, directory)
        }
    }

    /// A restored task whose saved session no longer exists must reconnect with a fresh
    /// conversation and say so, instead of leaving the task dead. Scripted stand-ins answer
    /// each provider's protocol so no CLI, login or quota is involved.
    private static func resumeFallbacks(_ audit: Auditor, _ directory: URL) async {
        audit.section("Tasks — a saved session that cannot be resumed starts a fresh one")
        let project = directory.appendingPathComponent("resume-project")
        let scripts = directory.appendingPathComponent("resume-scripts")
        final class Log { var deltas = 0; var notes: [String] = []; var connected: [String] = []; var failures = 0; var disconnects = 0; var turns = 0 }
        func observe(_ backend: any AgentBackend) -> Log {
            let log = Log()
            backend.onEvent = { event in
                switch event {
                case let .note(text): log.notes.append(text)
                case let .connected(id): log.connected.append(id)
                case .failure: log.failures += 1
                case .disconnected: log.disconnects += 1
                case .turnFinished: log.turns += 1
                case .assistantDelta: log.deltas += 1
                default: break
                }
            }
            return log
        }
        do {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            func script(_ name: String, _ body: String) throws -> String {
                let url = scripts.appendingPathComponent(name)
                try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                return url.path
            }
            let claudeScript = try script("claude-fallback.sh", #"""
            case "$*" in *--resume*) printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"No conversation found with session ID: dead"}'; exit 1;; esac
            while IFS= read -r line; do
              case "$line" in *'"subtype":"initialize"'*) id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\1/'); printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\n' "$id";; esac
            done
            """#)
            let codexScript = try script("codex-fallback.sh", #"""
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -nE 's/.*"id":([0-9]+).*/\1/p')
              case "$line" in
                *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id";;
                *'"method":"model'*'list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"data":[]}}\n' "$id";;
                *'"method":"thread'*'resume"'*) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"thread not found"}}\n' "$id";;
                *'"method":"thread'*'start"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"thread":{"id":"fresh-thread"}}}\n' "$id";;
                *'"method":"account'*'read"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id";;
              esac
            done
            """#)
            let grokScript = try script("grok-fallback.sh", #"""
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -nE 's/.*"id":([0-9]+).*/\1/p')
              case "$line" in
                *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\n' "$id";;
                *'"method":"session'*'load"'*) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"unknown session"}}\n' "$id";;
                *'"method":"session'*'new"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"fresh-session"}}\n' "$id";;
              esac
            done
            """#)

            let claude = ClaudeBackend()
            claude.persistsSelection = false
            claude.executableForTest = claudeScript
            claude.sessionSettings.resumeSession = "dead-session"
            let claudeLog = observe(claude)
            await claude.start(project: project, autoApprove: true)
            audit.check("Claude explains the failed resume", claudeLog.notes.contains { $0.contains("could not be resumed") && $0.contains("No conversation found") }, claudeLog.notes.joined(separator: " | "))
            audit.check("Claude reconnects with a fresh session", claudeLog.connected.last == "ready" && claude.isRunning)
            audit.equal("a failed Claude resume is not reported as a turn", claudeLog.turns, 0)
            audit.equal("a failed Claude resume is not reported as a crash", claudeLog.disconnects, 0)
            audit.equal("no failure is shown when the Claude fallback succeeds", claudeLog.failures, 0)
            claude.stop()

            let codex = CodexBackend()
            codex.persistsSelection = false
            codex.executableForTest = codexScript
            codex.sessionSettings.resumeSession = "dead-thread"
            let codexLog = observe(codex)
            await codex.start(project: project, autoApprove: true)
            audit.check("Codex explains the failed resume", codexLog.notes.contains { $0.contains("could not be resumed") && $0.contains("thread not found") }, codexLog.notes.joined(separator: " | "))
            audit.equal("Codex connects to a fresh thread", codexLog.connected.last, "fresh-thread")
            audit.equal("no failure is shown when the Codex fallback succeeds", codexLog.failures, 0)
            codex.stop()

            let grok = GrokBackend()
            grok.persistsSelection = false
            grok.executableForTest = grokScript
            grok.sessionSettings.resumeSession = "dead-grok"
            let grokLog = observe(grok)
            await grok.start(project: project, autoApprove: true)
            audit.check("Grok explains the failed resume", grokLog.notes.contains { $0.contains("could not be resumed") }, grokLog.notes.joined(separator: " | "))
            audit.equal("Grok connects to a fresh session", grokLog.connected.last, "fresh-session")
            audit.equal("no failure is shown when the Grok fallback succeeds", grokLog.failures, 0)
            grok.stop()

            // A successful load replays the old conversation as updates before its result; the
            // app already restored that transcript, so the replay must not be appended again.
            let replayScript = try script("grok-replay.sh", #"""
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -nE 's/.*"id":([0-9]+).*/\1/p')
              case "$line" in
                *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\n' "$id";;
                *'"method":"session'*'load"'*)
                  printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"kept","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"REPLAYED"}}}}\n'
                  printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"kept"}}\n' "$id";;
                *'"method":"session'*'prompt"'*)
                  printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"kept","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"LIVE"}}}}\n'
                  printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id";;
              esac
            done
            """#)
            let replayed = GrokBackend()
            replayed.persistsSelection = false
            replayed.executableForTest = replayScript
            replayed.sessionSettings.resumeSession = "kept"
            let replayLog = observe(replayed)
            await replayed.start(project: project, autoApprove: true)
            audit.equal("a resumed Grok session keeps its id", replayLog.connected.last, "kept")
            audit.check("history replayed during session/load is dropped, not appended", replayLog.deltas == 0 && replayed.droppedReplayUpdates == 1, "deltas=\(replayLog.deltas) dropped=\(replayed.droppedReplayUpdates)")
            await replayed.send("hello")
            audit.equal("updates after the load still arrive", replayLog.deltas, 1)
            replayed.stop()
        } catch { audit.check("resume fallback audit completes", false, error.localizedDescription) }
    }

    /// `turn/steer` against a scripted app-server: the expected turn id is sent, a matching
    /// acknowledgement marks the draft as sent, and a stale or failed reply keeps the draft.
    private static func codexSteering(_ audit: Auditor, _ directory: URL) async {
        audit.section("Tasks — Codex steering protocol and draft safety")
        // Answers every turn/steer request with the turn id named in TURN, or an error when TURN is "error".
        // The wire escapes slashes ("turn\/steer"), so patterns skip the separator.
        let script = #"""
        while IFS= read -r line; do
          case "$line" in
            *turn*steer*)
              id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
              if [ "$TURN" = error ]; then printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"no active turn"}}\n' "$id"
              else printf '{"jsonrpc":"2.0","id":%s,"result":{"turnId":"%s"}}\n' "$id" "$TURN"; fi;;
          esac
        done
        """#
        func scripted(turn: String, active: String? = "turn-1") throws -> (CodexBackend, [JSON]) {
            let backend = CodexBackend()
            backend.persistsSelection = false
            final class Box { var wire: [JSON] = []; var notes: [String] = [] }
            let box = Box()
            backend.observeProtocolForTest { box.wire.append(JSON($0)) }
            backend.onEvent = { if case let .note(text) = $0 { box.notes.append(text) } }
            try backend.startScriptedForTest(executable: "/bin/sh", arguments: ["-c", script], environment: ["TURN": turn],
                                             threadID: "thread-1", turnID: active)
            return (backend, box.wire)
        }
        do {
            let idle = CodexBackend()
            var idleNotes: [String] = []
            idle.onEvent = { if case let .note(text) = $0 { idleNotes.append(text) } }
            audit.check("steering without an active turn is refused", await idle.steer("fix it") == false)
            audit.check("the refusal is explained", idleNotes.last?.contains("no active turn") == true)
            audit.check("Codex advertises steering", idle.supportsSteering)
            audit.check("Grok and Claude do not advertise steering", !GrokBackend().supportsSteering && !ClaudeBackend().supportsSteering)

            let (ok, _) = try scripted(turn: "turn-1")
            var wire: [JSON] = []
            ok.observeProtocolForTest { wire.append(JSON($0)) }
            audit.check("a matching acknowledgement reports success", await ok.steer("  fix the guard  "))
            let request = wire.last { $0["method"].string == "turn/steer" }
            audit.equal("steer names the expected active turn", request?["params"]["expectedTurnId"].string, "turn-1")
            audit.equal("steer sends the trimmed text as input", request?["params"]["input"].array.first?["text"].string, "fix the guard")
            audit.equal("steer targets the live thread", request?["params"]["threadId"].string, "thread-1")
            ok.stop()

            let (stale, _) = try scripted(turn: "turn-2")
            var staleNotes: [String] = []
            stale.onEvent = { if case let .note(text) = $0 { staleNotes.append(text) } }
            audit.check("an acknowledgement for another turn is not success", await stale.steer("late") == false)
            audit.check("a stale acknowledgement is explained", staleNotes.last?.contains("did not acknowledge") == true)
            stale.stop()

            let (failed, _) = try scripted(turn: "error")
            audit.check("a protocol error is not success", await failed.steer("nope") == false)
            failed.stop()

            // The model keeps the draft unless the backend confirmed the steer.
            let project = directory.appendingPathComponent("steer-project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let model = AppModel(trust: .forAudit)
            model.installed = [:]
            model.openProject(project)
            defer { model.shutdown() }
            model.provider = .codex
            let (live, _) = try scripted(turn: "turn-1")
            model.backends[.codex] = live
            model.update(.codex) { $0.inFlight = 1 }
            model.chatDrafts[.codex] = "steer this"
            await model.steerDraft()
            audit.equal("a confirmed steer clears the draft", model.chatDrafts[.codex], "")
            audit.check("a confirmed steer is shown in the transcript", model.states[.codex]?.entries.last?.text == "Steering: steer this")
            live.stop()
            let (rejecting, _) = try scripted(turn: "turn-9")
            model.backends[.codex] = rejecting
            model.chatDrafts[.codex] = "keep me"
            await model.steerDraft()
            audit.equal("a refused steer keeps the draft", model.chatDrafts[.codex], "keep me")
            audit.check("a refused steer adds nothing to the transcript", model.states[.codex]?.entries.last?.text == "Steering: steer this")
            rejecting.stop()
            model.chatAttachments[.codex] = [try MessageAttachment(name: "note", text: "x")]
            model.chatDrafts[.codex] = "with attachment"
            model.backends[.codex] = try scripted(turn: "turn-1").0
            await model.steerDraft()
            audit.equal("steering never sends attachments; the draft stays", model.chatDrafts[.codex], "with attachment")
            model.backends[.codex]?.stop()
        } catch { audit.check("Codex steering audit completes", false, error.localizedDescription) }
    }

    /// The composer's context menu at the model level: what each item attaches, what it says
    /// when there is nothing to attach, and that attaching never writes the source file.
    private static func contextAttachments(_ audit: Auditor, _ directory: URL) async {
        audit.section("Tasks — editor context attachments and provider handoff")
        let project = directory.appendingPathComponent("context-project")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("main.swift")
        let original = "let first = 1\nlet second = 2\n"
        try? original.write(to: file, atomically: true, encoding: .utf8)
        let model = AppModel(trust: .forAudit)
        model.installed = [:]   // no provider child may start from provider switches below
        model.openProject(project)
        defer { model.shutdown() }
        func text(_ attachment: MessageAttachment?) -> String { String(decoding: attachment?.data ?? Data(), as: UTF8.self) }
        model.attachEditorContext(selectionOnly: true)
        audit.equal("selected-code attachment needs an open file", model.taskNotice, "Open a text file first.")
        model.open(file: file)
        guard let document = model.documents.active else { audit.check("context fixture opens", false); return }
        model.attachEditorContext(selectionOnly: true)
        audit.equal("selected-code attachment needs a selection", model.taskNotice, "Select the code you want to discuss.")
        document.selection = NSRange(location: 14, length: 14)
        model.attachEditorContext(selectionOnly: true)
        let selected = model.chatAttachments[model.provider]?.last
        audit.check("selected code is attached with its file path",
                    selected?.name.hasSuffix("selected code") == true && text(selected).contains("let second = 2")
                        && !text(selected).contains("let first") && text(selected).contains(file.path))
        document.replaceAll(with: "let edited = 3\n")
        model.attachEditorContext(selectionOnly: false)
        let buffer = model.chatAttachments[model.provider]?.last
        audit.check("current-file attachment carries unsaved edits and says so",
                    buffer?.name.hasSuffix("unsaved buffer") == true && text(buffer).contains("let edited = 3")
                        && text(buffer).contains("Unsaved editor content"))
        audit.equal("attaching never writes the source file", try? String(contentsOf: file, encoding: .utf8), original)
        model.attachProblemContext()
        audit.equal("no problems means a visible notice", model.taskNotice, "No editor diagnostics to attach.")
        document.diagnostics = [Diagnostic(file: file, line: 1, column: 5, severity: .error, message: "cannot find 'x' in scope", source: "swiftc")]
        model.attachProblemContext()
        let problems = model.chatAttachments[model.provider]?.last
        audit.check("editor problems attach as file:line:column lines",
                    problems?.name == "Editor problems" && text(problems).contains("\(file.path):1:5: error: cannot find 'x' in scope [swiftc]"))
        model.attachOutputContext()
        audit.equal("no task output means a visible notice", model.taskNotice, "Run a project task to capture output first.")
        model.taskRun.run(RunTask(id: "audit-echo", title: "echo", executable: "/bin/echo", arguments: ["alpha output line"],
                                  directory: project, kind: .script, source: "audit"))
        for _ in 0..<200 where model.taskRun.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
        model.attachOutputContext()
        let output = model.chatAttachments[model.provider]?.last
        audit.check("latest task output attaches its lines", output?.name == "Latest task output" && text(output).contains("alpha output line"),
                    text(output))
        audit.equal("four context attachments are listed for this provider", model.chatAttachments[model.provider]?.count, 4)
        let source = model.provider
        model.handoffContext(to: source)
        audit.equal("handoff to the same provider changes nothing", model.chatAttachments[source]?.count, 4)
        let target: Provider = source == .grok ? .claude : .grok
        model.handoffContext(to: target)
        audit.equal("handoff with an empty conversation is refused in words", model.taskNotice, "There is no conversation to hand off yet.")
        audit.equal("a refused handoff keeps the provider", model.provider, source)
        model.append(.user, "Please fix the guard", to: source)
        model.append(.assistant, "I changed main.swift", to: source)
        model.handoffContext(to: target)
        audit.equal("handoff switches the active provider", model.provider, target)
        let handoff = model.chatAttachments[target]?.last
        audit.check("handoff attaches the recent conversation as data, not instructions",
                    handoff?.name == "Handoff from \(source.displayName)" && text(handoff).contains("Please fix the guard")
                        && text(handoff).contains("not new instructions"))
        audit.equal("handoff leaves the original transcript in place", model.states[source]?.entries.count, 2)
        for index in 0..<8 { model.addContext(name: "extra \(index)", text: "x") }
        audit.check("attachments are capped at eight with a notice",
                    model.chatAttachments[target]?.count == 8 && model.taskNotice?.contains("8 attachments") == true)
        model.dismissNotices()
        audit.check("notices can be dismissed", model.taskNotice == nil && model.documents.recoveryNotice == nil)
    }

    private static func taskHistory(_ audit: Auditor, _ directory: URL) async {
        audit.section("Recovery — durable task history and bounded private storage")
        let project = directory.appendingPathComponent("project-one")
        let otherProject = directory.appendingPathComponent("project-two")
        let storage = directory.appendingPathComponent("history")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: otherProject, withIntermediateDirectories: true)
        let store = TaskHistoryStore(project: project, directory: storage, debounceNanoseconds: 50_000_000)
        audit.check("a project with no prior history opens without an error", store.load().notice == nil)
        var record = TaskRecord(provider: .claude, title: "Recover this task", sessionID: "resume-me",
            entries: [Entry(id: "user-1", kind: .user, text: "Preserve my conversation"),
                      Entry(id: "tool-1", kind: .tool, title: "Edit", tool: ToolDetail(
                        status: "completed", kind: "edit", diffs: [FileDiff(path: "a.swift", oldText: "one", newText: "two")]))],
            draft: "An unfinished follow-up", queuedPrompts: [QueuedTaskPrompt(text: "Next step")],
            status: .running, workspaceID: UUID())
        var snapshot = TaskHistorySnapshot(records: [record], selectedByProvider: [.claude: record.id])
        audit.check("task snapshot flush completes", await store.flush(snapshot), store.lastError ?? "")
        let reopened = TaskHistoryStore(project: project, directory: storage).load()
        audit.equal("task transcript survives recreation", reopened.records.first?.entries, record.entries)
        audit.equal("an unfinished draft survives recreation", reopened.records.first?.draft, record.draft)
        audit.equal("provider session resume id survives recreation", reopened.records.first?.sessionID, "resume-me")
        audit.equal("interrupted work is restored as interrupted", reopened.records.first?.status, .interrupted)
        audit.equal("queued instructions are retained without being submitted", reopened.records.first?.queuedPrompts.first?.text, "Next step")
        audit.equal("the task working copy id is retained", reopened.records.first?.workspaceID, record.workspaceID)
        audit.equal("active task is restored for its own provider", reopened.selectedByProvider[.claude], record.id)
        audit.check("another project cannot see this history",
            TaskHistoryStore(project: otherProject, directory: storage).load().records.isEmpty)
        let attributes = try? FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let folderAttributes = try? FileManager.default.attributesOfItem(atPath: storage.path)
        audit.equal("task files are owner-only", (attributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        audit.equal("recovery folder is owner-only", (folderAttributes?[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        for index in 0..<20 {
            record.draft = "Latest draft \(index)"
            snapshot.records = [record]
            store.scheduleSave(snapshot)
        }
        audit.check("synchronous shutdown flush drains coalesced saves", store.flushNow(), store.lastError ?? "")
        audit.equal("coalescing preserves the latest value",
            TaskHistoryStore(project: project, directory: storage).load().records.first?.draft, "Latest draft 19")
        record.draft = "Background saved"
        snapshot.records = [record]
        store.scheduleSave(snapshot)
        try? await Task.sleep(nanoseconds: 160_000_000)
        _ = await store.flush()
        audit.equal("scheduled save runs without an explicit new snapshot",
            TaskHistoryStore(project: project, directory: storage).load().records.first?.draft, "Background saved")

        var tooMany = snapshot
        tooMany.records = (0...TaskHistoryStore.recordLimit).map {
            TaskRecord(provider: .grok, title: "Task \($0)")
        }
        audit.check("oversized task count is refused", !(await store.flush(tooMany)))
        audit.equal("a failed save preserves the previous complete history",
            TaskHistoryStore(project: project, directory: storage).load().records.first?.draft, "Background saved")
        _ = store.flushNow(snapshot)
        let goodData = (try? Data(contentsOf: store.fileURL)) ?? Data()

        let other = TaskHistoryStore(project: otherProject, directory: storage)
        try? goodData.write(to: other.fileURL)
        _ = chmod(other.fileURL.path, 0o600)
        audit.check("a copied history from another project is rejected", other.load().notice != nil)
        audit.check("invalid restored history is not overwritten by empty startup state", !other.flushNow(TaskHistorySnapshot()))
        audit.equal("invalid history remains available for manual recovery", try? Data(contentsOf: other.fileURL), goodData)

        try? Data("{broken-json".utf8).write(to: store.fileURL)
        _ = chmod(store.fileURL.path, 0o600)
        let corrupt = TaskHistoryStore(project: project, directory: storage)
        audit.check("corrupt JSON produces a visible recovery note", corrupt.load().notice != nil)
        audit.check("corrupt JSON is not silently replaced with an empty file", !corrupt.flushNow(TaskHistorySnapshot()))
        try? FileManager.default.removeItem(at: store.fileURL)

        let oversizedFD = Darwin.open(store.fileURL.path, O_CREAT | O_WRONLY | O_EXCL, 0o600)
        if oversizedFD >= 0 {
            _ = ftruncate(oversizedFD, off_t(TaskHistoryStore.byteLimit + 1))
            Darwin.close(oversizedFD)
        }
        audit.check("oversized disk history is rejected before reading it into memory",
            TaskHistoryStore(project: project, directory: storage).load().notice != nil)
        try? FileManager.default.removeItem(at: store.fileURL)

        let sentinel = directory.appendingPathComponent("do-not-touch.txt")
        try? "untouched".write(to: sentinel, atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: sentinel)
        let linkStore = TaskHistoryStore(project: project, directory: storage)
        audit.check("symbolic-link history is never read", linkStore.load().notice != nil)
        audit.check("symbolic-link history is never overwritten", !linkStore.flushNow(snapshot))
        audit.equal("a linked target remains untouched", try? String(contentsOf: sentinel, encoding: .utf8), "untouched")
        try? FileManager.default.removeItem(at: store.fileURL)

        let linkedDirectory = directory.appendingPathComponent("linked-history")
        try? FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: storage)
        let unsafe = TaskHistoryStore(project: project, directory: linkedDirectory)
        audit.check("a symbolic-link storage directory is rejected", !unsafe.flushNow(snapshot))
    }

    private static func documentRecovery(_ audit: Auditor, _ directory: URL) async {
        audit.section("Recovery — editor buffers, external conflicts and explicit discard")
        let project = directory.appendingPathComponent("editor-project")
        let storage = directory.appendingPathComponent("editor-recovery")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("draft.swift")
        let cleanFile = project.appendingPathComponent("other.swift")
        try? "let original = 1\n".write(to: file, atomically: true, encoding: .utf8)
        try? "let clean = true\n".write(to: cleanFile, atomically: true, encoding: .utf8)
        let first = DocumentStore()
        first.configure(project: project, storageDirectory: storage)
        guard let document = first.open(file) else { audit.check("recovery fixture opens", false); return }
        _ = first.open(cleanFile)
        first.activeID = document.id
        document.replaceAll(with: "let unsaved = 2\n")
        document.selection = NSRange(location: 4, length: 7)
        document.scrollOffset = 45
        audit.check("dirty editor recovery flush succeeds", await first.flushRecovery(), first.recoveryNotice ?? "")
        let second = DocumentStore()
        second.configure(project: project, storageDirectory: storage)
        audit.equal("all open file tabs are restored", second.documents.count, 2)
        audit.equal("the active file tab is restored", second.active?.name, "draft.swift")
        audit.equal("unsaved buffer survives store recreation", second.active?.text, "let unsaved = 2\n")
        audit.check("restored text remains dirty without a false disk conflict",
            second.active?.isDirty == true && second.active?.changedOnDisk == false)
        audit.equal("selection is restored", second.active?.selection, NSRange(location: 4, length: 7))
        audit.equal("recovery never writes the source file", try? String(contentsOf: file, encoding: .utf8), "let original = 1\n")

        // Hold the timestamp constant to prove content identity, rather than mtime alone,
        // protects another tool's newer changes.
        let oldStamp = CodeDocument.modificationDate(of: file)
        try? "let external = 3\n".write(to: file, atomically: true, encoding: .utf8)
        if let oldStamp { try? FileManager.default.setAttributes([.modificationDate: oldStamp], ofItemAtPath: file.path) }
        let conflictStore = DocumentStore()
        conflictStore.configure(project: project, storageDirectory: storage)
        audit.equal("newer disk data does not replace recovered unsaved text", conflictStore.active?.text, "let unsaved = 2\n")
        audit.check("a changed on-disk digest flags the recovery conflict", conflictStore.active?.changedOnDisk == true)
        if let recovered = conflictStore.active {
            audit.check("normal save refuses to overwrite newer disk content", !conflictStore.save(recovered))
        }
        audit.equal("the external change survives a refused save", try? String(contentsOf: file, encoding: .utf8), "let external = 3\n")
        conflictStore.confirmClose = { _ in .discard }
        audit.check("explicit discard approves shutdown", conflictStore.approveClosing())
        _ = conflictStore.flushRecoveryNow()
        let discarded = DocumentStore()
        discarded.configure(project: project, storageDirectory: storage)
        audit.check("explicit discard cannot resurrect dirty edits", !discarded.hasUnsavedChanges)
        audit.equal("discard reopens current source contents", discarded.active?.text, "let external = 3\n")

        if let afterDiscard = conflictStore.active {
            afterDiscard.replaceAll(with: "edited after cancelling another window close\n")
        }
        _ = conflictStore.flushRecoveryNow()
        let editedAgain = DocumentStore()
        editedAgain.configure(project: project, storageDirectory: storage)
        audit.check("editing after a discarded close decision enables recovery again", editedAgain.hasUnsavedChanges)
        editedAgain.confirmClose = { _ in .discard }
        if let restored = editedAgain.active { _ = editedAgain.close(restored) }
        let closed = DocumentStore()
        closed.configure(project: project, storageDirectory: storage)
        audit.check("an explicitly closed dirty tab stays closed", !closed.documents.contains { $0.name == "draft.swift" })

        // Each fixture owns an independent store, and only the chosen latest store writes.
        let missingStore = DocumentStore()
        missingStore.configure(project: project, storageDirectory: directory.appendingPathComponent("missing-recovery"))
        let missingDoc = missingStore.open(file)
        missingDoc?.replaceAll(with: "recovered after deletion\n")
        _ = missingStore.flushRecoveryNow()
        try? FileManager.default.removeItem(at: file)
        let missingReopened = DocumentStore()
        missingReopened.configure(project: project, storageDirectory: directory.appendingPathComponent("missing-recovery"))
        audit.equal("unsaved work survives an externally deleted source", missingReopened.active?.text, "recovered after deletion\n")
        audit.check("a deleted source is flagged for explicit conflict resolution", missingReopened.active?.changedOnDisk == true)
        _ = missingReopened.flushRecoveryNow()
        let missingAgain = DocumentStore()
        missingAgain.configure(project: project, storageDirectory: directory.appendingPathComponent("missing-recovery"))
        audit.equal("deleted-file recovery survives another restart", missingAgain.active?.text, "recovered after deletion\n")

        let outside = directory.appendingPathComponent("outside-private.txt")
        try? "outside private file".write(to: outside, atomically: true, encoding: .utf8)
        let maliciousStorage = directory.appendingPathComponent("malicious-recovery")
        let rawStore = PrivateProjectFile(project: project, directory: maliciousStorage, byteLimit: 64 * 1024 * 1024)
        let escape = DocumentRecoveryRecord(path: "../outside-private.txt", text: "bad", diskTarget: outside.path)
        try? rawStore.save(DocumentRecoverySnapshot(documents: [escape], activePath: escape.path))
        let escaped = DocumentStore()
        escaped.configure(project: project, storageDirectory: maliciousStorage)
        audit.check("tampered recovery paths cannot open files outside the project", escaped.documents.isEmpty)
        audit.check("unsafe recovery paths are explained", escaped.recoveryNotice?.contains("Skipped") == true)

        let liveLink = project.appendingPathComponent("link.swift")
        try? FileManager.default.createSymbolicLink(at: liveLink, withDestinationURL: outside)
        let symlinkRecord = DocumentRecoveryRecord(path: "link.swift", text: "bad", diskTarget: liveLink.path)
        try? rawStore.save(DocumentRecoverySnapshot(documents: [symlinkRecord]))
        let symlinked = DocumentStore()
        symlinked.configure(project: project, storageDirectory: maliciousStorage)
        audit.check("recovery refuses symbolic links even inside the project", symlinked.documents.isEmpty)
        audit.equal("outside content remains untouched", try? String(contentsOf: outside, encoding: .utf8), "outside private file")

        // Cancel fixture timers before the shared temporary directory is removed.
        for store in [first, second, conflictStore, discarded, editedAgain, closed,
                      missingStore, missingReopened, missingAgain, escaped, symlinked] {
            _ = store.flushRecoveryNow()
        }
    }
}

extension AuditTaskHistory {
    /// Idle children are released whether the session finished a turn or merely connected.
    static func idleRelease(_ audit: Auditor) async {
        audit.section("Tasks — idle sessions are released whether or not they ran a turn")
        let previous = AppModel.idleReleaseDelay
        AppModel.idleReleaseDelay = 0.1
        defer { AppModel.idleReleaseDelay = previous }
        await Auditor.withTemporaryDirectory { dir in
            let model = AppModel(trust: .forAudit)
            defer { model.shutdown() }
            model.openProject(dir)
            model.taskWorkflowEnabled = true
            model.configureTaskHistory(project: dir)
            model.provider = .grok
            let backend = ScriptedBackend(provider: .grok, scripts: [])
            backend.currentModel = "grok-4-audit"
            model.backends[.grok] = backend
            await backend.start(project: dir, autoApprove: false)
            audit.equal("the toolbar names the live session's model", model.modelToolbarLabel(for: .grok), "grok-4-audit")
            model.handle(.connected(sessionID: "idle-audit"), from: .grok)
            let deadline = Date().addingTimeInterval(3)
            while model.backends[.grok] != nil && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            audit.check("a session that connected but never ran a turn is released after the idle delay",
                        model.backends[.grok] == nil && backend.stopCount == 1,
                        "stopCount=\(backend.stopCount) store=\(model.historyStore != nil) idleTask=\(model.idleStopTasks[.grok] != nil)")
            audit.check("the state says the session is idle and will reconnect on send",
                        model.states[.grok]?.isConnected == false && (model.states[.grok]?.status ?? "").contains("reconnects"),
                        model.states[.grok]?.status ?? "nil")
            audit.equal("the toolbar keeps naming the model while the session is released", model.modelToolbarLabel(for: .grok), "grok-4-audit")

            let busy = ScriptedBackend(provider: .claude, scripts: [])
            model.provider = .claude
            model.backends[.claude] = busy
            await busy.start(project: dir, autoApprove: false)
            model.handle(.connected(sessionID: "busy-audit"), from: .claude)
            model.update(.claude) { $0.inFlight = 1 }
            try? await Task.sleep(nanoseconds: 400_000_000)
            audit.check("a session with a turn in flight is not released", model.backends[.claude] != nil && busy.stopCount == 0)
            model.update(.claude) { $0.inFlight = 0 }
        }

        audit.section("Tasks — placeholder sessions are never resumed and connection notes do not stack")
        audit.check("\"ready\", \"pending\" and empty ids are not resumable", !AppModel.isResumableSession("ready") && !AppModel.isResumableSession("pending") && !AppModel.isResumableSession("") && !AppModel.isResumableSession(nil))
        audit.check("a real session id is resumable", AppModel.isResumableSession("aab6fdf7-49db-4da4-99f8-64c02dcf20a1"))
        await Auditor.withTemporaryDirectory { dir in
            let model = AppModel(trust: .forAudit)
            defer { model.shutdown() }
            model.openProject(dir)
            model.taskWorkflowEnabled = true
            model.configureTaskHistory(project: dir)
            model.provider = .claude
            model.handle(.connected(sessionID: "real-session"), from: .claude)
            _ = model.taskSnapshot()
            audit.check("a session that only connected is not saved for resume", model.taskRecords.first { $0.provider == .claude }?.sessionID == nil,
                        model.taskRecords.first { $0.provider == .claude }?.sessionID ?? "nil")
            model.handle(.turnFinished(stopReason: "end_turn", costUSD: nil), from: .claude)
            model.handle(.connected(sessionID: "ready"), from: .claude)
            audit.equal("a placeholder reported after a real id does not replace it", model.states[.claude]?.sessionID, "real-session")
            _ = model.taskSnapshot()
            audit.equal("a session with a finished turn is saved for resume", model.taskRecords.first { $0.provider == .claude }?.sessionID, "real-session")
            model.update(.claude) { $0.inFlight = 1 }
            model.handle(.connected(sessionID: "named-at-first-turn"), from: .claude)
            model.update(.claude) { $0.inFlight = 0 }
            _ = model.taskSnapshot()
            audit.equal("a session named while its first turn runs is saved for resume", model.taskRecords.first { $0.provider == .claude }?.sessionID, "named-at-first-turn")
            model.handle(.sessionDropped(reason: "audit"), from: .claude)
            audit.check("a failed resume drops the saved id", model.states[.claude]?.sessionID == nil)
            model.handle(.connected(sessionID: "ready"), from: .claude)
            audit.equal("a fresh session's placeholder is held in memory", model.states[.claude]?.sessionID, "ready")
            _ = model.taskSnapshot()
            audit.check("the placeholder is never saved for resume", model.taskRecords.first { $0.provider == .claude }?.sessionID == nil,
                        model.taskRecords.first { $0.provider == .claude }?.sessionID ?? "nil")
            model.append(.system, "Claude uses its default permission rules. Tools needing approval appear in this window.", to: .claude)
            model.append(.user, "hello", to: .claude)
            model.append(.assistant, "hi", to: .claude)
            model.append(.system, "Turn ended: end_turn", to: .claude)
            model.handle(.connected(sessionID: "ready"), from: .claude)
            model.append(.system, "Claude uses its default permission rules. Tools needing approval appear in this window.", to: .claude)
            model.append(.system, "The saved Claude session could not be resumed: audit. Starting a new conversation.", to: .claude)
            model.append(.system, "Codex usage: 16% of the current window used", to: .claude)
            let before = model.states[.claude]?.entries.count ?? 0
            model.trimConnectionBookkeeping(for: .claude)
            let after = model.states[.claude]?.entries ?? []
            audit.check("a new connection replaces the previous connection's trailing notes, usage lines included", after.count == before - 4 && after.last?.text == "Turn ended: end_turn",
                        "\(before) → \(after.count), last = \(after.last?.text ?? "nil")")
            audit.check("notes that precede real work are kept", after.contains { $0.kind == .user && $0.text == "hello" } && after.first.map(AppModel.isConnectionBookkeeping) == true)
            model.trimConnectionBookkeeping(for: .claude)
            audit.equal("trimming stops at the first entry that is not bookkeeping", model.states[.claude]?.entries.count, after.count)
        }
        let claudeReason = ClaudeBackend.startupReason(JSON(["type": "result", "subtype": "error_during_execution", "errors": ["Failed to authenticate: OAuth session expired"]]))
        audit.check("a startup failure names the CLI's error, not only its subtype", claudeReason?.contains("Failed to authenticate") == true, claudeReason ?? "nil")
        audit.equal("a bare result still reports its subtype", ClaudeBackend.startupReason(JSON(["type": "result", "subtype": "error_during_execution"])), "error_during_execution")
    }
}

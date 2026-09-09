import Foundation

/// Agent plumbing: the approval queue, per-provider transcripts, turn bookkeeping, and the
/// recovery path for a turn that never reports completion. Runs against a stub backend, so
/// nothing is spent. File-safety checks live in `AuditWorkspace`.
@MainActor
enum AuditApp {
    static func run(_ audit: Auditor) async {
        audit.section("App — approvals, turns, providers")
        for scratch in [NSTemporaryDirectory() + "x", "/private/var/folders/ab/x",
                        "/private/tmp/session/x", "/tmp/x"] {
            audit.check("a scratch path is never remembered as the project (\(scratch))",
                        AppModel.isScratchPath(scratch))
        }
        audit.check("a real path is remembered",
                    !AppModel.isScratchPath(NSHomeDirectory() + "/Projects/Orrery"))
        await Auditor.withTemporaryDirectory { dir in
            let model = AppModel(trust: .forAudit)
            model.openProject(dir)

            // Concurrent approvals must queue instead of dropping. Two agents — or one agent
            // asking about two commands — can have approvals in flight at once, and losing one
            // hangs that agent forever.
            var answered: [String] = []
            model.permissionQueue = []
            for name in ["first", "second"] {
                let request = PermissionRequest(
                    title: name, detail: "", options: [],
                    reply: { _ in answered.append(name) })
                model.permissionQueue.append(
                    PermissionRequest(title: request.title, detail: "", options: [],
                                      reply: { choice in
                                          request.reply(choice)
                                          model.permissionQueue.removeFirst()
                                      }))
            }
            audit.check("both approvals are queued", model.permissionQueue.count == 2)
            model.pendingPermission?.reply("accept")
            audit.check("answering the first surfaces the second",
                        model.pendingPermission?.title == "second")
            model.pendingPermission?.reply("accept")
            audit.check("every approval got an answer", answered == ["first", "second"],
                        answered.joined(separator: ","))
            audit.check("queue drains", model.permissionQueue.isEmpty)

            // A turn can end with no completion event — the CLI is killed, a pipe breaks, a
            // protocol message is dropped. The window must not sit on "Working…" forever.
            AppModel.cancelGraceSeconds = 1
            let stub = StubBackend()
            model.backends[model.provider] = stub
            await model.send("this turn will never come back")
            audit.check("turn marked busy", model.isBusy)
            model.cancel()
            audit.check("the stub received the cancel", stub.cancelled)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            audit.check("a stuck turn recovers locally", !model.isBusy)

            // Each provider keeps its own conversation across switches. Headless runs always
            // start on Grok regardless of the user's saved choice.
            audit.equal("a headless run ignores the saved provider preference", AppModel(trust: .forAudit).provider, .grok)
            model.backends[.grok] = StubBackend()
            model.provider = .grok
            await model.send("grok side")
            let grokCount = model.entries.count
            model.provider = .claude
            let claudeCount = model.entries.count
            model.provider = .grok
            audit.check("switching providers preserves each transcript",
                        grokCount > 0 && claudeCount == 0 && model.entries.count == grokCount,
                        "grok=\(grokCount) claude=\(claudeCount) back=\(model.entries.count)")

            model.provider = .grok
            await model.send("something to clear")
            let before = model.entries.count
            await model.newSession()
            audit.check("new session clears the transcript",
                        before > 0 && model.entries.isEmpty,
                        "before=\(before) after=\(model.entries.count)")

            // Grok queues prompts, so more than one turn can be in flight. A boolean busy flag
            // would let the first completion hide the Stop button while work is still running.
            model.backends[.grok] = StubBackend()
            await model.newSession()
            await model.send("first")
            await model.send("second")
            audit.check("two in-flight turns are both tracked", model.isBusy)
            model.handleForTest(.turnFinished(stopReason: "end_turn", costUSD: nil), from: .grok)
            audit.check("still busy after the first completes", model.isBusy)
            model.handleForTest(.turnFinished(stopReason: "end_turn", costUSD: nil), from: .grok)
            audit.check("idle after the second completes", !model.isBusy)

            audit.section("App — agent edits under an open tab")
            let watched = dir.appendingPathComponent("watched.txt")
            try? "before\n".write(to: watched, atomically: true, encoding: .utf8)
            model.open(file: watched)
            audit.check("the file opened in a tab", model.documents.active?.url == watched)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: watched.path)
            try? "after the agent\n".write(to: watched, atomically: true, encoding: .utf8)
            audit.check("not flagged before the turn ends",
                        model.documents.active?.changedOnDisk == false)

            // Auto-reload on: a clean tab silently picks up the agent's edit.
            model.autoReloadAfterTurns = true
            model.handleForTest(.turnFinished(stopReason: "end_turn", costUSD: nil),
                                from: model.provider)
            audit.equal("a clean tab is refreshed when the turn ends",
                        model.documents.active?.text, "after the agent\n")

            // Auto-reload must never discard the user's own unsaved edits.
            model.documents.active?.storage.replaceCharacters(
                in: NSRange(location: 0, length: 0), with: "my own work\n")
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: watched.path)
            try? "agent again\n".write(to: watched, atomically: true, encoding: .utf8)
            model.handleForTest(.turnFinished(stopReason: "end_turn", costUSD: nil),
                                from: model.provider)
            audit.check("a dirty tab keeps the user's text",
                        model.documents.active?.text.hasPrefix("my own work") == true,
                        model.documents.active?.text ?? "")
            audit.check("…and is flagged as changed on disk",
                        model.documents.active?.changedOnDisk == true)
        }
    }
}

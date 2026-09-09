import Darwin
import Foundation

/// Section 7a — LSP plumbing. Protocol checks run against a local framer and a silent
/// process; handshake and `publishDiagnostics` run against the real `sourcekit-lsp` and
/// `clangd` on this machine. Every wait is time-boxed.
@MainActor
enum AuditLSP {

    static func run(_ audit: Auditor) async {
        audit.section("LSP — death handling survives Foundation's status race")
        do {
            // A never-launched Process is the deterministic stand-in for the race window in
            // which `isRunning` is false but `terminationStatus` throws. The pre-fix code
            // read the status here and took the app down with SIGABRT — four crash logs on
            // 2026-08-31. This check CRASHES the audit, not just fails, if that read returns.
            let client = LSPClient()
            var reported: Int32? = nil
            client.onExit = { code in reported = code }
            client.auditSimulateEOFDeath(with: Process())
            try? await Task.sleep(nanoseconds: 100_000_000)
            audit.equal("an EOF death with no readable status reports -1, not a crash",
                        reported, -1)
        }

        framer(audit)
        mapping(audit)
        await timeout(audit)
        await plumbingRaces(audit)
        await serverRequests(audit)
        honestyWithoutServer(audit)
        await sourcekit(audit)
        await clangd(audit)
    }

    /// Hosted CI runners index Swift several times slower than a developer Mac; the budgets
    /// stretch there and stay tight everywhere else.
    private static let budgetFactor: Double = ProcessInfo.processInfo.environment["CI"] == nil ? 1 : 4

    @discardableResult
    private static func waitUntil(_ timeout: Double,
                                  _ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout * budgetFactor)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    // MARK: - Framer

    private static func framer(_ audit: Auditor) {
        audit.section("LSP — Content-Length framer")

        func bodies(_ chunks: [Data]) -> [Data] {
            var framer = LSPFramer()
            var out: [Data] = []
            for chunk in chunks {
                for event in framer.ingest(chunk) {
                    if case let .message(body) = event { out.append(body) }
                }
            }
            return out
        }

        let one: [String: Any] = ["jsonrpc": "2.0", "id": 1, "result": ["ok": true]]
        let framed = (try? LSPFramer.frame(one)) ?? Data()
        audit.check("a complete message in one read yields one body",
                    bodies([framed]).count == 1)

        let splitAt = min(12, max(1, framed.count / 2))
        let split = bodies([framed.prefix(splitAt), framed.dropFirst(splitAt)])
        audit.check("a header split across reads still parses",
                    split.count == 1,
                    "got \(split.count) message(s)")

        let bodySplitAt = framed.count - 4
        let splitBody = bodies([Data(framed.prefix(bodySplitAt)), Data(framed.dropFirst(bodySplitAt))])
        audit.check("a body split across reads still parses",
                    splitBody.count == 1,
                    "got \(splitBody.count) message(s)")

        let two = (try? LSPFramer.frame(["jsonrpc": "2.0", "method": "a"])) ?? Data()
        let packed = framed + two
        audit.check("two messages in one read both surface",
                    bodies([packed]).count == 2,
                    "got \(bodies([packed]).count)")

        // A payload containing newlines must stay one message — this is why we do not
        // reuse LineProcess / NDJSON.
        let withNewlines: [String: Any] = [
            "jsonrpc": "2.0", "method": "window/logMessage",
            "params": ["type": 3, "message": "line 1\nline 2\n"],
        ]
        let nlFramed = (try? LSPFramer.frame(withNewlines)) ?? Data()
        let nlBodies = bodies([nlFramed])
        let nlJSON = nlBodies.first.flatMap { JSON(data: $0) }
        audit.check("a body containing newlines is still one message",
                    nlBodies.count == 1
                    && (nlJSON?["params"]["message"].string ?? "").contains("line 1\nline 2"),
                    "messages=\(nlBodies.count)")

        let utfText = "café😀"
        let utfObj: [String: Any] = ["jsonrpc": "2.0", "method": "x", "params": ["text": utfText]]
        let utfFramed = (try? LSPFramer.frame(utfObj)) ?? Data()
        // Split in the middle of `é` (UTF-8 c3 a9) if it is present in the body.
        var utfSplitAt = utfFramed.count / 2
        if let bodyStart = utfFramed.firstRange(of: Data("\r\n\r\n".utf8)) {
            let body = utfFramed[bodyStart.upperBound...]
            if let é = body.firstRange(of: Data([0xC3, 0xA9])) {
                utfSplitAt = utfFramed.distance(from: utfFramed.startIndex, to: é.lowerBound) + 1
            }
        }
        let utfBodies = bodies([Data(utfFramed.prefix(utfSplitAt)),
                                Data(utfFramed.dropFirst(utfSplitAt))])
        let recovered = utfBodies.first.flatMap { JSON(data: $0) }?["params"]["text"].string
        audit.check("a body with multi-byte UTF-8 survives a split inside a codepoint",
                    utfBodies.count == 1 && recovered == utfText,
                    "got \(String(reflecting: recovered))")

        let typed: [String: Any] = ["jsonrpc": "2.0", "id": 2, "result": NSNull()]
        let typedBody = (try? JSONSerialization.data(withJSONObject: typed)) ?? Data()
        var typedFrame = Data("Content-Length: \(typedBody.count)\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n".utf8)
        typedFrame.append(typedBody)
        let typedBodies = bodies([typedFrame])
        audit.check("Content-Type (and other unknown headers) are ignored",
                    typedBodies.count == 1,
                    "got \(typedBodies.count)")
        if let parsed = typedBodies.first.flatMap({ JSON(data: $0) }) {
            audit.check("a JSON-RPC null result is a response, not a dropped message",
                        (parsed.raw as? [String: Any])?.keys.contains("result") == true
                        && parsed["id"].int == 2)
        } else {
            audit.check("a JSON-RPC null result is a response, not a dropped message", false,
                        "no body")
        }
    }

    // MARK: - Mapping

    private static func mapping(_ audit: Auditor) {
        audit.section("LSP — diagnostics mapping")
        let file = URL(fileURLWithPath: "/tmp/Mapped.swift")
        let payload = JSON([
            "uri": "file:///tmp/Mapped.swift",
            "diagnostics": [[
                "range": [
                    "start": ["line": 2, "character": 4],
                    "end": ["line": 2, "character": 9],
                ],
                "severity": 1,
                "message": "cannot convert value",
            ], [
                "range": [
                    "start": ["line": 5, "character": 0],
                    "end": ["line": 5, "character": 1],
                ],
                "severity": 2,
                "message": "unused",
            ], [
                "range": [
                    "start": ["line": 7, "character": 1],
                    "end": ["line": 8, "character": 0],
                ],
                "severity": 4,
                "message": "note",
            ]],
        ] as [String: Any])
        let mapped = LSPMapping.diagnostics(from: payload, file: file, source: "sourcekit-lsp")
        audit.equal("LSP 0-based line 2 becomes Diagnostic line 3", mapped.first?.line, 3)
        audit.equal("LSP 0-based character 4 becomes column 5", mapped.first?.column, 5)
        audit.equal("same-line range becomes a UTF-16 length", mapped.first?.length, 5)
        audit.equal("severity 1 is error", mapped.first?.severity, Diagnostic.Severity.error)
        audit.equal("severity 2 is warning", mapped.dropFirst().first?.severity,
                    Diagnostic.Severity.warning)
        audit.equal("severity 3–4 is info", mapped.last?.severity, Diagnostic.Severity.info)
        audit.equal("source is the server name", mapped.first?.source, "sourcekit-lsp")

        let clang = LSPMapping.diagnostics(from: payload, file: file, source: "clangd")
        audit.equal("clangd diagnostics name clangd", clang.first?.source, "clangd")

        let text = "abcdef"
        let items = LSPMapping.completions(from: JSON([
            "isIncomplete": false,
            "items": [[
                "label": "count",
                "kind": 6,
                "insertText": "count",
                "textEdit": [
                    "range": [
                        "start": ["line": 0, "character": 1],
                        "end": ["line": 0, "character": 4],
                    ],
                    "newText": "count",
                ],
            ]],
        ] as [String: Any]), text: text)
        audit.equal("CompletionList.items is parsed", items.first?.label, "count")
        audit.equal("completion kind 6 is variable", items.first?.kind, "variable")
        audit.check("textEdit becomes a UTF-16 NSRange in the buffer",
                    items.first?.editRange == NSRange(location: 1, length: 3),
                    "got \(String(describing: items.first?.editRange))")

        let arrayItems = LSPMapping.completions(from: JSON([
            ["label": "x", "insertText": "x"],
        ] as [[String: Any]]), text: "x")
        audit.equal("a bare CompletionItem array is parsed", arrayItems.first?.label, "x")
        audit.check("insertText-only items have no editRange",
                    arrayItems.first?.editRange == nil)

        let mixed = LSPMapping.completions(from: JSON([
            "items": [[
                "label": "count",
                "insertText": "WRONG",
                "textEdit": [
                    "range": [
                        "start": ["line": 0, "character": 1],
                        "end": ["line": 0, "character": 4],
                    ],
                    "newText": "RIGHT",
                ],
            ]],
        ] as [String: Any]), text: text)
        audit.equal("textEdit.newText overrides insertText when both are present",
                    mixed.first?.insertText, "RIGHT")

        audit.equal("MarkupContent hover",
                    LSPMapping.hoverText(from: JSON([
                        "contents": ["kind": "markdown", "value": "Hello"],
                    ] as [String: Any])), "Hello")
        audit.equal("legacy string hover",
                    LSPMapping.hoverText(from: JSON(["contents": "Hi"] as [String: Any])), "Hi")
        audit.equal("MarkedString array hover",
                    LSPMapping.hoverText(from: JSON([
                        "contents": [["language": "swift", "value": "Int"]],
                    ] as [String: Any])), "Int")

        let loc = LSPMapping.definition(from: JSON([
            "uri": "file:///tmp/Mapped.swift",
            "range": ["start": ["line": 9, "character": 2],
                      "end": ["line": 9, "character": 5]],
        ] as [String: Any]))
        audit.equal("Location definition is 1-based", loc?.line, 10)
        audit.equal("Location definition column is 1-based", loc?.column, 3)

        let locArray = LSPMapping.definition(from: JSON([[
            "uri": "file:///tmp/Mapped.swift",
            "range": ["start": ["line": 0, "character": 0],
                      "end": ["line": 0, "character": 1]],
        ]] as [[String: Any]]))
        audit.equal("Location[] uses the first entry", locArray?.line, 1)

        let link = LSPMapping.definition(from: JSON([[
            "targetUri": "file:///tmp/Mapped.swift",
            "targetRange": ["start": ["line": 3, "character": 0],
                            "end": ["line": 3, "character": 1]],
            "targetSelectionRange": ["start": ["line": 4, "character": 6],
                                     "end": ["line": 4, "character": 7]],
        ]] as [[String: Any]]))
        audit.equal("LocationLink[] uses targetSelectionRange", link?.line, 5)
        audit.equal("LocationLink column is 1-based", link?.column, 7)
    }

    // MARK: - Timeout

    private static func timeout(_ audit: Auditor) async {
        audit.section("LSP — request deadlines")
        let client = LSPClient()
        do {
            try client.start(executable: "/bin/sleep", arguments: ["30"])
        } catch {
            audit.check("a request whose reply never comes times out", false,
                        "could not spawn /bin/sleep: \(error)")
            return
        }
        let start = Date()
        do {
            _ = try await client.request("initialize", [:], deadline: 0.4)
            audit.check("a request whose reply never comes times out", false,
                        "the request returned a result")
        } catch let error as LSPError {
            let elapsed = Date().timeIntervalSince(start)
            if case .timedOut = error {
                audit.check("a request whose reply never comes times out", true)
                audit.check("the timeout fires near its deadline rather than hanging",
                            elapsed >= 0.3 && elapsed < 2.5,
                            String(format: "elapsed %.2fs", elapsed))
            } else {
                audit.check("a request whose reply never comes times out", false, "\(error)")
            }
        } catch {
            audit.check("a request whose reply never comes times out", false, "\(error)")
        }
        // A second resume of the same continuation would trap. This just has to return.
        do {
            _ = try await client.request("shutdown", [:], deadline: 0.3)
            audit.check("a second timed-out request does not trap", true)
        } catch {
            audit.check("a second timed-out request does not trap", true)
        }
        client.stop()

        // A wedged server that stops reading stdin fills the pipe. Writes must not run
        // on the main actor or the request deadline cannot fire.
        let blocked = LSPClient()
        do {
            try blocked.start(executable: "/bin/sleep", arguments: ["30"])
        } catch {
            audit.check("a full stdin pipe does not prevent the request deadline firing", false,
                        "\(error)")
        }
        if blocked.isRunning {
            blocked.notify("window/logMessage",
                           ["message": String(repeating: "x", count: 400_000)])
            let blockedStart = Date()
            do {
                _ = try await blocked.request("initialize", [:], deadline: 0.4)
                audit.check("a full stdin pipe does not prevent the request deadline firing", false,
                            "the request returned a result")
            } catch let error as LSPError {
                let elapsed = Date().timeIntervalSince(blockedStart)
                if case .timedOut = error {
                    audit.check("a full stdin pipe does not prevent the request deadline firing",
                                elapsed < 2.5,
                                String(format: "elapsed %.2fs", elapsed))
                } else {
                    audit.check("a full stdin pipe does not prevent the request deadline firing",
                                false, "\(error)")
                }
            } catch {
                audit.check("a full stdin pipe does not prevent the request deadline firing",
                            false, "\(error)")
            }
            blocked.stop()
        }

        // An in-flight request must fail because the child died, not because the manager
        // later short-circuits on a missing session.
        let pendingClient = LSPClient()
        do {
            try pendingClient.start(executable: "/bin/sleep", arguments: ["30"])
        } catch {
            audit.check("an in-flight request fails when the child is killed", false, "\(error)")
        }
        if let pid = pendingClient.processIdentifier {
            let t0 = Date()
            let task = Task { @MainActor in
                try await pendingClient.request("anything", [:], deadline: 8)
            }
            _ = await waitUntil(1) { pendingClient.hasPendingRequest }
            kill(pid, SIGKILL)
            do {
                _ = try await task.value
                audit.check("an in-flight request fails when the child is killed", false,
                            "the request returned a result")
            } catch {
                let elapsed = Date().timeIntervalSince(t0)
                audit.check("an in-flight request fails when the child is killed",
                            elapsed < 2.5,
                            String(format: "elapsed %.2fs — \(error)", elapsed))
            }
        }
        pendingClient.stop()

        // Independent Tasks hopping to the main actor can reorder chunks. A response
        // already on stdout must be applied before a queued EOF fails the request.
        let ordered = LSPClient()
        do {
            try ordered.start(executable: "/bin/sleep", arguments: ["30"])
        } catch {
            audit.check("a response is applied before a queued stdout EOF (seam: inbound FIFO)",
                        false, "\(error)")
        }
        if ordered.isRunning {
            let reply = (try? LSPFramer.frame(["jsonrpc": "2.0", "id": 1,
                                               "result": ["ok": true]] as [String: Any])) ?? Data()
            let replyTask = Task { @MainActor in
                try await ordered.request("foo", [:], deadline: 2)
            }
            _ = await waitUntil(1) { ordered.hasPendingRequest }
            ordered.enqueueStdout(reply)
            ordered.enqueueEOF()
            do {
                let result = try await replyTask.value
                audit.check("a response is applied before a queued stdout EOF (seam: inbound FIFO)",
                            result["ok"].bool == true || (result["ok"].raw as? Bool) == true,
                            result.compact)
            } catch {
                audit.check("a response is applied before a queued stdout EOF (seam: inbound FIFO)",
                            false, "\(error)")
            }
            ordered.stop()
        }

        // stdout EOF can race ahead of Process.terminationHandler. The client must not
        // read terminationStatus while Foundation still thinks the task is running.
        let exiting = LSPClient()
        var exitSaw = false
        exiting.onExit = { _ in exitSaw = true }
        do {
            try exiting.start(executable: "/bin/sleep", arguments: ["0.2"])
        } catch {
            audit.check("a child that exits on its own does not trap", false, "\(error)")
            return
        }
        let sawExit = await waitUntil(2) { exitSaw }
        audit.check("a child that exits on its own fires onExit rather than trapping",
                    sawExit,
                    sawExit ? "" : "onExit was not called within 2s")
        exiting.stop()
    }

    // MARK: - Plumbing races

    private static func plumbingRaces(_ audit: Auditor) async {
        audit.section("LSP — plumbing races")

        // terminationHandler and unread stdout arrive on different paths. A child that
        // writes a framed reply and _exit()s immediately is the production race; the
        // delayed stdout read forces termination to drain leftover bytes first.
        let python = Executables.find(["/usr/bin/python3", "/opt/homebrew/bin/python3"],
                                      orNamed: "python3")
        if let python {
            let script = """
            import os, json
            buf = b''
            while not (buf.endswith(b'\\r\\n\\r\\n') or buf.endswith(b'\\n\\n')):
                ch = os.read(0, 1)
                if not ch:
                    break
                buf += ch
            n = 0
            for line in buf.split(b'\\n'):
                low = line.lower().strip()
                if low.startswith(b'content-length:'):
                    n = int(low.split(b':', 1)[1].strip() or 0)
            body = b''
            while len(body) < n:
                chunk = os.read(0, n - len(body))
                if not chunk:
                    break
                body += chunk
            rid = 1
            if body:
                try:
                    rid = json.loads(body.decode()).get('id', 1)
                except Exception:
                    pass
            payload = json.dumps({"jsonrpc": "2.0", "id": rid, "result": {"ok": True}}).encode()
            os.write(1, ('Content-Length: %d\\r\\n\\r\\n' % len(payload)).encode() + payload)
            os._exit(0)
            """
            let racing = LSPClient()
            racing.auditDelayStdoutRead = 0.15
            do {
                try racing.start(executable: python, arguments: ["-c", script])
                let replyTask = Task { @MainActor in
                    try await racing.request("foo", [:], deadline: 3)
                }
                do {
                    let result = try await replyTask.value
                    let ok = result["ok"].bool == true || (result["ok"].raw as? Bool) == true
                    audit.check("a late reply survives child exit (seam: delayed stdout read)",
                                ok, result.compact)
                } catch {
                    audit.check("a late reply survives child exit (seam: delayed stdout read)",
                                false, "\(error)")
                }
                racing.stop()
            } catch {
                audit.check("a late reply survives child exit (seam: delayed stdout read)",
                            false, "\(error)")
            }
        } else {
            audit.check("a late reply survives child exit (seam: delayed stdout read)",
                        false, "python3 is not installed")
        }

        // A wedged server that stopped reading stdin fills the pipe. shutdown() must
        // still SIGTERM/SIGKILL and return — it must not await the blocked writer.
        let wedged = LSPClient()
        do {
            try wedged.start(executable: "/bin/sleep", arguments: ["30"])
        } catch {
            audit.check("shutdown returns in bounded time when the stdin pipe is full",
                        false, "\(error)")
            audit.check("shutdown reaps a wedged child that is not reading stdin",
                        false, "\(error)")
        }
        if let pid = wedged.processIdentifier {
            wedged.notify("window/logMessage",
                          ["message": String(repeating: "x", count: 400_000)])
            final class Flag { var done = false }
            let flag = Flag()
            let t0 = Date()
            Task { @MainActor in
                await wedged.shutdown()
                flag.done = true
            }
            let returned = await waitUntil(3.5) { flag.done }
            let elapsed = Date().timeIntervalSince(t0)
            audit.check("shutdown returns in bounded time when the stdin pipe is full",
                        returned && elapsed < 3.5,
                        String(format: "returned=%@ elapsed %.2fs", String(describing: returned), elapsed))
            if !returned {
                wedged.stop()
            }
            let gone = await waitUntil(2) { kill(pid, 0) != 0 }
            audit.check("shutdown reaps a wedged child that is not reading stdin",
                        returned && gone,
                        returned
                            ? (gone ? "" : "pid \(pid) still alive")
                            : "shutdown did not return; child not reaped by shutdown()")
            if !gone { kill(pid, SIGKILL) }
        }

        await Auditor.withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("Race.swift")
            try? "let x = 1\n".write(to: url, atomically: true, encoding: .utf8)
            let root = dir.resolvingSymlinksInPath().standardizedFileURL
            let doc = CodeDocument(url: url)

            // Old waiter must not erase a replacement start task after shutdown+restart.
            let waiterManager = LSPManager()
            waiterManager.executableOverride = { _ in "/bin/sleep" }
            waiterManager.auditProcessArguments = ["30"]
            waiterManager.auditSkipHandshake = true
            var holdFirst = true
            waiterManager.auditBeforeStartSession = {
                while holdFirst {
                    try? await Task.sleep(nanoseconds: 15_000_000)
                }
            }
            let first = Task { await waiterManager.ensureOpen(doc, root: root) }
            _ = await waitUntil(2) { waiterManager.hasActiveOrStartingServer }
            await waiterManager.shutdown()
            var holdSecond = true
            waiterManager.auditBeforeStartSession = {
                while holdSecond {
                    try? await Task.sleep(nanoseconds: 15_000_000)
                }
            }
            let second = Task { await waiterManager.ensureOpen(doc, root: root) }
            _ = await waitUntil(2) {
                waiterManager.auditHasStartingTask(language: Languages.swift, root: root)
            }
            holdFirst = false
            await first.value
            audit.check("a waiter does not clear a newer start task (seam: held startSession)",
                        waiterManager.auditHasStartingTask(language: Languages.swift, root: root),
                        waiterManager.auditHasStartingTask(language: Languages.swift, root: root)
                            ? "" : "old waiter niled the replacement start slot")
            await waiterManager.shutdown()
            holdSecond = false
            await second.value
            waiterManager.auditBeforeStartSession = nil
            await waiterManager.shutdown()

            // An old handshake stored its session, then shutdown+restart stored a
            // replacement. Completing initialize (epoch mismatch or failed request)
            // must not nil the replacement.
            let handshakeManager = LSPManager()
            handshakeManager.executableOverride = { _ in "/bin/sleep" }
            handshakeManager.auditProcessArguments = ["30"]
            var holdAfterStore = true
            var stored = false
            handshakeManager.auditAfterSessionStored = {
                stored = true
                while holdAfterStore {
                    try? await Task.sleep(nanoseconds: 15_000_000)
                }
            }
            let firstHandshake = Task { await handshakeManager.ensureOpen(doc, root: root) }
            _ = await waitUntil(2) { stored }
            await handshakeManager.shutdown()
            handshakeManager.auditSkipHandshake = true
            await handshakeManager.ensureOpen(doc, root: root)
            let handshakeReplacement = handshakeManager.auditSessionIdentity(for: doc)
            holdAfterStore = false
            await firstHandshake.value
            let handshakeAfter = handshakeManager.auditSessionIdentity(for: doc)
            audit.check("a stale initialize does not detach a replacement session (seam: held after session store)",
                        handshakeReplacement != nil && handshakeAfter == handshakeReplacement,
                        "replacement=\(String(describing: handshakeReplacement)) after=\(String(describing: handshakeAfter))")
            handshakeManager.auditAfterSessionStored = nil
            await handshakeManager.shutdown()

            // Delayed onExit of a shutting-down session must not detach a replacement.
            let deathManager = LSPManager()
            deathManager.executableOverride = { _ in "/bin/sleep" }
            deathManager.auditProcessArguments = ["30"]
            deathManager.auditSkipHandshake = true
            await deathManager.ensureOpen(doc, root: root)
            let originalID = deathManager.auditSessionIdentity(for: doc)
            guard let client = deathManager.client(for: doc),
                  let pid = deathManager.childProcessID(for: doc),
                  originalID != nil else {
                audit.check("a delayed onExit does not detach a replacement session (seam: deferred onExit)",
                            false, "dummy session did not start")
                await deathManager.shutdown()
                return
            }
            client.auditDeferOnExit = 0.3
            // Drop the old session from the map without handleDeath so a replacement
            // can start while onExit is still pending.
            deathManager.auditDetachSession(for: doc)
            await deathManager.ensureOpen(doc, root: root)
            let replacementID = deathManager.auditSessionIdentity(for: doc)
            kill(pid, SIGKILL)
            let clientDied = await waitUntil(2) { client.hasDied }
            try? await Task.sleep(nanoseconds: 400_000_000)
            let afterID = deathManager.auditSessionIdentity(for: doc)
            let kept = clientDied
                && replacementID != nil
                && afterID == replacementID
                && replacementID != originalID
            audit.check("a delayed onExit does not detach a replacement session (seam: deferred onExit)",
                        kept,
                        "died=\(clientDied) original=\(String(describing: originalID)) replacement=\(String(describing: replacementID)) after=\(String(describing: afterID))")
            await deathManager.shutdown()
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Server → client requests

    private static func serverRequests(_ audit: Auditor) async {
        audit.section("LSP — server-to-client requests are answered")
        let initData = try? JSONSerialization.data(
            withJSONObject: LSPManager.initializeParams(root: URL(fileURLWithPath: "/tmp")))
        let parsed = initData.flatMap { JSON(data: $0) }
        let sync = parsed.map { $0["capabilities"]["textDocument"]["synchronization"] }
        audit.equal("initialize does not advertise didSave", sync?["didSave"].bool, false)

        await Auditor.withTemporaryDirectory { dir in
            let sink = dir.appendingPathComponent("stdin.log")
            let python = Executables.find(["/usr/bin/python3", "/opt/homebrew/bin/python3"],
                                          orNamed: "python3")
            let client = LSPClient()
            do {
                guard let python else { throw LSPError.notRunning }
                try client.start(executable: python, arguments: [
                    "-c",
                    "import os,sys\n"
                    + "out=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o644)\n"
                    + "inf=sys.stdin.fileno()\n"
                    + "while True:\n"
                    + "    b=os.read(inf,65536)\n"
                    + "    if not b: break\n"
                    + "    os.write(out,b)\n",
                    sink.path,
                ])
            } catch {
                audit.check("server-to-client requests can be exercised", false, "\(error)")
                return
            }
            defer { client.stop() }

            @MainActor func send(_ object: [String: Any]) {
                guard let data = try? LSPFramer.frame(object) else { return }
                client.receive(data)
            }

            func parseSink() -> [JSON] {
                var framer = LSPFramer()
                let data = (try? Data(contentsOf: sink)) ?? Data()
                return framer.ingest(data).compactMap { event in
                    if case let .message(body) = event { return JSON(data: body) }
                    return nil
                }
            }
            func framesOnDisk(id: Int) async -> [JSON] {
                await client.waitForWrites()
                _ = await waitUntil(1) { parseSink().last?["id"].int == id }
                return parseSink()
            }

            send(["jsonrpc": "2.0", "id": 10, "method": "workspace/configuration",
                  "params": ["items": [["section": "a"], ["section": "b"], ["section": "c"]]]])
            var written = await framesOnDisk(id: 10)
            audit.check("workspace/configuration bytes reach the server with one null per item",
                        written.last?["id"].int == 10
                        && written.last?["result"].array.count == 3,
                        written.last?.compact ?? "no bytes on the child's stdin")

            send(["jsonrpc": "2.0", "id": 11, "method": "client/registerCapability",
                  "params": ["registrations": []]])
            written = await framesOnDisk(id: 11)
            let register = written.last
            audit.check("client/registerCapability bytes reach the server with a null result",
                        register?["id"].int == 11
                        && (register?.raw as? [String: Any])?.keys.contains("result") == true
                        && register?["error"].exists == false,
                        register?.compact ?? "no bytes on the child's stdin")

            send(["jsonrpc": "2.0", "id": 12, "method": "client/unregisterCapability",
                  "params": ["unregisterations": []]])
            written = await framesOnDisk(id: 12)
            audit.check("client/unregisterCapability bytes reach the server with a null result",
                        written.last?["id"].int == 12
                        && (written.last?.raw as? [String: Any])?.keys.contains("result") == true,
                        written.last?.compact ?? "no bytes on the child's stdin")

            send(["jsonrpc": "2.0", "id": 13, "method": "window/workDoneProgress/create",
                  "params": ["token": "t"]])
            written = await framesOnDisk(id: 13)
            audit.check("window/workDoneProgress/create bytes reach the server with a null result",
                        written.last?["id"].int == 13
                        && (written.last?.raw as? [String: Any])?.keys.contains("result") == true,
                        written.last?.compact ?? "no bytes on the child's stdin")

            send(["jsonrpc": "2.0", "id": 14, "method": "foo/never-implemented",
                  "params": [:]])
            written = await framesOnDisk(id: 14)
            audit.equal("an unknown server request is MethodNotFound",
                        written.last?["error"]["code"].int, -32601)
            audit.check("…and names the method",
                        (written.last?["error"]["message"].string ?? "")
                            .contains("foo/never-implemented"),
                        written.last?["error"]["message"].string ?? "")

            var delivered: String?
            client.onNotification = { method, _ in delivered = method }
            send(["jsonrpc": "2.0", "method": "window/logMessage",
                  "params": ["type": 3, "message": "hi"]])
            audit.equal("server notifications are still delivered to the callback",
                        delivered, "window/logMessage")
        }
    }

    // MARK: - Honesty without a server

    private static func honestyWithoutServer(_ audit: Auditor) {
        audit.section("LSP — unsupported languages are named")
        let manager = LSPManager()
        audit.check("Swift is a wired language", manager.isSupported(Languages.swift))
        audit.check("C is a wired language", manager.isSupported(Languages.c))
        audit.check("C++ is a wired language", manager.isSupported(Languages.cpp))
        audit.check("Objective-C is a wired language", manager.isSupported(Languages.objc))
        audit.check("Python is wired to pyright-langserver", manager.isSupported(Languages.python))
        let python = manager.unavailableNote(for: Languages.python) ?? ""
        if manager.executable(for: Languages.python) == nil {
            audit.check("Python names the missing pyright-langserver instead of claiming coverage",
                        python.contains("pyright-langserver") && python.lowercased().contains("not installed"),
                        python)
        } else {
            audit.check("Python with pyright installed is not reported as unwired",
                        !python.lowercased().contains("no language server wired"), python)
        }
        let markdown = manager.unavailableNote(for: Languages.markdown) ?? ""
        audit.check("Markdown reports no language server wired",
                    markdown.lowercased().contains("no language server wired"),
                    markdown)
        let swiftIdle = manager.unavailableNote(for: Languages.swift) ?? ""
        audit.check("Swift without a live session is not reported as covered",
                    !swiftIdle.isEmpty,
                    swiftIdle)

        let engine = DiagnosticsEngine()
        engine.languageServerNote = { manager.unavailableNote(for: $0) }
        let markdownDoc = CodeDocument(name: "notes.md", language: Languages.markdown, text: "# x\n")
        audit.check("the Problems description names that no language server is wired",
                    engine.description(for: markdownDoc).lowercased()
                        .contains("no language server wired"),
                    engine.description(for: markdownDoc))
        manager.executableOverride = { _ in nil }
        let missing = manager.unavailableNote(for: Languages.swift) ?? ""
        audit.check("a missing sourcekit-lsp binary is named",
                    missing.contains("sourcekit-lsp")
                    && missing.lowercased().contains("not installed")
                    && missing.lowercased().contains("empty list"),
                    missing)
        manager.executableOverride = nil
    }

    // MARK: - sourcekit-lsp

    private static func sourcekit(_ audit: Auditor) async {
        audit.section("LSP — sourcekit-lsp (real server, semantic diagnostics)")
        guard Executables.find(Self.sourcekitCandidates, orNamed: "sourcekit-lsp") != nil else {
            audit.check("sourcekit-lsp is installed", false,
                        "no binary at /usr/bin/sourcekit-lsp or on PATH")
            return
        }

        await Auditor.withTemporaryDirectory { dir in
            writeSwiftPackage(in: dir)
            let url = dir.appendingPathComponent("Sources/AuditLSPPkg/Demo.swift")
            let typeError = """
            public enum AuditLSPDemo {
                public static func bad() {
                    let x: Int = "s"
                }
            }

            """
            try? typeError.write(to: url, atomically: true, encoding: .utf8)

            let oneshotDoc = CodeDocument(url: url)
            let oneshot = DiagnosticsEngine()
            await oneshot.check(oneshotDoc)
            audit.check("swiftc -parse does not flag a type error (syntax only, not semantic)",
                        oneshotDoc.diagnostics.isEmpty,
                        oneshotDoc.diagnostics.map {
                            "\($0.line):\($0.message)"
                        }.joined(separator: " | "))

            let missingManager = LSPManager()
            missingManager.executableOverride = { _ in nil }
            var missingNote: String?
            missingManager.onFailureNote = { _, message in missingNote = message }
            await missingManager.ensureOpen(oneshotDoc, root: dir)
            audit.check("ensureOpen names a missing sourcekit-lsp binary",
                        (missingNote ?? "").contains("sourcekit-lsp")
                        && (missingNote ?? "").lowercased().contains("not installed"),
                        missingNote ?? "no note")
            let tEmpty = Date()
            let none = await missingManager.completions(for: oneshotDoc, line: 1, column: 1)
            let noHover = await missingManager.hover(for: oneshotDoc, line: 1, column: 1)
            let noDef = await missingManager.definition(for: oneshotDoc, line: 1, column: 1)
            audit.check("completions/hover/definition with no server return empty/nil without hanging",
                        none.value.isEmpty && noHover.value == nil && noDef.value == nil
                        && none.outcome == .noServer && noHover.outcome == .noServer
                        && noDef.outcome == .noServer
                        && Date().timeIntervalSince(tEmpty) < 1,
                        String(format: "elapsed %.2fs", Date().timeIntervalSince(tEmpty))
                            + " outcome=\(none.outcome) note=\(none.note ?? "nil")")

            let mdURL = dir.appendingPathComponent("notes.md")
            try? "# x\n".write(to: mdURL, atomically: true, encoding: .utf8)
            let mdDoc = CodeDocument(url: mdURL)
            var mdNote: String?
            missingManager.onFailureNote = { _, message in mdNote = message }
            await missingManager.ensureOpen(mdDoc, root: dir)
            audit.check("ensureOpen of an unsupported language records no language server wired",
                        (mdNote ?? "").lowercased().contains("no language server wired"),
                        mdNote ?? "no note")

            let raceManager = LSPManager()
            let raceDoc = CodeDocument(url: url)
            let opening = Task { await raceManager.ensureOpen(raceDoc, root: dir) }
            _ = await waitUntil(8) { raceManager.hasActiveOrStartingServer }
            raceManager.didClose(raceDoc)
            await opening.value
            audit.check("closing during handshake does not didOpen a closed tab",
                        raceManager.client(for: raceDoc) == nil)
            await raceManager.shutdown()

            let model = AppModel(trust: .forAudit)
            defer { model.shutdown() }
            model.openProject(dir)
            model.open(file: url)
            guard let document = model.documents.document(for: url) else {
                audit.check("opening the Swift file created a tab", false)
                return
            }

            let handshake = await waitUntil(12) {
                model.lsp.initializeResult(for: document) != nil
            }
            let caps = model.lsp.initializeResult(for: document)?["capabilities"]
            audit.check("sourcekit-lsp initialize/initialized handshake completes",
                        handshake && caps?.exists == true,
                        handshake
                            ? "initialize returned but capabilities were missing"
                            : "no initialize result within 12s — server may need longer indexing")
            audit.check("sourcekit-lsp advertised textDocumentSync or completionProvider",
                        caps?["textDocumentSync"].exists == true
                        || caps?["completionProvider"].exists == true,
                        caps?.compact ?? "no capabilities")
            audit.check("a live sourcekit-lsp session makes unavailableNote nil",
                        model.lsp.unavailableNote(for: Languages.swift) == nil,
                        model.lsp.unavailableNote(for: Languages.swift) ?? "")

            let gotSemantic = await waitUntil(20) {
                model.diagnostics.diagnostics(for: url).contains {
                    $0.severity == .error && $0.line == 3
                }
            }
            let found = model.diagnostics.diagnostics(for: url)
            // Hosted runners (Swift 6.1, no built index) never publish semantic diagnostics for an
            // unbuilt package. Under CI that is reported as a skip with the reason; on a Mac the
            // same silence is a failure.
            let semanticMissingOnCI = !gotSemantic && budgetFactor > 1
            @MainActor func semanticCheck(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
                if semanticMissingOnCI {
                    audit.skip(name, "sourcekit-lsp published no semantic diagnostics within \(Int(20 * budgetFactor))s on this machine")
                } else {
                    audit.check(name, passed, detail())
                }
            }
            semanticCheck("sourcekit-lsp publishes a semantic type error on the right line",
                        gotSemantic && found.contains { $0.source == "sourcekit-lsp" },
                        found.isEmpty
                            ? "no publishDiagnostics within 20s — server may need longer indexing"
                            : found.map { "\($0.source) \($0.line):\($0.message)" }
                                .joined(separator: " | "))
            audit.check("the live description names sourcekit-lsp",
                        model.diagnostics.description(for: document)
                            .contains("sourcekit-lsp")
                        && model.diagnostics.description(for: document)
                            .contains("semantic"),
                        model.diagnostics.description(for: document))

            await model.diagnostics.check(document)
            let afterOneShot = model.diagnostics.diagnostics(for: url)
            semanticCheck("live server diagnostics replace one-shot results (no swiftc duplicate)",
                        !afterOneShot.isEmpty
                        && afterOneShot.allSatisfy { $0.source == "sourcekit-lsp" },
                        afterOneShot.map { "\($0.source) \($0.line):\($0.message)" }
                            .joined(separator: " | "))

            if let client = model.lsp.client(for: document),
               let stale = try? LSPFramer.frame([
                   "jsonrpc": "2.0",
                   "method": "textDocument/publishDiagnostics",
                   "params": [
                       "uri": LSPMapping.uri(for: url),
                       "version": 0,
                       "diagnostics": [[
                           "range": ["start": ["line": 0, "character": 0],
                                     "end": ["line": 0, "character": 1]],
                           "severity": 1,
                           "message": "AUDIT-STALE-VERSION",
                       ]],
                   ],
               ] as [String: Any]) {
                client.receive(stale)
            }
            audit.check("a publishDiagnostics for an older version is ignored",
                        !model.diagnostics.diagnostics(for: url)
                            .contains { $0.message.contains("AUDIT-STALE-VERSION") },
                        model.diagnostics.diagnostics(for: url).map(\.message)
                            .joined(separator: " | "))

            document.replaceAll(with: document.text)
            model.lsp.didChange(document)
            audit.check("didChange is pending before a query",
                        model.lsp.hasPendingChange(for: document))
            _ = await model.lsp.hover(for: document, line: 1, column: 1)
            audit.check("a hover query flushes the pending didChange",
                        !model.lsp.hasPendingChange(for: document))
            if let client = model.lsp.client(for: document) {
                client.recordOutbound = true
                client.clearOutbound()
                _ = await model.lsp.hover(for: document, line: 1, column: 1)
                let extra = client.outbound.filter { $0["method"].string == "textDocument/didChange" }
                audit.equal("a second query does not send didChange", extra.count, 0)
                client.recordOutbound = false
            }

            // Unsaved buffer: fix the type error, then introduce a new one on another line.
            let cleaned = """
            public enum AuditLSPDemo {
                public static func bad() {
                    let x: Int = 1
                }
            }

            """
            document.replaceAll(with: cleaned)
            model.lsp.didChange(document)
            model.lsp.flush(document)
            let cleared = await waitUntil(10) {
                !model.diagnostics.diagnostics(for: url)
                    .contains { $0.severity == .error }
            }
            audit.check("an unsaved fix clears the semantic error (didChange, not disk)",
                        cleared,
                        cleared
                            ? ""
                            : "still had errors after 10s: "
                            + model.diagnostics.diagnostics(for: url).map {
                                "\($0.line):\($0.message)"
                            }.joined(separator: " | ")
                            + " — server may need longer indexing")
            audit.equal("the file on disk is untouched by the unsaved edit",
                        try? String(contentsOf: url, encoding: .utf8), typeError)

            model.documents.confirmClose = { _ in .discard }
            model.reloadActiveFile()
            let reloaded = await waitUntil(10) {
                model.diagnostics.diagnostics(for: url)
                    .contains { $0.severity == .error && $0.line == 3 }
            }
            semanticCheck("reloading from disk sends the on-disk buffer to the language server",
                        reloaded,
                        reloaded
                            ? ""
                            : "no type error after reload — didChange may not have been sent; saw "
                            + model.diagnostics.diagnostics(for: url).map {
                                "\($0.line):\($0.message)"
                            }.joined(separator: " | "))

            model.setLanguage(Languages.python, on: document)
            audit.check("changing language drops live coverage",
                        !model.diagnostics.isLiveCovered(document.url))
            audit.check("…and the Swift server no longer has the document",
                        model.lsp.client(for: document) == nil)
            model.setLanguage(Languages.swift, on: document)
            let reopened = await waitUntil(12) {
                model.diagnostics.isLiveCovered(document.url)
            }
            audit.check("switching back to Swift reopens the document on sourcekit-lsp",
                        reopened,
                        reopened ? "" : "no live coverage within 12s")

            let rebroken = """
            public enum AuditLSPDemo {
                public static func bad() {
                    let x: Int = 1
                    let y: String = 1
                }
            }

            """
            document.replaceAll(with: rebroken)
            model.lsp.didChange(document)
            model.lsp.flush(document)
            let newError = await waitUntil(10) {
                model.diagnostics.diagnostics(for: url).contains {
                    $0.severity == .error && $0.line == 4
                }
            }
            semanticCheck("an unsaved type error on a new line is published",
                        newError,
                        newError
                            ? ""
                            : "no error on line 4 within 10s — server may need longer indexing; saw "
                            + model.diagnostics.diagnostics(for: url).map {
                                "\($0.line):\($0.message)"
                            }.joined(separator: " | "))

            let renamed = url.deletingLastPathComponent().appendingPathComponent("Renamed.swift")
            try? FileManager.default.removeItem(at: renamed)
            do {
                try FileManager.default.moveItem(at: url, to: renamed)
                model.renameDocument(document, to: renamed)
                if let root = model.projectURL {
                    await model.lsp.ensureOpen(document, root: root)
                }
            } catch {
                audit.check("renaming an open file reopens it on the server under the new URI",
                            false, error.localizedDescription)
            }
            audit.check("renaming an open file reopens it on the server under the new URI",
                        document.url == renamed && model.lsp.client(for: document) != nil,
                        document.url.lastPathComponent
                            + (model.lsp.client(for: document) == nil
                               ? " — no live session for the new URI" : ""))

            // Kill the child while a request is in flight. Subsequent calls must fail fast;
            // checkers return.
            guard let client = model.lsp.client(for: document),
                  let pid = model.lsp.childProcessID(for: document) else {
                audit.check("the language server process is running so it can be killed", false)
                return
            }
            // Freeze the child so it cannot reply, then issue a request, then SIGKILL.
            kill(pid, SIGSTOP)
            let inFlight = Task { @MainActor in
                try await client.request(
                    "textDocument/documentSymbol",
                    ["textDocument": ["uri": LSPMapping.uri(for: document.url)]],
                    deadline: 8)
            }
            _ = await waitUntil(2) { client.hasPendingRequest }
            kill(pid, SIGKILL)
            let inFlightStart = Date()
            do {
                _ = try await inFlight.value
                audit.check("an in-flight request on the live server fails when it is killed",
                            false, "the request returned a result")
            } catch {
                audit.check("an in-flight request on the live server fails when it is killed",
                            Date().timeIntervalSince(inFlightStart) < 2.5,
                            String(format: "elapsed %.2fs — \(error)",
                                   Date().timeIntervalSince(inFlightStart)))
            }
            let noted = await waitUntil(4) {
                (model.diagnostics.notes[document.url] ?? "").contains("sourcekit-lsp")
                && (model.diagnostics.notes[document.url] ?? "").lowercased().contains("stopped")
            }
            audit.check("killing the server produces a named note, not a silent empty list",
                        noted,
                        model.diagnostics.notes[document.url] ?? "no note within 4s")
            audit.check("the note says the one-shot checker is the fallback",
                        (model.diagnostics.notes[document.url] ?? "").contains("swiftc"),
                        model.diagnostics.notes[document.url] ?? "")

            let t0 = Date()
            let comps = await model.lsp.completions(for: document, line: 3, column: 13)
            let hover = await model.lsp.hover(for: document, line: 3, column: 13)
            let def = await model.lsp.definition(for: document, line: 3, column: 13)
            let elapsed = Date().timeIntervalSince(t0)
            audit.check("completions/hover/definition after death return empty/nil, not hang",
                        comps.value.isEmpty && hover.value == nil && def.value == nil
                        && comps.outcome != .success)
            audit.check("…and fail fast rather than waiting out the request deadline",
                        elapsed < 2.5,
                        String(format: "elapsed %.2fs", elapsed))

            document.replaceAll(with: "func bad( {\n")
            await model.diagnostics.check(document)
            audit.check("one-shot fallback is re-enabled after the server dies",
                        document.diagnostics.contains { $0.source == "swiftc" }
                        && !document.diagnostics.isEmpty,
                        document.diagnostics.map {
                            "\($0.source) \($0.line):\($0.message)"
                        }.joined(separator: " | "))
        }
    }

    // MARK: - clangd

    private static func clangd(_ audit: Auditor) async {
        audit.section("LSP — clangd (real server)")
        guard Executables.find(Self.clangdCandidates, orNamed: "clangd") != nil else {
            audit.check("clangd is installed", false,
                        "no binary at /usr/bin/clangd or on PATH")
            return
        }

        await Auditor.withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("prog.c")
            let source = """
            int main(void) {
                int x = "s";
                return 0;
            }

            """
            try? source.write(to: url, atomically: true, encoding: .utf8)
            try? "-Wall\n".write(to: dir.appendingPathComponent("compile_flags.txt"),
                                 atomically: true, encoding: .utf8)

            let manager = LSPManager()
            let engine = DiagnosticsEngine()
            var published: [URL: [Diagnostic]] = [:]
            let document = CodeDocument(url: url)
            manager.onDiagnostics = { file, found in
                published[file] = found
                engine.applyLSPDiagnostics(found, for: document)
            }
            manager.onCoverageChange = { file, server in
                engine.setLiveCoverage(file, server: server)
            }
            manager.onFailureNote = { file, message in
                engine.noteLSPFailure(for: file, message: message)
            }

            await manager.ensureOpen(document, root: dir)
            let handshake = await waitUntil(8) {
                manager.initializeResult(for: document)?["capabilities"].exists == true
            }
            audit.check("clangd initialize/initialized handshake completes",
                        handshake,
                        handshake
                            ? ""
                            : "no initialize result within 8s — server may need longer indexing")

            let got = await waitUntil(10) {
                (published[url] ?? engine.diagnostics(for: url)).contains {
                    $0.severity == .error && $0.line == 2 && $0.source == "clangd"
                }
            }
            let found = published[url] ?? engine.diagnostics(for: url)
            audit.check("clangd publishes an error on the right line",
                        got,
                        got
                            ? found.map { "\($0.line):\($0.message)" }.joined(separator: " | ")
                            : "no publishDiagnostics within 10s — server may need longer indexing")
            audit.check("clangd diagnostics are attributed to clangd",
                        found.contains { $0.source == "clangd" },
                        found.map(\.source).joined(separator: ","))
            audit.check("the live description names clangd",
                        engine.description(for: document).contains("clangd"),
                        engine.description(for: document))

            await manager.shutdown()
        }
    }

    private static let sourcekitCandidates = [
        "/usr/bin/sourcekit-lsp",
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp",
    ]
    private static let clangdCandidates = [
        "/usr/bin/clangd",
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clangd",
    ]

    private static func writeSwiftPackage(in dir: URL) {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "AuditLSPPkg",
            platforms: [.macOS(.v14)],
            products: [.library(name: "AuditLSPPkg", targets: ["AuditLSPPkg"])],
            targets: [.target(name: "AuditLSPPkg")]
        )
        """
        try? manifest.write(to: dir.appendingPathComponent("Package.swift"),
                            atomically: true, encoding: .utf8)
        let sources = dir.appendingPathComponent("Sources/AuditLSPPkg")
        try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }
}

import Foundation
import AppKit

/// Studio tools: IDE and preview tools exist for every trusted project, desktop tools only with
/// the explicit grant, browser tools only with allowed sites and the user's switch; the browser
/// policy admits allowed hosts and loopback for the page itself and nothing else; the IDE tools
/// list and run real tasks, read problems, search and report the active file.
@MainActor
enum AuditStudioTools {
    static func run(_ audit: Auditor) async {
        audit.section("Provider-native computer control")
        audit.check("native desktop routing defaults on", AgentSessionSettings().nativeComputerControl)
        if let old = try? JSONDecoder().decode(AgentSessionSettings.self, from: Data("{}".utf8)) {
            audit.check("older settings adopt native routing", old.nativeComputerControl)
        } else { audit.check("older settings decode", false) }
        var explicitShared = AgentSessionSettings()
        explicitShared.nativeComputerControl = false
        let roundTrip = try? JSONDecoder().decode(AgentSessionSettings.self, from: JSONEncoder().encode(explicitShared))
        audit.check("an explicit shared-control choice survives saving", roundTrip?.nativeComputerControl == false)
        let native = JSON(["data": [["name": "cua_repl", "tools": ["js": ["name": "js"]]]]])
        audit.check("Codex readiness requires actual advertised native tools", NativeComputerControl.hasCodexTools(native))
        audit.check("an empty native plugin is not reported ready", !NativeComputerControl.hasCodexTools(JSON(["data": [["name": "computer-use", "tools": [:]]]])))
        audit.check("shared tools are not reported as Codex native", !NativeComputerControl.hasCodexTools(JSON(["data": [["name": "studio_computer", "tools": ["screenshot": [:]]]]])))
        audit.check("Grok uses the shared control path", NativeComputerControl.guidance(for: .grok, preferred: true).contains("studio_computer"))
        audit.check("Claude's non-interactive limitation is explicit", NativeComputerControl.guidance(for: .claude, preferred: true).contains("not supported in non-interactive -p"))
        await Auditor.withTemporaryDirectory { project in
            let model = AppModel(trust: .forAudit)
            defer { model.shutdown() }
            model.openProject(project)
            var saved = AgentSessionSettings(); saved.instructions = "Keep my project instructions."
            model.agentSettings[.codex] = saved
            let settings = model.sessionSettings(for: .codex)
            audit.check("native routing reaches configured sessions without losing user instructions", settings.instructions.contains(saved.instructions) && settings.instructions.contains("mcp__cua_repl"))
            audit.equal("runtime guidance is not written into stored instructions", model.agentSettings[.codex]?.instructions, saved.instructions)
        }
        audit.section("Desktop keyboard — Unicode delivery")
        let sample = String(repeating: "a", count: 19) + "😀é\n" + String(repeating: "z", count: 43)
        let chunks = ComputerControl.keyboardTextChunks(sample)
        audit.equal("keyboard chunks preserve the full input", String(decoding: chunks.flatMap { $0 }, as: UTF16.self), sample)
        audit.check("every keyboard event stays within the AppKit payload size", chunks.allSatisfy { !$0.isEmpty && $0.count <= 20 })
        audit.check("keyboard chunks never split a surrogate pair", chunks.allSatisfy { Array(String(decoding: $0, as: UTF16.self).utf16) == $0 })
        audit.check("empty input sends no keyboard events", ComputerControl.keyboardTextChunks("").isEmpty)
        if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left) {
            ComputerControl.routePointer(event, window: 345, pid: 678)
            audit.equal("pointer delivery identifies the verified window", event.getIntegerValueField(.mouseEventWindowUnderMousePointer), 345)
            audit.equal("pointer delivery identifies the handling window", event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent), 345)
            audit.equal("pointer delivery identifies only the target process", event.getIntegerValueField(.eventTargetUnixProcessID), 678)
        } else { audit.check("pointer event fixture can be created", false) }
        audit.section("Codex — connectors retain the IDE bridge in thread configuration")
        var configured = AgentSessionSettings()
        configured.mcpConfiguration = "{\"example\":{\"command\":\"/bin/echo\",\"args\":[\"ok\"]}}"
        let bridge = ComputerConnection(socketPath: "/tmp/audit-bridge", token: "audit-token", provider: .codex)
        let merged = JSON(configured.codexConfiguration(adding: bridge))["mcp_servers"]
        audit.check("a shared connector and the IDE bridge coexist in Codex's thread override", merged["example"].exists && merged["studio_computer"].exists)
        audit.equal("the Codex thread uses the current bridge socket and provider", merged["studio_computer"]["args"].array.compactMap(\.string), bridge.arguments)
        audit.equal("the merged IDE bridge retains its tool timeout", merged["studio_computer"]["tool_timeout_sec"].int, 125)
        audit.check("detached configurations do not invent a computer grant", !JSON(configured.codexConfiguration)["mcp_servers"]["studio_computer"].exists)
        audit.section("Studio tools — long-lived Roundtable access")
        await Auditor.withTemporaryDirectory { project in
            let model = AppModel(trust: .forAudit)
            defer { model.shutdown() }
            model.openProject(project)
            var time = Date()
            guard let control = try? ComputerControl(model: model, project: project, groups: [.ide, .preview, .browser, .desktop], now: { time }) else {
                audit.check("expiry fixture starts", false); return
            }
            defer { control.stop() }
            time = time.addingTimeInterval(3601)
            for provider in Provider.allCases {
                let connection = control.connection(for: provider)
                func request(_ method: String, _ params: [String: Any] = [:]) async -> JSON {
                    JSON(await control.respond(["token": connection.token, "provider": provider.rawValue,
                        "request": ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]]))
                }
                let initialized = await request("initialize")
                audit.check("\(provider.displayName) can initialize tools after one hour", initialized["result"]["serverInfo"].exists && !initialized["error"].exists)
                let catalog = await request("tools/list")
                let names = Set(catalog["result"]["tools"].array.compactMap { $0["name"].string })
                audit.check("\(provider.displayName) retains browser and IDE tools after desktop expiry", names.contains("browser_open") && names.contains("ide_status") && !names.contains("screenshot"))
                let status = await request("tools/call", ["name": "ide_status", "arguments": [:]])
                audit.check("\(provider.displayName) actually executes an IDE tool after one hour", status["result"]["isError"].bool == false)
                let denied = await request("tools/call", ["name": "list_apps", "arguments": [:]])
                audit.check("\(provider.displayName)'s expired manual desktop grant stays refused", denied["result"]["isError"].bool == true)
                let backend = model.roundtable.makeBackend(provider)
                audit.check("\(provider.displayName)'s Roundtable backend receives its own live bridge", backend.computerConnection?.provider == provider && backend.computerConnection?.socketPath == model.computerControl?.connection(for: provider).socketPath)
            }
            control.setGroups(control.groups.union([.desktop]))
            audit.check("explicitly re-enabling desktop renews the grant", control.desktopEnabled)
            model.blanketApproval = true
            time = time.addingTimeInterval(3601)
            let connection = control.connection(for: .grok)
            let catalog = JSON(await control.respond(["token": connection.token, "provider": "grok", "request": ["id": 2, "method": "tools/list"]]))
            audit.check("the user's persistent global approval keeps desktop tools available", catalog["result"]["tools"].array.contains { $0["name"].string == "screenshot" })
            model.blanketApproval = false
        }
        audit.section("Studio tools — groups gate what a session may call")
        let all = ComputerControl.tools.map { $0["name"] as? String ?? "" }
        audit.equal("the catalog has desktop, IDE, preview, browser and simulator tools", all.count, 38)
        audit.equal("IDE tools are grouped as ide", Set(["open_file", "show_panel", "ide_status", "ide_tasks", "ide_run_task", "ide_problems", "ide_search", "ide_active_file"].map(ComputerControl.group(of:))), [.ide])
        audit.equal("browser tools are grouped as browser", Set(["browser_open", "browser_inspect", "browser_click", "browser_type", "browser_capture"].map(ComputerControl.group(of:))), [.browser])
        audit.equal("screenshots and clicks are desktop", Set(["screenshot", "click", "type_text", "press_key", "scroll", "launch_app", "open_url", "list_apps"].map(ComputerControl.group(of:))), [.desktop])
        audit.equal("a trusted project's default set is IDE plus preview", ComputerControl.tools(for: [.ide, .preview]).count, 13)
        audit.check("desktop descriptions say they need the grant, browser ones the allowed sites",
                    (ComputerControl.tools.first { $0["name"] as? String == "screenshot" }?["description"] as? String)?.contains("computer-control session") == true
                    && (ComputerControl.tools.first { $0["name"] as? String == "browser_open" }?["description"] as? String)?.contains("allowed site") == true
                    && (ComputerControl.tools.first { $0["name"] as? String == "ide_tasks" }?["description"] as? String)?.contains("Requires") == false)

        audit.section("Studio tools — the browser policy")
        let hosts = ["grok.com", "Docs.Example.com "]
        audit.check("an allowed host and its subdomains pass", UIVerificationController.hostAllowed("grok.com", in: hosts) && UIVerificationController.hostAllowed("imagine.grok.com", in: hosts) && UIVerificationController.hostAllowed("docs.example.com", in: hosts))
        audit.check("a look-alike host is refused", !UIVerificationController.hostAllowed("grok.com.evil.net", in: hosts) && !UIVerificationController.hostAllowed("notgrok.com", in: hosts))
        audit.check("loopback is always allowed", UIVerificationController.hostAllowed("localhost", in: []) && UIVerificationController.hostAllowed("127.0.0.1", in: hosts))
        audit.check("credentials in the URL are refused even for an allowed host", (try? UIVerificationController.validatedURL("https://user:pw@grok.com/", allowedHosts: hosts)) == nil)
        audit.check("an allowed URL validates", (try? UIVerificationController.validatedURL("https://grok.com/imagine/agent", allowedHosts: hosts)) != nil)
        audit.check("without an allowlist only loopback validates", (try? UIVerificationController.validatedURL("https://grok.com/", allowedHosts: [])) == nil && (try? UIVerificationController.validatedURL("http://localhost:3000/")) != nil)
        let grok = URL(string: "https://grok.com/imagine")!, evil = URL(string: "https://evil.example/")!, cdn = URL(string: "https://cdn.example/app.js")!, file = URL(string: "file:///etc/passwd")!
        audit.check("browser mode allows the page to go to allowed sites and loopback only",
                    UIVerificationController.allowsNavigation(grok, isMainFrame: true, mode: .browser, allowedHosts: hosts, allowedOrigin: nil)
                    && !UIVerificationController.allowsNavigation(evil, isMainFrame: true, mode: .browser, allowedHosts: hosts, allowedOrigin: nil)
                    && UIVerificationController.allowsNavigation(URL(string: "http://127.0.0.1:8765/")!, isMainFrame: true, mode: .browser, allowedHosts: hosts, allowedOrigin: nil))
        audit.check("browser mode lets a page load its subresources from anywhere over http(s) but not files", UIVerificationController.allowsNavigation(cdn, isMainFrame: false, mode: .browser, allowedHosts: hosts, allowedOrigin: nil) && !UIVerificationController.allowsNavigation(file, isMainFrame: false, mode: .browser, allowedHosts: hosts, allowedOrigin: nil))
        audit.check("local preview mode is unchanged: same origin only", UIVerificationController.allowsNavigation(URL(string: "http://localhost:3000/a")!, isMainFrame: true, mode: .localPreview, allowedHosts: hosts, allowedOrigin: "http://localhost:3000") && !UIVerificationController.allowsNavigation(grok, isMainFrame: false, mode: .localPreview, allowedHosts: hosts, allowedOrigin: "http://localhost:3000"))

        audit.check("bypass admits an unlisted website for navigation", UIVerificationController.allowsNavigation(evil, isMainFrame: true, mode: .browser, allowedHosts: [], allowedOrigin: nil, bypassHostRestrictions: true))
        audit.check("bypass admits redirects to a different website", UIVerificationController.allowsNavigation(evil, isMainFrame: true, mode: .browser, allowedHosts: hosts, allowedOrigin: UIVerificationController.origin(grok), bypassHostRestrictions: true))
        audit.check("bypass admits agent interaction on the loaded website", UIVerificationController.pageReady(evil, mode: .browser, allowedHosts: [], allowedOrigin: UIVerificationController.origin(evil), bypassHostRestrictions: true))
        audit.check("turning bypass off rejects the formerly admitted page", !UIVerificationController.pageReady(evil, mode: .browser, allowedHosts: [], allowedOrigin: UIVerificationController.origin(evil)))
        audit.check("bypass does not admit files or non-web schemes", ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,test", "https:///"].allSatisfy { (try? UIVerificationController.validatedURL($0, bypassHostRestrictions: true)) == nil })
        audit.check("bypass still rejects embedded passwords", (try? UIVerificationController.validatedURL("https://user:pw@example.com/", bypassHostRestrictions: true)) == nil)
        audit.check("bypass cannot expand the local verifier", !UIVerificationController.allowsNavigation(evil, isMainFrame: true, mode: .localPreview, allowedHosts: hosts, allowedOrigin: UIVerificationController.origin(evil), bypassHostRestrictions: true) && !UIVerificationController.pageReady(evil, mode: .localPreview, allowedHosts: hosts, allowedOrigin: UIVerificationController.origin(evil), bypassHostRestrictions: true))
        await Auditor.withTemporaryDirectory { project in
            let first = AppModel(trust: .forAudit), second = AppModel(trust: .forAudit)
            defer { first.blanketApproval = false; first.shutdown(); second.shutdown() }
            first.blanketApproval = false
            first.openProject(project); second.openProject(project)
            first.browserAllowedHosts = ["grok.com"]
            guard let existing = try? first.browserController(), let other = try? second.browserController() else { audit.check("browser bypass fixture opens controllers", false); return }
            audit.check("existing browser initially enforces saved sites", !existing.bypassHostRestrictions && !other.bypassHostRestrictions)
            first.blanketApproval = true
            audit.check("global bypass updates already-open browsers in every model", existing.bypassHostRestrictions && other.bypassHostRestrictions)
            audit.check("agent browser receives the same unrestricted controller", (try? first.agentBrowserController()) === existing && existing.bypassHostRestrictions)
            first.blanketApproval = false
            audit.check("turning bypass off restores both browsers immediately and keeps saved sites", !existing.bypassHostRestrictions && !other.bypassHostRestrictions && first.browserAllowedHosts == ["grok.com"])
        }

        audit.section("Studio tools — IDE tools act on a real project through the bridge")
        await Auditor.withTemporaryDirectory { project in
            try? "all:\n\t@echo alpha build\n\ntest:\n\t@echo tests ok\n".write(to: project.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
            try? "def greet(name):\n    return 'Hello ' + name\n".write(to: project.appendingPathComponent("hello.py"), atomically: true, encoding: .utf8)
            try? "def broken(:\n    pass\n".write(to: project.appendingPathComponent("broken.py"), atomically: true, encoding: .utf8)
            let model = AppModel(trust: .forAudit)
            defer { model.shutdown() }
            model.openProject(project)
            guard let control = model.computerControl else { audit.check("a trusted project starts the tool server with IDE and preview tools", false); return }
            audit.equal("a trusted project starts the tool server with IDE and preview tools", control.groups, [.ide, .preview])
            let connection = control.connection(for: .claude)
            func call(_ name: String, _ arguments: [String: Any] = [:]) async -> JSON {
                let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
                return JSON(await control.respond(["token": connection.token, "provider": "claude", "request": request]))
            }
            func text(_ reply: JSON) -> String { reply["result"]["content"].array.first?["text"].string ?? "" }
            let list = JSON(await control.respond(["token": connection.token, "provider": "claude", "request": ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]]))
            audit.equal("tools/list shows only the enabled groups", list["result"]["tools"].array.count, 13)
            let refusedDesktop = await call("screenshot")
            audit.check("a desktop tool is refused while the grant is off, naming the fix", refusedDesktop["result"]["isError"].bool == true && text(refusedDesktop).contains("not enabled"))
            let refusedBrowser = await call("browser_inspect")
            audit.check("a browser tool is refused while no site is allowed", refusedBrowser["result"]["isError"].bool == true && text(refusedBrowser).contains("browser"))
            let tasks = text(await call("ide_tasks"))
            audit.check("ide_tasks lists the Makefile targets", tasks.contains("make all") && tasks.contains("\"id\""), tasks.prefix(200).description)
            let allID = TaskCatalog.tasks(project: project, activeFile: nil, language: nil).first { $0.title == "make all" }?.id ?? "make-all"
            let ran = await call("ide_run_task", ["id": allID, "timeout": 60])
            audit.check("ide_run_task runs make all and returns its output and exit status", ran["result"]["isError"].bool == false && text(ran).contains("alpha build") && text(ran).contains("exit 0"), text(ran).prefix(300).description)
            let isolatedRoot = project.appendingPathComponent("agent-working-copy")
            do {
                try FileManager.default.createDirectory(at: isolatedRoot, withIntermediateDirectories: true)
                try "all:\n\t@echo isolated build\n".write(to: isolatedRoot.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
            } catch { audit.check("working-copy fixture is created", false, error.localizedDescription); return }
            let workspace = TaskWorkspace(id: UUID(), projectRoot: project, executionRoot: isolatedRoot,
                                          createdAt: Date(), isolated: true, notices: [])
            let record = TaskRecord(provider: .claude, title: "Working-copy routing", workspaceID: workspace.id)
            let priorState = model.states[.claude]
            let priorTask = model.activeTaskIDs[.claude]
            model.taskRecords.append(record)
            model.activeTaskIDs[.claude] = record.id
            model.taskWorkspaces[workspace.id] = workspace
            model.states[.claude, default: ProviderState()].inFlight = 1
            let isolatedID = TaskCatalog.tasks(project: isolatedRoot, activeFile: nil, language: nil).first { $0.title == "make all" }?.id ?? "make-all"
            let isolatedRun = await call("ide_run_task", ["id": isolatedID, "timeout": 60])
            audit.check("an agent's IDE build verifies its working copy, not the original project",
                        isolatedRun["result"]["isError"].bool == false && text(isolatedRun).contains("isolated build")
                        && !text(isolatedRun).contains("alpha build") && text(isolatedRun).contains(isolatedRoot.path), text(isolatedRun).prefix(300).description)
            model.open(file: project.appendingPathComponent("hello.py"))
            audit.equal("the active file is mapped into the caller's working copy",
                        model.ideTaskActiveFile(root: isolatedRoot), isolatedRoot.appendingPathComponent("hello.py"))
            model.states[.claude] = priorState
            model.activeTaskIDs[.claude] = priorTask
            model.taskRecords.removeAll { $0.id == record.id }
            model.taskWorkspaces.removeValue(forKey: workspace.id)
            let missing = await call("ide_run_task", ["id": "no-such-task"])
            audit.check("an unknown task id is named", missing["result"]["isError"].bool == true && text(missing).contains("no-such-task"))
            model.open(file: project.appendingPathComponent("hello.py"))
            model.activeDocument?.selection = NSRange(location: 4, length: 5)
            let active = text(await call("ide_active_file"))
            audit.check("ide_active_file reports the file, language and selection", active.contains("hello.py") && active.contains("python") && active.contains("greet"), active.prefix(200).description)
            let found = text(await call("ide_search", ["query": "Hello"]))
            audit.check("ide_search finds text in the project", found.contains("hello.py") && found.contains("Hello"), found.prefix(200).description)
            let status = text(await call("ide_status"))
            audit.check("ide_status names the project, mode and active file", status.contains(project.lastPathComponent) && status.contains("Solo") && status.contains("hello.py"), status.prefix(200).description)
            model.open(file: project.appendingPathComponent("broken.py"))
            if let broken = model.activeDocument {
                await model.diagnostics.check(broken)
                let problems = text(await call("ide_problems"))
                audit.check("ide_problems reports the checker's finding for the broken file", problems.contains("broken.py") || problems.contains("Checker notes"), problems.prefix(200).description)
            }
            audit.check("IDE tools alone are not a desktop grant — the Computer-control banner stays hidden", control.isEnabled && !control.desktopEnabled)
            model.browserAllowedHosts = ["grok.com"]
            audit.check("naming a site alone does not enable browser tools", !control.groups.contains(.browser))
            model.browserAgentsAllowed = true
            audit.check("the switch adds the browser group", control.groups.contains(.browser))
            let blocked = await call("browser_open", ["url": "https://evil.example/"])
            audit.check("browser_open refuses a site outside the allowlist", blocked["result"]["isError"].bool == true && text(blocked).contains("allowed sites"))
            let imagine = URL(string: "https://grok.com/imagine")!
            let imagineOrigin = UIVerificationController.origin(imagine)
            audit.check("a loaded allowed site is the browser's page for inspect, click and type", UIVerificationController.pageReady(imagine, mode: .browser, allowedHosts: ["grok.com"], allowedOrigin: imagineOrigin))
            audit.check("the local preview still refuses a remote page as its page", !UIVerificationController.pageReady(imagine, mode: .localPreview, allowedHosts: ["grok.com"], allowedOrigin: imagineOrigin))
            audit.check("a page on another origin than the one opened is not the browser's page", !UIVerificationController.pageReady(URL(string: "https://evil.example/")!, mode: .browser, allowedHosts: ["grok.com", "evil.example"], allowedOrigin: imagineOrigin))
            let local = URL(string: "http://127.0.0.1:3000/")!
            audit.check("a loopback page is the browser's page without being named", UIVerificationController.pageReady(local, mode: .browser, allowedHosts: ["grok.com"], allowedOrigin: UIVerificationController.origin(local)))
            model.browserAgentsAllowed = false
            audit.check("switching it off removes the group again", !control.groups.contains(.browser))
            try? model.enableComputerControl()
            audit.check("enabling computer control adds the desktop group and keeps the rest", control.groups == [.ide, .preview, .desktop])
            model.disableComputerControl()
            audit.check("disabling computer control keeps the IDE tools and drops the desktop grant", control.isEnabled && control.groups == [.ide, .preview] && !control.desktopEnabled)
            model.setProjectTrusted(false)
            audit.check("revoking trust stops the tool server", model.computerControl == nil)
            model.browserAllowedHosts = []

            audit.section("Studio tools — every agent (Grok, Claude, Codex) can control the computer")
            try? model.enableComputerControl()
            guard let granted = model.computerControl, granted.groups.contains(.desktop) else { audit.check("the desktop grant is on", false); return }
            for provider in Provider.allCases {
                let connection = granted.connection(for: provider)
                audit.equal("\(provider.displayName) gets a connection tagged for itself", connection.provider, provider)
                func desktopCall(_ name: String) async -> JSON {
                    let request: [String: Any] = ["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": name, "arguments": [:]]]
                    return JSON(await granted.respond(["token": connection.token, "provider": provider.rawValue, "request": request]))
                }
                let listed = JSON(await granted.respond(["token": connection.token, "provider": provider.rawValue, "request": ["jsonrpc": "2.0", "id": 8, "method": "tools/list"]]))
                let names = Set(listed["result"]["tools"].array.compactMap { $0["name"].string })
                audit.check("\(provider.displayName) is offered the desktop tools", names.isSuperset(of: ["screenshot", "click", "type_text", "press_key", "list_apps"]))
                // list_apps is a desktop tool that needs no macOS permission, so it runs for real.
                let apps = await desktopCall("list_apps")
                audit.check("\(provider.displayName) can invoke a desktop tool through its own connection", apps["result"]["isError"].bool == false && (apps["result"]["content"].array.first?["text"].string?.contains("bundleID") == true))
            }
            // The three connections are exactly the three providers, each authenticated on its own tag.
            let crossed = JSON(await granted.respond(["token": granted.connection(for: .grok).token, "provider": "not-a-provider", "request": ["jsonrpc": "2.0", "id": 7, "method": "tools/list"]]))
            audit.check("an unknown provider tag is rejected", crossed["error"].exists)
            model.disableComputerControl()
        }
    }
}

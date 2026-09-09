import Foundation
import AppKit

@MainActor
enum AuditStudioFeatures {
    static func run(_ audit: Auditor) async {
        audit.section("Studio — provider settings and computer connection")
        var settings = AgentSessionSettings()
        settings.instructions = "Review carefully\nKeep the existing behavior."
        settings.model = "test-model"
        settings.effort = "high"
        settings.chrome = true
        settings.subagents = false
        settings.networkAccess = true
        settings.webSearch = "live"
        settings.mcpConfiguration = #"{"test":{"command":"/usr/bin/true","args":["a b"]}}"#
        audit.check("valid settings accepted", (try? settings.validate()) != nil)
        audit.check("Claude receives its browser setting", settings.claudeArguments.contains("--chrome"))
        audit.check("Claude receives literal multiline instructions", settings.claudeArguments.contains(settings.instructions))
        audit.equal("Grok receives subagent switch", settings.grokEnvironment["GROK_SUBAGENTS"], "0")
        audit.equal("Grok receives session instructions", settings.grokMetadata(autoApprove: true)["rules"] as? String, settings.instructions)
        audit.equal("Grok receives MCP server arguments", settings.acpMCPServers.first?["args"] as? [String], ["a b"])
        audit.equal("Codex receives network override", settings.codexConfiguration["sandbox_workspace_write.network_access"] as? Bool, true)
        audit.equal("Codex receives search mode", settings.codexConfiguration["web_search"] as? String, "live")
        audit.check("Codex native config uses TOML objects", TOMLArgument.value(["a": "b"]).contains("\"a\" = \"b\""))
        audit.equal("TOML literals quote shell-like content without evaluating it", TOMLArgument.value("$(touch nope)"), "\"$(touch nope)\"")
        for provider in Provider.allCases {
            audit.check("\(provider.displayName) native model option", settings.nativeArguments(for: provider, autoApprove: false).contains("test-model"))
        }
        settings.planMode = true
        audit.equal("Grok plan mode disables session yolo", settings.grokMetadata(autoApprove: true)["yoloMode"] as? Bool, false)
        settings.providerConfiguration = "{invalid"
        audit.check("invalid configuration rejected", (try? settings.validate()) == nil)
        settings.providerConfiguration = "{}"
        settings.maxBudget = "nan"
        audit.check("nonfinite budget rejected", (try? settings.validate()) == nil)
        settings.maxBudget = ""
        settings.mcpConfiguration = #"{"studio_computer":{"command":"evil"}}"#
        audit.check("built-in computer server cannot be shadowed", (try? settings.validate()) == nil)
        for (name, args) in [("open_url", ["url": "file:///etc/passwd"] as [String: Any]),
                             ("open_url", ["url": "javascript:alert(1)"]),
                             ("scroll", ["app": "test", "direction": "vertical", "amount": 31]),
                             ("click", ["app": "test", "x": Double.greatestFiniteMagnitude, "y": 0, "button": "left", "screenshot_id": "x"]),
                             ("press_key", ["app": "test", "key": "cmd+execute"]),
                             ("preview_open", ["url": "http://example.com/"]),
                             ("preview_open", ["url": "http://user:secret@localhost:3000/"]),
                             ("preview_click", ["selector": "#go", "extra": "no"]),
                             ("screenshot", ["unexpected": true])] {
            audit.check("invalid \(name) arguments rejected", (try? ComputerControl.validate(name: name, arguments: args)) == nil)
        }
        for target in ["app.orrery.studio", "app.orrery.studio.preview", "com.apple.systempreferences", "com.apple.SecurityAgent"] {
            audit.check("computer control cannot target \(target)", (try? ComputerControl.checkTarget(target)) == nil)
        }
        audit.equal("assistant modes are named for what they do", AssistantMode.allCases.map(\.rawValue), ["Solo", "Team", "Roundtable", "CLI"])
        audit.check("Claude offers specific versions besides the reported aliases",
                    ClaudeBackend().knownVersions.contains { $0.id == "claude-opus-4-8" } && ClaudeBackend().knownVersions.contains { $0.id == "claude-sonnet-4-6" })
        audit.check("providers whose catalog is explicit list no separate versions", GrokBackend().knownVersions.isEmpty && CodexBackend().knownVersions.isEmpty)
        let naming = AppModel(trust: .forAudit)
        audit.check("the toolbar model menu is named for its agent", naming.modelMenuTitle(for: .claude).hasPrefix("Claude · ") && naming.modelMenuTitle(for: .grok).hasPrefix("Grok · "))
        audit.check("wrong capability token rejected", !ComputerControl.matchesToken("wrong", "right"))
        audit.check("valid capability token accepted", ComputerControl.matchesToken("same", "same"))
        await Auditor.withTemporaryDirectory { root in
            let model = AppModel(trust: .forAudit)
            model.installed = [:]
            model.projectURL = root
            defer { model.shutdown() }
            do {
                let control = try ComputerControl(model: model, project: root, groups: Set(ToolGroup.allCases))
                model.computerControl = control
                var teamSettings = AgentSessionSettings()
                teamSettings.instructions = "Project instructions"
                teamSettings.resumeSession = "existing-chat"
                teamSettings.networkAccess = false
                model.agentSettings[.codex] = teamSettings
                let teamBackend = model.orchestrator.makeBackend(.codex)
                audit.check("Team retains project instructions before runtime guidance", teamBackend.sessionSettings.instructions.hasPrefix(teamSettings.instructions + "\n\n"))
                audit.equal("Team starts a fresh conversation", teamBackend.sessionSettings.resumeSession, "")
                audit.check("Team receives enabled computer connection", teamBackend.computerConnection != nil)
                model.autoApprove = true
                audit.check("project automatic-tools preference applies to Team", model.orchestrator.autoApprove)
                let connection = control.connection(for: .grok)
                let mode = try FileManager.default.attributesOfItem(atPath: connection.socketPath)[.posixPermissions] as? Int
                audit.equal("computer socket restricted to owner", mode, 0o600)
                let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
                let payload: [String: Any] = ["token": connection.token, "provider": "grok", "request": request]
                let reply = await Task.detached { try? ComputerMCPBridge.call(path: connection.socketPath, payload: payload) }.value
                audit.equal("actual Unix connection lists all tools", JSON(reply)["result"]["tools"].array.count, 38)
                audit.equal("ten desktop and IDE tools plus five local preview tools", JSON(reply)["result"]["tools"].array.filter { ($0["name"].string ?? "").hasPrefix("preview_") }.count, 5)
                var unauthorized = payload; unauthorized["token"] = "not-the-token"
                let denied = await control.respond(unauthorized)
                audit.check("server rejects unauthenticated request", JSON(denied)["error"].exists)
                var action = payload
                action["request"] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "show_panel", "arguments": ["panel": "editor"]]]
                let result = await control.respond(action)
                audit.check("session-granted tool executes end to end", JSON(result)["result"]["isError"].bool == false && model.workspaceLayout == .editor)
                audit.check("session grant requires no repeated approval", model.permissionQueue.isEmpty)
                if !CGPreflightScreenCaptureAccess() {
                    var screenshot = action
                    screenshot["request"] = ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "screenshot", "arguments": [:]]]
                    let unavailable = await control.respond(screenshot)
                    audit.check("missing macOS screen permission fails clearly", JSON(unavailable)["result"]["isError"].bool == true)
                }
                control.askBeforeEachAction = true
                // IDE tools never ask; the per-action prompt belongs to desktop and browser tools.
                var desktopAction = payload
                desktopAction["request"] = ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "list_apps", "arguments": [:]]]
                let pending = Task { await control.respond(desktopAction) }
                for _ in 0..<100 where model.permissionQueue.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
                audit.check("optional per-action mode queues approval", model.permissionQueue.count == 1)
                model.pendingPermission?.reply("deny")
                let rejected = await pending.value
                audit.check("denial returns a tool error", JSON(rejected)["result"]["isError"].bool == true)
                let revokedPending = Task { await control.respond(desktopAction) }
                for _ in 0..<100 where model.permissionQueue.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
                control.stop()
                let revokedReply = await revokedPending.value
                audit.check("stop clears a pending computer request", model.permissionQueue.isEmpty && JSON(revokedReply)["result"]["isError"].bool == true)
                let afterStop = await control.respond(payload)
                audit.check("revocation immediately blocks tools", JSON(afterStop)["error"].exists)
                for provider in Provider.allCases {
                    model.provider = provider
                    model.nativeArguments[provider] = "--help"
                    model.startNativeCLI(waitForView: false)
                    if let session = model.nativeSessions[provider] {
                        // The launch itself may be deferred to a later task; wait for it to begin.
                        for _ in 0..<100 where !session.isRunning && session.exitStatus == nil && session.startFailure == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
                        for _ in 0..<200 where session.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
                        audit.check("\(provider.displayName) native CLI exits successfully", session.exitStatus == 0,
                                    "exit \(session.exitStatus.map(String.init) ?? "nil") running=\(session.isRunning) startFailure=\(session.startFailure ?? "none") screen: \(session.emulator.screenText().trimmingCharacters(in: .whitespacesAndNewlines).prefix(300).replacingOccurrences(of: "\n", with: " | "))")
                        audit.check("\(provider.displayName) native CLI renders help in its terminal", !session.emulator.screenText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else if ToolchainWatch.locate(provider) == nil {
                        audit.skip("\(provider.displayName) native CLI session exists", "\(provider.displayName) CLI is not installed on this machine")
                    } else { audit.check("\(provider.displayName) native CLI session exists", false) }
                }
                let textURL = root.appendingPathComponent("notes.txt")
                let deferred = TerminalSession(directory: root)
                deferred.start(executable: "/bin/sh", arguments: ["-c", "stty size"], environment: ["PATH": "/usr/bin:/bin"], whenVisible: true)
                deferred.resize(cols: 91, rows: 31)
                for _ in 0..<100 where deferred.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
                audit.check("deferred CLI launches with its measured viewport", deferred.emulator.screenText().contains("31 91"))
                let cancelledLaunch = TerminalSession(directory: root)
                cancelledLaunch.start(executable: "/usr/bin/true", arguments: [], environment: [:], whenVisible: true)
                cancelledLaunch.resize(cols: 90, rows: 30)
                cancelledLaunch.terminate()
                try? await Task.sleep(nanoseconds: 80_000_000)
                audit.check("closing a pending CLI prevents its launch", !cancelledLaunch.isRunning && cancelledLaunch.exitStatus == nil)
                try Data("attachment-content".utf8).write(to: textURL)
                let attachment = try MessageAttachment(url: textURL)
                for provider in Provider.allCases {
                    audit.check("\(provider.displayName) text attachments preserve contents", (attachment.content(for: provider)["text"] as? String)?.contains("attachment-content") == true)
                }
                let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
                let imageURL = root.appendingPathComponent("sample.png")
                try image.representation(using: .png, properties: [:])!.write(to: imageURL)
                let picture = try MessageAttachment(url: imageURL)
                audit.equal("image attachments are normalized to PNG", picture.mimeType, "image/png")
                audit.equal("Grok image block", picture.content(for: .grok)["type"] as? String, "image")
                audit.equal("Claude image block", JSON(picture.content(for: .claude))["source"]["type"].string, "base64")
                audit.check("Codex image data URL", (picture.content(for: .codex)["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
                let bad = root.appendingPathComponent("binary.bin")
                try Data([0, 255, 0]).write(to: bad)
                audit.check("unsupported binary attachment rejected", (try? MessageAttachment(url: bad)) == nil)
            } catch { audit.check("computer fixture setup", false, error.localizedDescription) }
        }

        audit.section("Approvals — a blanket bypass covers every project and mode")
        await Auditor.withTemporaryDirectory { dir in
            let one = dir.appendingPathComponent("one"), two = dir.appendingPathComponent("two")
            try? FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
            let model = AppModel(trust: .forAudit)
            defer { model.blanketApproval = false; model.shutdown() }
            model.openProject(one)
            audit.check("approvals are on by default", !model.autoApprove && !model.blanketApproval)
            model.blanketApproval = true
            audit.check("the blanket switch makes this project run tools without asking", model.autoApprove && model.roundtable.autoApprove && model.orchestrator.autoApprove)
            audit.check("…and is saved as a global preference", AppModel.preferences.bool(forKey: AppModel.blanketApprovalKey))
            audit.check("the per-project rule itself is untouched", !model.projectAutoApprove)
            let other = AppModel(trust: .forAudit)
            defer { other.shutdown() }
            other.openProject(two)
            audit.check("another project, in another window, sees the blanket bypass", other.autoApprove)
            audit.check("native CLI launches get the bypass flags",
                        AgentSessionSettings().nativeArguments(for: .claude, autoApprove: other.autoApprove).contains("bypassPermissions")
                        && AgentSessionSettings().nativeArguments(for: .codex, autoApprove: other.autoApprove).contains("never"))
            audit.check("computer and browser actions skip the per-action prompt under the blanket bypass",
                        !ComputerControl.needsApproval(group: .desktop, askBeforeEachAction: true, blanket: true)
                        && ComputerControl.needsApproval(group: .desktop, askBeforeEachAction: true, blanket: false)
                        && !ComputerControl.needsApproval(group: .ide, askBeforeEachAction: true, blanket: false))
            audit.check("the blanket bypass gives every agent the browser and the simulator without their own switches",
                        !model.browserAgentsAllowed && !model.simulatorAgentsAllowed && model.agentsMayUseBrowser && model.agentsMayUseSimulator
                        && model.baseToolGroups.isSuperset(of: [.browser, .simulator]))
            audit.check("…and the agents' browser opens with no site named (the site list still bounds navigation)", (try? model.agentBrowserController()) != nil)
            audit.check("…and computer control is on for this project", model.computerControl?.desktopEnabled == true)
            audit.check("…and for the other window's project too", other.computerControl?.desktopEnabled == true)
            model.blanketApproval = false
            audit.check("switching it off restores per-project approvals in every window", !model.autoApprove && !other.autoApprove && !other.blanketApproval)
            audit.check("…and takes the browser and simulator back with it", !model.agentsMayUseBrowser && !model.agentsMayUseSimulator && !model.baseToolGroups.contains(.browser) && !model.baseToolGroups.contains(.simulator))
        }
    }
}

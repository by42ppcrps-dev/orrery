import Foundation
import CryptoKit
import OrreryRemoteProtocol
import OrreryRemoteClient

@MainActor
enum AuditActivity {
    static func run(_ audit: Auditor) async {
        audit.section("Activity — multiple Macs and independent viewers using the shipping client")
        await Auditor.withTemporaryDirectory { dir in
            let models = (0..<3).map { _ in AppModel(trust: .forAudit) }
            defer { models.forEach { $0.shutdown() } }
            for (index, model) in models.enumerated() {
                let path = dir.appendingPathComponent("workspace-\(index)")
                try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                model.openProject(path); model.installed = [.grok: true, .claude: true]; model.provider = .grok
                for provider in [Provider.grok, .claude] {
                    let backend = ScriptedBackend(provider: provider, scripts: [[.assistantDelta("answer from \(index) \(provider.rawValue)"), .turnFinished(stopReason: "end_turn", costUSD: nil)]])
                    model.backends[provider] = backend
                    backend.onEvent = { [weak model] event in model?.handle(event, from: provider) }
                    await backend.start(project: path, autoApprove: false)
                }
            }
            let first = RemoteControl(preferences: AppModel.preferences, directory: dir.appendingPathComponent("mac-a"))
            let second = RemoteControl(preferences: AppModel.preferences, directory: dir.appendingPathComponent("mac-b"))
            first.preferredPort = 0; second.preferredPort = 0
            first.attach(models[0]); first.attach(models[1]); second.attach(models[2])
            models[0].remote = first; models[1].remote = first; models[2].remote = second
            first.enabled = true; second.enabled = true
            defer { first.enabled = false; second.enabled = false }
            audit.check("two independent hosts can listen at the same time", await wait { first.listening && second.listening && first.port != second.port })
            let key = RemoteCrypto.PrivateKey(), otherKey = RemoteCrypto.PrivateKey()
            var saved: [RemoteClient.PairedMac] = []
            var saves = 0
            let hub = RemoteHub(read: { saved }, write: { saved = $0; saves += 1 }, identityProvider: { key })
            hub.setActive(true)
            defer { hub.setActive(false) }
            guard let a = hub.add() else { audit.check("first pairing can begin", false); return }
            @MainActor func pair(_ client: RemoteClient, _ host: RemoteControl) {
                host.startPairing()
                guard var offer = host.offer else { return }
                offer.hosts = ["127.0.0.1"]
                client.pair(with: offer.qrString, deviceName: "Audit viewer")
            }
            pair(a, first)
            audit.check("the shipping client pairs and saves one verified Mac", await wait { a.phase == .connected && saved.count == 1 && saves == 1 })
            guard let b = hub.add() else { audit.check("second pairing can begin", false); return }
            pair(b, second)
            audit.check("adding a second Mac keeps the first connected", await wait { b.phase == .connected && a.phase == .connected && saved.count == 2 })
            audit.check("each Mac carries only its own projects", a.state?.projects?.count == 2 && b.state?.projects?.count == 1 && b.state?.project == "workspace-2")
            let viewer = RemoteClient(identityProvider: { otherKey })
            defer { viewer.setActive(false) }
            pair(viewer, first)
            audit.check("a second device connects without replacing the first", await wait { viewer.phase == .connected && first.connectedDevices.count == 2 && a.isLive })
            guard let secondProject = a.state?.projects?.last?.id,
                  let solo = a.state?.activities?.first(where: { $0.projectID == secondProject && $0.mode == "solo" && $0.provider == "claude" }),
                  let team = viewer.state?.activities?.first(where: { $0.mode == "team" }) else {
                audit.check("activity lists all projects and agent modes", false); return
            }
            audit.check("all installed Solo agents, Team and Roundtable appear", a.state?.activities?.count == 8 && Set(a.state?.activities?.map(\.mode) ?? []) == ["solo", "team", "roundtable"])
            a.selectActivity(solo); viewer.selectActivity(team)
            let premature = await a.sendMessage("must not reach the previous conversation", target: "solo", provider: "grok")
            audit.check("controls cannot send to the old conversation while selection loads", !premature && models.allSatisfy { model in model.states.values.allSatisfy { !$0.entries.contains { $0.text == "must not reach the previous conversation" } } })
            audit.check("each viewer can choose its own project and conversation", await wait { a.state?.projectID == secondProject && a.state?.provider == "claude" && a.state?.mode == "Solo" && viewer.state?.mode == "Team" })
            audit.check("viewing does not change either Mac window", models[0].assistantMode == .chat && models[1].assistantMode == .chat && models[1].provider == .grok)
            let delivered = await a.sendMessage("target the selected agent", target: "solo", provider: "claude")
            audit.check("a remote send reaches the selected agent without changing the Mac's selection", delivered && models[1].states[.claude]?.entries.contains { $0.kind == .user && $0.text == "target the selected agent" } == true && models[1].provider == .grok)
            audit.check("the other host never receives the message", models[2].states.values.allSatisfy { !$0.entries.contains { $0.text == "target the selected agent" } })
            models[0].update(.claude) { $0.inFlight = 1; $0.status = "Working in the background" }
            audit.check("background activity reaches both viewers without changing their detail view", await wait {
                a.state?.activities?.contains { $0.project == "workspace-0" && $0.provider == "claude" && $0.isBusy } == true && viewer.state?.activities?.contains { $0.project == "workspace-0" && $0.provider == "claude" && $0.isBusy } == true && a.state?.projectID == secondProject && viewer.state?.mode == "Team"
            })
            a.connect()
            audit.check("reconnecting preserves the selected project, mode and provider", await wait { a.isLive && a.state?.projectID == secondProject && a.state?.provider == "claude" && a.state?.mode == "Solo" })
            let grok = models[1].backends[.grok] as? ScriptedBackend
            let claude = models[1].backends[.claude] as? ScriptedBackend
            await a.stop()
            audit.check("Stop targets the viewed agent and leaves other agents alone", claude?.cancelCount == 1 && grok?.cancelCount == 0 && models[1].provider == .grok)
            var decision: String?
            models[1].handle(.permission(.init(title: "Approve the selected project", detail: "audit", options: [.init(id: "deny", name: "Deny", kind: "reject_once")], reply: { decision = $0 })), from: .claude)
            audit.check("pending decisions update the all-project dashboard", await wait { a.state?.activities?.contains { $0.projectID == secondProject && $0.approvalCount > 0 } == true && a.state?.permissions.isEmpty == false })
            if let permission = a.state?.permissions.first { await a.approve(permission.id, option: "deny") }
            audit.check("confirmed approval reaches its owning project", decision == "deny")
            first.detach(models[1]); a.refresh()
            audit.check("a closed project clears its detail and disappears from activity", await wait { a.state?.project == nil && a.state?.activities?.contains { $0.projectID == secondProject } == false })
            let terminal = TerminalSession(directory: dir)
            terminal.start(executable: "/bin/sleep", arguments: ["20"], environment: [:])
            models[0].nativeSessions[.grok] = terminal
            audit.check("native CLI sessions appear even while Solo is selected", first.snapshot().activities?.contains { $0.mode == "cli" && $0.isBusy } == true && first.snapshot().projects?.first?.isBusy == true)
            _ = await first.perform(.init(kind: .stop, target: "cli", provider: "grok", projectID: first.snapshot().projectID))
            audit.check("explicit CLI Stop ends the selected terminal", await wait { !terminal.isRunning })
            models[0].orchestrator.seedDemo()
            let demo = first.snapshot(mode: "team")
            audit.check("Team detail includes attributed worker replies", demo.entries.contains { $0.speaker.contains("author") && !$0.text.isEmpty })
            audit.check("demo Team activity cannot look like live work", demo.status.contains("Demo") && demo.activities?.filter { $0.mode == "team" }.allSatisfy { !$0.isBusy && $0.title.hasPrefix("Demo:") } == true)
            let connectedID = viewer.mac?.deviceID ?? "missing"
            first.revoke(connectedID)
            audit.check("revoking one device disconnects it while another viewer stays live", await wait { !viewer.isLive && a.isLive && b.isLive })
            hub.setActive(false)
            audit.check("backgrounding marks every cached snapshot as paused", hub.clients.allSatisfy { !$0.isLive && $0.connectionLabel == "Paused" && $0.state != nil })
            let restored = RemoteHub(read: { saved }, write: { saved = $0 }, identityProvider: { key })
            restored.load()
            audit.check("both pairings survive a fresh hub without persisting transcripts", restored.clients.count == 2 && restored.clients.allSatisfy { $0.state == nil && !$0.isLive })
            a.forget()
            audit.check("forgetting one Mac preserves the other pairing", saved.count == 1 && saved.first?.serverPublicKey == second.serverPublicKey && hub.clients.count == 1)
            var failWrite = true
            let protected = RemoteHub(read: { saved }, write: { _ in if failWrite { throw CocoaError(.fileWriteNoPermission) } }, identityProvider: { key })
            protected.load(); protected.clients.first?.forget()
            audit.check("a storage failure cannot pretend a Mac was forgotten", protected.clients.count == 1 && protected.clients.first?.mac != nil && protected.clients.first?.lastError != nil)
            failWrite = false
            let blocked = RemoteHub(read: { throw CocoaError(.fileReadNoPermission) }, write: { _ in }, identityProvider: { key })
            blocked.load()
            audit.check("an inaccessible pairing store is reported and cannot be overwritten", blocked.error != nil && blocked.add() == nil)
        }
        await relayIntegration(audit)
        audit.section("Activity — transport bounds and compatibility")
        let row = RemoteState.Activity(id: "x", projectID: "p", project: String(repeating: "🪐", count: 2000), mode: "solo", provider: "grok", title: "Large activity", status: String(repeating: "🪐", count: 2000), isBusy: true)
        let state = RemoteState(macName: "Mac", project: "p", mode: "Solo", provider: "grok", providers: ["grok"], isBusy: true, status: "Working", entries: [], permissions: [], sentAt: Date(timeIntervalSince1970: 1_700_000_000), activities: (0..<1000).map { index in var value = row; value.id = "row-\(index)"; return value }, activityCount: 1000)
        let bounded = state.boundedForTransport()
        audit.check("large activity lists fit a sealed frame and disclose truncation", RemotePayload(state: bounded).encoded().count < RemoteProtocol.maxFrameBytes && (bounded.activities?.count ?? 0) <= 200 && bounded.activityCount == 1000)
        audit.check("new activity fields round-trip without replacing the selected conversation", RemotePayload.decode(RemotePayload(state: bounded).encoded())?.state == bounded)
        audit.check("activity search matches a project without inventing rows", state.matchingActivities(query: "large", scope: .working).count == 1000 && state.matchingActivities(query: "missing", scope: .all).isEmpty)
        audit.check("decision filter excludes work with no pending approvals", state.matchingActivities(query: "", scope: .decisions).isEmpty)
        let id = UUID().uuidString
        audit.check("relay data preserves an opaque session envelope", RelayPacket.decode(RelayPacket(type: "relay.data", id: id, data: "sealed-envelope").encoded())?.data == "sealed-envelope")
        audit.check("malformed relay channels and oversized messages are refused", RelayPacket.decode(RelayPacket(type: "relay.open", id: "invalid").encoded()) == nil && RelayPacket.decode(Data(count: RelayPacket.maxBytes + 1)) == nil)
        audit.check("routing control packets cannot smuggle a payload", RelayPacket.decode(RelayPacket(type: "relay.open", id: id, data: "payload").encoded()) == nil)
    }
    private static func relayIntegration(_ audit: Auditor) async {
        audit.section("Activity — shipping Mac and clients through the actual relay Worker")
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let relay = root.appendingPathComponent("Remote/OrreryRelay")
        guard let node = Executables.find([], orNamed: "node"),
              FileManager.default.fileExists(atPath: relay.appendingPathComponent("node_modules/miniflare/package.json").path) else {
            audit.skip("multi-viewer Worker integration", "Install Node.js and run npm ci in Remote/OrreryRelay to enable the real relay test.")
            return
        }
        await Auditor.withTemporaryDirectory { dir in
            let portFile = dir.appendingPathComponent("relay-port")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [relay.appendingPathComponent("tests/serve.js").path, portFile.path]
            process.currentDirectoryURL = relay
            process.environment = ["PATH": URL(fileURLWithPath: node).deletingLastPathComponent().path + ":/usr/bin:/bin", "TMPDIR": dir.path, "CI": "1"]
            let trace = dir.appendingPathComponent("relay-trace")
            FileManager.default.createFile(atPath: trace.path, contents: nil)
            let traceHandle = try? FileHandle(forWritingTo: trace)
            process.standardOutput = traceHandle; process.standardError = traceHandle
            defer { try? traceHandle?.close() }
            do { try process.run() } catch { audit.check("local relay runtime starts", false, error.localizedDescription); return }
            defer { if process.isRunning { process.terminate() } }
            guard await wait({ FileManager.default.fileExists(atPath: portFile.path) }),
                  let rawPort = try? String(contentsOf: portFile, encoding: .utf8), let port = UInt16(rawPort) else {
                audit.check("local relay runtime exposes its test port", false); return
            }
            let model = AppModel(trust: .forAudit)
            let project = dir.appendingPathComponent("project")
            try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            model.openProject(project); model.installed = [.grok: true]; model.provider = .grok
            // The provider setter schedules startup. Install the scripted backend before
            // yielding so a real CLI cannot race and overwrite this fixture's live status.
            let backend = ScriptedBackend(provider: .grok, scripts: [])
            model.backends[.grok] = backend
            backend.onEvent = { [weak model] event in model?.handle(event, from: .grok) }
            await backend.start(project: project, autoApprove: false)
            let control = RemoteControl(preferences: AppModel.preferences, directory: dir.appendingPathComponent("remote"))
            control.preferredPort = 0; control.attach(model); model.remote = control
            defer { control.enabled = false; control.relayURL = ""; model.shutdown() }
            control.relayURL = "http://127.0.0.1:\(port)"; control.enabled = true
            audit.check("the Mac connects to the actual Worker", await wait { control.listening && control.relayStatus == "waiting for the phone" })
            let keyA = RemoteCrypto.PrivateKey(), keyB = RemoteCrypto.PrivateKey()
            let a = RemoteClient(identityProvider: { keyA }), b = RemoteClient(identityProvider: { keyB })
            defer { a.setActive(false); b.setActive(false) }
            @MainActor func pair(_ client: RemoteClient) {
                control.startPairing()
                guard var offer = control.offer else { return }
                // A closed local port forces the shipping client's real relay fallback.
                offer.hosts = ["127.0.0.1"]; offer.port = 1
                client.pair(with: offer.qrString, deviceName: "Relay audit viewer")
            }
            pair(a)
            audit.check("first viewer pairs through the actual Worker", await wait(seconds: 20) { a.isLive && a.viaRelay }, "\(a.lastError ?? a.connectionLabel); host \(control.relayStatus); paired \(control.devices.count)")
            pair(b)
            audit.check("second viewer pairs through a separate encrypted relay channel", await wait(seconds: 20) { a.isLive && b.isLive && b.viaRelay && control.connectedDevices.count == 2 }, "\(b.lastError ?? b.connectionLabel); host \(control.relayStatus); paired \(control.devices.count)")
            guard let team = a.state?.activities?.first(where: { $0.mode == "team" }),
                  let solo = b.state?.activities?.first(where: { $0.mode == "solo" }) else { audit.check("relay activity is available", false); return }
            a.selectActivity(team); b.selectActivity(solo)
            audit.check("relay viewers receive only their selected conversations", await wait { !a.selecting && !b.selecting && a.state?.mode == "Team" && b.state?.mode == "Solo" })
            model.update(.grok) { $0.status = "Relay activity changed"; $0.inFlight = 1 }
            audit.check("a live change is encrypted separately for both relay viewers", await wait { a.state?.activities?.contains { $0.status == "Relay activity changed" } == true && b.state?.status == "Relay activity changed" }, "A: \(a.state?.activities?.map(\.status) ?? []), B: \(b.state?.provider ?? "none") \(b.state?.status ?? "none"), host: \(control.snapshot().status)")
            control.revoke(a.mac?.deviceID ?? "missing")
            audit.check("relay revocation drops one viewer and keeps the other updating", await wait { !a.isLive && b.isLive && control.connectedDevices.count == 1 })
            b.connect()
            audit.check("a relay viewer reconnects after revocation of its peer", await wait { b.isLive && b.state?.mode == "Solo" })
        }
    }

    private static func wait(seconds: Int = 6, _ predicate: () -> Bool) async -> Bool {
        for _ in 0..<(seconds * 50) {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }
}

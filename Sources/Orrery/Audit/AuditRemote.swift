import Foundation
import Network
import CryptoKit
import OrreryRemoteProtocol

/// Remote control: the protocol's pure parts first (offer codes, sealed frames, key agreement),
/// then a phone — a real WebSocket client on loopback — pairing with the right and wrong codes,
/// opening a session, sending a message, receiving the agent's answer as a push, approving a
/// tool request, being refused on replay, and being cut off when the switch goes off or the
/// device is removed.
@MainActor
enum AuditRemote {
    static func run(_ audit: Auditor) async {
        audit.section("Remote — pairing codes, sealed frames and key agreement")
        let offer = PairingOffer(name: "Audit Mac", hosts: ["127.0.0.1"], port: 4242, serverPublicKey: Data(repeating: 1, count: 32),
                                 token: Data(repeating: 2, count: 32), expires: Date(timeIntervalSince1970: 2_000_000_000))
        audit.check("a pairing offer round-trips through its QR text", PairingOffer.parse(offer.qrString) == offer && offer.qrString.hasPrefix(RemoteProtocol.qrPrefix))
        audit.check("a code without the prefix, or with short keys, is refused",
                    PairingOffer.parse("hello") == nil && PairingOffer.parse(RemoteProtocol.qrPrefix + RemoteCoding.base64url(Data("{\"version\":1,\"name\":\"x\",\"hosts\":[],\"port\":1,\"serverPublicKey\":\"AA==\",\"token\":\"AA==\",\"expires\":1}".utf8))) == nil)
        let key = SymmetricKey(size: .bits256)
        let client = RemoteSealer(key: key, isClient: true), server = RemoteSealer(key: key, isClient: false)
        let frame = (try? client.seal(Data("hi".utf8))) ?? Data()
        audit.equal("a sealed frame opens on the other side", try? server.open(frame), Data("hi".utf8))
        audit.check("the same frame again is refused as a replay", (try? server.open(frame)) == nil)
        var tampered = (try? client.seal(Data("hi".utf8))) ?? Data()
        if !tampered.isEmpty { tampered[tampered.count - 1] ^= 0x01 }
        audit.check("a tampered frame is refused", (try? server.open(tampered)) == nil)
        audit.check("a frame sealed for the other direction is refused", (try? client.open((try? client.seal(Data("x".utf8))) ?? Data())) == nil)
        audit.check("an oversized frame is refused before sealing", (try? client.seal(Data(count: RemoteProtocol.maxFrameBytes + 1))) == nil)
        let a = RemoteCrypto.PrivateKey(), b = RemoteCrypto.PrivateKey(), ea = RemoteCrypto.PrivateKey(), eb = RemoteCrypto.PrivateKey()
        let n1 = RemoteCrypto.randomToken(), n2 = RemoteCrypto.randomToken()
        let k1 = try? RemoteCrypto.sessionKey(localStatic: a, remoteStatic: b.publicKey, localEphemeral: ea, remoteEphemeral: eb.publicKey, clientNonce: n1, serverNonce: n2)
        let k2 = try? RemoteCrypto.sessionKey(localStatic: b, remoteStatic: a.publicKey, localEphemeral: eb, remoteEphemeral: ea.publicKey, clientNonce: n1, serverNonce: n2)
        let k3 = try? RemoteCrypto.sessionKey(localStatic: a, remoteStatic: b.publicKey, localEphemeral: RemoteCrypto.PrivateKey(), remoteEphemeral: eb.publicKey, clientNonce: n1, serverNonce: n2)
        audit.check("both sides derive the same session key", k1 != nil && k1 == k2)
        audit.check("a different ephemeral key gives a different session key", k1 != k3)
        audit.check("token comparison is constant-time and exact", RemoteCrypto.equal(n1, n1) && !RemoteCrypto.equal(n1, n2) && !RemoteCrypto.equal(n1, n1.dropLast()))

        audit.section("Remote — bounded state and explicit project routing")
        var invalidOffer = offer
        invalidOffer.hosts = []
        audit.check("empty pairing addresses are rejected", PairingOffer.parse(invalidOffer.qrString) == nil)
        invalidOffer = offer; invalidOffer.port = 0
        audit.check("port zero cannot be paired", PairingOffer.parse(invalidOffer.qrString) == nil)
        invalidOffer = offer; invalidOffer.hosts = ["host/path"]
        audit.check("pairing addresses cannot inject URL paths", PairingOffer.parse(invalidOffer.qrString) == nil)
        let huge = RemoteState(macName: "Mac", project: "test", mode: "Solo", provider: "grok", providers: ["grok"], isBusy: false, status: "Ready",
                               entries: (0..<40).map { .init(id: "entry-\($0)", speaker: "Agent", kind: "assistant", text: String(repeating: "💫\n", count: 12_000)) }, permissions: [])
        let bounded = huge.boundedForTransport()
        audit.check("large Unicode transcripts stay inside the sealed frame limit", RemotePayload(state: bounded).encoded().count < RemoteProtocol.maxFrameBytes)
        audit.check("bounding keeps the newest entry", bounded.entries.last?.id == huge.entries.last?.id)
        let legacy = RemotePayload(state: RemoteState(macName: "Mac", project: nil, mode: "Solo", provider: "grok", providers: [], isBusy: false, status: "Ready", entries: [], permissions: []))
        audit.check("legacy state still decodes without project or acknowledgement fields", RemotePayload.decode(legacy.encoded())?.state?.projectID == nil)
        let acknowledged = RemotePayload(acknowledgedCommandID: "request-1")
        audit.equal("command acknowledgement survives the wire", RemotePayload.decode(acknowledged.encoded())?.acknowledgedCommandID, "request-1")
        await Auditor.withTemporaryDirectory { dir in
            let first = AppModel(trust: .forAudit), second = AppModel(trust: .forAudit)
            defer { first.shutdown(); second.shutdown() }
            for (index, model) in [first, second].enumerated() {
                let path = dir.appendingPathComponent("project-\(index)")
                try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                model.openProject(path); model.installed = [.grok: true]; model.provider = .grok
            }
            let control = RemoteControl(preferences: AppModel.preferences, directory: dir.appendingPathComponent("control"))
            control.attach(first); control.attach(second)
            first.remote = control; second.remote = control
            let state = control.snapshot()
            audit.equal("one remote service lists both open projects", state.projects?.count, 2)
            let firstID = state.projects?.first?.id ?? "missing", secondID = state.projects?.last?.id ?? "missing"
            let restarted = RemoteControl(preferences: AppModel.preferences, directory: dir.appendingPathComponent("restart"))
            restarted.attach(first)
            audit.equal("project identity survives recreating the remote service", restarted.snapshot().projectID, firstID)
            audit.equal("a selected project gets its own snapshot", control.snapshot(projectID: secondID).project, "project-1")
            audit.check("a stale project is not silently replaced with the active project", control.snapshot(projectID: "closed").project == nil)
            let stale = await control.perform(RemoteCommand(kind: .send, text: "not delivered", target: "solo", projectID: "closed"))
            audit.check("commands for closed projects are rejected", stale != nil && first.state.entries.isEmpty && second.state.entries.isEmpty)
            let unknown = await control.perform(RemoteCommand(kind: .send, text: "not delivered", target: "typo", projectID: firstID))
            audit.check("an unknown mode never falls through to Solo", unknown != nil)
            let missing = await control.perform(RemoteCommand(kind: .send, text: "not delivered", target: "solo", provider: "missing", projectID: firstID))
            audit.check("an unknown provider is rejected instead of using another agent", missing != nil)
            var chosen: String?
            second.handle(.permission(PermissionRequest(title: "Second project approval", detail: "test", options: [.init(id: "deny", name: "Deny", kind: "reject_once")], reply: { chosen = $0 })), from: .grok)
            let approvalID = second.permissionQueue.first?.id.uuidString ?? "missing"
            let wrong = await control.perform(RemoteCommand(kind: .approve, text: "deny", target: approvalID, projectID: firstID))
            audit.check("an approval cannot cross project boundaries", wrong != nil && chosen == nil)
            let right = await control.perform(RemoteCommand(kind: .approve, text: "deny", target: approvalID, projectID: secondID))
            audit.check("the same approval works for its owning project", right == nil && chosen == "deny")
            let modeChange = await control.perform(RemoteCommand(kind: .state, target: "team", projectID: firstID))
            audit.check("choosing a remote mode leaves the Mac conversation unchanged", modeChange == nil && first.assistantMode == .chat && first.state.entries.isEmpty)
            first.orchestrator.installedProviders = [.grok, .claude]
            first.orchestrator.makeBackend = { ScriptedBackend(provider: $0, scripts: []) }
            first.orchestrator.start(task: "Wait for a phone stop", project: dir)
            audit.check("the Team stop fixture starts a real run", first.orchestrator.isRunning)
            _ = await control.perform(RemoteCommand(kind: .stop, target: "team", projectID: firstID))
            audit.check("phone Stop cancels Team rather than a Solo conversation", !first.orchestrator.isRunning && first.orchestrator.phase == .cancelled)
            first.assistantMode = .chat
            let busyBackend = ScriptedBackend(provider: .grok, scripts: [])
            await busyBackend.start(project: dir, autoApprove: false)
            first.backends[.grok] = busyBackend
            first.states[.grok] = ProviderState()
            first.states[.grok]?.inFlight = 1
            first.taskQueues[.grok] = (0..<12).map { QueuedTaskPrompt(text: "Queued \($0)", attachments: []) }
            let fullQueue = await control.perform(RemoteCommand(kind: .send, text: "must stay on phone", target: "solo", projectID: firstID))
            audit.check("a full queue cannot produce a false delivery acknowledgement", fullQueue != nil && first.taskQueues[.grok]?.count == 12)
            control.detach(first)
            audit.check("closing one project preserves the others", control.snapshot().projects?.count == 1 && control.snapshot().project == "project-1")
            audit.check("the closed project's ID is invalidated", !control.projectExists(firstID))
        }

        audit.section("Remote — a phone on loopback: pair, session, send, push, approve, replay, revoke")
        await Auditor.withTemporaryDirectory { dir in
            let project = dir.appendingPathComponent("project", isDirectory: true)
            try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let model = AppModel(trust: .forAudit)
            defer { model.shutdown() }
            model.installed = [.grok: true, .claude: false, .codex: false]
            model.openProject(project)
            model.provider = .grok
            let backend = ScriptedBackend(provider: .grok, scripts: [
                [.assistantDelta("scripted answer from the Mac"), .turnFinished(stopReason: "end_turn", costUSD: nil)],
                [.assistantDelta("second answer"), .turnFinished(stopReason: "end_turn", costUSD: nil)],
            ])
            backend.currentModel = "grok-audit"
            model.backends[.grok] = backend
            backend.onEvent = { [weak model] event in model?.handle(event, from: .grok) }
            await backend.start(project: project, autoApprove: false)
            model.handle(.connected(sessionID: "remote-audit"), from: .grok)

            let control = RemoteControl(preferences: AppModel.preferences, directory: dir.appendingPathComponent("remote", isDirectory: true))
            control.attach(model)
            model.remote = control   // the model notifies this instance of every change
            audit.check("remote control is off until switched on", !control.enabled && !control.listening)
            control.enabled = true
            _ = await waitUntil(4) { control.listening }
            audit.check("switching it on listens on a free port", control.listening && control.port != 0, control.lastError ?? "port \(control.port)")
            let keyFile = dir.appendingPathComponent("remote/server.key")
            let mode = (try? FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            audit.check("the Mac's key is stored owner-only", mode & 0o777 == 0o600)
            audit.check("no offer exists until pairing starts", control.offer == nil)
            control.startPairing()
            guard let offer = control.offer, let serverKey = try? RemoteCrypto.PublicKey(rawRepresentation: offer.serverPublicKey) else {
                audit.check("a pairing offer is produced", false); return
            }
            audit.check("the offer names the port, this Mac's key and a five-minute lifetime",
                        offer.port == control.port && offer.serverPublicKey == control.serverPublicKey && offer.expires.timeIntervalSinceNow > 250 && offer.token.count == 32)
            audit.check("the QR text parses back", PairingOffer.parse(offer.qrString) == offer)

            let deviceKey = RemoteCrypto.PrivateKey()
            let devicePub = deviceKey.publicKey.rawRepresentation
            func pairingEnvelope(token: Data, name: String) -> RemoteEnvelope? {
                guard let pairKey = try? RemoteCrypto.pairingKey(local: deviceKey, remote: serverKey, token: token),
                      let body = try? RemoteCoding.encoder.encode(PairingRequest(token: token, deviceName: name)),
                      let sealed = try? RemoteSealer(key: pairKey, isClient: true).seal(body) else { return nil }
                return RemoteEnvelope(type: "pair", devicePublicKey: devicePub, sealed: sealed)
            }

            let impostor = RemoteTestClient(port: control.port)
            audit.check("a phone can connect on loopback", await impostor.connect())
            let refused = await impostor.exchange(pairingEnvelope(token: Data(repeating: 9, count: 32), name: "Impostor")!)
            audit.check("a wrong pairing code is refused, nothing is paired, the offer survives",
                        refused?.type == "error" && control.devices.isEmpty && control.offer != nil, refused?.message ?? "no reply")
            _ = await waitUntil(2) { impostor.closed }
            audit.check("…and that connection is dropped", impostor.closed)

            let phone = RemoteTestClient(port: control.port)
            _ = await phone.connect()
            let paired = await phone.exchange(pairingEnvelope(token: offer.token, name: "Audit iPhone")!)
            let pairKey = try? RemoteCrypto.pairingKey(local: deviceKey, remote: serverKey, token: offer.token)
            let pairedReplyOpens = paired?.sealed.flatMap { sealed in pairKey.flatMap { try? RemoteSealer(key: $0, isClient: true).open(sealed) } } != nil
            audit.check("the right code pairs the device and the reply is sealed with the pairing key",
                        paired?.type == "paired" && paired?.deviceID != nil && pairedReplyOpens && control.devices.count == 1 && control.devices.first?.name == "Audit iPhone", paired?.message ?? paired?.type ?? "no reply")
            audit.check("the offer is consumed by the pairing", control.offer == nil)
            let deviceID = paired?.deviceID ?? ""
            let again = RemoteTestClient(port: control.port)
            _ = await again.connect()
            let reused = await again.exchange(pairingEnvelope(token: offer.token, name: "Again")!)
            audit.check("the same code cannot pair a second time", reused?.type == "error" && control.devices.count == 1)

            let session = RemoteTestClient(port: control.port)
            _ = await session.connect()
            let ephemeral = RemoteCrypto.PrivateKey()
            let clientNonce = RemoteCrypto.randomToken()
            let welcome = await session.exchange(RemoteEnvelope(type: "hello", deviceID: deviceID, ephemeral: ephemeral.publicKey.rawRepresentation, nonce: clientNonce))
            guard welcome?.type == "welcome", let serverEphemeral = welcome?.ephemeral, let serverNonce = welcome?.nonce, let welcomeSealed = welcome?.sealed,
                  let serverEphemeralKey = try? RemoteCrypto.PublicKey(rawRepresentation: serverEphemeral),
                  let sessionKey = try? RemoteCrypto.sessionKey(localStatic: deviceKey, remoteStatic: serverKey, localEphemeral: ephemeral, remoteEphemeral: serverEphemeralKey, clientNonce: clientNonce, serverNonce: serverNonce) else {
                audit.check("a paired device is welcomed with the Mac's ephemeral key and nonce", false, welcome?.message ?? welcome?.type ?? "no reply"); return
            }
            audit.check("a paired device is welcomed with the Mac's ephemeral key and nonce", true)
            let sealer = RemoteSealer(key: sessionKey, isClient: true)
            let welcomeState = (try? sealer.open(welcomeSealed)).flatMap(RemotePayload.decode)?.state
            audit.check("the welcome carries a sealed snapshot: Solo, the project name, no approvals pending",
                        welcomeState?.mode == "Solo" && welcomeState?.project == "project" && welcomeState?.permissions.isEmpty == true && welcomeState?.providers == ["grok"], welcomeState.map { "\($0.mode) \($0.project ?? "-")" } ?? "no state")
            audit.check("the device's last-seen time is recorded", control.devices.first?.lastSeen != nil && control.connectedDevices == [deviceID])

            let sendFrame = (try? sealer.seal(RemotePayload(command: RemoteCommand(kind: .send, text: "Hello from the phone", target: "solo", provider: "grok", id: "live-send-1", projectID: welcomeState?.projectID)).encoded())) ?? Data()
            let sendReply = await session.exchange(RemoteEnvelope(type: "frame", sealed: sendFrame), timeout: 6)
            let sendState = sendReply?.sealed.flatMap { try? sealer.open($0) }.flatMap(RemotePayload.decode)
            audit.check("a message sent from the phone lands in the Solo transcript and the reply comes back sealed",
                        sendState?.error == nil && sendState?.state?.entries.contains { $0.kind == "user" && $0.text == "Hello from the phone" } == true, sendState?.error ?? "no reply")
            audit.equal("a live send returns its command acknowledgement", sendState?.acknowledgedCommandID, "live-send-1")
            var answerSeen = sendState?.state?.entries.contains { $0.kind == "assistant" && $0.text.contains("scripted answer") } == true
            var seen: [String] = ["reply: " + (sendState?.state?.entries.map { "\($0.kind)=\($0.text.prefix(20))" }.joined(separator: ",") ?? "nil")]
            for _ in 0..<6 where !answerSeen {
                guard let pushed = await session.next(timeout: 2) else { seen.append("timeout"); break }
                guard let envelope = RemoteEnvelope.decode(pushed) else { seen.append("undecodable"); break }
                guard let sealed = envelope.sealed else { seen.append("type \(envelope.type) \(envelope.message ?? "")"); break }
                guard let opened = try? sealer.open(sealed) else { seen.append("open failed"); break }
                guard let state = RemotePayload.decode(opened)?.state else { seen.append("no state"); break }
                seen.append("push: " + state.entries.map { "\($0.kind)=\($0.text.prefix(20))" }.joined(separator: ","))
                answerSeen = state.entries.contains { $0.kind == "assistant" && $0.text.contains("scripted answer") }
            }
            audit.check("the agent's answer reaches the phone (in the reply or a push) without asking", answerSeen, seen.joined(separator: " | "))

            var replied: String?
            model.handle(.permission(PermissionRequest(title: "Write notes.md", detail: "the file",
                                                       options: [PermissionOption(id: "allow-once", name: "Allow", kind: "allow_once"), PermissionOption(id: "reject-once", name: "Deny", kind: "reject_once")],
                                                       reply: { replied = $0 })), from: .grok)
            var permissionID: String?
            for _ in 0..<6 where permissionID == nil {
                guard let pushed = await session.next(timeout: 2), let envelope = RemoteEnvelope.decode(pushed), let sealed = envelope.sealed,
                      let state = (try? sealer.open(sealed)).flatMap(RemotePayload.decode)?.state else { break }
                permissionID = state.permissions.first?.id
                if let permission = state.permissions.first {
                    audit.check("a tool request is pushed with its provider, title and options",
                                permission.provider == "grok" && permission.title.contains("Write notes.md") && permission.options.map(\.id) == ["allow-once", "reject-once"])
                }
            }
            audit.check("the pending approval reached the phone", permissionID != nil)
            let approveFrame = (try? sealer.seal(RemotePayload(command: RemoteCommand(kind: .approve, text: "allow-once", target: permissionID ?? "")).encoded())) ?? Data()
            let approveReply = await session.exchange(RemoteEnvelope(type: "frame", sealed: approveFrame), timeout: 4)
            let approveState = approveReply?.sealed.flatMap { try? sealer.open($0) }.flatMap(RemotePayload.decode)
            audit.check("approving from the phone answers the request on the Mac", replied == "allow-once" && model.permissionQueue.isEmpty && approveState?.state?.permissions.isEmpty == true)
            let replay = await session.exchange(RemoteEnvelope(type: "frame", sealed: approveFrame), timeout: 4)
            audit.check("a replayed frame is refused and the session dropped", replay?.type == "error" && replay?.message?.contains("refused") == true, replay?.message ?? "no reply")
            _ = await waitUntil(2) { session.closed }

            let stranger = RemoteTestClient(port: control.port)
            _ = await stranger.connect()
            let unknown = await stranger.exchange(RemoteEnvelope(type: "hello", deviceID: "not-paired", ephemeral: RemoteCrypto.PrivateKey().publicKey.rawRepresentation, nonce: RemoteCrypto.randomToken()))
            audit.check("an unpaired device gets no session", unknown?.type == "error")
            let garbage = RemoteTestClient(port: control.port)
            _ = await garbage.connect()
            let junk = await garbage.exchange(RemoteEnvelope(type: "frame", sealed: Data(repeating: 7, count: 40)))
            audit.check("a frame before the handshake is refused", junk?.type == "error")

            audit.section("Remote — through a relay, from any network")
            let fakeRelay = FakeRelay()
            let relayPort = await fakeRelay.start()
            audit.check("a stand-in relay listens on loopback", relayPort != 0)
            control.relayURL = "http://127.0.0.1:\(relayPort)"
            control.startPairing()
            let relayOffer = control.offer
            audit.check("with a relay set, the pairing code carries the relay, this Mac's room and the room token",
                        relayOffer?.relay == control.relayURL && relayOffer?.room == control.relayRoom && (relayOffer?.relayToken?.count ?? 0) >= 16
                        && PairingOffer.parse(relayOffer?.qrString ?? "") == relayOffer, relayOffer?.qrString.prefix(60).description ?? "no offer")
            audit.check("the room is 16 URL-safe characters made from the Mac's key, so it survives restarts",
                        control.relayRoom.count == 16 && RemoteControl(preferences: AppModel.preferences, directory: dir.appendingPathComponent("remote", isDirectory: true)).relayRoom == control.relayRoom)
            let tokenMode = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("remote/relay.token").path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            audit.check("the room token is stored owner-only", tokenMode & 0o777 == 0o600, String(tokenMode, radix: 8))
            control.cancelPairing()
            audit.check("the phone's relay address is wss on https relays and ws on http ones",
                        relayOffer?.relayURL(side: "phone")?.absoluteString == "ws://127.0.0.1:\(relayPort)/phone/\(control.relayRoom)?token=\(relayOffer?.relayToken ?? "")"
                        && PairingOffer(name: "m", hosts: ["h"], port: 1, serverPublicKey: offer.serverPublicKey, token: offer.token, expires: Date(), relay: "https://relay.example", room: "abcdefghij", relayToken: "0123456789abcdef").relayURL(side: "mac")?.absoluteString == "wss://relay.example/mac/abcdefghij?token=0123456789abcdef")
            audit.check("a malformed relay in a pairing code is refused", !PairingOffer(name: "m", hosts: ["h"], port: 1, serverPublicKey: offer.serverPublicKey, token: offer.token, expires: Date(), relay: "ftp://x", room: "ab", relayToken: "short").relayIsValid)
            audit.check("the Mac connects out to the relay and waits for a phone", await waitUntil(5) { control.relayStatus == "waiting for the phone" }, control.relayStatus)
            audit.equal("…and the relay saw exactly one Mac socket", fakeRelay.macConnections, 1)

            func handshake(_ client: RemoteTestClient) async -> (RemoteSealer, RemoteState?)? {
                let ephemeral = RemoteCrypto.PrivateKey()
                let clientNonce = RemoteCrypto.randomToken()
                let welcome = await client.exchange(RemoteEnvelope(type: "hello", deviceID: deviceID, ephemeral: ephemeral.publicKey.rawRepresentation, nonce: clientNonce), timeout: 5)
                guard welcome?.type == "welcome", let serverEphemeral = welcome?.ephemeral, let serverNonce = welcome?.nonce, let welcomeSealed = welcome?.sealed,
                      let serverEphemeralKey = try? RemoteCrypto.PublicKey(rawRepresentation: serverEphemeral),
                      let key = try? RemoteCrypto.sessionKey(localStatic: deviceKey, remoteStatic: serverKey, localEphemeral: ephemeral, remoteEphemeral: serverEphemeralKey, clientNonce: clientNonce, serverNonce: serverNonce) else { return nil }
                let sealer = RemoteSealer(key: key, isClient: true)
                return (sealer, (try? sealer.open(welcomeSealed)).flatMap(RemotePayload.decode)?.state)
            }
            let relayPhone = RemoteTestClient(port: relayPort)
            audit.check("a phone reaches the relay", await relayPhone.connect())
            let relayed = await handshake(relayPhone)
            audit.check("a phone through the relay completes the same handshake and gets the sealed snapshot", relayed?.1?.project == "project", control.relayStatus)
            audit.check("…and the Mac shows the phone as connected through the relay", control.relayPhoneConnected)
            if let (relaySealer, relayState) = relayed {
                let frame = (try? relaySealer.seal(RemotePayload(command: RemoteCommand(kind: .send, text: "Hello through the relay", target: "solo", provider: "grok", id: "relay-send-1", projectID: relayState?.projectID)).encoded())) ?? Data()
                let reply = await relayPhone.exchange(RemoteEnvelope(type: "frame", sealed: frame), timeout: 6)
                let replied = reply?.sealed.flatMap { try? relaySealer.open($0) }.flatMap(RemotePayload.decode)
                audit.check("a message sent through the relay lands in the transcript and its sealed reply comes back",
                            replied?.acknowledgedCommandID == "relay-send-1" && replied?.state?.entries.contains { $0.kind == "user" && $0.text == "Hello through the relay" } == true, reply?.message ?? reply?.type ?? "no reply")
            }
            fakeRelay.dropMac()
            audit.check("when the relay drops the Mac's socket (a phone left), the Mac comes back for the next phone",
                        await waitUntil(6) { fakeRelay.macConnections == 2 && control.relayStatus == "waiting for the phone" }, "\(fakeRelay.macConnections) \(control.relayStatus)")
            let secondPhone = RemoteTestClient(port: relayPort)
            _ = await secondPhone.connect()
            audit.check("a second phone session through the relay works on the fresh socket", (await handshake(secondPhone))?.1?.project == "project")
            control.relayURL = ""
            audit.check("clearing the relay address ends the outbound leg", await waitUntil(3) { control.relayStatus == "off" && !control.relayPhoneConnected }, control.relayStatus)
            control.relayURL = "not a url"
            audit.check("a bad relay address is reported, not dialled", control.relayStatus.contains("not a valid"), control.relayStatus)
            control.relayURL = ""
            fakeRelay.stop()

            control.revoke(deviceID)
            audit.check("removing a device forgets it", control.devices.isEmpty && control.connectedDevices.isEmpty)
            let revoked = RemoteTestClient(port: control.port)
            _ = await revoked.connect()
            let afterRevoke = await revoked.exchange(RemoteEnvelope(type: "hello", deviceID: deviceID, ephemeral: RemoteCrypto.PrivateKey().publicKey.rawRepresentation, nonce: RemoteCrypto.randomToken()))
            audit.check("…and it can no longer open a session", afterRevoke?.type == "error")

            control.enabled = false
            audit.check("switching it off stops listening at once", !control.listening && control.port == 0 && control.offer == nil)
            let late = RemoteTestClient(port: offer.port)
            audit.check("nothing accepts connections afterwards", !(await late.connect()))
            audit.check("the switch is a saved preference", !AppModel.preferences.bool(forKey: RemoteControl.enabledKey))
        }
        await AuditActivity.run(audit)
    }

    private static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

/// A minimal phone: one WebSocket connection on loopback, messages in an inbox.
@MainActor
final class RemoteTestClient {
    private let connection: NWConnection
    private var inbox: [Data] = []
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Data?, Never>)] = []
    private(set) var closed = false
    private var connectContinuation: CheckedContinuation<Bool, Never>?

    init(port: UInt16) {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        // A WebSocket client needs the URL form: the upgrade request carries the host and path.
        connection = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)")!), using: parameters)
    }

    func connect() async -> Bool {
        await withCheckedContinuation { continuation in
            connectContinuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.connectContinuation?.resume(returning: true); self.connectContinuation = nil
                    case .failed, .cancelled:
                        self.closed = true
                        self.connectContinuation?.resume(returning: false); self.connectContinuation = nil
                        let pending = self.waiters; self.waiters = []
                        for waiter in pending { waiter.continuation.resume(returning: nil) }
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
            receive()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run { self?.connectContinuation?.resume(returning: false); self?.connectContinuation = nil }
            }
        }
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    if let waiter = self.waiters.first { self.waiters.removeFirst(); waiter.continuation.resume(returning: data) } else { self.inbox.append(data) }
                }
                if error == nil, !self.closed { self.receive() } else if error != nil {
                    self.closed = true
                    let pending = self.waiters; self.waiters = []
                    for waiter in pending { waiter.continuation.resume(returning: nil) }
                }
            }
        }
    }

    func send(_ envelope: RemoteEnvelope) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "orrery", metadata: [metadata])
        connection.send(content: envelope.encoded(), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func next(timeout: TimeInterval) async -> Data? {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if closed { return nil }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters.append((id, continuation))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run {
                    guard let self, let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                    let waiter = self.waiters.remove(at: index)
                    waiter.continuation.resume(returning: nil)
                }
            }
        }
    }

    func exchange(_ envelope: RemoteEnvelope, timeout: TimeInterval = 3) async -> RemoteEnvelope? {
        send(envelope)
        guard let data = await next(timeout: timeout) else { return nil }
        return RemoteEnvelope.decode(data)
    }
}


/// A stand-in relay for the audit: the first WebSocket in is the Mac, the next one the phone,
/// frames go across unchanged, and `dropMac` does what the real relay does when a phone leaves.
@MainActor
final class FakeRelay {
    private var listener: NWListener?
    private var mac: NWConnection?
    private var phone: NWConnection?
    private(set) var macConnections = 0
    private var ready: CheckedContinuation<UInt16, Never>?

    func start() async -> UInt16 {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = RemoteProtocol.maxFrameBytes * 2
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: parameters, on: .any) else { return 0 }
        self.listener = listener
        return await withCheckedContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if case .ready = state { self.ready?.resume(returning: listener.port?.rawValue ?? 0); self.ready = nil }
                    if case .failed = state { self.ready?.resume(returning: 0); self.ready = nil }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self else { connection.cancel(); return }
                    if self.mac == nil { self.mac = connection; self.macConnections += 1 } else { self.phone?.cancel(); self.phone = connection }
                    connection.stateUpdateHandler = { [weak self, weak connection] state in
                        MainActor.assumeIsolated {
                            guard let self, let connection else { return }
                            switch state {
                            case .failed, .cancelled:
                                if self.mac === connection { self.mac = nil }
                                if self.phone === connection { self.phone = nil; self.mac?.cancel() }   // phone gone → Mac reconnects
                            default: break
                            }
                        }
                    }
                    connection.start(queue: .main)
                    self.pump(connection)
                }
            }
            listener.start(queue: .main)
        }
    }

    private func pump(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self, let connection else { return }
                let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
                if opcode == .close || error != nil { connection.cancel(); return }
                if let data, !data.isEmpty {
                    let other = connection === self.mac ? self.phone : self.mac
                    let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
                    other?.send(content: data, contentContext: NWConnection.ContentContext(identifier: "relay", metadata: [metadata]), isComplete: true, completion: .contentProcessed { _ in })
                }
                self.pump(connection)
            }
        }
    }

    func dropMac() { mac?.cancel() }

    func stop() {
        phone?.cancel(); mac?.cancel()
        listener?.cancel(); listener = nil
    }
}

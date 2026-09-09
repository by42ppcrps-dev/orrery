import Foundation
import Network
import CryptoKit
import Security
import Combine
import OrreryRemoteProtocol

@MainActor
public final class RemoteClient: ObservableObject, Identifiable {
    public struct PairedMac: Codable, Equatable {
        public var deviceID: String
        public var name: String
        public var hosts: [String]
        public var port: UInt16
        public var serverPublicKey: Data
        /// Set when the Mac's pairing code carried a relay: the way in from any network.
        public var relay: String? = nil
        public var room: String? = nil
        public var relayToken: String? = nil
        public init(deviceID: String, name: String, hosts: [String], port: UInt16, serverPublicKey: Data,
                    relay: String? = nil, room: String? = nil, relayToken: String? = nil) {
            self.deviceID = deviceID; self.name = name; self.hosts = hosts; self.port = port
            self.serverPublicKey = serverPublicKey; self.relay = relay; self.room = room; self.relayToken = relayToken
        }
        public var isValid: Bool {
            !deviceID.isEmpty && PairingOffer.parse(PairingOffer(name: name, hosts: hosts, port: port, serverPublicKey: serverPublicKey,
                token: Data(repeating: 0, count: 32), expires: Date(), relay: relay, room: room, relayToken: relayToken).qrString) != nil
        }
        public var hasRelay: Bool { relay != nil && room != nil && relayToken != nil }
    }
    public enum Phase: Equatable { case unpaired, connecting, connected, failed(String) }
    @Published public private(set) var mac: PairedMac?
    @Published public private(set) var phase: Phase = .unpaired
    @Published public private(set) var state: RemoteState?
    @Published public private(set) var lastError: String?
    @Published public private(set) var sending = false
    @Published public private(set) var selecting = false
    private var selectionCommandID: String?
    @Published public var drafts: [String: String] = [:]
    @Published public private(set) var lastReceived: Date?
    /// True while the current connection goes through the relay rather than the local network.
    @Published public private(set) var viaRelay = false

    private var connection: NWConnection?
    private var sealer: RemoteSealer?
    private var identity: RemoteCrypto.PrivateKey?
    private var ephemeral: RemoteCrypto.PrivateKey?
    private var clientNonce = Data()
    private var pendingPairing: (offer: PairingOffer, key: SymmetricKey, name: String)?
    private var hostIndex = 0
    private var retryCount = 0
    private var desiredProjectID: String?
    private var desiredMode: String?
    private var desiredProvider: String?
    private var active = true
    private var reconnectTask: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var acknowledgements: [String: CheckedContinuation<Bool, Never>] = [:]
    public let id = UUID()
    public var onPaired: ((PairedMac) throws -> Void)?
    public var onForget: (() throws -> Void)?
    private let identityProvider: @MainActor () throws -> RemoteCrypto.PrivateKey
    public init(mac: PairedMac? = nil, identityProvider: @escaping @MainActor () throws -> RemoteCrypto.PrivateKey = RemoteClient.deviceKey) {
        self.mac = mac; self.identityProvider = identityProvider
    }
    public var isLive: Bool { phase == .connected && Date().timeIntervalSince(lastReceived ?? .distantPast) < 15 }
    public var connectionLabel: String {
        if isLive { return viaRelay ? "Live · relay" : "Live · direct" }
        if phase == .connecting { return "Connecting" }
        if case .failed(let reason) = phase, reason == "Connection paused" { return "Paused" }
        return "Offline"
    }

    public static func deviceKey() throws -> RemoteCrypto.PrivateKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "app.orrery.remote.devicekey", kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return try RemoteCrypto.PrivateKey(rawRepresentation: data) }
        guard status == errSecItemNotFound else { throw ClientError.message("Unlock this device to access its pairing key.") }
        let key = RemoteCrypto.PrivateKey()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "app.orrery.remote.devicekey", kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let saved = SecItemAdd(add as CFDictionary, nil)
        if saved == errSecDuplicateItem { return try deviceKey() }
        guard saved == errSecSuccess else { throw ClientError.message("The pairing key could not be saved securely. Try again after unlocking this device.") }
        return key
    }

    public func pair(with text: String, deviceName: String) {
        guard let offer = PairingOffer.parse(text) else { lastError = "That is not a valid Orrery pairing code."; return }
        guard !offer.isExpired else { lastError = "This code expired. Make a new one on the Mac."; return }
        do {
            let identity = try identityProvider()
            let serverKey = try RemoteCrypto.PublicKey(rawRepresentation: offer.serverPublicKey)
            let key = try RemoteCrypto.pairingKey(local: identity, remote: serverKey, token: offer.token)
            disconnect()
            self.identity = identity
            pendingPairing = (offer, key, deviceName)
            lastError = nil; state = nil; desiredProjectID = nil
            mac = PairedMac(deviceID: "", name: offer.name, hosts: offer.hosts, port: offer.port, serverPublicKey: offer.serverPublicKey,
                            relay: offer.relay, room: offer.room, relayToken: offer.relayToken)
            hostIndex = 0; retryCount = 0
            connect()
        } catch { lastError = error.localizedDescription }
    }

    public func cancelPairing() {
        disconnect(); pendingPairing = nil
        if mac?.deviceID.isEmpty == true { mac = nil }
        phase = mac == nil ? .unpaired : .failed("Disconnected")
    }

    public func forget() {
        do { try onForget?() } catch { lastError = error.localizedDescription; return }
        disconnect(); pendingPairing = nil; identity = nil
        mac = nil; state = nil; lastError = nil; desiredProjectID = nil; drafts = [:]
        phase = .unpaired
    }

    public func setActive(_ value: Bool) {
        active = value
        if value {
            if mac != nil, phase != .connected { hostIndex = 0; connect() }
        } else { disconnect() }
    }

    public func connect() {
        guard active, let mac, !mac.hosts.isEmpty, mac.port > 0 else { return }
        disconnect(keepPhase: true)
        do { identity = try identityProvider() }
        catch { fail(error.localizedDescription, retry: false); return }
        if let pendingPairing, pendingPairing.offer.isExpired { fail("Pairing code expired. Generate a new code on the Mac.", retry: false); return }
        // Every local address first; when none answers and the pairing carried a relay, go through it.
        let relayTurn = hostIndex >= mac.hosts.count && mac.hasRelay
        let url: URL
        if relayTurn {
            let offer = PairingOffer(name: mac.name, hosts: mac.hosts, port: mac.port, serverPublicKey: mac.serverPublicKey,
                                     token: Data(repeating: 0, count: 32), expires: Date(), relay: mac.relay, room: mac.room, relayToken: mac.relayToken)
            guard let relayURL = offer.relayURL(side: "phone") else { fail("The relay address is invalid. Pair again.", retry: false); return }
            url = relayURL
        } else {
            let host = mac.hosts[hostIndex % mac.hosts.count]
            var address = URLComponents(); address.scheme = "ws"; address.host = host; address.port = Int(mac.port)
            guard let direct = address.url else { fail("The Mac address is invalid. Pair again.", retry: false); return }
            url = direct
        }
        viaRelay = relayTurn
        phase = .connecting
        let parameters: NWParameters = url.scheme == "wss" ? .tls : .tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        // JSON base64 wrapping makes a sealed frame larger than its plaintext.
        websocket.maximumMessageSize = RemoteProtocol.maxFrameBytes * 2
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready: self.pendingPairing == nil ? self.sendHello() : self.sendPairing()
                case .failed: self.tryNextHost()
                case .cancelled: self.fail("Connection closed.", retry: true)
                default: break // .waiting gets a bounded deadline, not an endless spinner.
                }
            }
        }
        deadline = Task { [weak self, weak connection] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, let connection, self.connection === connection, self.phase != .connected else { return }
            self.tryNextHost()
        }
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func tryNextHost() {
        guard let mac else { return }
        if hostIndex + 1 < mac.hosts.count { hostIndex += 1; connect() }
        else if hostIndex < mac.hosts.count, mac.hasRelay { hostIndex = mac.hosts.count; connect() }   // the relay, once the LAN is exhausted
        else {
            hostIndex = 0
            fail(mac.hasRelay ? "Can't reach your Mac directly or through its relay. Keep Orrery open with Remote control enabled; the relay needs the Mac online."
                              : "Can't reach your Mac. Keep Orrery open and use the same Wi-Fi or your VPN, or set up a relay on the Mac. Check that Remote control is enabled.", retry: pendingPairing == nil)
        }
    }

    private func fail(_ reason: String, retry: Bool) {
        disconnect(keepPhase: true)
        phase = .failed(reason); lastError = reason
        guard retry, active, mac?.deviceID.isEmpty == false else { return }
        retryCount += 1
        let seconds = min(30, 3 * retryCount)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.active else { return }
            self.connect()
        }
    }

    public func disconnect(keepPhase: Bool = false) {
        reconnectTask?.cancel(); deadline?.cancel(); heartbeat?.cancel()
        let old = connection; connection = nil; old?.cancel()
        sealer = nil; ephemeral = nil
        selecting = false; selectionCommandID = nil
        let pending = acknowledgements.values; acknowledgements.removeAll()
        for continuation in pending { continuation.resume(returning: false) }
        if !keepPhase, mac != nil { phase = .failed("Connection paused") }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, complete, error in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if error != nil || metadata?.opcode == .close || (complete && data == nil && context == nil) {
                    if self.phase == .connecting { self.tryNextHost() }
                    else { self.fail("Connection lost. Reconnecting…", retry: true) }
                    return
                }
                if let data, !data.isEmpty { self.handle(data) }
                if self.connection === connection { self.receive(on: connection) }
            }
        }
    }

    private func send(_ envelope: RemoteEnvelope) {
        guard let connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "orrery", metadata: [metadata])
        connection.send(content: envelope.encoded(), contentContext: context, isComplete: true, completion: .contentProcessed { [weak self, weak connection] error in
            Task { @MainActor in
                guard let error, let self, let connection, self.connection === connection else { return }
                if self.phase == .connecting { self.tryNextHost() }
                else { self.fail("Delivery interrupted: \(error.localizedDescription). Check the conversation before sending again.", retry: true) }
            }
        })
    }

    private func sendPairing() {
        guard let pending = pendingPairing, let identity else { return }
        do {
            let request = PairingRequest(token: pending.offer.token, deviceName: pending.name)
            let sealed = try RemoteSealer(key: pending.key, isClient: true).seal(RemoteCoding.encoder.encode(request))
            send(RemoteEnvelope(type: "pair", devicePublicKey: identity.publicKey.rawRepresentation, sealed: sealed))
        } catch { fail("Could not prepare secure pairing.", retry: false) }
    }

    private func sendHello() {
        guard let mac else { return }
        let ephemeral = RemoteCrypto.PrivateKey(); self.ephemeral = ephemeral
        clientNonce = RemoteCrypto.randomToken()
        send(RemoteEnvelope(type: "hello", deviceID: mac.deviceID, ephemeral: ephemeral.publicKey.rawRepresentation, nonce: clientNonce))
    }

    private func handle(_ data: Data) {
        guard data.count <= RemoteProtocol.maxFrameBytes * 2, let envelope = RemoteEnvelope.decode(data) else {
            fail("The Mac sent an invalid message.", retry: false); return
        }
        switch envelope.type {
        case "paired":
            guard sealer == nil, let pending = pendingPairing, let identity,
                  let id = envelope.deviceID,
                  id == RemoteCoding.base64url(Data(SHA256.hash(data: identity.publicKey.rawRepresentation)).prefix(12)),
                  let sealed = envelope.sealed,
                  (try? RemoteSealer(key: pending.key, isClient: true).open(sealed)) != nil else {
                fail("Pairing reply could not be verified.", retry: false); return
            }
            guard var paired = mac else { fail("Pairing was cancelled.", retry: false); return }
            paired.deviceID = id
            do { try onPaired?(paired) }
            catch { fail("Could not save pairing securely. \(error.localizedDescription)", retry: false); return }
            pendingPairing = nil; mac = paired
            sendHello()
        case "welcome":
            guard sealer == nil, let mac, let identity, let ephemeral,
                  let serverEphemeral = envelope.ephemeral, let serverNonce = envelope.nonce, serverNonce.count == 32,
                  let sealed = envelope.sealed,
                  let serverStatic = try? RemoteCrypto.PublicKey(rawRepresentation: mac.serverPublicKey),
                  let serverEphemeralKey = try? RemoteCrypto.PublicKey(rawRepresentation: serverEphemeral),
                  let key = try? RemoteCrypto.sessionKey(localStatic: identity, remoteStatic: serverStatic,
                      localEphemeral: ephemeral, remoteEphemeral: serverEphemeralKey, clientNonce: clientNonce, serverNonce: serverNonce) else {
                fail("The Mac's identity could not be verified. Pair again from your Mac.", retry: false); return
            }
            let sealer = RemoteSealer(key: key, isClient: true)
            guard let plain = try? sealer.open(sealed), let payload = RemotePayload.decode(plain), payload.state != nil else {
                fail("The secure connection could not be verified.", retry: false); return
            }
            self.sealer = sealer; self.ephemeral = nil
            phase = .connected; lastError = nil; retryCount = 0; deadline?.cancel()
            if let desiredProjectID, payload.state?.projects?.contains(where: { $0.id == desiredProjectID }) == true {
                lastReceived = Date()
                select(projectID: desiredProjectID, mode: desiredMode, provider: desiredProvider)
            } else { accept(payload) }
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled, let self, self.phase == .connected else { return }
                    if Date().timeIntervalSince(self.lastReceived ?? .distantPast) > 15 {
                        self.fail("The Mac stopped responding. Reconnecting…", retry: true); return
                    }
                    self.refresh()
                }
            }
        case "frame":
            guard let sealer, let sealed = envelope.sealed, let plain = try? sealer.open(sealed), let payload = RemotePayload.decode(plain) else {
                fail("A message failed its security check. The connection was closed.", retry: false); return
            }
            accept(payload)
        case "error":
            // Unsealed errors are never accepted as authenticated session instructions.
            fail(sealer == nil ? (envelope.message ?? "The Mac refused the connection. Pair again if this device was removed.") : "The secure connection ended.", retry: false)
        default: fail("The Mac uses an unsupported remote protocol. Update Orrery on both devices.", retry: false)
        }
    }

    private func accept(_ payload: RemotePayload) {
        lastReceived = Date()
        let selectionConfirmed = selectionCommandID != nil && payload.acknowledgedCommandID == selectionCommandID
        if selectionConfirmed { selecting = false; selectionCommandID = nil }
        if let state = payload.state, !selecting {
            self.state = state; desiredProjectID = state.projectID
            desiredMode = state.mode.lowercased(); desiredProvider = state.provider.isEmpty ? nil : state.provider
        }
        if let error = payload.error { lastError = error }
        if let id = payload.acknowledgedCommandID, let continuation = acknowledgements.removeValue(forKey: id) {
            continuation.resume(returning: payload.error == nil)
        }
    }

    private func command(_ command: RemoteCommand) -> Bool {
        guard let sealer, phase == .connected, let frame = try? sealer.seal(RemotePayload(command: command).encoded()) else {
            lastError = "Not connected. Your message has been kept."; return false
        }
        send(RemoteEnvelope(type: "frame", sealed: frame)); return true
    }

    public func refresh() { guard !selecting else { return }; _ = command(RemoteCommand(kind: .state, projectID: state?.projectID)) }
    private func select(projectID: String?, mode: String? = nil, provider: String? = nil) {
        guard !sending, !selecting else { return }
        if (mode != nil || provider != nil), state?.capabilities?.contains("independent-selection") != true {
            lastError = "Update Orrery on the Mac before changing the viewed agent or mode."; return
        }
        let id = UUID().uuidString
        selecting = true; selectionCommandID = id
        if !command(RemoteCommand(kind: .state, target: mode, provider: provider, id: id, projectID: projectID)) {
            selecting = false; selectionCommandID = nil; return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.selectionCommandID == id else { return }
            self.fail("The Mac did not confirm the selected conversation. Reconnecting…", retry: true)
        }
    }
    public func selectActivity(_ activity: RemoteState.Activity) {
        select(projectID: activity.projectID, mode: activity.mode, provider: activity.provider.isEmpty ? nil : activity.provider)
    }
    public func selectProject(_ id: String) { select(projectID: id) }
    public func selectMode(_ mode: String) { select(projectID: state?.projectID, mode: mode) }
    public func selectProvider(_ provider: String) { select(projectID: state?.projectID, mode: "solo", provider: provider) }
    public func clearError() { lastError = nil }

    private func confirmed(_ command: RemoteCommand) async -> Bool {
        guard !selecting else { lastError = "Wait for the selected conversation to load."; return false }
        guard state?.capabilities?.contains("command-ack") == true else {
            lastError = "Update Orrery on the Mac to use confirmed phone controls."; return false
        }
        var request = command; let id = UUID().uuidString; request.id = id
        request.projectID = state?.projectID
        guard request.projectID != nil else { lastError = "Choose an open project first."; return false }
        lastError = nil
        return await withCheckedContinuation { continuation in
            acknowledgements[id] = continuation
            if !self.command(request) { acknowledgements.removeValue(forKey: id)?.resume(returning: false); return }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, let pending = self.acknowledgements.removeValue(forKey: id) else { return }
                self.lastError = "The Mac hasn't confirmed delivery. Your draft is kept; check the conversation before sending again."
                pending.resume(returning: false)
            }
        }
    }

    public func sendMessage(_ text: String, target: String, provider: String?) async -> Bool {
        guard !sending else { return false }
        sending = true; defer { sending = false }
        return await confirmed(RemoteCommand(kind: .send, text: text, target: target, provider: provider))
    }
    public func approve(_ permissionID: String, option: String) async { _ = await confirmed(RemoteCommand(kind: .approve, text: option, target: permissionID)) }
    public func stop() async { _ = await confirmed(RemoteCommand(kind: .stop, target: state?.mode.lowercased(), provider: state?.provider)) }
}

private enum ClientError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

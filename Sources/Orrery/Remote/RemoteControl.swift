import Foundation
import Network
import CryptoKit
import OrreryRemoteProtocol

/// Remote control from a paired phone. Off by default. When on, Orrery listens on a port of
/// the Mac's choosing (advertised over Bonjour on the local network), shows a one-time pairing
/// code, and lets paired devices read the current transcript, send messages, approve or deny
/// tool requests and stop a turn — nothing else. Every message after the handshake is sealed
/// with a key only that phone and this Mac can derive; see `RemoteProtocol`. Nothing goes
/// through any server of ours: same network, or a VPN of the user's choosing.
@MainActor @Observable
final class RemoteControl {
    struct PairedDevice: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var publicKey: Data
        var pairedAt: Date
        var lastSeen: Date?
    }

    static let shared = RemoteControl()
    @MainActor private final class ProjectReference {
        private let temporaryID = UUID().uuidString
        var id: String {
            guard let path = model?.projectURL?.resolvingSymlinksInPath().standardizedFileURL.path else { return temporaryID }
            return RemoteCoding.base64url(Data(SHA256.hash(data: Data(path.utf8))).prefix(16))
        }
        weak var model: AppModel?
        init(_ model: AppModel) { self.model = model }
    }
    private var projectReferences: [ProjectReference] = []
    private var scheduledSends: Set<String> = []

    func attach(_ model: AppModel) {
        projectReferences.removeAll { $0.model == nil || $0.model?.isShutDown == true }
        if !projectReferences.contains(where: { $0.model === model }) { projectReferences.append(ProjectReference(model)) }
        if self.model == nil { self.model = model }
        noteChange()
    }

    func detach(_ model: AppModel) {
        projectReferences.removeAll { $0.model == nil || $0.model === model }
        if self.model === model { self.model = projectReferences.first?.model }
        if projectReferences.isEmpty { stop() } else { noteChange() }
    }

    private var liveProjects: [ProjectReference] { projectReferences.filter { $0.model?.isShutDown == false && $0.model?.projectURL != nil } }
    func projectExists(_ id: String) -> Bool { liveProjects.contains { $0.id == id } }
    private func resolvedModel(_ id: String?) -> AppModel? {
        if let id { return liveProjects.first { $0.id == id }?.model }
        return model?.isShutDown == false ? model : nil
    }
    private func projectID(for model: AppModel) -> String? { liveProjects.first { $0.model === model }?.id }

    static let enabledKey = "remote.enabled.v1"
    static let maxConnections = 8
    static let commandsPerSecond = 20

    private(set) var devices: [PairedDevice] = []
    private(set) var offer: PairingOffer?
    private(set) var port: UInt16 = 0
    private(set) var listening = false
    private(set) var connectedDevices: [String] = []
    private(set) var lastError: String?
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            preferences.set(enabled, forKey: Self.enabledKey)
            if enabled { start() } else { stop() }
        }
    }
    /// Optional fixed port (0 = any free port); a fixed port survives relaunches for VPN setups.
    var preferredPort: UInt16 = 0
    /// A deployed Remote/OrreryRelay Worker (https://…workers.dev) that carries the phone's sealed
    /// frames when it is on another network. Empty means LAN or VPN only.
    static let relayURLKey = "remote.relay.url.v1"
    var relayURL: String {
        didSet {
            guard relayURL != oldValue else { return }
            preferences.set(relayURL, forKey: Self.relayURLKey)
            stopRelay()
            if enabled { startRelay() }
        }
    }
    /// "off", "connecting", "waiting for the phone", "phone connected", or an error.
    private(set) var relayStatus = "off"
    private var relayLink: RelayLink?
    private var relayToken = ""
    /// This Mac's room at the relay: made from its static key, so it survives restarts and
    /// reinstalls and never has to be typed.
    var relayRoom: String { RemoteCoding.base64url(Data(SHA256.hash(data: serverPublicKey)).prefix(12)) }

    weak var model: AppModel?
    private let preferences: UserDefaults
    private let directory: URL
    private var serverKey: RemoteCrypto.PrivateKey
    private var listener: NWListener?
    private var connections: [RemoteConnection] = []
    private var pushTask: Task<Void, Never>?

    init(preferences: UserDefaults? = nil, directory: URL = PrivateProjectFile.defaultDirectory("Remote")) {
        let preferences = preferences ?? AppModel.preferences
        self.preferences = preferences
        self.directory = directory
        enabled = preferences.bool(forKey: Self.enabledKey)
        preferredPort = UInt16(clamping: preferences.integer(forKey: "remote.port.v1"))
        relayURL = preferences.string(forKey: Self.relayURLKey) ?? ""
        serverKey = RemoteCrypto.PrivateKey()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        serverKey = Self.loadOrCreateKey(at: directory.appendingPathComponent("server.key"))
        relayToken = Self.loadOrCreateToken(at: directory.appendingPathComponent("relay.token"))
        devices = (try? JSONDecoder().decode([PairedDevice].self, from: Data(contentsOf: directory.appendingPathComponent("devices.json")))) ?? []
    }

    var serverPublicKey: Data { serverKey.publicKey.rawRepresentation }

    private static func loadOrCreateKey(at url: URL) -> RemoteCrypto.PrivateKey {
        if let data = try? Data(contentsOf: url), let key = try? RemoteCrypto.PrivateKey(rawRepresentation: data) { return key }
        let key = RemoteCrypto.PrivateKey()
        try? key.rawRepresentation.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return key
    }

    /// The room token: 32 random bytes, owner-only on disk, made once. Both sides present it to
    /// the relay; the relay checks equality and nothing else.
    private static func loadOrCreateToken(at url: URL) -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8), text.count >= 16 { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let token = RemoteCoding.base64url(RemoteCrypto.randomToken())
        try? token.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    private func saveDevices() {
        let url = directory.appendingPathComponent("devices.json")
        if let data = try? JSONEncoder().encode(devices) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    // MARK: Lifecycle

    func start() {
        guard listener == nil else { return }
        lastError = nil
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = RemoteProtocol.maxFrameBytes * 2
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters, on: preferredPort == 0 ? .any : (NWEndpoint.Port(rawValue: preferredPort) ?? .any))
            listener.service = NWListener.Service(name: nil, type: RemoteProtocol.bonjourType)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.port = listener.port?.rawValue ?? 0
                        self.listening = true
                        self.preferredPort = self.port
                        self.preferences.set(Int(self.port), forKey: "remote.port.v1")
                    case let .failed(error):
                        self.lastError = "Remote listener failed: \(error.localizedDescription)"
                        self.listening = false
                        self.listener = nil
                    case .cancelled:
                        self.listening = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self else { connection.cancel(); return }
                    guard self.connections.count < Self.maxConnections else { connection.cancel(); return }
                    let remote = RemoteConnection(connection: connection, control: self)
                    self.connections.append(remote)
                    remote.start()
                }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            lastError = "Remote listener could not start: \(error.localizedDescription)"
        }
        startRelay()
    }

    /// The outbound leg to the relay. The Mac keeps one socket open to its room; a phone that
    /// connects there talks through it exactly as it would on the LAN — same handshake, same
    /// sealed frames — and when the phone leaves, the relay closes this socket so the next
    /// phone gets a fresh session.
    private func startRelay() {
        guard enabled, relayLink == nil, !relayURL.isEmpty else { return }
        let offer = PairingOffer(name: "", hosts: ["x"], port: 1, serverPublicKey: serverPublicKey, token: Data(repeating: 0, count: 32),
                                 expires: Date(), relay: relayURL, room: relayRoom, relayToken: relayToken)
        guard offer.relayIsValid, let url = offer.relayURL(side: "mac") else { relayStatus = "the relay address is not a valid http(s) URL"; return }
        let link = RelayLink(url: url, control: self)
        relayLink = link
        link.connect()
    }

    func relayLinkChanged(_ status: String) { relayStatus = status }

    /// Ends the outbound leg and any phone session riding on it.
    private func stopRelay() {
        relayLink?.stop(); relayLink = nil
        for connection in connections where connection.viaRelay { connection.close() }
        connections.removeAll { $0.viaRelay }
        refreshConnected()
        relayStatus = "off"
    }

    func adoptRelayConnection(_ remote: RemoteConnection) {
        guard connections.count < Self.maxConnections else { remote.close(); return }
        connections.append(remote)
        remote.start()
    }

    /// For the settings pane: the relay socket is up and a phone has completed its handshake.
    var relayPhoneConnected: Bool { connections.contains { $0.viaRelay && $0.isAuthenticated } }

    func stop() {
        pushTask?.cancel(); pushTask = nil
        stopRelay()
        for connection in connections { connection.close() }
        connections = []
        connectedDevices = []
        listener?.cancel()
        listener = nil
        listening = false
        port = 0
        offer = nil
    }

    func connectionClosed(_ connection: RemoteConnection) {
        connections.removeAll { $0 === connection }
        refreshConnected()
    }

    private func refreshConnected() {
        connectedDevices = Array(Set(connections.compactMap { $0.deviceID })).sorted()
    }

    // MARK: Pairing

    /// A fresh one-time offer; the previous one is void. Requires the listener to be up.
    func startPairing() {
        guard enabled, listening, port != 0 else { offer = nil; return }
        offer = PairingOffer(name: Host.current().localizedName ?? "Mac", hosts: Self.reachableHosts(), port: port,
                             serverPublicKey: serverPublicKey, token: RemoteCrypto.randomToken(),
                             expires: Date().addingTimeInterval(RemoteProtocol.pairingLifetime),
                             relay: relayURL.isEmpty ? nil : relayURL, room: relayURL.isEmpty ? nil : relayRoom,
                             relayToken: relayURL.isEmpty ? nil : relayToken)
    }

    func cancelPairing() { offer = nil }

    func revoke(_ deviceID: String) {
        devices.removeAll { $0.id == deviceID }
        saveDevices()
        for connection in connections where connection.deviceID == deviceID { connection.close() }
        connections.removeAll { $0.deviceID == deviceID }
        refreshConnected()
    }

    /// The Mac's IPv4 addresses a phone could reach: every interface but loopback and link-local.
    static func reachableHosts() -> [String] {
        var hosts: [String] = []
        if let name = Host.current().localizedName, !name.isEmpty {
            // Use the actual Bonjour host name when available, never the display name.
            if let local = Host.current().names.first(where: { $0.hasSuffix(".local") }) { hosts.append(local) }
        }
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return hosts }
        defer { freeifaddrs(pointer) }
        for cursor in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(cursor.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = cursor.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(cString: buffer)
            if host.hasPrefix("169.254.") || hosts.contains(host) { continue }
            hosts.append(host)
        }
        return hosts
    }

    // MARK: Handshake decisions (pure enough to audit without a socket)

    enum PairingOutcome: Equatable { case paired(PairedDevice), refused(String) }

    /// Verifies a pairing envelope against the current offer. Consumes the offer on success.
    func pair(devicePublicKey: Data, sealed: Data) -> PairingOutcome {
        guard let offer, !offer.isExpired else { return .refused("No pairing is in progress on the Mac.") }
        guard devicePublicKey.count == 32, let remote = try? RemoteCrypto.PublicKey(rawRepresentation: devicePublicKey) else { return .refused("Malformed device key.") }
        guard let key = try? RemoteCrypto.pairingKey(local: serverKey, remote: remote, token: offer.token),
              let plain = try? RemoteSealer(key: key, isClient: false).open(sealed),
              let request = try? RemoteCoding.decoder.decode(PairingRequest.self, from: plain) else { return .refused("The pairing message could not be read.") }
        guard RemoteCrypto.equal(request.token, offer.token) else { return .refused("The pairing code did not match.") }
        let id = RemoteCoding.base64url(Data(SHA256.hash(data: devicePublicKey)).prefix(12))
        let device = PairedDevice(id: id, name: String(request.deviceName.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("iPhone"),
                                  publicKey: devicePublicKey, pairedAt: Date(), lastSeen: nil)
        devices.removeAll { $0.id == id }
        devices.append(device)
        saveDevices()
        self.offer = nil
        return .paired(device)
    }

    /// The pairing key for answering a successful pairing (the same key the phone used).
    func pairingReplyKey(devicePublicKey: Data, token: Data) -> SymmetricKey? {
        guard let remote = try? RemoteCrypto.PublicKey(rawRepresentation: devicePublicKey) else { return nil }
        return try? RemoteCrypto.pairingKey(local: serverKey, remote: remote, token: token)
    }

    func sessionKey(for device: PairedDevice, localEphemeral: RemoteCrypto.PrivateKey, remoteEphemeral: Data, clientNonce: Data, serverNonce: Data) -> SymmetricKey? {
        guard let remoteStatic = try? RemoteCrypto.PublicKey(rawRepresentation: device.publicKey),
              let ephemeral = try? RemoteCrypto.PublicKey(rawRepresentation: remoteEphemeral) else { return nil }
        return try? RemoteCrypto.sessionKey(localStatic: serverKey, remoteStatic: remoteStatic, localEphemeral: localEphemeral, remoteEphemeral: ephemeral,
                                            clientNonce: clientNonce, serverNonce: serverNonce)
    }

    func device(_ id: String) -> PairedDevice? { devices.first { $0.id == id } }

    func touch(_ id: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].lastSeen = Date()
        saveDevices()
        refreshConnected()
    }

    // MARK: The model bridge

    /// What a phone sees: the tail of the current conversation and the pending approvals.
    static func mode(_ target: String) -> AssistantMode? {
        switch target.lowercased() {
        case "solo": return .chat
        case "team": return .team
        case "roundtable": return .roundtable
        case "cli": return .cli
        default: return nil
        }
    }

    func snapshot(projectID selectedID: String? = nil, mode target: String? = nil, provider rawProvider: String? = nil) -> RemoteState {
        let macName = Host.current().localizedName ?? "Mac"
        guard let model = resolvedModel(selectedID) else {
            return RemoteState(macName: macName, project: nil, mode: "Solo", provider: "", providers: [], isBusy: false, status: selectedID == nil ? "No window" : "Project closed — choose another project", entries: [], permissions: [], projects: projectList, capabilities: ["projects", "command-ack", "activity", "independent-selection"], activities: activityList, activityCount: activityList.count)
        }
        let mode = target.flatMap(Self.mode) ?? model.assistantMode
        let provider = rawProvider.flatMap(Provider.init(rawValue:)) ?? model.provider
        var entries: [RemoteState.Entry] = []
        var busy = false
        var status = ""
        switch mode {
        case .roundtable:
            busy = model.roundtable.isRunning
            status = model.roundtable.notice ?? (busy ? "Roundtable is running" : "Roundtable")
            entries = model.roundtable.entries.suffix(40).map {
                RemoteState.Entry(id: $0.id.uuidString, speaker: $0.displayName, kind: $0.provider == nil ? "user" : ($0.failed ? "failure" : "assistant"), text: $0.text, costUSD: $0.costUSD)
            }
        case .team:
            busy = model.orchestrator.isRunning
            status = model.orchestrator.isDemo ? "Demo — no agents are running" : (busy ? "Team is running" : "Team")
            let team = model.orchestrator
            let logStart = max(0, team.log.count - 10)
            entries = team.log.suffix(10).enumerated().map { .init(id: "log-\(logStart + $0.offset)", speaker: "Team", kind: "system", text: $0.element) }
            let turns = team.items.flatMap { item in item.lane.suffix(5).map { (item.title, $0) } }
                .sorted { $0.1.at < $1.1.at }.suffix(20)
            entries += turns.map { title, turn in .init(id: turn.id.uuidString, speaker: turn.provider.displayName + " · " + turn.role,
                                                        kind: "assistant", text: title + "\n" + turn.text, costUSD: turn.costUSD) }
            if let live = team.planningLive {
                entries.append(.init(id: "team-planning-live", speaker: live.provider.displayName + " · orchestrator", kind: "assistant", text: live.text + "\n" + live.tools.suffix(3).joined(separator: "\n")))
            }
            for item in team.items where item.live != nil {
                let live = item.live!
                entries.append(.init(id: "live-" + item.id.uuidString, speaker: live.provider.displayName + " · " + live.role,
                                     kind: "assistant", text: item.title + "\n" + live.text + "\n" + live.tools.suffix(3).joined(separator: "\n")))
            }
        case .cli:
            busy = model.nativeSessions[provider]?.isRunning == true
            status = "Native CLI runs on the Mac. Its terminal and provider-owned prompts are available there."
        case .chat:
            let state = model.states[provider] ?? ProviderState()
            busy = state.isBusy
            status = state.status
            entries = state.entries.suffix(40).map {
                RemoteState.Entry(id: $0.id, speaker: $0.kind == .user ? "You" : provider.displayName, kind: $0.kind.rawValue,
                                  text: $0.kind == .tool ? ($0.title.isEmpty ? "Tool" : $0.title) : $0.text)
            }
        }
        let permissions = model.permissionQueue.map { request in
            RemoteState.Permission(id: request.id.uuidString, provider: model.permissionProvider(for: request.id)?.rawValue ?? "",
                                   title: request.title, detail: String(request.detail.prefix(4000)),
                                   options: request.options.map { RemoteState.Permission.Option(id: $0.id, name: $0.name, kind: $0.kind) })
        }
        return RemoteState(macName: macName, project: model.projectURL?.lastPathComponent, mode: mode.rawValue,
                           provider: provider.rawValue, providers: Provider.allCases.filter { model.installed[$0] == true }.map(\.rawValue),
                           isBusy: busy, status: status,
                           entries: entries.map { var entry = $0; entry.text = String(entry.text.prefix(12_000)); return entry },
                           permissions: Array(permissions.prefix(20)), projectID: projectID(for: model), projects: projectList,
                           capabilities: ["projects", "command-ack", "activity", "independent-selection"], activities: activityList, activityCount: activityList.count)
    }

    private var projectList: [RemoteState.Project] {
        liveProjects.map { reference in
            let model = reference.model!
            return .init(id: reference.id, name: model.projectURL?.lastPathComponent ?? "Project",
                         isBusy: model.roundtable.isRunning || model.orchestrator.isRunning || model.states.values.contains(where: \.isBusy) || model.nativeSessions.values.contains(where: \.isRunning))
        }
    }

    var activityList: [RemoteState.Activity] {
        var rows: [RemoteState.Activity] = []
        for reference in liveProjects {
            guard let model = reference.model else { continue }
            let project = model.projectURL?.lastPathComponent ?? "Project"
            let approvals = model.permissionQueue.count
            func row(_ id: String, _ mode: String, _ provider: String, _ title: String, _ status: String, _ busy: Bool, _ waiting: Int = 0) {
                rows.append(.init(id: reference.id + ":" + id, projectID: reference.id, project: project, mode: mode,
                                  provider: provider, title: title, status: status, isBusy: busy, approvalCount: waiting))
            }
            for provider in Provider.allCases where model.installed[provider] == true || !(model.states[provider]?.entries.isEmpty ?? true) {
                let state = model.states[provider] ?? ProviderState()
                let waiting = model.permissionQueue.filter { model.permissionProvider(for: $0.id) == provider }.count
                row("solo-" + provider.rawValue, "solo", provider.rawValue, provider.displayName,
                    state.status, state.isBusy || model.starting.contains(provider), waiting)
            }
            let team = model.orchestrator
            let teamStatus: String
            switch team.phase {
            case .idle: teamStatus = "Ready"
            case .planning: teamStatus = "Planning"
            case .working: teamStatus = "Working on \(team.items.count) tasks"
            case .done: teamStatus = "Finished"
            case .cancelled: teamStatus = "Stopped"
            case .failed(let reason): teamStatus = String(reason.prefix(500))
            }
            row("team", "team", team.orchestratorProvider.rawValue, team.isDemo ? "Demo: Team" : "Team", team.isDemo ? "Demo — no agents are running" : teamStatus, !team.isDemo && (team.isRunning || model.teamPreparing), approvals)
            for item in team.items {
                let live = item.live
                row("team-" + item.id.uuidString, "team", (live?.provider ?? item.author).rawValue,
                    (team.isDemo ? "Demo: " : "") + item.title, live.map { "\($0.provider.displayName) · \($0.role)" } ?? item.state.rawValue.replacingOccurrences(of: "acceptedWithObjections", with: "Accepted with objections").replacingOccurrences(of: "notConverging", with: "Needs attention").capitalized, live != nil && team.isRunning && !team.isDemo)
            }
            row("roundtable", "roundtable", "", "Roundtable", model.roundtable.notice ?? (model.roundtable.isRunning ? "Discussing" : "Ready"), model.roundtable.isRunning, approvals)
            for provider in Provider.allCases {
                if let session = model.nativeSessions[provider] {
                    row("cli-" + provider.rawValue, "cli", provider.rawValue, provider.displayName + " CLI",
                        session.isRunning ? "Terminal session open on the Mac" : "Terminal session stopped", session.isRunning)
                }
            }
        }
        // Waiting decisions and live work remain visible when transport limits trim the list.
        return rows.sorted {
            if ($0.approvalCount > 0) != ($1.approvalCount > 0) { return $0.approvalCount > 0 }
            if $0.isBusy != $1.isBusy { return $0.isBusy }
            return ($0.project.localizedStandardCompare($1.project) == .orderedAscending) || ($0.project == $1.project && $0.id < $1.id)
        }
    }

    /// Runs one command from a paired phone. Only these four things; nothing here can enable
    /// computer control, change approvals policy or touch settings.
    func perform(_ command: RemoteCommand) async -> String? {
        guard let model = resolvedModel(command.projectID) else { return "That project is no longer open. Choose a project again." }
        switch command.kind {
        case .ping: return nil
        case .state:
            if let target = command.target, Self.mode(target) == nil { return "Unknown conversation mode." }
            if let raw = command.provider, Provider(rawValue: raw) == nil { return "Unknown agent." }
            return nil
        case .send:
            let text = (command.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "Nothing to send." }
            guard text.utf8.count <= 64_000 else { return "The message is too long. Keep it below 64 KB." }
            guard command.target == nil || ["solo", "team", "roundtable"].contains(command.target!) else { return "Unknown conversation mode." }
            guard !model.taskMutationBusy else { return "The project is preparing a working copy. Try again shortly." }
            guard model.isProjectTrusted else { return "Trust the project on the Mac first." }
            if command.target == "roundtable" || (command.target == nil && model.assistantMode == .roundtable) {
                // While a run is going the phone steers it instead of being refused.
                if !model.roundtable.steer(text) {
                    let key = projectID(for: model) ?? "default"
                    guard !scheduledSends.contains(key) else { return "Roundtable is starting. Wait for it to start before steering." }
                    let previousEntries = Set(model.roundtable.entries.map(\.id))
                    scheduledSends.insert(key)
                    Task { [weak self, weak model] in
                        defer { self?.scheduledSends.remove(key) }
                        guard let model, !model.isShutDown, model.isProjectTrusted else { return }
                        await model.roundtable.send(text)
                    }
                    // Acknowledge acceptance into the conversation, not merely scheduling.
                    for _ in 0..<400 {
                        if model.roundtable.entries.contains(where: { !previousEntries.contains($0.id) && $0.text == text }) { return nil }
                        if !scheduledSends.contains(key) { return model.roundtable.notice ?? "Roundtable could not accept the message." }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    return "Roundtable is still preparing. Your draft is kept; check the conversation before sending again."
                }
            } else if command.target == "team" || (command.target == nil && model.assistantMode == .team) {
                guard !model.orchestrator.isRunning, !model.teamPreparing else { return "The team is working. Stop it before starting another task." }
                let previousTask = model.teamTaskID
                model.orchestratorDraft = text
                await model.startTeamTask()
                if model.teamTaskID == previousTask, !model.orchestrator.isRunning { return model.taskNotice ?? "The team could not start." }
            } else {
                let provider = command.provider.flatMap(Provider.init(rawValue:)) ?? model.provider
                if let raw = command.provider, Provider(rawValue: raw) == nil { return "Unknown agent." }
                guard model.installed[provider] == true else { return "Install this agent on the Mac first." }
                guard !model.starting.contains(provider), !model.taskPreparing.contains(provider) else { return "The agent is connecting. Try again shortly." }
                if model.states[provider]?.isBusy == true {
                    guard (model.taskQueues[provider]?.count ?? 0) < 12 else { return "The queue is full (12 messages). Your draft has been kept." }
                    model.enqueuePrompt(text, attachments: [], for: provider)
                    return nil
                }
                let key = "solo-\(projectID(for: model) ?? "default")-\(provider.rawValue)"
                guard !scheduledSends.contains(key) else { return "The agent is accepting another message. Your draft has been kept." }
                let previousEntries = Set((model.states[provider]?.entries ?? []).map(\.id))
                let previousQueue = Set((model.taskQueues[provider] ?? []).map(\.id))
                scheduledSends.insert(key)
                Task { [weak self, weak model] in
                    defer { self?.scheduledSends.remove(key) }
                    guard let model, !model.isShutDown else { return }
                    await model.startIfNeeded(for: provider)
                    guard !model.isShutDown, !model.starting.contains(provider) else { return }
                    await model.sendToProvider(text, target: provider)
                }
                // Delivery is confirmed when accepted, without waiting for the AI's whole answer.
                for _ in 0..<400 {
                    let accepted = model.states[provider]?.entries.contains { !previousEntries.contains($0.id) && $0.kind == .user && $0.text == text } == true
                        || model.taskQueues[provider]?.contains { !previousQueue.contains($0.id) && $0.text == text } == true
                    if accepted { return nil }
                    if !scheduledSends.contains(key) { return model.taskNotice ?? model.states[provider]?.entries.last(where: { $0.kind == .failure })?.text ?? "The agent could not accept the message. Your draft has been kept." }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return "The agent is still preparing. Your draft is kept; check the conversation before sending again."
            }
            return nil
        case .approve:
            guard let target = command.target, let id = UUID(uuidString: target),
                  let request = model.permissionQueue.first(where: { $0.id == id }) else { return "That request is no longer waiting." }
            let choice = command.text
            guard choice == nil || request.options.contains(where: { $0.id == choice }) else { return "Unknown option." }
            request.reply(choice)
            return nil
        case .stop:
            if let target = command.target, Self.mode(target) == nil { return "Unknown conversation mode." }
            if let raw = command.provider, Provider(rawValue: raw) == nil { return "Unknown agent." }
            let provider = command.provider.flatMap(Provider.init(rawValue:)) ?? model.provider
            switch command.target.flatMap(Self.mode) ?? model.assistantMode {
            case .roundtable: model.roundtable.stop()
            case .team: model.orchestrator.stop()
            case .cli: model.nativeSessions[provider]?.terminate()
            case .chat: model.cancel(provider: provider)
            }
            return nil
        }
    }

    /// Called by the model whenever a transcript, a permission or a run changes; coalesced.
    func noteChange() {
        guard !connections.isEmpty else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            for connection in self.connections where connection.isAuthenticated { connection.push(connection.snapshot()) }
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// One phone connection: clear-text handshake, then sealed frames both ways.
@MainActor
final class RemoteConnection {
    private let connection: NWConnection?
    private var relaySend: ((Data, (() -> Void)?) -> Void)?
    private var relayClose: (() -> Void)?
    private var closed = false
    private weak var control: RemoteControl?
    private(set) var deviceID: String?
    private var sealer: RemoteSealer?
    private var commandTimes: [Date] = []
    private var seenCommandIDs: [String] = []
    private var handshakeTimeout: Task<Void, Never>?
    private(set) var selectedProjectID: String?
    private var selectedMode: String?
    private var selectedProvider: String?
    func snapshot() -> RemoteState {
        control!.snapshot(projectID: selectedProjectID, mode: selectedMode, provider: selectedProvider)
    }
    var isAuthenticated: Bool { sealer != nil && deviceID != nil }
    /// True for the Mac's own socket to the relay: it idles until a phone arrives, so it gets no
    /// handshake deadline, and its state is reported to the relay link.
    let viaRelay: Bool
    var onState: ((NWConnection.State) -> Void)?

    init(connection: NWConnection, control: RemoteControl, viaRelay: Bool = false) {
        self.connection = connection
        self.control = control
        self.viaRelay = viaRelay
    }

    init(control: RemoteControl, send: @escaping (Data, (() -> Void)?) -> Void, close: @escaping () -> Void) {
        self.connection = nil; self.control = control; self.viaRelay = true
        self.relaySend = send; self.relayClose = close
    }

    func start() {
        if !viaRelay || connection == nil { handshakeTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, !self.isAuthenticated else { return }
            self.close()
        } }
        guard let connection else { return }
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onState?(state)
                switch state {
                case .failed, .cancelled:
                    self.control?.connectionClosed(self)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func close() {
        guard !closed else { return }; closed = true
        handshakeTimeout?.cancel()
        sealer = nil; deviceID = nil
        connection?.cancel()
        let finish = relayClose; relayClose = nil; relaySend = nil
        control?.connectionClosed(self); finish?()
    }

    private func receive() {
        guard !closed, let connection else { return }
        connection.receiveMessage { [weak self] data, context, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let opcode = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if opcode?.opcode == .close || (complete && data == nil && context == nil) { self.close(); return }
                if let data, !data.isEmpty { self.handle(data) }
                if error == nil { self.receive() } else { self.close() }
            }
        }
    }

    private func send(_ envelope: RemoteEnvelope, then completion: (() -> Void)? = nil) {
        guard !closed else { return }
        if let relaySend { relaySend(envelope.encoded(), completion); return }
        guard let connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "orrery", metadata: [metadata])
        connection.send(content: envelope.encoded(), contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            if let completion { DispatchQueue.main.async { completion() } }
        })
    }

    /// The refusal is delivered before the connection is dropped.
    private func fail(_ message: String, close shouldClose: Bool = true) {
        send(RemoteEnvelope(type: "error", message: message), then: shouldClose ? { [weak self] in self?.close() } : nil)
    }

    func push(_ state: RemoteState) {
        guard let sealer, let frame = try? sealer.seal(RemotePayload(state: state.boundedForTransport()).encoded()) else { return }
        send(RemoteEnvelope(type: "frame", sealed: frame))
    }

    fileprivate func handle(_ data: Data) {
        guard !closed else { return }
        guard data.count <= RemoteProtocol.maxFrameBytes * 2, let envelope = RemoteEnvelope.decode(data), let control else { fail("Malformed message."); return }
        switch envelope.type {
        case "pair":
            guard !isAuthenticated else { fail("Session already established."); return }
            guard let key = envelope.devicePublicKey, let sealed = envelope.sealed else { fail("Malformed pairing message."); return }
            let token = control.offer?.token
            switch control.pair(devicePublicKey: key, sealed: sealed) {
            case let .refused(reason):
                fail(reason)
            case let .paired(device):
                guard let token, let replyKey = control.pairingReplyKey(devicePublicKey: key, token: token),
                      let reply = try? RemoteSealer(key: replyKey, isClient: false).seal(Data("{\"ok\":true}".utf8)) else { fail("Pairing reply failed."); return }
                send(RemoteEnvelope(type: "paired", deviceID: device.id, sealed: reply))
            }
        case "hello":
            guard !isAuthenticated else { fail("Session already established."); return }
            guard let id = envelope.deviceID, let device = control.device(id), let ephemeral = envelope.ephemeral, ephemeral.count == 32,
                  let clientNonce = envelope.nonce, clientNonce.count >= 16 else { fail("This device is not paired with this Mac."); return }
            let localEphemeral = RemoteCrypto.PrivateKey()
            let serverNonce = RemoteCrypto.randomToken()
            guard let key = control.sessionKey(for: device, localEphemeral: localEphemeral, remoteEphemeral: ephemeral, clientNonce: clientNonce, serverNonce: serverNonce) else { fail("Key agreement failed."); return }
            let sealer = RemoteSealer(key: key, isClient: false)
            guard let welcome = try? sealer.seal(RemotePayload(state: control.snapshot().boundedForTransport()).encoded()) else { fail("Sealing failed."); return }
            self.sealer = sealer
            handshakeTimeout?.cancel()
            let initial = control.snapshot()
            selectedProjectID = initial.projectID
            selectedMode = initial.mode.lowercased(); selectedProvider = initial.provider
            deviceID = id
            control.touch(id)
            send(RemoteEnvelope(type: "welcome", ephemeral: localEphemeral.publicKey.rawRepresentation, nonce: serverNonce, sealed: welcome))
        case "frame":
            guard let sealer, let sealed = envelope.sealed else { fail("Not authenticated."); return }
            let plain: Data
            do { plain = try sealer.open(sealed) } catch { fail("Frame refused: \(error)"); return }
            guard let payload = RemotePayload.decode(plain), let command = payload.command else { fail("Malformed command.", close: false); return }
            let now = Date()
            commandTimes = commandTimes.filter { now.timeIntervalSince($0) < 1 } + [now]
            guard commandTimes.count <= RemoteControl.commandsPerSecond else { fail("Too many commands."); return }
            Task { [weak self] in
                guard let self, self.isAuthenticated, let control = self.control,
                      let deviceID = self.deviceID, control.device(deviceID) != nil else { return }
                if let id = command.id {
                    guard !self.seenCommandIDs.contains(id) else { return }
                    self.seenCommandIDs.append(id)
                    self.seenCommandIDs = Array(self.seenCommandIDs.suffix(256))
                }
                var scoped = command
                if scoped.projectID == nil { scoped.projectID = self.selectedProjectID }
                if scoped.kind == .send || scoped.kind == .stop {
                    if scoped.target == nil { scoped.target = self.selectedMode }
                    if scoped.provider == nil { scoped.provider = self.selectedProvider }
                }
                let error: String?
                if command.kind == .state, let id = command.projectID, !control.projectExists(id) {
                    error = "That project is no longer open."
                } else {
                    error = await control.perform(scoped)
                    if command.kind == .state, error == nil {
                        if let id = command.projectID { self.selectedProjectID = id }
                        if let mode = command.target { self.selectedMode = mode }
                        if let provider = command.provider { self.selectedProvider = provider }
                    }
                }
                let payload = RemotePayload(state: self.snapshot().boundedForTransport(), error: error,
                                            acknowledgedCommandID: command.id)
                if let sealer = self.sealer, let frame = try? sealer.seal(payload.encoded()) { self.send(RemoteEnvelope(type: "frame", sealed: frame)) }
            }
        default:
            fail("Unknown message type.")
        }
    }
}


/// One outbound socket, one independent encrypted RemoteConnection per relay channel.
/// Older relays remain usable with a single viewer until their owner updates the Worker.
@MainActor
final class RelayLink {
    private let url: URL
    private weak var control: RemoteControl?
    private var connection: NWConnection?
    private var channels: [String: RemoteConnection] = [:]
    private var legacy: RemoteConnection?
    private var multiplexed = false
    private var attempt = 0
    private var reconnect: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var stopped = false
    private(set) var connectionsMade = 0

    init(url: URL, control: RemoteControl) {
        var address = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        address.queryItems = (address.queryItems ?? []) + [URLQueryItem(name: "protocol", value: "2")]
        self.url = address.url!; self.control = control
    }
    func connect() {
        guard !stopped, let control else { return }
        disconnect()
        let base: NWParameters = url.scheme == "ws" ? .tcp : .tls
        let websocket = NWProtocolWebSocket.Options(); websocket.autoReplyPing = true
        websocket.maximumMessageSize = RelayPacket.maxBytes
        base.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        let connection = NWConnection(to: .url(url), using: base)
        self.connection = connection; connectionsMade += 1
        control.relayLinkChanged("connecting")
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.attempt = 0; self.deadline?.cancel()
                    self.control?.relayLinkChanged("waiting for the phone")
                case .failed, .cancelled: self.scheduleReconnect()
                default: break
                }
            }
        }
        deadline = Task { [weak self, weak connection] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, let connection, self.connection === connection else { return }
            self.scheduleReconnect()
        }
        connection.start(queue: .main); receive(connection)
    }
    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, complete, error in
            MainActor.assumeIsolated {
                guard let self, let connection, self.connection === connection else { return }
                let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
                if error != nil || opcode == .close || (complete && data == nil && context == nil) { self.scheduleReconnect(); return }
                if let data, !data.isEmpty { self.handle(data) }
                if self.connection === connection { self.receive(connection) }
            }
        }
    }
    private func handle(_ data: Data) {
        guard let control else { return }
        if let packet = RelayPacket.decode(data) {
            switch packet.type {
            case "relay.ready":
                guard legacy == nil, !multiplexed else { scheduleReconnect(); return }
                multiplexed = true
            case "relay.open":
                guard multiplexed, let id = packet.id, channels[id] == nil else { scheduleReconnect(); return }
                guard channels.count < RemoteControl.maxConnections else { send(RelayPacket(type: "relay.close", id: id).encoded()); return }
                let remote = RemoteConnection(control: control, send: { [weak self] data, completion in
                    guard let self else { return }
                    self.send(RelayPacket(type: "relay.data", id: id, data: String(decoding: data, as: UTF8.self)).encoded(), then: completion)
                }, close: { [weak self] in
                    guard let self, self.channels.removeValue(forKey: id) != nil else { return }
                    self.send(RelayPacket(type: "relay.close", id: id).encoded())
                })
                channels[id] = remote; control.adoptRelayConnection(remote)
            case "relay.data":
                guard multiplexed, let id = packet.id, let body = packet.data else { scheduleReconnect(); return }
                channels[id]?.handle(Data(body.utf8))
            case "relay.close":
                guard multiplexed, let id = packet.id else { scheduleReconnect(); return }
                channels.removeValue(forKey: id)?.close()
            default: break
            }
        } else if !multiplexed, RemoteEnvelope.decode(data) != nil {
            if legacy == nil {
                let remote = RemoteConnection(control: control, send: { [weak self] data, completion in self?.send(data, then: completion) },
                    close: { [weak self] in self?.scheduleReconnect() })
                legacy = remote; control.adoptRelayConnection(remote)
            }
            legacy?.handle(data)
        } else { scheduleReconnect() }
    }
    private func send(_ data: Data, then completion: (() -> Void)? = nil) {
        guard let connection, data.count <= RelayPacket.maxBytes else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        connection.send(content: data, contentContext: .init(identifier: "relay", metadata: [metadata]), isComplete: true,
            completion: .contentProcessed { [weak self, weak connection] error in
                DispatchQueue.main.async {
                    guard let self, let connection, self.connection === connection else { return }
                    if error != nil { self.scheduleReconnect() } else { completion?() }
                }
            })
    }
    private func disconnect() {
        deadline?.cancel()
        let previous = connection; connection = nil; previous?.cancel()
        let sessions = Array(channels.values); channels.removeAll()
        let oldLegacy = legacy; legacy = nil
        // Clear transports before closing sessions so callbacks cannot reconnect recursively.
        for session in sessions { session.close() }
        oldLegacy?.close(); multiplexed = false
    }
    private func scheduleReconnect() {
        guard !stopped, connection != nil else { return }
        disconnect(); control?.relayLinkChanged("reconnecting")
        attempt += 1
        let delay = min(30.0, pow(2.0, Double(attempt - 1)))
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.connect()
        }
    }
    func stop() { stopped = true; reconnect?.cancel(); reconnect = nil; disconnect() }
}

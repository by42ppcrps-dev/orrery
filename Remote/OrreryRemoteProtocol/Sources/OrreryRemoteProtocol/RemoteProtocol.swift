import Foundation
import CryptoKit

/// The Orrery remote-control protocol, version 1.
///
/// Pairing: the Mac shows a QR code carrying a one-time token, its static public key and where
/// to reach it. The phone makes its own static key, seals the token to the Mac's key and sends
/// it; the Mac checks the token (once, within its lifetime), remembers the phone's key and
/// answers sealed. From then on the phone is known by its key, never by a password.
///
/// Sessions: each connection runs a fresh key agreement — both static keys and both ephemeral
/// keys go into the session key, so a stolen recording cannot be decrypted later and neither
/// side can be impersonated without its static private key. Every message after the handshake
/// is a sealed frame (ChaCha20-Poly1305) with a strictly increasing counter, so a replayed or
/// reordered frame is refused. Nothing here needs TLS certificates: the QR code pins the Mac's
/// key and the pairing token proves the phone was in front of the Mac.
public enum RemoteProtocol {
    public static let version = 1
    public static let qrPrefix = "orrery-remote:"
    public static let pairingLifetime: TimeInterval = 300
    public static let maxFrameBytes = 512 * 1024
    public static let bonjourType = "_orrery-remote._tcp"
}

/// What the QR code carries.
public struct PairingOffer: Codable, Equatable, Sendable {
    public var version: Int
    public var name: String
    public var hosts: [String]
    public var port: UInt16
    public var serverPublicKey: Data
    public var token: Data
    public var expires: Date
    /// Optional: a relay (Remote/OrreryRelay Worker) that carries sealed frames when the phone is
    /// on another network, the Mac's room there, and the room's token. Older phones ignore them.
    public var relay: String?
    public var room: String?
    public var relayToken: String?

    public init(name: String, hosts: [String], port: UInt16, serverPublicKey: Data, token: Data, expires: Date,
                relay: String? = nil, room: String? = nil, relayToken: String? = nil) {
        self.version = RemoteProtocol.version
        self.name = name; self.hosts = hosts; self.port = port
        self.serverPublicKey = serverPublicKey; self.token = token
        self.relay = relay; self.room = room; self.relayToken = relayToken
        // Whole seconds: the QR text encodes seconds, and an offer must equal its parse.
        self.expires = Date(timeIntervalSince1970: expires.timeIntervalSince1970.rounded(.down))
    }

    public var isExpired: Bool { Date() >= expires }

    /// No relay, or a well-formed one: an http(s) base URL, a room of 8–64 URL-safe characters and
    /// a token of at least 16.
    public var relayIsValid: Bool {
        guard relay != nil || room != nil || relayToken != nil else { return true }
        guard let relay, let room, let relayToken, let url = URL(string: relay), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil, relay.count <= 253,
              (8...64).contains(room.count), room.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              relayToken.count >= 16, relayToken.count <= 128, relayToken.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return false }
        return true
    }

    /// The WebSocket URL a side uses at the relay: `wss://host/mac/<room>?token=…` or `/phone/…`.
    public func relayURL(side: String) -> URL? {
        guard let relay, let room, let relayToken, var parts = URLComponents(string: relay) else { return nil }
        parts.scheme = parts.scheme?.lowercased() == "http" ? "ws" : "wss"
        parts.path = "/" + side + "/" + room
        parts.queryItems = [URLQueryItem(name: "token", value: relayToken)]
        return parts.url
    }

    /// `orrery-remote:` + base64url JSON — scannable, pasteable.
    public var qrString: String {
        let data = (try? RemoteCoding.encoder.encode(self)) ?? Data()
        return RemoteProtocol.qrPrefix + RemoteCoding.base64url(data)
    }

    public static func parse(_ text: String) -> PairingOffer? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(RemoteProtocol.qrPrefix),
              let data = RemoteCoding.data(base64url: String(trimmed.dropFirst(RemoteProtocol.qrPrefix.count))),
              let offer = try? RemoteCoding.decoder.decode(PairingOffer.self, from: data),
              offer.version == RemoteProtocol.version, offer.serverPublicKey.count == 32, offer.token.count == 32,
              offer.port > 0, !offer.hosts.isEmpty, offer.hosts.count <= 32,
              offer.hosts.allSatisfy({ !$0.isEmpty && $0.count <= 253 && !$0.contains(where: { $0.isWhitespace || "/?#@".contains($0) }) }),
              offer.relayIsValid else { return nil }
        return offer
    }
}

public enum RemoteCoding {
    public static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.sortedKeys]; return e }()
    public static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func data(base64url: String) -> Data? {
        var text = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }
}

// MARK: - Keys and sessions

public enum RemoteCrypto {
    public typealias PrivateKey = Curve25519.KeyAgreement.PrivateKey
    public typealias PublicKey = Curve25519.KeyAgreement.PublicKey

    public static func randomToken() -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }

    /// Constant-time comparison for tokens.
    public static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    /// The pairing key: the phone's static key with the Mac's static key, bound to the token so
    /// that a pairing message can only be read by the Mac whose QR code was scanned.
    public static func pairingKey(local: PrivateKey, remote: PublicKey, token: Data) throws -> SymmetricKey {
        let shared = try local.sharedSecretFromKeyAgreement(with: remote)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: token, sharedInfo: Data("orrery-remote-pair-v1".utf8), outputByteCount: 32)
    }

    /// The session key: both static keys and both ephemeral keys, salted with both nonces.
    /// Order of the two shared secrets is fixed (static first) so both sides derive the same key.
    public static func sessionKey(localStatic: PrivateKey, remoteStatic: PublicKey,
                                  localEphemeral: PrivateKey, remoteEphemeral: PublicKey,
                                  clientNonce: Data, serverNonce: Data) throws -> SymmetricKey {
        let staticShared = try localStatic.sharedSecretFromKeyAgreement(with: remoteStatic)
        let ephemeralShared = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteEphemeral)
        var material = Data()
        staticShared.withUnsafeBytes { material.append(contentsOf: $0) }
        ephemeralShared.withUnsafeBytes { material.append(contentsOf: $0) }
        let combined = SymmetricKey(data: material)
        let salt = clientNonce + serverNonce
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: combined, salt: salt, info: Data("orrery-remote-session-v1".utf8), outputByteCount: 32)
    }
}

/// One direction of sealed frames. `seal` numbers every frame; `open` refuses any frame whose
/// number is not greater than the last one accepted, so replays and reorders fail closed.
public final class RemoteSealer {
    public enum Failure: Error, Equatable { case malformed, replayed, unauthenticated, tooLarge }

    private let key: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private let sendPrefix: UInt32
    private let receivePrefix: UInt32

    /// `isClient` picks distinct nonce spaces for the two directions.
    public init(key: SymmetricKey, isClient: Bool) {
        self.key = key
        sendPrefix = isClient ? 0x0000_0001 : 0x0000_0002
        receivePrefix = isClient ? 0x0000_0002 : 0x0000_0001
    }

    private static func nonce(prefix: UInt32, counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 12)
        bytes.replaceSubrange(0..<4, with: withUnsafeBytes(of: prefix.bigEndian) { Data($0) })
        bytes.replaceSubrange(4..<12, with: withUnsafeBytes(of: counter.bigEndian) { Data($0) })
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// Frame layout: 8-byte counter (big endian) + ciphertext + 16-byte tag.
    public func seal(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= RemoteProtocol.maxFrameBytes else { throw Failure.tooLarge }
        sendCounter += 1
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: Self.nonce(prefix: sendPrefix, counter: sendCounter),
                                      authenticating: withUnsafeBytes(of: sendCounter.bigEndian) { Data($0) })
        return withUnsafeBytes(of: sendCounter.bigEndian) { Data($0) } + box.ciphertext + box.tag
    }

    public func open(_ frame: Data) throws -> Data {
        guard frame.count >= 8 + 16, frame.count <= RemoteProtocol.maxFrameBytes + 8 + 16 else { throw frame.count < 24 ? Failure.malformed : Failure.tooLarge }
        let counter = frame.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard counter > receiveCounter else { throw Failure.replayed }
        let body = frame.dropFirst(8)
        let ciphertext = body.dropLast(16), tag = body.suffix(16)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(prefix: receivePrefix, counter: counter), ciphertext: ciphertext, tag: tag)
            let plain = try ChaChaPoly.open(box, using: key, authenticating: withUnsafeBytes(of: counter.bigEndian) { Data($0) })
            receiveCounter = counter
            return plain
        } catch { throw Failure.unauthenticated }
    }
}

// MARK: - Messages

/// Every message is a JSON object with a `type`. Before the session is sealed, only `pair`,
/// `paired`, `hello`, `welcome` and `error` travel in the clear; after it, everything travels
/// inside `frame`.
public struct RemoteEnvelope: Codable, Equatable, Sendable {
    public var type: String
    public var devicePublicKey: Data?
    public var deviceID: String?
    public var ephemeral: Data?
    public var nonce: Data?
    public var sealed: Data?
    public var message: String?

    public init(type: String, devicePublicKey: Data? = nil, deviceID: String? = nil, ephemeral: Data? = nil, nonce: Data? = nil, sealed: Data? = nil, message: String? = nil) {
        self.type = type; self.devicePublicKey = devicePublicKey; self.deviceID = deviceID
        self.ephemeral = ephemeral; self.nonce = nonce; self.sealed = sealed; self.message = message
    }

    public func encoded() -> Data { (try? RemoteCoding.encoder.encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> RemoteEnvelope? { try? RemoteCoding.decoder.decode(RemoteEnvelope.self, from: data) }
}

/// The plaintext of a pairing request, sealed with the pairing key.
public struct PairingRequest: Codable, Equatable, Sendable {
    public var token: Data
    public var deviceName: String
    public init(token: Data, deviceName: String) { self.token = token; self.deviceName = deviceName }
}

/// Commands the phone sends inside sealed frames.
public struct RemoteCommand: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case state, send, approve, stop, ping }
    public var kind: Kind
    public var id: String?
    public var projectID: String?
    /// `send`: the message text. `approve`: the option id. `stop`: unused.
    public var text: String?
    /// `send`: "solo" or "roundtable"; `approve`: the permission id.
    public var target: String?
    /// `send` to Solo: the provider raw value (grok/claude/codex) or nil for the current one.
    public var provider: String?

    public init(kind: Kind, text: String? = nil, target: String? = nil, provider: String? = nil, id: String? = nil, projectID: String? = nil) {
        self.id = id; self.projectID = projectID
        self.kind = kind; self.text = text; self.target = target; self.provider = provider
    }
}

/// What the Mac sends inside sealed frames: a full snapshot every time (small; the phone shows
/// the tail of one transcript and the pending approvals).
public struct RemoteState: Codable, Equatable, Sendable {
    public struct Project: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var isBusy: Bool
        public init(id: String, name: String, isBusy: Bool) { self.id = id; self.name = name; self.isBusy = isBusy }
    }
    public var projectID: String?
    public var projects: [Project]?
    public var capabilities: [String]?

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var speaker: String
        public var kind: String
        public var text: String
        public var costUSD: Double?
        public init(id: String, speaker: String, kind: String, text: String, costUSD: Double? = nil) {
            self.id = id; self.speaker = speaker; self.kind = kind; self.text = text; self.costUSD = costUSD
        }
    }
    public struct Permission: Codable, Equatable, Sendable, Identifiable {
        public struct Option: Codable, Equatable, Sendable, Identifiable {
            public var id: String
            public var name: String
            public var kind: String
            public init(id: String, name: String, kind: String) { self.id = id; self.name = name; self.kind = kind }
        }
        public var id: String
        public var provider: String
        public var title: String
        public var detail: String
        public var options: [Option]
        public init(id: String, provider: String, title: String, detail: String, options: [Option]) {
            self.id = id; self.provider = provider; self.title = title; self.detail = detail; self.options = options
        }
    }
    public var macName: String
    public var project: String?
    public var mode: String
    public var provider: String
    public var providers: [String]
    public var isBusy: Bool
    public var status: String
    public var entries: [Entry]
    public var permissions: [Permission]
    public var sentAt: Date

    public init(macName: String, project: String?, mode: String, provider: String, providers: [String], isBusy: Bool, status: String, entries: [Entry], permissions: [Permission], sentAt: Date = Date(), projectID: String? = nil, projects: [Project]? = nil, capabilities: [String]? = nil) {
        self.projectID = projectID; self.projects = projects; self.capabilities = capabilities
        self.macName = macName; self.project = project; self.mode = mode; self.provider = provider; self.providers = providers
        self.isBusy = isBusy; self.status = status; self.entries = entries; self.permissions = permissions; self.sentAt = sentAt
    }
}

/// A sealed payload is either a command (phone → Mac) or a state (Mac → phone), or an error.
public struct RemotePayload: Codable, Equatable, Sendable {
    public var command: RemoteCommand?
    public var acknowledgedCommandID: String?
    public var state: RemoteState?
    public var error: String?
    public init(command: RemoteCommand? = nil, state: RemoteState? = nil, error: String? = nil, acknowledgedCommandID: String? = nil) {
        self.acknowledgedCommandID = acknowledgedCommandID
        self.command = command; self.state = state; self.error = error
    }
    public func encoded() -> Data { (try? RemoteCoding.encoder.encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> RemotePayload? { try? RemoteCoding.decoder.decode(RemotePayload.self, from: data) }
}

/// Retain the newest useful content while keeping JSON/base64 frames bounded. This also
/// handles unusually large Unicode messages and large approval queues without losing the
/// entire connection. Older entries remain available on the Mac.
public extension RemoteState {
    func boundedForTransport() -> RemoteState {
        var value = self
        value.macName = String(value.macName.prefix(255))
        value.status = String(value.status.prefix(1000))
        value.entries = Array(value.entries.suffix(40))
        value.permissions = Array(value.permissions.prefix(20))
        value.projects = value.projects.map { Array($0.prefix(40)) }
        while RemotePayload(state: value).encoded().count > RemoteProtocol.maxFrameBytes - 4096 {
            if value.entries.count > 1 { value.entries.removeFirst() }
            else if let text = value.entries.first?.text, text.count > 1000 {
                value.entries[0].text = String(text.prefix(text.count / 2)) + "\n\n[Continued on your Mac]"
            } else if !value.permissions.isEmpty { value.permissions.removeLast() }
            else { value.entries = []; value.status = "Open the Mac to view this large response."; break }
        }
        return value
    }
}

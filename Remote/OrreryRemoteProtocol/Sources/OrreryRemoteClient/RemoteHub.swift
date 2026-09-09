import Foundation
import Combine
import Security
import OrreryRemoteProtocol

/// One connection per paired Mac. Only pairing information is persisted; transcripts stay in memory.
@MainActor
public final class RemoteHub: ObservableObject {
    public static let limit = 8
    @Published public private(set) var clients: [RemoteClient] = []
    @Published public private(set) var error: String?
    private let read: @MainActor () throws -> [RemoteClient.PairedMac]
    private let write: @MainActor ([RemoteClient.PairedMac]) throws -> Void
    private let identityProvider: @MainActor () throws -> RemoteCrypto.PrivateKey
    private var loaded = false
    private var active = false

    public init(read: @escaping @MainActor () throws -> [RemoteClient.PairedMac] = RemotePairingStore.read,
                write: @escaping @MainActor ([RemoteClient.PairedMac]) throws -> Void = RemotePairingStore.write,
                identityProvider: @escaping @MainActor () throws -> RemoteCrypto.PrivateKey = RemoteClient.deviceKey) {
        self.read = read; self.write = write; self.identityProvider = identityProvider
    }

    public func load() {
        guard !loaded else { return }
        do {
            let saved = try read()
            guard saved.count <= Self.limit, saved.allSatisfy(\.isValid), Set(saved.map(\.serverPublicKey)).count == saved.count else {
                throw PairingStoreError.invalid
            }
            clients = saved.map { makeClient($0) }; loaded = true; error = nil
            for client in clients { client.setActive(active) }
        } catch { self.error = error.localizedDescription }
    }

    private func makeClient(_ mac: RemoteClient.PairedMac? = nil) -> RemoteClient {
        let client = RemoteClient(mac: mac, identityProvider: identityProvider)
        client.onPaired = { [weak self, weak client] paired in
            guard let self, let client else { throw PairingStoreError.invalid }
            let others = self.clients.filter { $0 !== client && $0.mac?.serverPublicKey != paired.serverPublicKey }
            let saved = others.compactMap(\.mac).filter { !$0.deviceID.isEmpty } + [paired]
            guard saved.count <= Self.limit, saved.allSatisfy(\.isValid) else { throw PairingStoreError.invalid }
            try self.write(saved)
            for previous in self.clients where previous !== client && previous.mac?.serverPublicKey == paired.serverPublicKey {
                previous.setActive(false)
            }
            self.clients = others + [client]
        }
        client.onForget = { [weak self, weak client] in
            guard let self, let client else { throw PairingStoreError.invalid }
            let others = self.clients.filter { $0 !== client }
            try self.write(others.compactMap(\.mac).filter { !$0.deviceID.isEmpty })
            self.clients = others
        }
        return client
    }

    /// Keeps a new pairing separate from every existing connection, including failed attempts.
    public func add() -> RemoteClient? {
        load()
        guard loaded else { return nil }
        guard clients.count < Self.limit else { error = "You can pair up to eight Macs. Forget one before adding another."; return nil }
        let client = makeClient(); clients.append(client); error = nil
        client.setActive(active)
        return client
    }

    public func cancelPairing(_ client: RemoteClient) {
        guard client.mac?.deviceID.isEmpty != false else { return }
        client.cancelPairing(); clients.removeAll { $0 === client }
    }

    public func setActive(_ value: Bool) {
        active = value; load()
        clients.forEach { $0.setActive(value) }
    }
    public func reconnect() { clients.forEach { $0.connect() } }
}

private enum PairingStoreError: LocalizedError {
    case inaccessible, invalid
    var errorDescription: String? {
        switch self {
        case .inaccessible: return "Pairing information could not be accessed in Keychain. Unlock this device and try again."
        case .invalid: return "Saved pairing information is invalid. Restore a valid pairing before continuing."
        }
    }
}

@MainActor
public enum RemotePairingStore {
    private static let account = "app.orrery.remote.paired-macs.v2"
    private static let legacyKey = "orrery.remote.mac.v1"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
    }
    public static func read() throws -> [RemoteClient.PairedMac] {
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count <= 128_000,
                  let saved = try? JSONDecoder().decode([RemoteClient.PairedMac].self, from: data),
                  saved.count <= RemoteHub.limit, saved.allSatisfy(\.isValid), Set(saved.map(\.serverPublicKey)).count == saved.count else { throw PairingStoreError.invalid }
            // A previous migration may have saved securely and exited before removing the legacy value.
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return saved
        }
        guard status == errSecItemNotFound else { throw PairingStoreError.inaccessible }
        if let legacy = UserDefaults.standard.data(forKey: legacyKey) {
            guard legacy.count <= 128_000, let mac = try? JSONDecoder().decode(RemoteClient.PairedMac.self, from: legacy), mac.isValid else { throw PairingStoreError.invalid }
            try write([mac])
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return [mac]
        }
        return []
    }
    public static func write(_ macs: [RemoteClient.PairedMac]) throws {
        guard macs.count <= RemoteHub.limit, macs.allSatisfy(\.isValid) else { throw PairingStoreError.invalid }
        let data = try JSONEncoder().encode(macs)
        guard data.count <= 128_000 else { throw PairingStoreError.invalid }
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PairingStoreError.inaccessible }
    }
}

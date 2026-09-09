import Foundation
import Security

/// Automatic launches must not summon password dialogs. The one interactive path is an
/// explicit Unlock button; a successful grant is retained in memory for this app session.
enum KeychainAccess {
    private static let lock = NSLock()
    private static let operationLock = NSLock()
    nonisolated(unsafe) private static var unlocked: [String: String] = [:]
    private static func id(_ service: String, _ account: String) -> String { service + "\n" + account }

    static func read(service: String, account: String, interactive: Bool = false) -> String? {
        let key = id(service, account)
        lock.lock(); let cached = unlocked[key]; lock.unlock()
        if let cached { return cached }
        // Existing macOS items live in the legacy Keychain. Its UI switch is separate from
        // kSecUseAuthenticationUI; serialize the scoped switch and always restore it.
        if interactive { operationLock.lock() }
        else if !operationLock.try() { return nil }
        defer { operationLock.unlock() }
        var wasAllowed = DarwinBoolean(true)
        guard SecKeychainGetUserInteractionAllowed(&wasAllowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(interactive) == errSecSuccess else { return nil }
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        lock.lock(); unlocked[key] = value; lock.unlock()
        return value
    }

    static func forget(service: String, account: String) {
        lock.lock(); unlocked.removeValue(forKey: id(service, account)); lock.unlock()
    }
}

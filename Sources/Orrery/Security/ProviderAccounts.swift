import Foundation
import Security

/// How a provider's child processes authenticate: the CLI's own sign-in (subscription), or an
/// API key kept in the macOS Keychain and handed to that provider's children only.
enum ProviderAuthMode: String, Codable, CaseIterable, Identifiable {
    case subscription, apiKey
    var id: String { rawValue }
    var title: String { self == .subscription ? "Subscription (the CLI's own sign-in)" : "API credits (key stored in the Keychain)" }
}

/// Test seam and single point of contact with the Keychain. Presence checks read attributes
/// only; the secret itself is read once, when a child is launched in API-credit mode.
struct KeychainStore {
    var hasKey: (Provider) -> Bool
    var read: (Provider) -> String?
    var write: (Provider, String) throws -> Void
    var delete: (Provider) throws -> Void

    static let service = "app.orrery.studio.api-key"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func base(_ provider: Provider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }

    static let keychain = KeychainStore(
        hasKey: { provider in
            var query = base(provider)
            query[kSecReturnAttributes as String] = true
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
        },
        read: { provider in
            KeychainAccess.read(service: service, account: provider.rawValue)
        },
        write: { provider, key in
            KeychainAccess.forget(service: service, account: provider.rawValue)
            let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                             kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            let status = SecItemUpdate(base(provider) as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                let added = SecItemAdd(base(provider).merging(attributes) { _, new in new } as CFDictionary, nil)
                guard added == errSecSuccess else { throw Failure(message: "The Keychain refused to store the key (\(added)).") }
            } else if status != errSecSuccess {
                throw Failure(message: "The Keychain refused to update the key (\(status)).")
            }
        },
        delete: { provider in
            KeychainAccess.forget(service: service, account: provider.rawValue)
            let status = SecItemDelete(base(provider) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure(message: "The Keychain refused to remove the key (\(status)).")
            }
        })

    /// An in-memory store for audits and for headless runs, which must never touch the user's Keychain.
    static func memory() -> KeychainStore {
        final class Box: @unchecked Sendable { var keys: [Provider: String] = [:]; let lock = NSLock() }
        let box = Box()
        return KeychainStore(
            hasKey: { provider in box.lock.lock(); defer { box.lock.unlock() }; return box.keys[provider] != nil },
            read: { provider in box.lock.lock(); defer { box.lock.unlock() }; return box.keys[provider] },
            write: { provider, key in box.lock.lock(); box.keys[provider] = key; box.lock.unlock() },
            delete: { provider in box.lock.lock(); box.keys[provider] = nil; box.lock.unlock() })
    }
}

extension AppModel {
    /// Puts arguments into the CLI pane's launch options, one per line as that pane expects,
    /// and shows the pane. Nothing is launched until the user presses Launch.
    func presetNativeCLI(_ arguments: [String], for provider: Provider) {
        nativeArguments[provider] = arguments.joined(separator: "\n")
        self.provider = provider
        assistantMode = .cli
    }
}

/// Per-provider account mode, the Keychain-backed API keys, and honest sign-in status read
/// from the CLIs' own stores without reading any secret.
@MainActor @Observable
final class ProviderAccounts {
    static let shared = ProviderAccounts(store: AppModel.persistsPreferences ? .keychain : .memory())
    static let keyByteLimit = 512
    private let preferences: UserDefaults
    private var store: KeychainStore
    private(set) var modes: [Provider: ProviderAuthMode] = [:]
    private(set) var storedKeys: Set<Provider> = []

    init(store: KeychainStore, preferences: UserDefaults? = nil) {
        self.store = store
        self.preferences = preferences ?? AppModel.preferences
        for provider in Provider.allCases {
            if let raw = self.preferences.string(forKey: Self.modeKey(provider)), let mode = ProviderAuthMode(rawValue: raw) {
                modes[provider] = mode
            }
        }
        refreshPresence()
    }

    private static func modeKey(_ provider: Provider) -> String { "account.mode." + provider.rawValue }

    /// The environment variable each CLI documents for API-key authentication.
    static func environmentVariable(for provider: Provider) -> String {
        switch provider {
        case .grok: return "XAI_API_KEY"
        case .claude: return "ANTHROPIC_API_KEY"
        case .codex: return "OPENAI_API_KEY"
        }
    }

    /// Arguments that run the provider's own sign-in flow in the CLI pane.
    static func loginArguments(for provider: Provider) -> [String] {
        switch provider {
        case .grok: return ["login"]
        case .claude: return ["auth", "login"]
        case .codex: return ["login"]
        }
    }

    func mode(for provider: Provider) -> ProviderAuthMode { modes[provider] ?? .subscription }

    func setMode(_ mode: ProviderAuthMode, for provider: Provider) {
        modes[provider] = mode
        preferences.set(mode.rawValue, forKey: Self.modeKey(provider))
    }

    func hasKey(for provider: Provider) -> Bool { storedKeys.contains(provider) }

    func refreshPresence() {
        storedKeys = Set(Provider.allCases.filter { store.hasKey($0) })
    }

    /// Stores a key. Keys are single-line tokens; anything else is refused before it reaches the Keychain.
    func storeKey(_ key: String, for provider: Provider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.keyByteLimit,
              !trimmed.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }) else {
            throw KeychainStore.Failure(message: "Paste the API key itself: one line, no spaces, at most \(Self.keyByteLimit) bytes.")
        }
        try store.write(provider, trimmed)
        refreshPresence()
    }

    func removeKey(for provider: Provider) throws {
        try store.delete(provider)
        refreshPresence()
    }

    /// What a child of this provider should receive. Empty unless the user chose API credits
    /// and a key is stored; never another provider's key.
    func childEnvironment(for provider: Provider) -> [String: String] {
        guard mode(for: provider) == .apiKey, let key = store.read(provider), !key.isEmpty else { return [:] }
        return [Self.environmentVariable(for: provider): key]
    }

    /// Sign-in status from the CLI's own store, by presence only. Codex's auth file names its
    /// mode; Claude keeps its login in the Keychain; Grok keeps a file.
    static func subscriptionStatus(for provider: Provider, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> String {
        let manager = FileManager.default
        switch provider {
        case .grok:
            return manager.fileExists(atPath: home.appendingPathComponent(".grok/auth.json").path)
                ? "Signed in (~/.grok/auth.json is present)." : "Not signed in: no ~/.grok/auth.json."
        case .claude:
            if manager.fileExists(atPath: home.appendingPathComponent(".claude/.credentials.json").path) {
                return "Signed in (credentials file present)."
            }
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: "Claude Code-credentials",
                                        kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var item: CFTypeRef?
            return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
                ? "Signed in (Claude Code keeps its login in the macOS Keychain)." : "Not signed in: no Claude Code login in the Keychain."
        case .codex:
            let url = home.appendingPathComponent(".codex/auth.json")
            guard let data = try? Data(contentsOf: url), data.count <= 65_536,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Not signed in: no ~/.codex/auth.json."
            }
            let mode = (object["auth_mode"] as? String) ?? (object["mode"] as? String) ?? "unknown"
            return "Signed in with \(mode == "chatgpt" ? "ChatGPT" : mode) (~/.codex/auth.json)."
        }
    }
}

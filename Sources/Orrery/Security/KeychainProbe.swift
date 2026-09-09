import Foundation

extension SelfTest {
    /// `--keychain-probe <grok|claude|codex>`: exercises the real Keychain store with a
    /// throwaway key and removes it again, so the API-credit path is verified on this Mac
    /// without ever touching a real key. Refuses to run if a real key is stored.
    static func keychainProbe() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--keychain-probe"), index + 1 < args.count,
              let provider = Provider(rawValue: args[index + 1]) else {
            print("usage: Orrery --keychain-probe <grok|claude|codex>")
            exit(2)
        }
        let store = KeychainStore.keychain
        var ok = true
        func step(_ name: String, _ passed: Bool) {
            print((passed ? "PASS  " : "FAIL  ") + name)
            ok = ok && passed
        }
        if store.hasKey(provider) {
            print("NOTE  a \(provider.rawValue) key is already stored; the probe leaves it alone and stops.")
            exit(3)
        }
        let token = "orrery-probe-" + UUID().uuidString
        do {
            try store.write(provider, token)
            step("a throwaway \(provider.rawValue) key is stored in the login Keychain (service \(KeychainStore.service))", store.hasKey(provider))
            step("the stored key reads back unchanged", store.read(provider) == token)
            try store.write(provider, token + "-2")
            step("storing again updates the item in place", store.read(provider) == token + "-2")
            try store.delete(provider)
            step("the key is removed", !store.hasKey(provider) && store.read(provider) == nil)
            try store.delete(provider)
            step("removing an absent key is not an error", true)
        } catch {
            step("Keychain operation failed: \(error.localizedDescription)", false)
            try? store.delete(provider)
        }
        print(ok ? "keychain probe passed" : "keychain probe FAILED")
        exit(ok ? 0 : 1)
    }
}

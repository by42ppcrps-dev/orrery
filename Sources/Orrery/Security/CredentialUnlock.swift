import Foundation
import LocalAuthentication

/// LocalAuthentication unlocks an Orrery session. It does not pretend to replace the
/// separate access-control approval on an older, file-based Keychain item.
enum CredentialUnlock {
    struct Item: Sendable { let service: String; let account: String }
    enum Result: Equatable {
        case unlocked(Int), cancelled, unavailable, needsKeychainPermission(Int)
        var message: String {
            switch self {
            case .unlocked(let count): return "\(count) saved credential\(count == 1 ? "" : "s") available for this app session. New agent sessions can use them."
            case .cancelled: return "Unlock cancelled. Your saved credentials were kept."
            case .unavailable: return "Device authentication is unavailable. You can use the existing Keychain access option instead."
            case .needsKeychainPermission: return "An older Keychain item needs macOS access approval once. Use Allow existing Keychain access below; subsequent access uses this app's stable signature."
            }
        }
    }
    static var supportsTouchID: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) && context.biometryType == .touchID
    }
    static var buttonTitle: String { supportsTouchID ? "Unlock with Touch ID" : "Unlock with device authentication" }

    static func authenticate() async -> Bool? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return nil }
        context.localizedCancelTitle = "Cancel"
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock your saved credentials for this Orrery session") { accepted, _ in
                continuation.resume(returning: accepted)
            }
        }
    }

    static func unlock(_ items: [Item], authenticate: () async -> Bool? = { await Self.authenticate() },
                       read: @escaping @Sendable (Item) -> Bool = { KeychainAccess.read(service: $0.service, account: $0.account) != nil }) async -> Result {
        guard !items.isEmpty else { return .unlocked(0) }
        guard let accepted = await authenticate() else { return .unavailable }
        guard accepted else { return .cancelled }
        // Never chain a legacy password popup onto a biometric prompt. The person must
        // explicitly choose that separate, one-time legacy access action if it is needed.
        let count = await Task.detached { items.reduce(0) { $0 + (read($1) ? 1 : 0) } }.value
        return count == items.count ? .unlocked(count) : .needsKeychainPermission(count)
    }
}

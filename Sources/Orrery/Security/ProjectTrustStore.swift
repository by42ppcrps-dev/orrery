import Foundation

/// Trust is explicit and exact per project directory, never inherited by sibling projects.
/// Directory identity also invalidates a remembered grant when a folder is replaced.
@MainActor
final class ProjectTrustStore {
    static let shared = ProjectTrustStore()
    static let forAudit = ProjectTrustStore(approveAllForTesting: true)
    private let defaults: UserDefaults
    private let approveAllForTesting: Bool
    private let key = "security.trustedProjects.v1"
    private var observers: [UUID: (URL, Bool) -> Void] = [:]

    func observe(_ callback: @escaping (URL, Bool) -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    init(defaults: UserDefaults = .standard, approveAllForTesting: Bool = false) {
        self.defaults = defaults
        self.approveAllForTesting = approveAllForTesting
    }

    func contains(_ root: URL) -> Bool {
        if approveAllForTesting { return true }
        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let identity = identity(root) else { return false }
        return (defaults.dictionary(forKey: key) as? [String: String])?[path] == identity
    }

    func setTrusted(_ root: URL, _ trusted: Bool) {
        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
        var grants = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if trusted, let identity = identity(root) { grants[path] = identity }
        else { grants.removeValue(forKey: path) }
        defaults.set(grants, forKey: key)
        for callback in Array(observers.values) { callback(root, trusted) }
    }

    private func identity(_ root: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: root.resolvingSymlinksInPath().path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device):\(inode)"
    }
}

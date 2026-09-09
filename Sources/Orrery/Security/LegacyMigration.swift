import Foundation

/// One-time move from the app's previous name (Grok Studio, identifier `local.grokstudio`).
/// The Application Support folder is renamed rather than copied, so task history, working
/// copies, project settings and the usage record keep their single owner-only location; the
/// old preference domain (provider, models, project trust, tab lists, account modes) is merged
/// into the new one without overwriting anything already set. Safe to call every launch: it
/// does nothing once the new locations exist and the marker is set.
enum LegacyMigration {
    static let legacyName = "GrokStudio"
    static let legacyDomain = "local.grokstudio"
    static let marker = "migration.fromGrokStudio.v1"

    struct Outcome: Equatable {
        var movedEntries = 0
        var leftBehind = 0
        var copiedKeys = 0
    }

    @discardableResult
    static func run(applicationSupport: URL, newName: String = "Orrery",
                    legacyDefaults: UserDefaults?, legacyDomainName: String = legacyDomain,
                    defaults: UserDefaults) -> Outcome {
        var outcome = Outcome()
        let manager = FileManager.default
        let old = applicationSupport.appendingPathComponent(legacyName, isDirectory: true)
        let new = applicationSupport.appendingPathComponent(newName, isDirectory: true)
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: old.path, isDirectory: &isDirectory), isDirectory.boolValue {
            // Entries are moved, never copied. Where both sides have a folder the merge goes one
            // level down; where both have a file the old one stays where it is and is reported.
            func merge(_ source: URL, into destination: URL) {
                guard let children = try? manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
                try? manager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for child in children {
                    let target = destination.appendingPathComponent(child.lastPathComponent)
                    if !manager.fileExists(atPath: target.path) {
                        if (try? manager.moveItem(at: child, to: target)) != nil { outcome.movedEntries += 1 } else { outcome.leftBehind += 1 }
                    } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                              (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        merge(child, into: target)
                    } else {
                        outcome.leftBehind += 1
                    }
                }
                if (try? manager.contentsOfDirectory(atPath: source.path))?.isEmpty == true { try? manager.removeItem(at: source) }
            }
            merge(old, into: new)
        }
        if !defaults.bool(forKey: marker) {
            if let values = legacyDefaults?.persistentDomain(forName: legacyDomainName) {
                for (key, value) in values where key != marker && defaults.object(forKey: key) == nil {
                    defaults.set(value, forKey: key)
                    outcome.copiedKeys += 1
                }
            }
            defaults.set(true, forKey: marker)
        }
        return outcome
    }

    @MainActor
    static func runAtLaunch() {
        guard AppModel.persistsPreferences else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        run(applicationSupport: support, legacyDefaults: UserDefaults(suiteName: legacyDomain), defaults: .standard)
    }
}

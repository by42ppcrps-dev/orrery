import AppKit
import Observation

struct DocumentRecoverySnapshot: Codable {
    var documents: [DocumentRecoveryRecord] = []
    var activePath: String?
}

/// The set of open editor tabs, plus the file operations the sidebar needs.
@MainActor
@Observable
final class DocumentStore {
    private(set) var documents: [CodeDocument] = []
    var activeID: CodeDocument.ID? {
        didSet {
            if activeID != oldValue, let active { touch(active); scheduleRecovery() }
        }
    }
    /// Most-recently-used order, so ⌘P and ⌃Tab offer what you were just looking at.
    private(set) var recentOrder: [CodeDocument.ID] = []
    /// A message the editor pane shows once — save conflicts, failed writes.
    var notice: String?
    /// Fired after a document was written to disk; the app runs plugin save hooks from it.
    var onDidSave: ((CodeDocument) -> Void)?
    /// Fired before a tab is removed so the language server can `didClose` it.
    var onWillClose: ((CodeDocument) -> Void)?
    /// Fired after a clean tab is reloaded from disk so the language server sees the new buffer.
    var onReloaded: ((CodeDocument) -> Void)?
    @ObservationIgnored private var recoveryProject: URL?
    @ObservationIgnored private var recoveryPersistence: DebouncedProjectPersistence<DocumentRecoverySnapshot>?
    @ObservationIgnored private var recoveryCaptureTask: Task<Void, Never>?
    @ObservationIgnored private var loadingRecovery = false
    @ObservationIgnored private var discardedRecoveryIDs: Set<UUID> = []
    private(set) var recoveryNotice: String?
    var recoveryFileURL: URL? { recoveryPersistence?.file.fileURL }

    /// Hides the recovery message. Recovered buffers, conflict flags and the recovery file
    /// are untouched; only the banner text goes away.
    func dismissRecoveryNotice() {
        if notice == recoveryNotice { notice = nil }
        recoveryNotice = nil
    }

    enum CloseDecision { case save, discard, cancel }
    /// Shared by every close path, including menus, project switches and window close.
    var confirmClose: ([CodeDocument]) -> CloseDecision = { documents in
        guard NSApplication.shared.activationPolicy() != .prohibited else { return .cancel }
        let alert = NSAlert()
        alert.messageText = "Save your changes before closing?"
        alert.informativeText = documents.map(\.name).joined(separator: ", ")
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    func approveClosing(_ candidates: [CodeDocument]? = nil) -> Bool {
        let dirty = (candidates ?? documents).filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        switch confirmClose(dirty) {
        case .cancel: return false
        case .discard:
            // Closing a window does not necessarily remove the live document before shutdown.
            // Explicit Discard must therefore remove its unsaved recovery immediately.
            discardedRecoveryIDs.formUnion(dirty.map(\.id))
            _ = flushRecoveryNow()
            return true
        case .save:
            // A failed/conflicted save must keep the window and every tab open.
            for document in dirty where !save(document) { return false }
            return true
        }
    }

    var active: CodeDocument? { documents.first { $0.id == activeID } }
    var dirtyDocuments: [CodeDocument] { documents.filter(\.isDirty) }
    var hasUnsavedChanges: Bool { documents.contains(where: \.isDirty) }

    /// How many tabs to keep before closing the least recently used clean one. Unsaved tabs are
    /// never closed automatically.
    static let tabLimit = 24

    @discardableResult
    func open(_ url: URL, activate: Bool = true) -> CodeDocument? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL

        if let existing = documents.first(where: {
            $0.url.resolvingSymlinksInPath().standardizedFileURL == resolved
        }) {
            if activate { activeID = existing.id }
            touch(existing)
            return existing
        }
        let document = CodeDocument(url: url)
        observeRecovery(document)
        documents.append(document)
        if activate { activeID = document.id }
        touch(document)
        trimTabs()
        scheduleRecovery()
        return document
    }

    @discardableResult
    func close(_ document: CodeDocument, approved: Bool = false) -> Bool {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return true }
        guard approved || approveClosing([document]) else { return false }
        onWillClose?(document)
        document.onRecoveryChange = nil
        documents.remove(at: index)
        recentOrder.removeAll { $0 == document.id }
        if activeID == document.id {
            activeID = recentOrder.first ?? documents.last?.id
        }
        discardedRecoveryIDs.remove(document.id)
        // A crash immediately after Discard/Close must not resurrect a stale dirty buffer.
        _ = flushRecoveryNow()
        return true
    }

    @discardableResult
    func closeAll() -> Bool {
        guard approveClosing() else { return false }
        let closing = documents
        for document in closing { onWillClose?(document); document.onRecoveryChange = nil }
        documents.removeAll()
        recentOrder.removeAll()
        activeID = nil
        discardedRecoveryIDs.removeAll()
        _ = flushRecoveryNow()
        return true
    }

    func closeOthers(than document: CodeDocument) {
        let victims = documents.filter { $0.id != document.id && !$0.isDirty }
        for victim in victims { onWillClose?(victim); victim.onRecoveryChange = nil }
        documents.removeAll { $0.id != document.id && !$0.isDirty }
        recentOrder = recentOrder.filter { id in documents.contains { $0.id == id } }
        activeID = document.id
        scheduleRecovery()
    }

    private func touch(_ document: CodeDocument) {
        recentOrder.removeAll { $0 == document.id }
        recentOrder.insert(document.id, at: 0)
    }

    private func trimTabs() {
        guard documents.count > Self.tabLimit else { return }
        // Drop the least recently used clean tab; never discard unsaved work.
        for id in recentOrder.reversed() where id != activeID {
            guard let candidate = documents.first(where: { $0.id == id }), !candidate.isDirty
            else { continue }
            close(candidate)
            if documents.count <= Self.tabLimit { return }
        }
    }

    /// Cycle tabs in most-recently-used order.
    func selectNext(_ offset: Int) {
        guard !documents.isEmpty else { return }
        let ids = documents.map(\.id)
        let current = activeID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = (current + offset + ids.count) % ids.count
        activeID = ids[next]
    }

    // MARK: Saving

    @discardableResult
    func save(_ document: CodeDocument) -> Bool {
        switch document.save() {
        case .saved:
            onDidSave?(document)
            return true
        case .refusedUnreadable:
            notice = "\(document.name) is not editable text, so it was not written."
            return false
        case .conflicted:
            notice = "\(document.name) changed on disk since you opened it. Reload to see the "
                + "new version, or use Save Anyway to overwrite it."
            return false
        case let .failed(message):
            notice = "Could not save \(document.name): \(message)"
            return false
        }
    }

    @discardableResult
    func saveAll() -> Int {
        var saved = 0
        for document in documents where document.isDirty {
            if save(document) { saved += 1 }
        }
        return saved
    }

    /// Called when an agent finishes a turn: an agent edit under an open tab must be noticed.
    func checkAllOnDisk() {
        for document in documents { document.checkDisk() }
    }

    /// Reload every open tab that is clean and has changed on disk. A tab with unsaved edits is
    /// left alone and keeps its banner, because discarding someone's typing is never the safe
    /// default.
    @discardableResult
    func reloadUnmodifiedFromDisk() -> Int {
        var reloaded = 0
        for document in documents where document.changedOnDisk && !document.isDirty {
            document.reload()
            onReloaded?(document)
            reloaded += 1
        }
        return reloaded
    }

    func document(for url: URL) -> CodeDocument? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        return documents.first { $0.url.resolvingSymlinksInPath().standardizedFileURL == resolved }
    }

    func setDiagnostics(_ diagnostics: [Diagnostic], for url: URL) {
        document(for: url)?.diagnostics = diagnostics
    }

    // MARK: Recovery

    /// Call after the previous project's tabs have closed and before opening initial files.
    /// Only project files are recovered; provider credential/configuration editors are excluded.
    func configure(project: URL, storageDirectory: URL? = nil) {
        let canonical = WorkspaceFileAccess.canonicalPath(project)
            .map { URL(fileURLWithPath: $0) } ?? project.resolvingSymlinksInPath().standardizedFileURL
        guard recoveryProject != canonical else { return }
        _ = flushRecoveryNow()
        recoveryProject = canonical
        recoveryNotice = nil
        discardedRecoveryIDs.removeAll()
        let persistence = DebouncedProjectPersistence<DocumentRecoverySnapshot>(file: PrivateProjectFile(
            project: canonical,
            directory: storageDirectory ?? PrivateProjectFile.defaultDirectory("DocumentRecovery"),
            byteLimit: 64 * 1024 * 1024), debounceNanoseconds: 0, validate: Self.validateRecovery)
        recoveryPersistence = persistence
        guard documents.isEmpty else {
            for document in documents { observeRecovery(document) }
            scheduleRecovery()
            return
        }
        loadingRecovery = true
        defer { loadingRecovery = false }
        do {
            guard let recovered = try persistence.load() else { return }
            var rejected = 0
            for record in recovered.documents {
                guard let url = recoveryURL(for: record, root: canonical) else { rejected += 1; continue }
                let exists = FileManager.default.fileExists(atPath: url.path)
                guard exists || record.text != nil else { continue }
                let document = CodeDocument(url: url, recoveryRoot: canonical)
                guard document.isReadable || record.text != nil else { continue }
                document.restoreRecovery(record)
                observeRecovery(document)
                documents.append(document)
                touch(document)
                if recovered.activePath == record.path { activeID = document.id }
            }
            if activeID == nil { activeID = documents.last?.id }
            let dirty = dirtyDocuments.count
            let conflicts = dirtyDocuments.filter(\.changedOnDisk).count
            if dirty > 0 {
                recoveryNotice = "Recovered \(dirty) unsaved file\(dirty == 1 ? "" : "s")."
                    + (conflicts > 0 ? " \(conflicts) also changed on disk; your edits are preserved for review." : "")
            }
            if rejected > 0 {
                recoveryNotice = (recoveryNotice.map { $0 + " " } ?? "")
                    + "Skipped \(rejected) recovery path\(rejected == 1 ? "" : "s") that no longer safely belong to this project."
            }
            if let recoveryNotice { notice = recoveryNotice }
        } catch {
            recoveryNotice = "Editor recovery could not be restored: \(error.localizedDescription)"
            notice = recoveryNotice
        }
    }

    private func observeRecovery(_ document: CodeDocument) {
        document.onRecoveryChange = { [weak self, weak document] in
            guard let self, let document else { return }
            self.discardedRecoveryIDs.remove(document.id)
            self.scheduleRecovery()
        }
    }

    func scheduleRecovery() {
        guard !loadingRecovery, recoveryPersistence != nil, recoveryCaptureTask == nil else { return }
        // At most one snapshot per 750 ms, even during continuous typing. Capturing NSString
        // contents only here avoids copying every open buffer for each keystroke.
        recoveryCaptureTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 750_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.recoveryCaptureTask = nil
            guard let snapshot = self.recoverySnapshot(), let persistence = self.recoveryPersistence else { return }
            if !(await persistence.flush(snapshot)) {
                self.recoveryNotice = "Editor recovery could not be saved: \(persistence.lastError ?? "Unknown error")"
                self.notice = self.recoveryNotice
            }
        }
    }

    @discardableResult
    func flushRecovery() async -> Bool {
        recoveryCaptureTask?.cancel(); recoveryCaptureTask = nil
        guard let snapshot = recoverySnapshot(), let recoveryPersistence else { return true }
        let success = await recoveryPersistence.flush(snapshot)
        if !success { recoveryNotice = recoveryPersistence.lastError; notice = recoveryNotice }
        return success
    }

    @discardableResult
    func flushRecoveryNow() -> Bool {
        recoveryCaptureTask?.cancel(); recoveryCaptureTask = nil
        guard !loadingRecovery, let snapshot = recoverySnapshot(), let recoveryPersistence else { return true }
        let success = recoveryPersistence.flushNow(snapshot)
        if !success { recoveryNotice = recoveryPersistence.lastError; notice = recoveryNotice }
        return success
    }

    private func recoverySnapshot() -> DocumentRecoverySnapshot? {
        guard let root = recoveryProject else { return nil }
        let prefix = root.path + "/"
        var records: [DocumentRecoveryRecord] = []
        var activePath: String?
        for document in documents where document.isReadable {
            let parent = document.url.deletingLastPathComponent()
            let canonicalParent = WorkspaceFileAccess.canonicalPath(parent)
                .map { URL(fileURLWithPath: $0) } ?? parent.resolvingSymlinksInPath().standardizedFileURL
            let candidate = canonicalParent.appendingPathComponent(document.url.lastPathComponent).path
            guard candidate.hasPrefix(prefix) else { continue }
            let relative = String(candidate.dropFirst(prefix.count))
            let record = document.recoveryRecord(path: relative,
                includeEdits: !discardedRecoveryIDs.contains(document.id))
            guard recoveryURL(for: record, root: root) != nil else { continue }
            records.append(record)
            if document.id == activeID { activePath = relative }
        }
        return DocumentRecoverySnapshot(documents: records, activePath: activePath)
    }

    private func recoveryURL(for record: DocumentRecoveryRecord, root: URL) -> URL? {
        guard let parts = try? WorkspaceFileAccess(root: root).components(for: record.path),
              !record.path.hasPrefix("/"), !parts.isEmpty else { return nil }
        let url = root.appendingPathComponent(parts.joined(separator: "/"))
        // Baselines cannot redirect restored Save / Save Anyway to a different file.
        if let target = record.diskTarget {
            let raw = URL(fileURLWithPath: target).standardizedFileURL
            let normalizedParent = WorkspaceFileAccess.canonicalPath(raw.deletingLastPathComponent())
                .map { URL(fileURLWithPath: $0) } ?? raw.deletingLastPathComponent()
            guard normalizedParent.appendingPathComponent(raw.lastPathComponent).path == url.path else { return nil }
        } else if record.text != nil { return nil }
        var cursor = root
        for part in parts {
            cursor.appendPathComponent(part)
            let attributes = try? FileManager.default.attributesOfItem(atPath: cursor.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink { return nil }
        }
        return url
    }

    private static func validateRecovery(_ snapshot: DocumentRecoverySnapshot) throws {
        guard snapshot.documents.count <= 128,
              Set(snapshot.documents.map(\.path)).count == snapshot.documents.count,
              snapshot.documents.allSatisfy({ record in
                  record.path.utf8.count <= 4096 && (record.text?.utf8.count ?? 0) <= CodeDocument.sizeLimit
                      && (record.diskDigest == nil || record.diskDigest?.count == 32)
              }) else {
            throw PrivateProjectFile.Failure("Editor recovery exceeds its limits or contains invalid records.")
        }
    }
}

// MARK: - File operations

/// Creating, renaming and removing files. Deletes go to the Trash — an IDE that hard-deletes a
/// file the user picked by mistake has no way to give it back.
@MainActor
enum FileOperations {
    enum Failure: LocalizedError {
        case exists(String)
        case system(String)
        var errorDescription: String? {
            switch self {
            case let .exists(name): return "\(name) already exists."
            case let .system(message): return message
            }
        }
    }

    static func createFile(named name: String, in directory: URL) throws -> URL {
        try validateName(name)
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.exists(name) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: url, options: .withoutOverwriting)
            return url
        } catch { throw Failure.system(error.localizedDescription) }
    }

    static func createFolder(named name: String, in directory: URL) throws -> URL {
        try validateName(name)
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.exists(name) }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        } catch { throw Failure.system(error.localizedDescription) }
    }

    static func rename(_ url: URL, to name: String) throws -> URL {
        try validateName(name)
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        guard target != url else { return url }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw Failure.exists(name)
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch { throw Failure.system(error.localizedDescription) }
    }

    static func moveToTrash(_ url: URL) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch { throw Failure.system(error.localizedDescription) }
    }

    static func duplicate(_ url: URL) throws -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = url
        var counter = 2
        repeat {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            counter += 1
        } while FileManager.default.fileExists(atPath: candidate.path) && counter < 100
        do {
            try FileManager.default.copyItem(at: url, to: candidate)
            return candidate
        } catch { throw Failure.system(error.localizedDescription) }
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw Failure.system("Enter a single file or folder name without slashes or control characters.") }
    }
}

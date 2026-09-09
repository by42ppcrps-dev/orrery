import Foundation
import CryptoKit
import Darwin

struct TaskWorkspace: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var projectRoot: URL
    var executionRoot: URL
    var createdAt: Date
    var isolated: Bool
    var notices: [String]
}

struct TaskFileChange: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case added, modified, deleted }
    var path: String
    var kind: Kind
    var isBinary: Bool
    var beforeBytes: Int
    var afterBytes: Int
    var applied: Bool
    var matchesAppliedVersion: Bool
    var beforeMode: UInt16?
    var afterMode: UInt16?
    var id: String { path }
}

struct TaskWorkspaceUsage: Sendable {
    var taskSnapshotBytes: Int
    var totalSnapshotBytes: Int
    var maximumSnapshotBytes: Int
}

struct TaskFilePreview: Sendable {
    var path: String
    var before: String?
    var after: String?
    var isBinary: Bool
    var truncated: Bool
}

/// Independent working copies prevent editing collisions. They do not sandbox agent processes.
/// Every transfer back to the project compares the exact checkpoint bytes and permissions first.
actor TaskWorkspaceStore {
    static let shared = TaskWorkspaceStore()
    static let maximumFileBytes = 16 * 1_024 * 1_024
    static let maximumTotalBytes = 256 * 1_024 * 1_024
    static let maximumFileCount = 20_000
    static let maximumStoredSnapshotBytes = 1_024 * 1_024 * 1_024
    static let excludedDirectories: Set<String> = ["node_modules", ".build", "build", "dist", "target", ".next", ".cache", ".venv", "venv", "DerivedData", "Pods", "Carthage"]

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
    private struct Entry: Codable, Equatable {
        var hash: String
        var size: Int
        var mode: UInt16
    }
    private struct Applied: Codable {
        var before: Entry?
        var after: Entry?
    }
    private struct Pending: Codable {
        var path: String
        var expected: Entry?
        var desired: Entry?
        var appliedAfter: Applied?
        var restoringDirect: Bool
    }
    private struct Manifest: Codable {
        var version = 1
        var workspace: TaskWorkspace
        var baseline: [String: Entry]
        var captured: [String: Entry]
        var applied: [String: Applied] = [:]
        var trackedPaths: Set<String>
        var pending: Pending?
    }
    private let directory: URL
    private let snapshotQuota: Int
    private var cachedSnapshotBytes: Int?

    init(directory: URL? = nil, snapshotQuota: Int = TaskWorkspaceStore.maximumStoredSnapshotBytes) {
        self.snapshotQuota = snapshotQuota
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orrery/TaskWorkspaces", isDirectory: true)
    }

    /// Capture the actual working files, including preexisting uncommitted edits. A private,
    /// independent Git baseline is created when the selected project is a Git repository.
    func create(taskID: UUID, project: URL, isolated: Bool = true) async throws -> TaskWorkspace {
        try prepareStorage()
        let container = folder(taskID)
        guard !FileManager.default.fileExists(atPath: container.path) else {
            let existing = try load(taskID).workspace
            guard WorkspaceFileAccess.canonicalPath(existing.projectRoot) == WorkspaceFileAccess.canonicalPath(project),
                  existing.isolated == isolated else { throw failure("This task already belongs to another working folder.") }
            return existing
        }
        guard let canonical = WorkspaceFileAccess.canonicalPath(project) else { throw failure("The project folder is unavailable.") }
        let projectRoot = URL(fileURLWithPath: canonical, isDirectory: true)
        guard canonical != "/", !canonical.hasPrefix(directory.standardizedFileURL.path + "/") else { throw failure("Choose a project folder outside task storage.") }
        try createPrivateDirectory(container)
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: container); cachedSnapshotBytes = nil }
        }
        try createPrivateDirectory(container.appendingPathComponent("objects"))
        let tracked = try await trackedFiles(in: projectRoot)
        var notices = ["Snapshots include regular files and executable permissions, with a 20,000-file, 16 MB per-file and 256 MB total limit. Git metadata, empty folders and extended attributes are excluded. Symbolic links are refused."]
        var excluded = Set<String>()
        let baseline = try scan(projectRoot, taskID: taskID, tracked: tracked.paths, excluded: &excluded)
        notices.append("Snapshot contents share a \(ByteCountFormatter.string(fromByteCount: Int64(snapshotQuota), countStyle: .file)) limit across tasks. Working copies and build outputs use additional space. Old tasks are never deleted automatically.")
        if !excluded.isEmpty {
            notices.append("Untracked generated/dependency folders excluded: " + excluded.sorted().joined(separator: ", ") + ". Install dependencies in this working copy when needed. Tracked files are always included.")
        }
        let execution = isolated ? container.appendingPathComponent("work", isDirectory: true) : projectRoot
        if isolated {
            try createPrivateDirectory(execution)
            for (path, entry) in baseline {
                let data = try object(entry, taskID)
                let access = SafeFiles(root: execution)
                if try !access.clone(path, source: container.appendingPathComponent("objects/" + entry.hash), mode: entry.mode) {
                    try access.replace(path, expected: nil, data: data, mode: entry.mode)
                } else if try access.read(path)?.data != data {
                    throw failure("A cloned checkpoint file changed while copying. No partial task was retained.")
                }
            }
            notices.append("This is an independent copy of the current files. Changes reach your project only when applied. Process/file/network restrictions are configured separately.")
            if tracked.isGit {
                try await initializeGit(in: execution)
                notices.append("Git history starts at the task checkpoint. The original repository, branch, index and history are unchanged.")
            }
        }
        let workspace = TaskWorkspace(id: taskID, projectRoot: projectRoot, executionRoot: execution,
                                      createdAt: Date(), isolated: isolated, notices: notices)
        try save(Manifest(workspace: workspace, baseline: baseline, captured: baseline, trackedPaths: tracked.paths), taskID)
        completed = true
        return workspace
    }

    func workspace(taskID: UUID) throws -> TaskWorkspace { try load(taskID).workspace }

    func usage(taskID: UUID) throws -> TaskWorkspaceUsage {
        _ = try load(taskID)
        cachedSnapshotBytes = nil
        return TaskWorkspaceUsage(taskSnapshotBytes: try objectBytes(in: folder(taskID)),
                                  totalSnapshotBytes: try totalSnapshotBytes(), maximumSnapshotBytes: snapshotQuota)
    }

    /// Explicit capture only: no recursive polling or file hashing while the IDE is idle.
    func capture(taskID: UUID) throws -> [TaskFileChange] {
        var manifest = try load(taskID)
        var excluded = Set<String>()
        do {
            manifest.captured = try scan(manifest.workspace.executionRoot, taskID: taskID,
                                         tracked: manifest.trackedPaths.union(manifest.baseline.keys), excluded: &excluded)
        } catch {
            try? pruneUnusedObjects(manifest, taskID)
            throw error
        }
        try save(manifest, taskID)
        try pruneUnusedObjects(manifest, taskID)
        return try changes(manifest, taskID)
    }

    func changes(taskID: UUID) throws -> [TaskFileChange] { try changes(load(taskID), taskID) }

    func diff(taskID: UUID, path: String) throws -> TaskFilePreview {
        try validate(path)
        let manifest = try load(taskID)
        let old = try manifest.baseline[path].map { try object($0, taskID) }
        let new = try manifest.captured[path].map { try object($0, taskID) }
        let binary = [old, new].compactMap { $0 }.contains { isBinary($0) }
        let limit = 256 * 1_024
        func preview(_ data: Data?) -> String? {
            guard let data else { return nil }
            guard !binary else { return nil }
            return String(decoding: data.prefix(limit), as: UTF8.self)
        }
        return TaskFilePreview(path: path, before: preview(old), after: preview(new), isBinary: binary,
                               truncated: (old?.count ?? 0) > limit || (new?.count ?? 0) > limit)
    }

    /// Apply an explicitly captured version. Never reread agent files during application.
    /// Preflight every selected path before changing any project file.
    func integrate(taskID: UUID, paths: [String]? = nil) throws {
        var manifest = try load(taskID)
        guard manifest.workspace.isolated else { throw failure("This task already runs in the project folder.") }
        let selected = try selectedPaths(paths, manifest)
        let access = SafeFiles(root: manifest.workspace.projectRoot)
        for path in selected {
            let expected = manifest.applied[path].map { $0.after } ?? manifest.baseline[path]
            try assertMatches(access.read(path), expected, path: path)
        }
        for path in selected {
            let expected = manifest.applied[path].map { $0.after } ?? manifest.baseline[path]
            let desired = manifest.captured[path]
            // The journal is durable before replacing bytes. On interruption, comparisons
            // recognize either the baseline or applied state; newer user edits always refuse.
            let applied = Applied(before: manifest.baseline[path], after: desired)
            manifest.pending = Pending(path: path, expected: expected, desired: desired,
                                       appliedAfter: applied, restoringDirect: false)
            try save(manifest, taskID)
            try access.replace(path, expected: try materialize(expected, taskID),
                               data: try desired.map { try object($0, taskID) }, mode: desired?.mode ?? 0o600)
            manifest.applied[path] = applied
            manifest.pending = nil
            try save(manifest, taskID)
        }
    }

    /// In an isolated task, undo previously applied files. In a direct task, restore the last
    /// captured changes. An edit made after that capture/application is never overwritten.
    func restore(taskID: UUID, paths: [String]? = nil) throws {
        var manifest = try load(taskID)
        let selected: [String]
        if manifest.workspace.isolated {
            selected = paths ?? manifest.applied.keys.sorted()
            for path in selected { try validate(path); guard manifest.applied[path] != nil else { throw failure("\(path) has not been applied from this task.") } }
        } else { selected = try selectedPaths(paths, manifest) }
        let access = SafeFiles(root: manifest.workspace.projectRoot)
        for path in selected {
            let expected = manifest.workspace.isolated ? manifest.applied[path]?.after : manifest.captured[path]
            try assertMatches(access.read(path), expected, path: path)
        }
        for path in selected {
            let expected = manifest.workspace.isolated ? manifest.applied[path]?.after : manifest.captured[path]
            let desired = manifest.baseline[path]
            manifest.pending = Pending(path: path, expected: expected, desired: desired,
                                       appliedAfter: nil, restoringDirect: !manifest.workspace.isolated)
            try save(manifest, taskID)
            try access.replace(path, expected: try materialize(expected, taskID),
                               data: try desired.map { try object($0, taskID) }, mode: desired?.mode ?? 0o600)
            if manifest.workspace.isolated { manifest.applied.removeValue(forKey: path) }
            else { manifest.captured[path] = desired }
            manifest.pending = nil
            try save(manifest, taskID)
        }
    }

    /// The caller must stop agents and close editors using executionRoot before discarding.
    func remove(taskID: UUID) throws {
        _ = try load(taskID)
        try FileManager.default.removeItem(at: folder(taskID))
        cachedSnapshotBytes = nil
    }

    private func selectedPaths(_ paths: [String]?, _ manifest: Manifest) throws -> [String] {
        let changed = Set(manifest.baseline.keys).union(manifest.captured.keys).union(manifest.applied.keys).filter {
            manifest.baseline[$0] != manifest.captured[$0] || manifest.applied[$0] != nil
        }
        let selected = paths ?? changed.sorted()
        guard Set(selected).count == selected.count else { throw failure("Duplicate change paths.") }
        for path in selected { try validate(path); guard changed.contains(path) else { throw failure("\(path) is not a captured task change.") } }
        return selected
    }
    private func changes(_ manifest: Manifest, _ id: UUID) throws -> [TaskFileChange] {
        try selectedPaths(nil, manifest).map { path in
            let before = manifest.baseline[path], after = manifest.captured[path]
            let binary = try [before, after].compactMap { $0 }.contains { try isBinary(object($0, id)) }
            return TaskFileChange(path: path, kind: after == nil ? .deleted : before == nil ? .added : .modified,
                                  isBinary: binary, beforeBytes: before?.size ?? 0, afterBytes: after?.size ?? 0,
                                  applied: manifest.applied[path] != nil, matchesAppliedVersion: manifest.applied[path].map { $0.after == after } ?? false,
                                  beforeMode: before?.mode, afterMode: after?.mode)
        }
    }
    private func materialize(_ entry: Entry?, _ id: UUID) throws -> SafeFiles.File? {
        try entry.map { SafeFiles.File(data: try object($0, id), mode: $0.mode) }
    }
    private func assertMatches(_ actual: SafeFiles.File?, _ expected: Entry?, path: String) throws {
        guard actual.map({ entry($0) }) == expected else { throw failure("\(path) changed outside this task. Your newer edits were preserved; review and reconcile this file manually.") }
    }
    private func isBinary(_ data: Data) -> Bool { data.contains(0) || String(data: data, encoding: .utf8) == nil }
    private func entry(_ file: SafeFiles.File) -> Entry {
        Entry(hash: SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined(), size: file.data.count, mode: file.mode)
    }
    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func failure(_ message: String) -> Failure { Failure(message: message) }
    private func validate(_ path: String) throws { try SafeFiles.validate(path) }

    private func scan(_ requestedRoot: URL, taskID: UUID, tracked: Set<String>, excluded: inout Set<String>) throws -> [String: Entry] {
        // Resolve platform aliases through an opened directory, never by following a swapped
        // working-root symlink. File reads still traverse their parents with O_NOFOLLOW.
        let descriptor = open(requestedRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("The task working folder is missing or is a symbolic link.") }
        defer { close(descriptor) }
        var resolved = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &resolved) == 0 else { throw failure("The task working folder is unavailable.") }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        var result: [String: Entry] = [:]
        var bytes = 0
        _ = try totalSnapshotBytes()
        let access = SafeFiles(root: root)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        var enumerationError: Error?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw failure("Could not inspect the working folder.") }
        let prefix = root.path + "/"
        var trackedParents = Set<String>()
        for file in tracked {
            var parts = file.split(separator: "/").map(String.init)
            while parts.count > 1 { parts.removeLast(); trackedParents.insert(parts.joined(separator: "/")) }
        }
        for case let url as URL in iterator {
            try Task.checkCancellation()
            guard url.path.hasPrefix(prefix) else { throw failure("File enumeration escaped the working folder.") }
            let path = String(url.path.dropFirst(prefix.count))
            try validate(path)
            if url.lastPathComponent == ".git" { iterator.skipDescendants(); continue }
            let values = try url.resourceValues(forKeys: keys)
            let parts = path.split(separator: "/").map(String.init)
            if let excludedPart = parts.first(where: { Self.excludedDirectories.contains($0) }), !tracked.contains(path) {
                let descendantTracked = trackedParents.contains(path)
                if !descendantTracked {
                    excluded.insert(excludedPart)
                    if values.isDirectory == true { iterator.skipDescendants() }
                    continue
                }
            }
            guard values.isSymbolicLink != true else { throw failure("\(path) is a symbolic link. Task checkpoints require regular files; remove the link or choose another project folder.") }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw failure("\(path) is not a regular file and cannot be checkpointed.") }
            guard result.count < Self.maximumFileCount else { throw failure("The task exceeds the 20,000-file checkpoint limit. Choose a smaller project folder.") }
            guard let file = try access.read(path) else { throw failure("\(path) disappeared while creating the checkpoint. Retry after file changes settle.") }
            bytes += file.data.count
            guard bytes <= Self.maximumTotalBytes else { throw failure("The task exceeds the 256 MB checkpoint limit. Choose a smaller project folder.") }
            let record = entry(file)
            try storeObject(file.data, entry: record, taskID)
            result[path] = record
        }
        if let enumerationError { throw enumerationError }
        return result
    }

    private func trackedFiles(in root: URL) async throws -> (isGit: Bool, paths: Set<String>) {
        let probe = try await runGit(["rev-parse", "--show-toplevel"], root: root, timeout: 10)
        guard !probe.timedOut, !probe.cancelled else { throw failure("Checking the project's Git repository timed out or was cancelled.") }
        guard probe.status == 0 else { return (false, []) }
        // ls-files is relative to this folder, including when the chosen project is a subfolder.
        let files = try await runGit(["ls-files", "-z", "--cached", "--", "."], root: root, timeout: 15)
        guard files.status == 0, !files.timedOut, !files.cancelled else { throw failure("Could not enumerate tracked files; no partial task copy was created.") }
        let paths = Set(files.standardOutput.split(separator: "\0").map(String.init))
        for path in paths { try validate(path) }
        guard paths.count <= Self.maximumFileCount else { throw failure("The repository exceeds the 20,000-file checkpoint limit.") }
        return (true, paths)
    }
    private func initializeGit(in root: URL) async throws {
        for arguments in [["init", "--quiet"], ["add", "--all", "--force", "--", "."],
                          ["-c", "user.name=Orrery", "-c", "user.email=orrery@orrery.invalid", "-c", "commit.gpgSign=false", "commit", "--quiet", "--allow-empty", "-m", "Task starting files"]] {
            let result = try await runGit(arguments, root: root, timeout: 30)
            guard result.status == 0, !result.timedOut, !result.cancelled else { throw failure("Could not initialize independent task history. The original project was not changed.") }
        }
    }
    private func runGit(_ arguments: [String], root: URL, timeout: TimeInterval) async throws -> ProcessRunner.Result {
        // Do not inherit GIT_DIR, GIT_INDEX_FILE, GIT_CONFIG_COUNT, template overrides, or
        // credential/loader variables from the host. Git never runs hooks or fsmonitor here.
        try await ProcessRunner.run("/usr/bin/env", ["-i", "PATH=/usr/bin:/bin",
            "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
            "GIT_TERMINAL_PROMPT=0", "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments,
            cwd: root, timeout: timeout)
    }
    private func pruneUnusedObjects(_ manifest: Manifest, _ id: UUID) throws {
        var used = Set(manifest.baseline.values.map(\.hash)).union(manifest.captured.values.map(\.hash))
        for applied in manifest.applied.values {
            if let hash = applied.before?.hash { used.insert(hash) }
            if let hash = applied.after?.hash { used.insert(hash) }
        }
        if let hash = manifest.pending?.expected?.hash { used.insert(hash) }
        if let hash = manifest.pending?.desired?.hash { used.insert(hash) }
        let objects = folder(id).appendingPathComponent("objects")
        for url in try FileManager.default.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            guard name.count == 64, name.allSatisfy({ $0.isHexDigit }), !used.contains(name) else { continue }
            let access = SafeFiles(root: folder(id))
            if let file = try access.read("objects/" + name) {
                try access.replace("objects/" + name, expected: file, data: nil, mode: 0o600)
                cachedSnapshotBytes = max(0, (cachedSnapshotBytes ?? 0) - file.data.count)
            }
        }
    }
    private func objectBytes(in taskFolder: URL) throws -> Int {
        let objects = taskFolder.appendingPathComponent("objects")
        guard FileManager.default.fileExists(atPath: objects.path) else { return 0 }
        var rootInfo = stat()
        guard lstat(objects.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else { throw failure("Snapshot storage must not contain symbolic links.") }
        var total = 0
        for item in try FileManager.default.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil) {
            var info = stat()
            guard lstat(item.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0, info.st_size <= Self.maximumFileBytes else { throw failure("Snapshot storage contains an invalid file.") }
            total += Int(info.st_size)
        }
        return total
    }
    private func totalSnapshotBytes() throws -> Int {
        if let cachedSnapshotBytes { return cachedSnapshotBytes }
        var total = 0
        for taskFolder in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: taskFolder.lastPathComponent) != nil else { continue }
            var info = stat()
            guard lstat(taskFolder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw failure("Task storage must not contain symbolic links.") }
            total += try objectBytes(in: taskFolder)
        }
        cachedSnapshotBytes = total
        return total
    }
    private func prepareStorage() throws { try createPrivateDirectory(directory) }
    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw failure("Task storage must be a private folder owned by your account.") }
        guard chmod(url.path, 0o700) == 0 else { throw failure("Could not secure the task storage folder.") }
    }
    private func storeObject(_ data: Data, entry: Entry, _ id: UUID) throws {
        let access = SafeFiles(root: folder(id))
        let path = "objects/" + entry.hash
        if let old = try access.read(path) {
            guard old.data == data else { throw failure("Checkpoint storage is damaged.") }
        } else {
            let used = try totalSnapshotBytes()
            guard data.count <= snapshotQuota - used else {
                throw failure("Task snapshots reached the \(ByteCountFormatter.string(fromByteCount: Int64(snapshotQuota), countStyle: .file)) storage limit. Remove old tasks you no longer need before creating more snapshots. Existing work was preserved.")
            }
            try access.replace(path, expected: nil, data: data, mode: 0o600)
            cachedSnapshotBytes = used + data.count
        }
    }
    private func object(_ entry: Entry, _ id: UUID) throws -> Data {
        guard entry.hash.count == 64, entry.hash.allSatisfy({ $0.isHexDigit }),
              let file = try SafeFiles(root: folder(id)).read("objects/" + entry.hash),
              file.data.count == entry.size, self.entry(file).hash == entry.hash else { throw failure("Checkpoint data is missing or damaged.") }
        return file.data
    }
    private func save(_ manifest: Manifest, _ id: UUID) throws {
        let data = try JSONEncoder().encode(manifest)
        let access = SafeFiles(root: folder(id))
        try access.replace("manifest.json", expected: try access.read("manifest.json"), data: data, mode: 0o600)
    }
    private func load(_ id: UUID) throws -> Manifest {
        guard let file = try SafeFiles(root: folder(id)).read("manifest.json") else { throw failure("The task checkpoint is unavailable.") }
        var manifest = try JSONDecoder().decode(Manifest.self, from: file.data)
        // The store moved (the rename from Grok Studio, or a copied home folder): a working copy
        // whose recorded root has this workspace's own layout under another store root is
        // rebased onto the current store, once, and the manifest is rewritten.
        let expectedWork = folder(id).appendingPathComponent("work", isDirectory: true)
        if manifest.workspace.isolated, manifest.workspace.executionRoot != expectedWork,
           manifest.workspace.executionRoot.lastPathComponent == "work",
           manifest.workspace.executionRoot.deletingLastPathComponent().lastPathComponent == id.uuidString,
           FileManager.default.fileExists(atPath: expectedWork.path) {
            manifest.workspace.executionRoot = expectedWork
            try save(manifest, id)
        }
        guard manifest.version == 1, manifest.workspace.id == id,
              manifest.baseline.count <= Self.maximumFileCount, manifest.captured.count <= Self.maximumFileCount,
              !manifest.workspace.isolated || manifest.workspace.executionRoot == folder(id).appendingPathComponent("work", isDirectory: true)
        else { throw failure("The task checkpoint metadata is invalid.") }
        for path in Set(manifest.baseline.keys).union(manifest.captured.keys).union(manifest.applied.keys).union(manifest.trackedPaths) { try validate(path) }
        if let pending = manifest.pending {
            try validate(pending.path)
            let actual = try SafeFiles(root: manifest.workspace.projectRoot).read(pending.path).map { entry($0) }
            if actual == pending.desired {
                manifest.applied[pending.path] = pending.appliedAfter
                if pending.restoringDirect { manifest.captured[pending.path] = pending.desired }
            } else if actual != pending.expected {
                throw failure("An interrupted apply/restore conflicts with newer edits in \(pending.path). No file was overwritten. Reconcile that file before continuing this task.")
            }
            manifest.pending = nil
            try save(manifest, id)
        }
        return manifest
    }

    /// Descriptor-relative traversal rejects symlink races in reads, writes and deletes.
    private struct SafeFiles {
        struct File: Equatable { var data: Data; var mode: UInt16 }
        var root: URL
        static func validate(_ path: String) throws {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.utf8.contains(0), !path.hasPrefix("/"),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw Failure(message: "Invalid task file path.")
            }
        }
        func read(_ path: String) throws -> File? { try parent(path, create: false, missingOK: true) { try readAt($0, $1) } }
        /// APFS copy-on-write clones share storage blocks, never a writable file identity.
        /// Cross-volume and non-APFS filesystems fall back to the bounded byte copy.
        func clone(_ path: String, source: URL, mode: UInt16) throws -> Bool {
            try parent(path, create: true, missingOK: false) { parent, name -> Bool? in
                guard try readAt(parent, name) == nil else { throw Failure(message: "The task copy destination already exists.") }
                let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw systemFailure() }
                defer { close(descriptor) }
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure(message: "Checkpoint source is not a regular file.") }
                guard fclonefileat(descriptor, parent, name, 0) == 0 else {
                    if [ENOTSUP, EXDEV, EINVAL, ENOSYS].contains(errno) { return false }
                    throw systemFailure()
                }
                let cloned = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard cloned >= 0 else { throw systemFailure() }
                defer { close(cloned) }
                guard fchmod(cloned, mode_t(mode & 0o777)) == 0, fsync(cloned) == 0 else { throw systemFailure() }
                return true
            } ?? false
        }
        func replace(_ path: String, expected: File?, data: Data?, mode: UInt16) throws {
            guard (data?.count ?? 0) <= TaskWorkspaceStore.maximumFileBytes else { throw Failure(message: "The file exceeds the 16 MB checkpoint limit.") }
            try parent(path, create: data != nil, missingOK: data == nil) { parent, name in
                guard try readAt(parent, name) == expected else { throw Failure(message: "\(path) changed while applying the task. Newer edits were preserved.") }
                guard let data else {
                    if expected != nil, unlinkat(parent, name, 0) != 0 { throw systemFailure() }
                    _ = fsync(parent)
                    return
                }
                let temporary = ".grok-task-" + UUID().uuidString
                let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw systemFailure() }
                defer { close(descriptor); unlinkat(parent, temporary, 0) }
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw systemFailure() }
                        offset += count
                    }
                }
                guard fchmod(descriptor, mode_t(mode & 0o777)) == 0, fsync(descriptor) == 0 else { throw systemFailure() }
                // Verify once more after staging bytes to narrow races with external editors.
                guard try readAt(parent, name) == expected else { throw Failure(message: "\(path) changed while applying the task. Newer edits were preserved.") }
                guard renameat(parent, temporary, parent, name) == 0 else { throw systemFailure() }
                _ = fsync(parent)
            }
        }
        private func readAt(_ parent: Int32, _ name: String) throws -> File? {
            let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if descriptor < 0 && errno == ENOENT { return nil }
            guard descriptor >= 0 else { throw systemFailure() }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0, info.st_size <= TaskWorkspaceStore.maximumFileBytes else {
                throw Failure(message: "Only regular files up to 16 MB can be checkpointed.")
            }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw systemFailure() }
                if count == 0 { break }
                guard data.count + count <= TaskWorkspaceStore.maximumFileBytes else { throw Failure(message: "A file grew beyond the 16 MB checkpoint limit.") }
                data.append(contentsOf: buffer.prefix(count))
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0, after.st_size == info.st_size,
                  after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
                throw Failure(message: "A file changed while creating its checkpoint. Retry when file changes settle.")
            }
            return File(data: data, mode: UInt16(info.st_mode & 0o777))
        }
        private func parent<T>(_ path: String, create: Bool, missingOK: Bool,
                               body: (Int32, String) throws -> T?) throws -> T? {
            try Self.validate(path)
            let parts = path.split(separator: "/").map(String.init)
            let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw systemFailure() }
            var current = descriptor
            defer { close(current) }
            for part in parts.dropLast() {
                if create, mkdirat(current, part, 0o700) != 0 && errno != EEXIST { throw systemFailure() }
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && missingOK { return nil }
                guard next >= 0 else { throw Failure(message: "A task file parent is missing or is a symbolic link.") }
                close(current); current = next
            }
            return try body(current, parts.last!)
        }
        private func systemFailure() -> Failure { Failure(message: String(cString: strerror(errno))) }
    }
}

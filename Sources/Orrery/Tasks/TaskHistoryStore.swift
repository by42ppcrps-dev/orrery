import Foundation
import CryptoKit
import Darwin

enum TaskRecordStatus: String, Codable {
    case idle, running, interrupted
}

struct QueuedTaskPrompt: Identifiable, Codable {
    var id: UUID = UUID()
    var text: String
    var attachments: [MessageAttachment] = []
    var createdAt: Date = Date()
}

struct TaskRecord: Identifiable, Codable {
    var id: UUID = UUID()
    var provider: Provider
    var title: String
    var sessionID: String?
    var entries: [Entry] = []
    var draft: String = ""
    var attachments: [MessageAttachment] = []
    var queuedPrompts: [QueuedTaskPrompt] = []
    var status: TaskRecordStatus = .idle
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var workspaceID: UUID?
    var origin: String?
    var teamUseExistingPlan: Bool?
}

struct TeamDraft: Codable {
    var text: String
    var attachments: [MessageAttachment]
    var orchestrator: Provider
    var useExistingPlan: Bool
}

struct TaskHistorySnapshot: Codable {
    var records: [TaskRecord] = []
    var selectedByProvider: [Provider: UUID] = [:]
    var teamDraft: TeamDraft?
    // Diagnostic text belongs to this load, never to the persisted transcript.
    var notice: String?

    enum CodingKeys: CodingKey { case records, selectedByProvider, teamDraft }
}

/// Bounded local conversation storage. Scheduling a save only retains a value snapshot;
/// JSON encoding, durable writes and replacement happen on a serial utility queue.
@MainActor
final class TaskHistoryStore {
    static let recordLimit = 100
    static let byteLimit = 32 * 1024 * 1024
    private let persistence: DebouncedProjectPersistence<TaskHistorySnapshot>
    var lastError: String? { persistence.lastError }
    var fileURL: URL { persistence.file.fileURL }

    init(project: URL, directory: URL? = nil, debounceNanoseconds: UInt64 = 750_000_000) {
        persistence = DebouncedProjectPersistence(file: PrivateProjectFile(
            project: project,
            directory: directory ?? PrivateProjectFile.defaultDirectory("TaskHistory"),
            byteLimit: Self.byteLimit), debounceNanoseconds: debounceNanoseconds,
            validate: Self.validate)
    }

    func load() -> TaskHistorySnapshot {
        do {
            var snapshot = try persistence.load() ?? TaskHistorySnapshot()
            for index in snapshot.records.indices where snapshot.records[index].status == .running {
                snapshot.records[index].status = .interrupted
            }
            let ids = Set(snapshot.records.map(\.id))
            snapshot.selectedByProvider = snapshot.selectedByProvider.filter { provider, id in
                ids.contains(id) && snapshot.records.contains { $0.id == id && $0.provider == provider }
            }
            return snapshot
        } catch {
            return TaskHistorySnapshot(notice: "Task history could not be restored: \(error.localizedDescription)")
        }
    }

    func scheduleSave(_ snapshot: TaskHistorySnapshot) { persistence.schedule(snapshot) }

    @discardableResult
    func flush(_ snapshot: TaskHistorySnapshot? = nil) async -> Bool {
        await persistence.flush(snapshot)
    }

    /// Used only at orderly shutdown, where macOS requires a synchronous termination reply.
    @discardableResult
    func flushNow(_ snapshot: TaskHistorySnapshot? = nil) -> Bool {
        persistence.flushNow(snapshot)
    }

    private static func validate(_ value: TaskHistorySnapshot) throws {
        if let draft = value.teamDraft {
            try TeamContext.validate(draft.attachments)
            guard draft.text.utf8.count <= 1_000_000 else { throw PrivateProjectFile.Failure("Team draft exceeds its recovery limit.") }
        }
        guard value.records.count <= recordLimit,
              Set(value.records.map(\.id)).count == value.records.count,
              value.records.allSatisfy({ record in
                  record.entries.count <= 20_000 && record.queuedPrompts.count <= 100
                      && record.attachments.count <= 8 && record.title.utf8.count <= 4096
                      && record.queuedPrompts.allSatisfy { $0.attachments.count <= 8 }
              }) else {
            throw PrivateProjectFile.Failure("Task history exceeds its recovery limits or contains duplicate tasks.")
        }
    }
}

/// Shared by task history and editor recovery. The disk format has an independent version
/// and project identity so copying a file between projects cannot import unrelated history.
struct PrivateProjectFile {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    private struct Envelope<Value: Codable>: Codable {
        var version = 1
        var project: String
        var value: Value
    }

    let directory: URL
    let projectKey: String
    let byteLimit: Int
    var fileURL: URL { directory.appendingPathComponent(projectKey + ".json") }

    init(project: URL, directory: URL, byteLimit: Int) {
        let canonicalProject = WorkspaceFileAccess.canonicalURL(project).path
        projectKey = SHA256.hash(data: Data(canonicalProject.utf8)).map { String(format: "%02x", $0) }.joined()
        // Resolve the parent (including macOS's /private alias), but deliberately not the private
        // leaf. A malicious symlink at the storage directory must be refused, not followed.
        let parent = directory.deletingLastPathComponent()
        self.directory = WorkspaceFileAccess.canonicalURL(parent).appendingPathComponent(directory.lastPathComponent)
        self.byteLimit = byteLimit
    }

    /// Headless runs (audits, probes, selftest) must never write into the user's real data
    /// folder; they get a per-process temporary root instead.
    static let headless = CommandLine.arguments.contains(where: { ["--audit", "--probe", "--selftest", "--keychain-probe"].contains($0) })

    static func defaultDirectory(_ name: String) -> URL {
        let root = headless
            ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orrery-headless-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orrery", isDirectory: true)
        return root.appendingPathComponent(name, isDirectory: true)
    }

    func load<Value: Codable>(_ type: Value.Type) throws -> Value? {
        guard let data = try read() else { return nil }
        do {
            let envelope = try JSONDecoder().decode(Envelope<Value>.self, from: data)
            guard envelope.version == 1, envelope.project == projectKey else {
                throw Failure("The recovery file has an unsupported version or belongs to another project.")
            }
            return envelope.value
        } catch let failure as Failure { throw failure }
        catch { throw Failure("The recovery file is damaged. The original file has been left in place.") }
    }

    func save<Value: Codable>(_ value: Value) throws {
        let data = try JSONEncoder().encode(Envelope(project: projectKey, value: value))
        guard data.count <= byteLimit else {
            throw Failure("Recovery storage is full (\(byteLimit / 1024 / 1024) MB limit). The previous recovery file has been preserved.")
        }
        try withDirectory(create: true) { parent in
            let name = fileURL.lastPathComponent
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1 else {
                    throw Failure("The recovery destination is not a private regular file.")
                }
            } else if errno != ENOENT { throw systemFailure() }
            let temporary = ".recovery-" + UUID().uuidString
            let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw systemFailure() }
            defer { Darwin.close(descriptor); unlinkat(parent, temporary, 0) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw systemFailure() }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0, renameat(parent, temporary, parent, name) == 0,
                  fsync(parent) == 0 else { throw systemFailure() }
        }
    }

    private func read() throws -> Data? {
        try withDirectory(create: false) { parent in
            guard parent >= 0 else { return nil }
            let descriptor = openat(parent, fileURL.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if descriptor < 0 && errno == ENOENT { return nil }
            guard descriptor >= 0 else { throw Failure("The recovery file cannot be opened safely.") }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
                  info.st_size >= 0, info.st_size <= byteLimit else {
                throw Failure("The recovery file is oversized or is not a private regular file.")
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 32_768)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw systemFailure() }
                if count == 0 { return data }
                guard data.count + count <= byteLimit else { throw Failure("The recovery file grew beyond its size limit.") }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
    }

    private func withDirectory<T>(create: Bool, _ body: (Int32) throws -> T) throws -> T {
        // The stored spelling is already canonical. Re-standardizing here would strip
        // `/private` again and reintroduce the `/var` symlink into the O_NOFOLLOW walk.
        let parts = directory.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains("\0") }) else {
            throw Failure("Invalid recovery directory.")
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemFailure() }
        defer { Darwin.close(descriptor) }
        for (index, part) in parts.enumerated() {
            if create && mkdirat(descriptor, part, 0o700) != 0 && errno != EEXIST { throw systemFailure() }
            let next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT && !create { return try body(-1) }
            guard next >= 0 else { throw Failure("A recovery folder is inaccessible or is a symbolic link.") }
            Darwin.close(descriptor)
            descriptor = next
            if index == parts.count - 1 {
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
                      info.st_mode & 0o077 == 0 else {
                    throw Failure("Recovery requires a folder owned by you with private permissions (0700).")
                }
            }
        }
        return try body(descriptor)
    }

    private func systemFailure() -> Failure { Failure(String(cString: strerror(errno))) }
}

@MainActor
final class DebouncedProjectPersistence<Value: Codable> {
    let file: PrivateProjectFile
    private(set) var lastError: String?
    private let queue = DispatchQueue(label: "app.orrery.studio.recovery", qos: .utility)
    private let debounceNanoseconds: UInt64
    private let validate: (Value) throws -> Void
    private var pending: Value?
    private var delayed: Task<Void, Never>?
    private var loadFailure: String?
    private var revision: UInt64 = 0

    init(file: PrivateProjectFile, debounceNanoseconds: UInt64 = 750_000_000,
         validate: @escaping (Value) throws -> Void = { _ in }) {
        self.file = file
        self.debounceNanoseconds = debounceNanoseconds
        self.validate = validate
    }

    func load() throws -> Value? {
        do {
            let value: Value? = try queue.sync { try file.load(Value.self) }
            if let value { try validate(value) }
            lastError = nil
            return value
        } catch {
            lastError = error.localizedDescription
            // Do not turn a damaged, newer-format or insecure file into an empty history
            // during the first normal autosave. Keep the original recoverable by the user.
            loadFailure = error.localizedDescription
            throw error
        }
    }

    func schedule(_ value: Value) {
        pending = value
        revision &+= 1
        guard delayed == nil else { return }
        let delay = debounceNanoseconds
        delayed = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled else { return }
            _ = await self?.flush()
        }
    }

    @discardableResult
    func flush(_ value: Value? = nil) async -> Bool {
        delayed?.cancel(); delayed = nil
        if let loadFailure { lastError = loadFailure; return false }
        if let value { pending = value; revision &+= 1 }
        let snapshot = pending
        let savedRevision = revision
        pending = nil
        let file = file
        let validate = validate
        let failure: String? = await withCheckedContinuation { continuation in
            queue.async {
                do {
                    if let snapshot { try validate(snapshot); try file.save(snapshot) }
                    continuation.resume(returning: nil)
                } catch { continuation.resume(returning: error.localizedDescription) }
            }
        }
        lastError = failure
        if failure != nil && revision == savedRevision { pending = snapshot }
        return failure == nil
    }

    @discardableResult
    func flushNow(_ value: Value? = nil) -> Bool {
        delayed?.cancel(); delayed = nil
        if let loadFailure { lastError = loadFailure; return false }
        if let value { pending = value; revision &+= 1 }
        let snapshot = pending
        pending = nil
        do {
            try queue.sync {
                if let snapshot { try validate(snapshot); try file.save(snapshot) }
            }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            pending = snapshot
            return false
        }
    }
}

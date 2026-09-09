import Foundation
import Darwin

/// Host-side agent filesystem operations are confined to the selected workspace. Walk with
/// directory descriptors and O_NOFOLLOW so checking a path then swapping a symlink cannot
/// turn a permitted read/write into access to a different directory.
struct WorkspaceFileAccess {
    let root: URL
    static let limit = 4_000_000

    /// Foundation sometimes hides macOS's /private prefix even after resolving symlinks.
    /// realpath supplies the actual spelling returned by filesystem enumeration and CLIs.
    static func canonicalPath(_ url: URL) -> String? {
        guard let pointer = realpath(url.path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// realpath of the deepest existing ancestor with the remaining components appended
    /// unresolved. Foundation's `standardizedFileURL` and `resolvingSymlinksInPath` drop
    /// macOS's `/private` prefix, which turns `/var` and `/tmp` back into symbolic links; a
    /// kernel sandbox profile or an O_NOFOLLOW directory walk then rejects the spelling.
    static func canonicalURL(_ url: URL) -> URL {
        var components: [String] = []
        for part in url.path.split(separator: "/").map(String.init) {
            if part == "." || part.isEmpty { continue }
            if part == ".." { _ = components.popLast(); continue }
            components.append(part)
        }
        var pending: [String] = []
        while true {
            let candidate = "/" + components.joined(separator: "/")
            if let resolved = canonicalPath(URL(fileURLWithPath: candidate)) {
                var result = URL(fileURLWithPath: resolved, isDirectory: true)
                for part in pending.reversed() { result.appendPathComponent(part) }
                return result
            }
            guard let last = components.popLast() else { return url }
            pending.append(last)
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func components(for path: String) throws -> [String] {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw fail("Invalid file path.") }
        guard let canonicalRoot = Self.canonicalPath(root) else { throw systemFailure() }
        let candidate: String
        if path.hasPrefix("/") {
            let rawRoot = root.standardizedFileURL.path
            let rawPrefix = rawRoot == "/" ? "/" : rawRoot + "/"
            let canonicalPrefix = canonicalRoot == "/" ? "/" : canonicalRoot + "/"
            if path.hasPrefix(rawPrefix) {
                candidate = String(path.dropFirst(rawPrefix.count))
            } else if path.hasPrefix(canonicalPrefix) {
                candidate = String(path.dropFirst(canonicalPrefix.count))
            } else { throw fail("The requested file is outside this workspace.") }
        } else { candidate = path }
        let parts = candidate.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw fail("File paths cannot contain empty, dot or parent segments.") }
        return parts
    }

    func read(_ path: String) throws -> Data {
        try withParent(path, create: false) { parent, name in
            try read(parent: parent, name: name)
        }
    }

    func write(_ data: Data, to path: String, expected: Data? = nil) throws {
        guard data.count <= Self.limit else { throw fail("File exceeds the 4 MB write limit.") }
        try withParent(path, create: true) { parent, name in
            var existing = stat()
            let exists = fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0
            guard !exists || existing.st_mode & S_IFMT == S_IFREG else {
                throw fail("Only regular files can be replaced; symbolic links are refused.")
            }
            if let expected, try read(parent: parent, name: name) != expected {
                throw fail("The file changed since it was read. Refresh before replacing it.")
            }
            let temporary = ".orrery-" + UUID().uuidString
            let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw systemFailure() }
            defer { close(fd); unlinkat(parent, temporary, 0) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw systemFailure() }
                    offset += count
                }
            }
            // Preserve executable bits; new files are private by default.
            guard fchmod(fd, exists ? existing.st_mode & 0o777 : 0o600) == 0,
                  fsync(fd) == 0, renameat(parent, temporary, parent, name) == 0
            else { throw systemFailure() }
        }
    }

    private func read(parent: Int32, name: String) throws -> Data {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw systemFailure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= Self.limit else { throw fail("Only regular files up to 4 MB can be read.") }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw systemFailure() }
            if count == 0 { return result }
            guard result.count + count <= Self.limit else { throw fail("File grew past the 4 MB read limit.") }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private func withParent<T>(_ path: String, create: Bool,
                               _ body: (Int32, String) throws -> T) throws -> T {
        let parts = try components(for: path)
        guard let canonicalRoot = Self.canonicalPath(root) else { throw systemFailure() }
        var directory = open(canonicalRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw systemFailure() }
        defer { close(directory) }
        for part in parts.dropLast() {
            if create && mkdirat(directory, part, 0o700) != 0 && errno != EEXIST { throw systemFailure() }
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw fail("A parent folder is missing or is a symbolic link.") }
            close(directory)
            directory = next
        }
        return try body(directory, parts.last!)
    }

    private func fail(_ message: String) -> Failure { Failure(message: message) }
    private func systemFailure() -> Failure { fail(String(cString: strerror(errno))) }
}

/// Avoid unintentionally switching a subscription CLI to paid API billing, and keep unrelated
/// cloud credentials and dynamic-loader overrides out of agent child processes.
enum AgentEnvironment {
    static func sanitized(_ input: [String: String]) -> [String: String] {
        input.filter { key, _ in
            let key = key.uppercased()
            return !key.hasSuffix("_API_KEY") && !key.hasSuffix("_SECRET")
                && !key.hasSuffix("_TOKEN") && !key.hasSuffix("_PASSWORD")
                && !key.hasPrefix("AWS_") && !key.hasPrefix("AZURE_")
                && !key.hasPrefix("GOOGLE_APPLICATION_CREDENTIALS")
                && !key.hasPrefix("DYLD_") && !key.hasPrefix("LD_")
                && !["NODE_OPTIONS", "PYTHONPATH", "PYTHONSTARTUP", "BASH_ENV", "ENV"].contains(key)
        }
    }
}

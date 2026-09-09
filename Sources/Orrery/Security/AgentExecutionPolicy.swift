import Foundation
import Darwin

/// Host policy is independent of provider approval prompts and provider-native sandboxes.
/// Confinement covers direct local filesystem writes by the agent and inherited children.
/// Reads and networking stay available; this is not a confidential-data or network sandbox.
enum AgentExecutionPolicy: String, Codable, CaseIterable, Identifiable {
    case confinedWrites, fullAccess
    var id: String { rawValue }
    var title: String {
        self == .confinedWrites ? "Confine local writes" : "Full macOS account access"
    }
}

struct AgentExecutionRequest {
    let policy: AgentExecutionPolicy
    let workspace: URL
    let provider: Provider
    /// Plan mode: the workspace stays readable but is not writable inside the boundary.
    var readOnlyWorkspace = false
    /// The provider's "additional writable folders", writable inside the boundary as well.
    var additionalDirectories: [URL] = []
}

final class AgentExecutionLease {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

struct AgentExecutionLaunch {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let lease: AgentExecutionLease?
}

enum AgentExecutionBoundary {
    static let sandboxExecutable = "/usr/bin/sandbox-exec"
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: sandboxExecutable) }

    /// This protects common credential files, not every possible secret on a developer's
    /// computer. The current CLI's own credential store remains readable for sign-in: Claude
    /// Code keeps its login in the macOS Keychain, so the keychain database is hidden only from
    /// Grok and Codex (their sign-in is file based). Keychain items themselves stay governed by
    /// macOS's per-item access control; the database on disk is encrypted with the login password.
    static func protectedPaths(provider: Provider, home: URL) -> [URL] {
        var paths = [".ssh", ".aws", ".azure", ".config/gcloud",
                     "Library/Safari", "Library/Application Support/Google/Chrome",
                     "Library/Application Support/Chromium", "Library/Application Support/Microsoft Edge",
                     "Library/Application Support/BraveSoftware/Brave-Browser", "Library/Application Support/Firefox"]
        if provider != .claude { paths.append("Library/Keychains") }
        if provider != .grok { paths.append(".grok/auth.json") }
        if provider != .codex { paths.append(".codex/auth.json") }
        if provider != .claude { paths.append(".claude/.credentials.json") }
        return paths.flatMap { path -> [URL] in
            let direct = home.appendingPathComponent(path).standardizedFileURL
            let resolved = direct.resolvingSymlinksInPath().standardizedFileURL
            return resolved == direct ? [direct] : [direct, resolved]
        }
    }

    /// The fixed support paths below hold session state, not entire provider installations.
    /// Global hooks, executable/plugin directories and configuration are intentionally absent.
    static func supportPaths(provider: Provider, home: URL) -> (directories: [URL], files: [URL]) {
        let directories: [String]
        let files: [String]
        switch provider {
        case .grok:
            directories = [".grok/sessions", ".grok/logs", ".grok/memtrace", ".grok/memory", ".grok/upload_queue"]
            files = [".grok/active_sessions.json", ".grok/active_sessions.lock", ".grok/auth.json.lock", ".grok/sandbox-events.jsonl", ".grok/models_cache.json", ".grok/agent_id"]
        case .claude:
            directories = [".claude/projects", ".claude/debug", ".claude/tasks", ".claude/plans", ".claude/sessions", ".claude/session-env", ".claude/shell-snapshots", ".claude/telemetry"]
            files = [".claude/.last-cleanup"]
        case .codex:
            directories = [".codex/sessions", ".codex/log", ".codex/cache", ".codex/tmp", ".codex/.tmp", ".codex/shell_snapshots", ".codex/thread-writer-locks"]
            files = [".codex/session_index.jsonl", ".codex/models_cache.json", ".codex/installation_id"]
                + ["state_5", "logs_2", "thread_history_1", "goals_1", "memories_1", "queue_1"].flatMap {
                    [".codex/\($0).sqlite", ".codex/\($0).sqlite-wal", ".codex/\($0).sqlite-shm"]
                }
        }
        var directoryURLs = directories.map { home.appendingPathComponent($0) }
        // Claude Code keeps per-session shell state under /tmp/claude-<uid>/<project-slug>/ and
        // ignores TMPDIR for it; without this its Bash tool fails before any command runs.
        if provider == .claude { directoryURLs.append(claudeScratchRoot) }
        return (directoryURLs, files.map { home.appendingPathComponent($0) })
    }

    /// `/private/tmp/claude-<uid>`: the real path (the kernel matches real paths, and `/tmp`
    /// is a symlink), created by Claude Code itself on first use.
    static var claudeScratchRoot: URL { URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true) }

    /// Claude Code's shell harness also writes small tracking files straight under /tmp
    /// (`/tmp/claude-1ab8-cwd`); nothing else of that name is expected there.
    /// Seatbelt's regex dialect: no `{m,n}` quantifiers, and `-` first inside a bracket.
    static let claudeScratchFilePattern = #"^/private/tmp/claude-[0-9a-f]+-[-A-Za-z0-9_.]+$"#

    static func supportPatterns(provider: Provider) -> [String] {
        provider == .claude ? [claudeScratchFilePattern] : []
    }

    static func prepare(executable: String, arguments: [String], environment: [String: String],
                        execution: AgentExecutionRequest?, sandboxPath: String = sandboxExecutable) throws -> AgentExecutionLaunch {
        guard let execution, execution.policy == .confinedWrites else {
            return AgentExecutionLaunch(executable: executable, arguments: arguments, environment: environment, lease: nil)
        }
        guard FileManager.default.isExecutableFile(atPath: sandboxPath) else {
            throw ComputerError("Local write confinement is unavailable on this Mac. The agent was not started. Choose full access explicitly only if you want to run without this boundary.")
        }
        let workspace = try checkedDirectory(execution.workspace)
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard workspace.path != "/", workspace != home.resolvingSymlinksInPath().standardizedFileURL else {
            throw ComputerError("Choose a project folder below your home folder or filesystem root before enabling local write confinement.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orrery-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let lease = AgentExecutionLease(directory: directory)
        let temporary = try checkedDirectory(directory)
        let support = supportPaths(provider: execution.provider, home: home)
        // Refuse redirected support state rather than expanding a grant through a symlink. The
        // Claude scratch root is granted at its real path under /private/tmp; the walk would
        // otherwise see the /tmp symlink that Foundation folds it back into.
        for path in support.directories + support.files where path != claudeScratchRoot { try rejectSymlinkComponents(path) }
        // A listed folder is granted at its real path (the kernel matches real paths); one that
        // does not exist cannot be written anyway and is skipped rather than blocking the launch.
        let extra = execution.additionalDirectories.compactMap { try? checkedDirectory($0.resolvingSymlinksInPath()) }
        let profile = try profile(workspace: workspace, temporary: temporary,
                                  supportDirectories: support.directories + extra, supportFiles: support.files,
                                  protectedPaths: protectedPaths(provider: execution.provider, home: home),
                                  readOnlyWorkspace: execution.readOnlyWorkspace,
                                  supportPatterns: supportPatterns(provider: execution.provider))
        var environment = environment
        for name in ["TMPDIR", "TMP", "TEMP"] { environment[name] = temporary.path + "/" }
        for name in ["XDG_CACHE_HOME", "CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH"] {
            environment[name] = temporary.appendingPathComponent(name.lowercased()).path
        }
        // Never run an unwrapped retry. sandbox-exec itself exits without exec-ing the target
        // when the kernel rejects a profile; protocol startup then reports that failure.
        return AgentExecutionLaunch(executable: sandboxPath, arguments: ["-p", profile, executable] + arguments,
                                    environment: environment, lease: lease)
    }

    static func profile(workspace: URL, temporary: URL, supportDirectories: [URL] = [], supportFiles: [URL] = [],
                        protectedPaths: [URL] = [], readOnlyWorkspace: Bool = false, supportPatterns: [String] = []) throws -> String {
        // The kernel matches sandbox path filters against real paths (`/private/var/...`).
        // A `/var/...` or `/tmp/...` spelling would silently match nothing.
        let directories = ((readOnlyWorkspace ? [] : [workspace]) + [temporary] + supportDirectories).map(WorkspaceFileAccess.canonicalURL)
        let supportFiles = supportFiles.map(WorkspaceFileAccess.canonicalURL)
        let protectedPaths = protectedPaths.map(WorkspaceFileAccess.canonicalURL)
        var result = """
        (version 1)
        (deny default)
        (allow process-exec process-fork)
        (allow signal process-info* (target same-sandbox))
        (allow file-read* sysctl-read)
        (allow sysctl-write (sysctl-name "kern.grade_cputype"))
        (allow mach-host*)
        (allow network-outbound network-inbound network-bind)
        (allow system-socket (require-all (socket-domain AF_SYSTEM) (socket-protocol 2)))
        (allow mach-lookup
          (global-name "com.apple.system.opendirectoryd.libinfo")
          (global-name "com.apple.system.opendirectoryd.membership")
          (global-name "com.apple.bsd.dirhelper")
          (global-name "com.apple.SecurityServer")
          (global-name "com.apple.securityd")
          (global-name "com.apple.networkd")
          (global-name "com.apple.ocspd")
          (global-name "com.apple.trustd.agent")
          (global-name "com.apple.SystemConfiguration.DNSConfiguration")
          (global-name "com.apple.SystemConfiguration.configd")
          (global-name "com.apple.cfprefsd.agent")
          (global-name "com.apple.cfprefsd.daemon")
          (global-name "com.apple.logd")
          (global-name "com.apple.system.notification_center"))
        (allow ipc-posix-shm-read-data (ipc-posix-name "apple.shm.notification_center")
          (ipc-posix-name-regex #"^apple\\.cfprefs\\."))
        (allow ipc-posix-sem)
        (allow pseudo-tty)
        (allow file-write* file-ioctl (literal "/dev/null") (literal "/dev/ptmx"))
        (allow file-ioctl (regex #"^/dev/ttys[0-9]+$"))
        (allow file-write* (require-all (regex #"^/dev/ttys[0-9]+$") (extension "com.apple.sandbox.pty")))
        """
        for directory in directories {
            result += "\n(allow file-write* (subpath \(try literal(directory.path))))"
        }
        for file in supportFiles {
            result += "\n(allow file-write* (literal \(try literal(file.path))))"
        }
        for pattern in supportPatterns {
            guard !pattern.contains("\"") else { throw ComputerError("A support path pattern contains a quote.") }
            result += "\n(allow file-write* (regex #\"\(pattern)\"))"
        }
        for path in protectedPaths {
            result += "\n(deny file-read* file-write* (subpath \(try literal(path.path))))"
        }
        return result
    }

    private static func literal(_ text: String) throws -> String {
        guard !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw ComputerError("A project or runtime path contains unsupported control characters.")
        }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func checkedDirectory(_ url: URL) throws -> URL {
        let canonical = WorkspaceFileAccess.canonicalURL(url)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &directory), directory.boolValue else {
            throw ComputerError("The execution folder is missing or is not a directory.")
        }
        return canonical
    }

    private static func rejectSymlinkComponents(_ url: URL) throws {
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for part in url.standardizedFileURL.pathComponents.dropFirst() {
            cursor.appendPathComponent(part)
            var info = stat()
            if lstat(cursor.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                throw ComputerError("Local write confinement cannot grant redirected provider state at \(cursor.path). Restore the ordinary directory or choose full access explicitly.")
            }
        }
    }
}

import Foundation

/// Source control through the git command line: status, stage, unstage, discard, commit, push,
/// pull, fetch, init and clone. Nothing is polled: the status refreshes when a project opens,
/// after an agent's turn, after a save and after every action here. Commands never prompt — a
/// push that needs a password or a passphrase fails with git's own message instead of hanging.
@MainActor @Observable
final class GitRepository {
    struct Entry: Identifiable, Equatable {
        var path: String
        /// Index (staged) state: M A D R C T, or "." for none.
        var staged: Character
        /// Working tree state: M D T, "." for none, "?" for untracked.
        var unstaged: Character
        var id: String { path }
        var isUntracked: Bool { unstaged == "?" }
        var isStaged: Bool { !isUntracked && staged != "." }
        var hasUnstaged: Bool { unstaged != "." }
        /// One letter for badges: the working-tree state when there is one, else the index state.
        var label: String { isUntracked ? "?" : hasUnstaged ? String(unstaged) : String(staged) }
    }

    struct Status: Equatable {
        var isRepo = false
        var branch = ""
        var upstream = ""
        var ahead = 0
        var behind = 0
        var head = ""
        var entries: [Entry] = []
        var staged: [Entry] { entries.filter(\.isStaged) }
        var unstaged: [Entry] { entries.filter { $0.hasUnstaged } }
        var isClean: Bool { entries.isEmpty }
    }

    struct Outcome: Equatable {
        var status: Int32
        var output: String
        var error: String
        var ok: Bool { status == 0 }
        var message: String { (error.isEmpty ? output : error).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static let executable = "/usr/bin/git"
    /// git must never wait for a password, passphrase or editor: the pane has no terminal.
    static var environment: [String: String] {
        ["GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": "ssh -o BatchMode=yes", "GIT_EDITOR": "true",
         "GIT_ASKPASS": "", "SSH_ASKPASS": "", "LC_ALL": "C"]
    }

    private(set) var status = Status()
    private(set) var recentCommits: [String] = []
    private(set) var remote = ""
    private(set) var isBusy = false
    private(set) var lastMessage = ""
    private(set) var lastFailed = false
    private(set) var project: URL?
    var commitMessage = ""
    /// Replaceable for audits; the default runs the real git with a deadline.
    var runner: @MainActor ([String], URL, TimeInterval) async -> Outcome = { arguments, cwd, timeout in
        do {
            let result = try await ProcessRunner.run(GitRepository.executable, arguments, cwd: cwd, environment: GitRepository.environment, timeout: timeout)
            return Outcome(status: result.timedOut ? 124 : result.status, output: result.standardOutput,
                           error: result.timedOut ? "git did not finish within \(Int(timeout)) seconds." : result.standardError)
        } catch {
            return Outcome(status: 127, output: "", error: error.localizedDescription)
        }
    }

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: Self.executable) }

    func attach(project: URL?) {
        self.project = project
        status = Status(); recentCommits = []; remote = ""; lastMessage = ""; lastFailed = false; commitMessage = ""
        guard project != nil else { return }
        Task { await refresh() }
    }

    // MARK: Parsing (pure, audited)

    /// `git status --porcelain=v2 --branch` — header lines, changed entries (1/2), untracked (?).
    static func parseStatus(_ text: String) -> Status {
        var status = Status(isRepo: true)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard let kind = fields.first else { continue }
            switch kind {
            case "#":
                guard fields.count >= 3 else { continue }
                let value = fields[2...].joined(separator: " ")
                switch fields[1] {
                case "branch.head": status.branch = value == "(detached)" ? "detached HEAD" : value
                case "branch.upstream": status.upstream = value
                case "branch.oid": status.head = value == "(initial)" ? "" : String(value.prefix(8))
                case "branch.ab":
                    for part in fields[2...] {
                        if part.hasPrefix("+") { status.ahead = Int(part.dropFirst()) ?? 0 }
                        if part.hasPrefix("-") { status.behind = Int(part.dropFirst()) ?? 0 }
                    }
                default: break
                }
            case "1":
                guard fields.count >= 9 else { continue }
                let xy = Array(fields[1])
                status.entries.append(Entry(path: fields[8...].joined(separator: " "), staged: xy.first ?? ".", unstaged: xy.count > 1 ? xy[1] : "."))
            case "2":
                // Renames: "2 XY sub mH mI mW hH hI Xscore path<TAB>origPath"
                guard fields.count >= 10 else { continue }
                let xy = Array(fields[1])
                let rest = fields[9...].joined(separator: " ")
                let path = rest.split(separator: "\t").first.map(String.init) ?? rest
                status.entries.append(Entry(path: path, staged: xy.first ?? ".", unstaged: xy.count > 1 ? xy[1] : "."))
            case "u":
                guard fields.count >= 11 else { continue }
                status.entries.append(Entry(path: fields[10...].joined(separator: " "), staged: "U", unstaged: "U"))
            case "?":
                status.entries.append(Entry(path: fields[1...].joined(separator: " "), staged: ".", unstaged: "?"))
            default: break
            }
        }
        status.entries.sort { $0.path < $1.path }
        return status
    }

    /// Badge for a file: its one-letter state, or nil when it is unchanged.
    func badge(for url: URL, project: URL? = nil) -> String? {
        guard let root = project ?? self.project else { return nil }
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return nil }
        let relative = String(path.dropFirst(rootPath.count))
        return status.entries.first { $0.path == relative }?.label
    }

    // MARK: Commands

    private func run(_ arguments: [String], timeout: TimeInterval = 30, refresh: Bool = true, report: Bool = true) async -> Outcome {
        guard let project else { return Outcome(status: 1, output: "", error: "Open a project first.") }
        isBusy = true
        defer { isBusy = false }
        let outcome = await runner(arguments, project, timeout)
        if report {
            lastFailed = !outcome.ok
            let verb = arguments.first ?? "git"
            lastMessage = outcome.ok ? (outcome.message.isEmpty ? "git \(verb): done." : outcome.message) : "git \(verb) failed: \(outcome.message.isEmpty ? "exit \(outcome.status)" : outcome.message)"
        }
        if refresh { await self.refresh(reporting: false) }
        return outcome
    }

    func refresh(reporting: Bool = true) async {
        guard project != nil, isAvailable else { status = Status(); return }
        let probe = await runner(["rev-parse", "--is-inside-work-tree"], project!, 10)
        guard probe.ok, probe.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            status = Status(); recentCommits = []; remote = ""
            return
        }
        let porcelain = await runner(["status", "--porcelain=v2", "--branch", "--untracked-files=all"], project!, 20)
        status = porcelain.ok ? Self.parseStatus(porcelain.output) : Status(isRepo: true)
        let remotes = await runner(["remote", "get-url", "origin"], project!, 10)
        remote = remotes.ok ? remotes.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let log = await runner(["log", "--oneline", "-n", "12", "--no-decorate"], project!, 10)
        recentCommits = log.ok ? log.output.split(separator: "\n").map(String.init) : []
        if reporting, !porcelain.ok { lastFailed = true; lastMessage = "git status failed: \(porcelain.message)" }
    }

    func stage(_ paths: [String]) async { guard !paths.isEmpty else { return }; _ = await run(["add", "-A", "--"] + paths) }
    func stageAll() async { _ = await run(["add", "-A"]) }
    func unstage(_ paths: [String]) async { guard !paths.isEmpty else { return }; _ = await run(["reset", "-q", "--"] + paths) }

    /// Throws away the working-tree change of one path. Untracked files are deleted; tracked ones
    /// go back to the index version. The pane asks before calling this.
    func discard(_ path: String) async {
        guard let entry = status.entries.first(where: { $0.path == path }) else { return }
        if entry.isUntracked {
            guard let project else { return }
            let url = project.appendingPathComponent(path)
            do { try FileManager.default.removeItem(at: url); lastFailed = false; lastMessage = "Removed \(path)." }
            catch { lastFailed = true; lastMessage = "Could not remove \(path): \(error.localizedDescription)" }
            await refresh(reporting: false)
        } else {
            _ = await run(["checkout", "--", path])
        }
    }

    func commit(all: Bool) async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { lastFailed = true; lastMessage = "Write a commit message first."; return }
        if all { let staged = await run(["add", "-A"], refresh: false, report: false); guard staged.ok else { lastFailed = true; lastMessage = "git add failed: \(staged.message)"; return } }
        let outcome = await run(["commit", "-m", message])
        if outcome.ok { commitMessage = "" }
    }

    func push() async {
        if status.upstream.isEmpty, !status.branch.isEmpty, status.branch != "detached HEAD" {
            _ = await run(["push", "-u", "origin", status.branch], timeout: 120)
        } else {
            _ = await run(["push"], timeout: 120)
        }
    }
    func pull() async { _ = await run(["pull", "--ff-only"], timeout: 120) }
    func fetch() async { _ = await run(["fetch", "--prune"], timeout: 120) }
    func initialize() async { _ = await run(["init", "-b", "main"]) }

    func diff(_ path: String, staged: Bool) async -> String {
        guard let project else { return "" }
        let entry = status.entries.first { $0.path == path }
        if entry?.isUntracked == true {
            let url = project.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url), data.count <= 512 * 1024, let text = String(data: data, encoding: .utf8) else { return "(new file; not shown)" }
            return text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
        }
        let outcome = await runner(["--no-pager", "diff", "--no-ext-diff", "--no-textconv"] + (staged ? ["--cached"] : []) + ["--", path], project, 20)
        return outcome.ok ? outcome.output : outcome.message
    }

    /// Clones `url` into `parent/<name>`; returns the new folder on success.
    func clone(_ url: String, into parent: URL) async -> URL? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { lastFailed = true; lastMessage = "Enter a repository URL."; return nil }
        let name = Self.cloneFolderName(trimmed)
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { lastFailed = true; lastMessage = "\(destination.path) already exists."; return nil }
        isBusy = true
        defer { isBusy = false }
        let outcome = await runner(["clone", "--", trimmed, destination.path], parent, 300)
        lastFailed = !outcome.ok
        lastMessage = outcome.ok ? "Cloned into \(destination.path)." : "git clone failed: \(outcome.message)"
        return outcome.ok ? destination : nil
    }

    static func cloneFolderName(_ url: String) -> String {
        var last = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? "repository"
        if last.hasSuffix(".git") { last.removeLast(4) }
        let safe = last.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        return safe.isEmpty ? "repository" : safe
    }
}

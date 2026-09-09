import Foundation
import Observation

/// One shell running in one emulator — what the Terminal pane shows. Owned by `AppModel` so the
/// shell survives hiding the pane; killed only by Restart or quitting the app.
@MainActor
@Observable
final class TerminalSession {
    let emulator: TerminalEmulator
    private let pty = PTYProcess()

    private(set) var isRunning = false
    /// Exit status of the last shell, shown when it ends. nil while running or never started.
    private(set) var exitStatus: Int32?
    private(set) var startFailure: String?
    private(set) var title = ""
    /// Bumped whenever the grid changes, so SwiftUI and the render view know to repaint.
    private(set) var revision = 0

    private var workingDirectory: URL
    /// Output arrives on the PTY queue in bursts; it is buffered and drained on the main actor
    /// once per pass, so a compiler spraying output cannot schedule ten thousand hops.
    private let pending = PendingBytes()
    @ObservationIgnored private var pendingLaunch: (executable: String, arguments: [String], environment: [String: String], execution: AgentExecutionRequest?)?
    @ObservationIgnored private var executionLease: AgentExecutionLease?
    @ObservationIgnored private var launchAfterLayout: Task<Void, Never>?

    init(directory: URL, cols: Int = 80, rows: Int = 24) {
        workingDirectory = directory
        emulator = TerminalEmulator(cols: cols, rows: rows)
        emulator.onOutput = { [weak self] data in self?.pty.write(data) }
        emulator.onTitleChange = { [weak self] title in self?.title = title }
    }

    /// The user's own shell, as a login shell, exactly as Terminal.app starts one.
    func start() {
        guard !isRunning else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment.removeValue(forKey: "NO_COLOR")
        start(executable: shell, arguments: ["-l"], environment: environment)
    }

    func start(executable: String, arguments: [String], environment: [String: String], whenVisible: Bool = false,
               execution: AgentExecutionRequest? = nil) {
        guard !isRunning else { return }
        exitStatus = nil
        startFailure = nil
        if whenVisible {
            pendingLaunch = (executable, arguments, environment, execution)
            isRunning = true
            return
        }
        pty.onData = { [weak self] data in
            guard let self else { return }
            if self.pending.append(data) {
                Task { @MainActor [weak self] in self?.drain() }
            }
        }
        pty.onExit = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.drain()
                self.isRunning = false
                self.executionLease = nil
                self.exitStatus = status
                self.revision += 1
            }
        }
        do {
            let launch = try AgentExecutionBoundary.prepare(executable: executable, arguments: arguments,
                                                            environment: environment, execution: execution)
            try pty.spawn(executable: launch.executable, arguments: launch.arguments,
                          environment: launch.environment, currentDirectory: workingDirectory,
                          cols: emulator.cols, rows: emulator.rows)
            executionLease = launch.lease
            isRunning = true
        } catch {
            startFailure = error.localizedDescription
        }
        revision += 1
    }

    private func drain() {
        let data = pending.take()
        guard !data.isEmpty else { return }
        emulator.feed(data)
        revision += 1
    }

    func send(_ data: Data) {
        pty.write(data)
    }

    func send(text: String) { send(Data(text.utf8)) }

    /// Paste honours bracketed-paste mode so shells and editors treat it as one block.
    func paste(_ text: String) {
        if emulator.bracketedPaste {
            send(text: "\u{1B}[200~" + text + "\u{1B}[201~")
        } else {
            send(text: text)
        }
    }

    func resize(cols: Int, rows: Int) {
        if pendingLaunch != nil {
            // Start with the settled viewport so fast commands also see the correct PTY size.
            // Resizing again cancels this debounce; termination cancels the launch entirely.
            launchAfterLayout?.cancel()
            launchAfterLayout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                guard let self, let launch = self.pendingLaunch else { return }
                self.pendingLaunch = nil
                self.isRunning = false
                self.start(executable: launch.executable, arguments: launch.arguments, environment: launch.environment,
                           execution: launch.execution)
            }
        }
        guard cols != emulator.cols || rows != emulator.rows else { return }
        emulator.resize(cols: cols, rows: rows)
        pty.resize(cols: cols, rows: rows)
        revision += 1
    }

    func terminate() {
        launchAfterLayout?.cancel(); launchAfterLayout = nil
        if pendingLaunch != nil {
            pendingLaunch = nil
            isRunning = false
        }
        pty.terminate()
    }

    /// Kill the shell and start a fresh one in the same directory.
    func restart(in directory: URL? = nil) {
        if let directory { workingDirectory = directory }
        pty.terminate()
        // The new shell starts when the old one reports exit; poll briefly instead of racing it.
        Task { @MainActor [weak self] in
            for _ in 0..<50 {
                guard let self else { return }
                if !self.isRunning {
                    self.start()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}

/// The cross-queue handoff buffer. `append` returns true when a drain needs scheduling —
/// exactly one drain is in flight at a time.
private final class PendingBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var drainScheduled = false

    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        if drainScheduled { return false }
        drainScheduled = true
        return true
    }

    func take() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let data = buffer
        buffer = Data()
        drainScheduled = false
        return data
    }
}

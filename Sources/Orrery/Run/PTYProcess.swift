import Foundation
import Darwin

/// A child process on a real pseudo-terminal — what makes the shell interactive, `isatty()`
/// true, colours on, and job control work.
///
/// No `fork()`: the master comes from `posix_openpt`, and the child is `posix_spawn`ed with
/// `POSIX_SPAWN_SETSID` plus a file action that *opens the slave path as fd 0*. A session
/// leader's first `open` of a terminal makes it the controlling terminal, so the child gets a
/// proper ctty without any code running between fork and exec — which matters in a process
/// this threaded.
final class PTYProcess {

    private(set) var masterFD: Int32 = -1
    private(set) var pid: pid_t = -1
    var isRunning: Bool { pid > 0 }

    /// Called on `queue` with whatever the child wrote. The owner hops to the main actor.
    var onData: ((Data) -> Void)?
    /// Called on `queue` exactly once, with the exit status (or 128+signal).
    var onExit: ((Int32) -> Void)?

    private let queue = DispatchQueue(label: "orrery.pty")
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var pendingWrites = Data()
    private var exited = false

    enum Failure: LocalizedError {
        case openFailed(String)
        case spawnFailed(String, Int32)
        var errorDescription: String? {
            switch self {
            case let .openFailed(step): return "Could not open a pseudo-terminal (\(step))."
            case let .spawnFailed(exe, code):
                return "Could not start \(exe): \(String(cString: strerror(code)))"
            }
        }
    }

    /// `_IOW('t', 103, struct winsize)` — the macro does not import into Swift.
    private static let TIOCSWINSZ: UInt = 0x8008_7467

    func spawn(executable: String, arguments: [String], environment: [String: String],
               currentDirectory: URL, cols: Int, rows: Int) throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw Failure.openFailed("posix_openpt") }
        guard grantpt(master) == 0, unlockpt(master) == 0,
              let slaveName = ptsname(master) else {
            close(master)
            throw Failure.openFailed("grantpt/unlockpt")
        }
        let slavePath = String(cString: slaveName)

        // The tty initializes itself on the first open of the slave — wiping any window size
        // set before that. Found by the audit: `stty size` reported 0 0. So the parent opens
        // the slave first (O_NOCTTY: no terminal is being adopted here), sets the size, and
        // closes its copy right after the spawn so EOF detection still works.
        let earlySlave = open(slavePath, O_RDWR | O_NOCTTY)
        var size = winsize(ws_row: UInt16(max(2, rows)), ws_col: UInt16(max(2, cols)),
                           ws_xpixel: 0, ws_ypixel: 0)
        _ = withUnsafeMutablePointer(to: &size) { ioctl(master, Self.TIOCSWINSZ, $0) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // The child opens the slave itself — as a fresh session leader, that open acquires the
        // terminal as its ctty. Then stdout/stderr are the same fd.
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, currentDirectory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var signals = sigset_t()
        sigfillset(&signals)
        posix_spawnattr_setsigdefault(&attributes, &signals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID
                                                    | POSIX_SPAWN_SETSIGDEF
                                                    | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var child: pid_t = 0
        let result = withCStrings(argv) { argvPointers in
            withCStrings(envp) { envpPointers in
                posix_spawn(&child, executable, &actions, &attributes,
                            argvPointers, envpPointers)
            }
        }
        if earlySlave >= 0 { close(earlySlave) }
        guard result == 0 else {
            close(master)
            throw Failure.spawnFailed(executable, result)
        }

        masterFD = master
        pid = child
        exited = false

        // Non-blocking, so a stalled child can never wedge the app on a read or a write.
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in self?.drainMaster() }
        source.setCancelHandler { [weak self] in self?.finish() }
        source.resume()
        readSource = source
    }

    private func drainMaster() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(masterFD, &buffer, buffer.count)
            if count > 0 {
                onData?(Data(buffer[0..<count]))
                continue
            }
            if count < 0 && errno == EAGAIN { return }
            if count < 0 && errno == EINTR { continue }
            // 0 or EIO: every slave fd is closed — the child (and its children) are gone.
            readSource?.cancel()
            readSource = nil
            return
        }
    }

    /// Runs on `queue` when the read side is done: reap the child and report its status.
    private func finish() {
        guard !exited else { return }
        exited = true
        writeSource?.cancel()
        writeSource = nil
        pendingWrites.removeAll()
        var status: Int32 = 0
        var reported: Int32 = -1
        if pid > 0 && waitpid(pid, &status, 0) == pid {
            if (status & 0x7F) == 0 {                 // WIFEXITED
                reported = (status >> 8) & 0xFF       // WEXITSTATUS
            } else {
                reported = 128 + (status & 0x7F)      // died on a signal
            }
        }
        if masterFD >= 0 { close(masterFD) }
        masterFD = -1
        pid = -1
        onExit?(reported)
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            self.pendingWrites.append(data)
            self.flushWrites()
        }
    }

    /// On `queue`. Writes what the kernel will take now; a full buffer arms a write source
    /// instead of blocking, so pasting into a stopped program cannot hang the app.
    private func flushWrites() {
        while !pendingWrites.isEmpty {
            let written = pendingWrites.withUnsafeBytes { raw -> Int in
                Darwin.write(masterFD, raw.baseAddress, raw.count)
            }
            if written > 0 {
                pendingWrites.removeFirst(written)
            } else if errno == EAGAIN {
                armWriteSource()
                return
            } else if errno == EINTR {
                continue
            } else {
                pendingWrites.removeAll()
                return
            }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func armWriteSource() {
        guard writeSource == nil, masterFD >= 0 else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in self?.flushWrites() }
        source.resume()
        writeSource = source
    }

    func resize(cols: Int, rows: Int) {
        queue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            var size = winsize(ws_row: UInt16(max(2, rows)), ws_col: UInt16(max(2, cols)),
                               ws_xpixel: 0, ws_ypixel: 0)
            // The tty driver delivers SIGWINCH to the foreground process group itself.
            _ = withUnsafeMutablePointer(to: &size) { ioctl(self.masterFD, Self.TIOCSWINSZ, $0) }
        }
    }

    /// Hang up on the whole job: SIGHUP to the child's process group (it is the session leader,
    /// so pgid == pid), then close the master, which is a hangup for anything that ignored it.
    func terminate() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.pid > 0 { killpg(self.pid, SIGHUP) }
            self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.pid > 0 else { return }
                killpg(self.pid, SIGKILL)
            }
        }
    }

    deinit {
        if pid > 0 { killpg(pid, SIGKILL) }
        if masterFD >= 0 { close(masterFD) }
    }
}

/// Calls `body` with a NULL-terminated array of C strings that lives for the duration of the
/// call — what `posix_spawn` wants for argv and envp.
private func withCStrings<T>(_ strings: [String],
                             _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T)
    -> T {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}

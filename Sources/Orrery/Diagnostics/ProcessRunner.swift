import Foundation

/// Runs a command off the main thread and returns what it printed. Used by the diagnostics
/// engine and the task runner, both of which must never block the window.
enum ProcessRunner {
    struct Result: Sendable {
        var status: Int32
        var standardOutput: String
        var standardError: String
        var timedOut: Bool
        var cancelled: Bool = false
        var combined: String { standardOutput + (standardOutput.isEmpty ? "" : "\n") + standardError }
    }

    /// Same extras the Run pane appends, so a Finder-launched app finds Homebrew tools.
    static func extendedPATH(_ existing: String?) -> String {
        let extras = "/opt/homebrew/bin:/usr/local/bin"
        let base = (existing?.isEmpty == false) ? existing! : "/usr/bin:/bin"
        return base + ":" + extras
    }

    enum Failure: LocalizedError {
        case notExecutable(String)
        var errorDescription: String? {
            switch self {
            case let .notExecutable(path): return "\(path) is not an executable file."
            }
        }
    }

    /// A checker that hangs must not wedge the editor, so every run has a deadline.
    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil,
                    environment extra: [String: String] = [:],
                    timeout: TimeInterval = 20, stdin: String? = nil) async throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw Failure.notExecutable(executable)
        }
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if handle.isCancelled {
                    continuation.resume(returning: Result(
                        status: -1, standardOutput: "", standardError: "",
                        timedOut: false, cancelled: true))
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let cwd { process.currentDirectoryURL = cwd }
                var environment = ProcessInfo.processInfo.environment
                environment["NO_COLOR"] = "1"
                environment["TERM"] = "dumb"
                environment["CLICOLOR"] = "0"
                for (key, value) in extra { environment[key] = value }
                // After extras, so a stripped PATH still receives Homebrew. Finder-launched
                // apps otherwise fail `npm`/`cargo` with exit 127.
                environment["PATH"] = extendedPATH(environment["PATH"])
                process.environment = environment

                let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = inPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                handle.attach(process)

                if let stdin {
                    try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                }
                try? inPipe.fileHandleForWriting.close()

                // Read both pipes concurrently: a child that fills one of them while we wait
                // on the other deadlocks, and compilers are chatty on stderr.
                let readers = DispatchGroup()
                let outLock = NSLock()
                var outData = Data(), errData = Data()
                readers.enter()
                DispatchQueue.global().async {
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    outLock.lock(); outData = data; outLock.unlock()
                    readers.leave()
                }
                readers.enter()
                DispatchQueue.global().async {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    outLock.lock(); errData = data; outLock.unlock()
                    readers.leave()
                }

                // Exit is observed through `terminationHandler`, not `waitUntilExit()`.
                // Calling `waitUntilExit()` from two threads — the timeout watchdog and the
                // main path — hangs Foundation's Process, which showed up as the audit losing
                // a checker's output on roughly one run in three, then wedging entirely.
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }

                var timedOut = false
                if finished.wait(timeout: .now() + timeout) == .timedOut {
                    timedOut = true
                    process.terminate()
                    if finished.wait(timeout: .now() + 2) == .timedOut {
                        // Ignoring SIGTERM. SIGKILL cannot be ignored.
                        kill(process.processIdentifier, SIGKILL)
                        _ = finished.wait(timeout: .now() + 2)
                    }
                }
                // The child is gone, so both pipes are at EOF — but a grandchild can inherit
                // the write end and hold them open, so this wait is bounded too.
                if readers.wait(timeout: .now() + 5) == .timedOut {
                    try? outPipe.fileHandleForReading.close()
                    try? errPipe.fileHandleForReading.close()
                }
                outLock.lock()
                let capturedOut = outData, capturedErr = errData
                outLock.unlock()

                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    standardOutput: String(data: capturedOut, encoding: .utf8) ?? "",
                    standardError: String(data: capturedErr, encoding: .utf8) ?? "",
                    timedOut: timedOut,
                    cancelled: handle.isCancelled))
            }
        }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Shared by the timeout path and Task cancellation so Stop can kill a gate process
    /// without waiting out the full deadline.
    private final class ProcessHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func attach(_ process: Process) {
            lock.lock()
            self.process = process
            let cancelled = self.cancelled
            lock.unlock()
            if cancelled { Self.kill(process) }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = self.process
            lock.unlock()
            if let process { Self.kill(process) }
        }

        private static func kill(_ process: Process) {
            process.terminate()
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: 2)
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }
}

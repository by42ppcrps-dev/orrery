import Foundation
import AppKit

/// The small state machine behind the watchdog: one outstanding ping at a time, one sample per
/// hang, and the hang's length when the main thread finally answers.
struct HangDetector {
    let threshold: TimeInterval
    private(set) var outstandingSince: Date?
    private(set) var sampledThisHang = false

    init(threshold: TimeInterval) { self.threshold = threshold }

    /// A ping was handed to the main thread. Ignored while one is still unanswered.
    mutating func pingSent(at now: Date) {
        if outstandingSince == nil { outstandingSince = now }
    }

    /// The main thread answered. Returns how long it had been stuck when a sample was taken for
    /// this hang, nil for an ordinary prompt answer.
    mutating func pongReceived(at now: Date) -> TimeInterval? {
        defer { outstandingSince = nil; sampledThisHang = false }
        guard sampledThisHang, let since = outstandingSince else { return nil }
        return now.timeIntervalSince(since)
    }

    /// True exactly once per hang, the first time the outstanding ping is older than the threshold.
    mutating func shouldSample(at now: Date) -> Bool {
        guard let since = outstandingSince, !sampledThisHang, now.timeIntervalSince(since) >= threshold else { return false }
        sampledThisHang = true
        return true
    }
}

/// Watches the main thread from a background thread. When it has not answered for
/// `threshold` seconds, a symbolicated sample of this process is written to
/// ~/Library/Logs/Orrery/ together with a note of what the app was doing, once per hang, and a
/// line is added when the main thread comes back. A freeze then arrives with evidence instead
/// of a guess.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    struct Report: Equatable {
        let file: URL
        let stuckFor: TimeInterval
    }

    let threshold: TimeInterval
    let interval: TimeInterval
    let logDirectory: URL
    /// How a sample is taken (`/usr/bin/sample` by default); audits inject a fake.
    var sampler: @Sendable (pid_t, TimeInterval) -> String
    /// How the main thread is asked to answer (`DispatchQueue.main.async` by default).
    var ping: @Sendable (@escaping @Sendable () -> Void) -> Void
    /// The clock; audits step it by hand.
    var clock: @Sendable () -> Date = { Date() }
    /// What the app was doing, as the model last reported it (`note(_:)`), read on the watchdog thread.
    private var lastNote = ""
    /// Called on the watchdog thread when a hang has been sampled and, again, when it ends.
    var onReport: (@Sendable (Report) -> Void)?

    private let lock = NSLock()
    private var detector: HangDetector
    private var running = false
    private var currentFile: URL?
    private(set) var reports: [Report] = []

    init(threshold: TimeInterval = 8, interval: TimeInterval = 1,
         logDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orrery", isDirectory: true),
         sampler: (@Sendable (pid_t, TimeInterval) -> String)? = nil,
         ping: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil) {
        self.threshold = threshold
        self.interval = interval
        self.logDirectory = logDirectory
        self.detector = HangDetector(threshold: threshold)
        self.sampler = sampler ?? Self.systemSampler
        self.ping = ping ?? { work in DispatchQueue.main.async(execute: work) }
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        let thread = Thread { [weak self] in
            while let self, self.isRunning {
                self.tick(now: self.clock())
                Thread.sleep(forTimeInterval: self.interval)
            }
        }
        thread.name = "app.orrery.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() { lock.lock(); running = false; lock.unlock() }

    /// The model calls this whenever its state changes, so a hang file can say what was going on.
    func note(_ text: String) { lock.lock(); lastNote = text; lock.unlock() }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// One step of the loop, callable directly by audits with a chosen clock.
    func tick(now: Date) {
        lock.lock()
        let needsPing = detector.outstandingSince == nil
        if needsPing { detector.pingSent(at: now) }
        let sample = detector.shouldSample(at: now)
        lock.unlock()
        if needsPing {
            ping { [weak self] in guard let self else { return }; self.pong(at: self.clock()) }
        }
        if sample { capture(now: now) }
    }

    private func pong(at now: Date) {
        lock.lock()
        let stuck = detector.pongReceived(at: now)
        let file = currentFile
        currentFile = nil
        lock.unlock()
        guard let stuck, let file else { return }
        Self.append("\nMain thread answered again after \(String(format: "%.1f", stuck)) s (\(Self.stamp(now))).\n", to: file)
        let report = Report(file: file, stuckFor: stuck)
        lock.lock(); reports.append(report); lock.unlock()
        onReport?(report)
    }

    private func capture(now: Date) {
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = logDirectory.appendingPathComponent("hang-\(Self.stamp(now, forFile: true)).txt")
        let version = Bundle.main.infoDictionary.map { "\($0["CFBundleShortVersionString"] ?? "?") (\($0["CFBundleVersion"] ?? "?"))" } ?? "?"
        lock.lock(); let note = lastNote; lock.unlock()
        let header = "Orrery \(version) — the main thread has not answered for \(Int(threshold)) s (\(Self.stamp(now))).\n"
            + "What the app was doing: \(note)\n\n"
        try? header.write(to: file, atomically: true, encoding: .utf8)
        // The file is on record before the sample runs: sampling takes seconds, and a main
        // thread that wakes meanwhile must still get its "answered again" line.
        lock.lock(); currentFile = file; lock.unlock()
        onReport?(Report(file: file, stuckFor: threshold))
        Self.append(sampler(ProcessInfo.processInfo.processIdentifier, 3), to: file)
    }

    private static func append(_ text: String, to file: URL) {
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    }

    private static func stamp(_ date: Date, forFile: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = forFile ? "yyyyMMdd-HHmmss" : "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// `/usr/bin/sample <pid> <seconds>`: Apple's sampler, symbolicated, from a separate process
    /// so a stuck main thread cannot stop it. Empty output when the tool is missing or refuses.
    static let systemSampler: @Sendable (pid_t, TimeInterval) -> String = { pid, seconds in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = ["\(pid)", "\(Int(seconds))", "-mayDie"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "sample could not run: \(error.localizedDescription)\n" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

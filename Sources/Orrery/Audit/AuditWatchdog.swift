import Foundation

/// The main-thread watchdog: the detector's arithmetic, then the whole thing against a main
/// thread that stops answering, then Apple's sampler for real on this very process.
@MainActor
enum AuditWatchdog {
    static func run(_ audit: Auditor) async {
        audit.section("Watchdog — one sample per hang, and the hang's length when it ends")
        var detector = HangDetector(threshold: 8)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        detector.pingSent(at: t0)
        audit.check("nothing is sampled before the threshold", !detector.shouldSample(at: t0.addingTimeInterval(7.9)))
        audit.check("the first tick past the threshold samples", detector.shouldSample(at: t0.addingTimeInterval(8)))
        audit.check("…and only once for that hang", !detector.shouldSample(at: t0.addingTimeInterval(9)) && !detector.shouldSample(at: t0.addingTimeInterval(60)))
        detector.pingSent(at: t0.addingTimeInterval(10))
        audit.check("a second ping while one is unanswered does not restart the clock", detector.outstandingSince == t0)
        audit.equal("the answer reports how long the main thread was stuck", detector.pongReceived(at: t0.addingTimeInterval(20)), 20)
        detector.pingSent(at: t0.addingTimeInterval(30))
        audit.check("an ordinary answer is not a hang", detector.pongReceived(at: t0.addingTimeInterval(30.01)) == nil)
        detector.pingSent(at: t0.addingTimeInterval(40))
        audit.check("a later hang is sampled again", detector.shouldSample(at: t0.addingTimeInterval(48)))

        audit.section("Watchdog — a stuck main thread is sampled and the note says what the app was doing")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orrery-watchdog-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        final class Main: @unchecked Sendable {
            let lock = NSLock()
            var pending: [@Sendable () -> Void] = []
            var responsive = true
            func ping(_ work: @escaping @Sendable () -> Void) { lock.lock(); if responsive { lock.unlock(); work() } else { pending.append(work); lock.unlock() } }
            func release() { lock.lock(); let work = pending; pending = []; responsive = true; lock.unlock(); work.forEach { $0() } }
        }
        let main = Main()
        final class Count: @unchecked Sendable { let lock = NSLock(); var samples = 0 }
        let count = Count()
        let watchdog = MainThreadWatchdog(threshold: 8, interval: 1, logDirectory: root,
                                          sampler: { pid, _ in count.lock.lock(); count.samples += 1; count.lock.unlock(); return "Sampling process \(pid)\nCall graph:\n    fake frames\n" },
                                          ping: { work in main.ping(work) })
        watchdog.note("mode Roundtable, running, 42 entries")
        final class Clock: @unchecked Sendable { let lock = NSLock(); var now = Date(timeIntervalSince1970: 2_000_000); func read() -> Date { lock.lock(); defer { lock.unlock() }; return now } }
        let clock = Clock()
        watchdog.clock = { clock.read() }
        let base = clock.read()
        /// Steps the clock to `seconds` after base and runs one tick.
        func tick(_ seconds: TimeInterval) { clock.lock.lock(); clock.now = base.addingTimeInterval(seconds); clock.lock.unlock(); watchdog.tick(now: clock.read()) }
        tick(0)
        tick(3)
        audit.check("a main thread that answers is never sampled", count.samples == 0 && watchdog.reports.isEmpty)
        main.lock.lock(); main.responsive = false; main.lock.unlock()
        tick(4)   // this ping goes unanswered
        for second in 5...11 { tick(TimeInterval(second)) }
        audit.equal("nothing is sampled in the first 7 s of the hang", count.samples, 0)
        tick(12)
        audit.equal("the hang is sampled exactly once when it reaches 8 s", count.samples, 1)
        for second in 13...30 { tick(TimeInterval(second)) }
        audit.equal("…and not again while it goes on", count.samples, 1)
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let text = files.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        audit.check("one hang file is written under the log folder", files.count == 1 && files[0].lastPathComponent.hasPrefix("hang-"), files.map(\.lastPathComponent).description)
        audit.check("it says what the app was doing and carries the sample", text.contains("mode Roundtable, running, 42 entries") && text.contains("Call graph") && text.contains("has not answered for 8 s"))
        audit.check("nothing says it recovered yet", !text.contains("answered again"))
        clock.lock.lock(); clock.now = base.addingTimeInterval(31); clock.lock.unlock()
        main.release()
        let after = files.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        audit.check("when the main thread answers, the file gets the hang's length", after.contains("answered again after 27.0 s"), after.suffix(120).description)
        audit.check("the report is kept with that length", watchdog.reports.count == 1 && watchdog.reports.first?.stuckFor == 27)
        tick(40)
        tick(41)
        audit.equal("a responsive main thread afterwards is left alone", count.samples, 1)
        main.lock.lock(); main.responsive = false; main.lock.unlock()
        for second in 42...52 { tick(TimeInterval(second)) }
        audit.equal("a second hang gets its own sample", count.samples, 2)
        clock.lock.lock(); clock.now = base.addingTimeInterval(53); clock.lock.unlock()
        main.release()
        let mode = (try? FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int) ?? 0
        audit.check("the log folder is owner-only", mode & 0o777 == 0o700, String(mode, radix: 8))

        audit.section("Watchdog — a main thread that wakes while the sample is still running is not missed")
        let slowRoot = root.appendingPathComponent("slow", isDirectory: true)
        let gate = DispatchSemaphore(value: 0)
        let slowMain = Main()
        let slow = MainThreadWatchdog(threshold: 8, interval: 1, logDirectory: slowRoot,
                                      sampler: { _, _ in gate.wait(); return "Call graph:\n    slow frames\n" },
                                      ping: { work in slowMain.ping(work) })
        let slowClock = Clock()
        slow.clock = { slowClock.read() }
        let slowBase = slowClock.read()
        slow.tick(now: slowBase)
        slowMain.lock.lock(); slowMain.responsive = false; slowMain.lock.unlock()
        slowClock.lock.lock(); slowClock.now = slowBase.addingTimeInterval(2); slowClock.lock.unlock()
        slow.tick(now: slowClock.read())     // the unanswered ping
        slowClock.lock.lock(); slowClock.now = slowBase.addingTimeInterval(11); slowClock.lock.unlock()
        let sampling = Task.detached { slow.tick(now: slowClock.read()) }   // blocks in the sampler until the gate opens
        try? await Task.sleep(nanoseconds: 300_000_000)
        slowClock.lock.lock(); slowClock.now = slowBase.addingTimeInterval(12); slowClock.lock.unlock()
        slowMain.release()                   // the main thread wakes while the sample is still running
        gate.signal()
        await sampling.value
        let slowFiles = (try? FileManager.default.contentsOfDirectory(at: slowRoot, includingPropertiesForKeys: nil)) ?? []
        let slowText = slowFiles.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        audit.check("the hang file still gets both the sample and the recovery line",
                    slowText.contains("slow frames") && slowText.contains("answered again after 10.0 s"), slowText.suffix(160).description)

        audit.section("Watchdog — Apple's sampler works on this process")
        let output = MainThreadWatchdog.systemSampler(ProcessInfo.processInfo.processIdentifier, 1)
        audit.check("/usr/bin/sample returns a symbolicated call graph for this process",
                    output.contains("Call graph") && output.contains("Orrery"), output.prefix(200).description)
    }
}

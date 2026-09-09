import Foundation

/// Shared bookkeeping for `Orrery --audit`. Every section reports through this, so the exit
/// code and the summary stay honest no matter how many sections there are.
@MainActor
final class Auditor {
    private(set) var failures = 0
    private(set) var total = 0
    /// Checks that could not run on this machine (no CLI, no real store). Printed, counted
    /// apart from passes, never a pass: a skip is information, not proof.
    private(set) var skipped: [String] = []
    private var currentSection = ""
    /// Only print failures. Useful when the suite gets long.
    var quiet = false

    func section(_ name: String) {
        currentSection = name
        if !quiet { print("\n── \(name)") }
    }

    func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if !passed { failures += 1 }
        guard !passed || !quiet else { return }
        // The detail explains a failure. Printing it on a pass makes the log read as though
        // something went wrong ("PASS  found nothing — nothing found").
        let text = passed ? "" : detail()
        print("\(passed ? "PASS" : "FAIL")  \(name)\(text.isEmpty ? "" : " — \(text)")")
    }

    func skip(_ name: String, _ reason: String) {
        skipped.append(name)
        print("SKIP  \(name) — \(reason)")
    }

    func equal<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        // `reflecting` so a multi-line string failure prints as one escaped line.
        check(name, actual == expected,
              "got \(String(reflecting: actual)), expected \(String(reflecting: expected))")
    }

    func summary() -> Int32 {
        print("")
        let note = skipped.isEmpty ? "" : " (\(skipped.count) skipped on this machine)"
        if failures == 0 {
            print("all \(total) checks passed\(note)")
        } else {
            print("\(failures) of \(total) checks FAILED\(note)")
        }
        return failures == 0 ? 0 : 1
    }

    /// A scratch directory that is removed when the closure returns.
    static func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-audit-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }
}

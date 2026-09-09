import Foundation
import XCTest

/// The project's real suite is `Orrery --audit`. `swift test` must run it so the
/// orchestrator acceptance gate is not an empty-package failure.
final class AuditGateTests: XCTestCase {
    func testHeadlessAudit() throws {
        let root = Self.packageRoot
        guard let exe = Self.executable(in: root) else {
            XCTFail("Orrery executable not found under \(root.path)/.build; swift build first")
            return
        }
        let process = Process()
        process.executableURL = exe
        process.arguments = ["--audit"]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain before waiting: --audit prints a line per check and Darwin's
        // pipe is 64 KiB. Waiting first lets the child fill the pipe and stall.
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        process.waitUntilExit()
        let failures = text.split(separator: "\n").filter { $0.hasPrefix("FAIL  ") }
            .joined(separator: "\n")
        XCTAssertEqual(process.terminationStatus, 0,
                       "Orrery --audit failed:\n\(failures)\n\(text.suffix(4000))")
    }

    private static var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func executable(in root: URL) -> URL? {
        let fm = FileManager.default
        let direct = root.appendingPathComponent(".build/debug/Orrery")
        if fm.isExecutableFile(atPath: direct.path) { return direct }
        let build = root.appendingPathComponent(".build")
        guard let triples = try? fm.contentsOfDirectory(atPath: build.path) else { return nil }
        for triple in triples {
            let candidate = build
                .appendingPathComponent(triple)
                .appendingPathComponent("debug/Orrery")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

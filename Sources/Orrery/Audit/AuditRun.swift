import Foundation

/// The task runner: tasks come from the project's own files, real commands run and stream, and
/// an error in the output is a clickable location that opens the right file at the right line.
@MainActor
enum AuditRun {

    static func run(_ audit: Auditor) async {
        await Auditor.withTemporaryDirectory { dir in
            detection(audit, dir)
            await execution(audit, dir)
            await clickable(audit, dir)
            await streamingAndStop(audit, dir)
            honesty(audit, dir)
        }
        thisPackageHasTests(audit)
    }

    @discardableResult
    private static func waitUntil(_ timeout: Double,
                                  _ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    // MARK: Detection

    private static func detection(_ audit: Auditor, _ dir: URL) {
        audit.section("Run — tasks come from the project, not a hardcoded list")

        let empty = TaskCatalog.tasks(project: dir, activeFile: nil, language: nil)
        audit.check("an empty project offers no tasks", empty.isEmpty,
                    empty.map(\.id).joined(separator: ","))

        try? "// swift-tools-version: 6.0\nimport PackageDescription\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true,
                   encoding: .utf8)
        try? #"{"name":"x","scripts":{"lint":"echo lint","test":"echo t"}}"#
            .write(to: dir.appendingPathComponent("package.json"), atomically: true,
                   encoding: .utf8)
        try? """
            build:
            \techo built
            all:
            \techo all
            clean:
            \techo cleaned
            install:
            \techo installed
            test:
            \techo tested
            deploy:
            \techo deployed
            %.o: %.c
            \techo pattern
            VAR = 3
            """.write(to: dir.appendingPathComponent("Makefile"), atomically: true,
                      encoding: .utf8)
        try? "[package]\nname = \"x\"\n"
            .write(to: dir.appendingPathComponent("Cargo.toml"), atomically: true,
                   encoding: .utf8)

        let tasks = TaskCatalog.tasks(project: dir, activeFile: nil, language: nil)
        func has(_ id: String) -> Bool { tasks.contains { $0.id == id } }
        audit.check("Package.swift yields swift build/test/run",
                    has("swift-build") && has("swift-test") && has("swift-run"))
        audit.check("package.json scripts become npm tasks",
                    has("npm-lint") && has("npm-test"))
        audit.check("Makefile targets become make tasks", has("make-build"))
        audit.check("make build and make all are build tasks",
                    tasks.first { $0.id == "make-build" }?.kind == .build
                    && tasks.first { $0.id == "make-all" }?.kind == .build)
        audit.check("make test is a test task",
                    tasks.first { $0.id == "make-test" }?.kind == .test)
        audit.check("make clean/install/deploy are scripts, not build",
                    tasks.first { $0.id == "make-clean" }?.kind == .script
                    && tasks.first { $0.id == "make-install" }?.kind == .script
                    && tasks.first { $0.id == "make-deploy" }?.kind == .script,
                    tasks.filter { $0.source == "Makefile" }
                        .map { "\($0.id):\($0.kind.rawValue)" }.joined(separator: ","))
        audit.check("pattern rules and variables are not targets",
                    !tasks.contains { $0.id.contains("%") || $0.id.contains("VAR") },
                    tasks.map(\.id).joined(separator: ","))
        audit.check("cargo tasks exist for Cargo.toml", has("cargo-build"))
        if Executables.find([], orNamed: "cargo") == nil {
            audit.check("…and name the missing tool instead of pretending",
                        tasks.first { $0.id == "cargo-build" }?.missingTool == "cargo")
        }

        let pyFile = dir.appendingPathComponent("tool.py")
        try? "print(1)\n".write(to: pyFile, atomically: true, encoding: .utf8)
        let withFile = TaskCatalog.tasks(project: dir, activeFile: pyFile,
                                         language: Languages.byID("python"))
        audit.check("the open Python file is runnable",
                    withFile.contains { $0.id == "file-python" && $0.kind == .run })
    }

    // MARK: Execution

    private static func execution(_ audit: Auditor, _ dir: URL) async {
        audit.section("Run — real commands, real exit codes")
        let runner = TaskRunModel()

        let ok = dir.appendingPathComponent("ok.py")
        try? "print('the-marker-line')\n".write(to: ok, atomically: true, encoding: .utf8)
        runner.refreshTasks(project: nil, activeFile: ok, language: Languages.byID("python"))
        guard let task = runner.tasks.first(where: { $0.id == "file-python" }) else {
            audit.check("python task available", false)
            return
        }
        runner.run(task)
        let finished = await waitUntil(15) { runner.exitStatus != nil }
        audit.check("the run finished", finished)
        audit.equal("a clean script exits 0", runner.exitStatus, 0)
        audit.check("its output streamed into the pane",
                    runner.lines.contains { $0.text == "the-marker-line" },
                    runner.lines.map(\.text).joined(separator: " | "))
        audit.check("the run is timed", runner.duration > 0)

        let bad = dir.appendingPathComponent("fails.py")
        try? "import sys\nsys.exit(4)\n".write(to: bad, atomically: true, encoding: .utf8)
        runner.refreshTasks(project: nil, activeFile: bad, language: Languages.byID("python"))
        if let failing = runner.tasks.first(where: { $0.id == "file-python" }) {
            runner.run(failing)
            _ = await waitUntil(15) { runner.exitStatus != nil }
            audit.equal("a failing script's exit code is reported", runner.exitStatus, 4)
        }
    }

    // MARK: Clickable locations

    private static func clickable(_ audit: Auditor, _ dir: URL) async {
        audit.section("Run — an error in the output opens the file at the line")
        let model = AppModel(trust: .forAudit)
        model.openProject(dir)

        // A Python runtime error: the traceback frame must point at bad.py line 3.
        let bad = dir.appendingPathComponent("bad.py")
        try? "x = 1\ny = 2\nraise ValueError('boom')\n"
            .write(to: bad, atomically: true, encoding: .utf8)
        model.taskRun.refreshTasks(project: nil, activeFile: bad,
                                   language: Languages.byID("python"))
        if let task = model.taskRun.tasks.first(where: { $0.id == "file-python" }) {
            model.taskRun.run(task)
            _ = await waitUntil(15) { model.taskRun.exitStatus != nil }
            audit.check("the traceback run failed as expected", model.taskRun.exitStatus != 0)
            let frame = model.taskRun.lines.first { $0.diagnostic != nil }
            audit.check("a traceback frame became a diagnostic", frame != nil,
                        model.taskRun.lines.map(\.text).joined(separator: " | "))
            if let diagnostic = frame?.diagnostic {
                audit.equal("…pointing at the right file", diagnostic.file.lastPathComponent,
                            "bad.py")
                audit.equal("…and the right line", diagnostic.line, 3)
                // The same call the pane's click makes:
                model.open(file: diagnostic.file, atLine: diagnostic.line,
                           column: diagnostic.column)
                audit.equal("clicking it opens the file in a tab",
                            model.documents.active?.url.lastPathComponent, "bad.py")
                audit.check("…and moves the caret to the line",
                            model.editorRequest != nil)
            }
        } else {
            audit.check("python task for the traceback test", false)
        }

        // A compiler error, gcc style, through a clang build task.
        let source = dir.appendingPathComponent("bad.c")
        try? "#include <stdio.h>\n\nint main(void) {\n    return x;\n}\n"
            .write(to: source, atomically: true, encoding: .utf8)
        model.taskRun.refreshTasks(project: nil, activeFile: source,
                                   language: Languages.byID("c"))
        if let task = model.taskRun.tasks.first(where: { $0.id == "file-clang" }) {
            model.taskRun.run(task)
            _ = await waitUntil(20) { model.taskRun.exitStatus != nil }
            audit.check("the compile failed as expected", model.taskRun.exitStatus != 0)
            let error = model.taskRun.lines.first {
                $0.diagnostic?.severity == .error && $0.diagnostic?.file.lastPathComponent == "bad.c"
            }
            audit.check("the compiler error is a clickable diagnostic", error != nil,
                        model.taskRun.lines.map(\.text).suffix(4).joined(separator: " | "))
            audit.equal("…with the compiler's line number", error?.diagnostic?.line, 4)
            audit.check("…and the compiler's column", (error?.diagnostic?.column ?? 0) > 1)
        } else {
            audit.check("clang task for the compile test", false)
        }

        // Lines that merely look like locations must not become clicks.
        let phony = TaskOutputParser.diagnostic(
            for: "/no/such/file.c:12:3: error: made up", directory: dir)
        audit.check("a nonexistent path is not clickable", phony == nil)
        let prose = TaskOutputParser.diagnostic(
            for: "note: timing: 12:30: error rate nominal", directory: dir)
        audit.check("prose with colons is not a diagnostic", prose == nil)
    }

    // MARK: Streaming and stop

    private static func streamingAndStop(_ audit: Auditor, _ dir: URL) async {
        audit.section("Run — output streams while running, and Stop stops")
        let runner = TaskRunModel()
        try? "stream:\n\t@echo first-marker && sleep 1.2 && echo late-marker\n\nhang:\n\t@sleep 30\n"
            .write(to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        runner.refreshTasks(project: dir, activeFile: nil, language: nil)

        guard let stream = runner.tasks.first(where: { $0.id == "make-stream" }) else {
            audit.check("make stream task detected", false,
                        runner.tasks.map(\.id).joined(separator: ","))
            return
        }
        runner.run(stream)
        let sawFirst = await waitUntil(5) {
            runner.lines.contains { $0.text.contains("first-marker") }
        }
        let lateAlready = runner.lines.contains { $0.text.contains("late-marker") }
        audit.check("early output is visible while the task still runs",
                    sawFirst && runner.isRunning && !lateAlready,
                    "first=\(sawFirst) running=\(runner.isRunning) late=\(lateAlready)")
        _ = await waitUntil(10) { runner.exitStatus != nil }
        audit.check("the late output arrived by the end",
                    runner.lines.contains { $0.text.contains("late-marker") })
        audit.equal("make exits clean", runner.exitStatus, 0)

        guard let hang = runner.tasks.first(where: { $0.id == "make-hang" }) else {
            audit.check("make hang task detected", false)
            return
        }
        runner.run(hang)
        _ = await waitUntil(5) { runner.isRunning }
        runner.stop()
        let stopped = await waitUntil(6) { runner.exitStatus != nil }
        audit.check("Stop ends a hung task", stopped && !runner.isRunning,
                    "status=\(String(describing: runner.exitStatus))")
    }

    // MARK: Honesty

    private static func honesty(_ audit: Auditor, _ dir: URL) {
        audit.section("Run — missing things are named, not hidden")
        let runner = TaskRunModel()
        runner.reportNoTask(.test, project: dir)
        audit.check("no test task says so, and where it looked",
                    runner.note?.contains("No test task") == true
                    && runner.note?.contains("Package.swift") == true,
                    runner.note ?? "nil")

        let ghost = RunTask(id: "ghost", title: "gadgetize all", executable: nil,
                            arguments: [], directory: dir, kind: .build, source: "test",
                            missingTool: "gadget")
        runner.run(ghost)
        audit.check("a task with a missing tool names it and runs nothing",
                    runner.note?.contains("gadget") == true && runner.exitStatus == nil,
                    runner.note ?? "nil")
    }

    /// The acceptance gate runs `swift test` for any Package.swift. An empty package
    /// fails with "no tests found"; this package's tests are `Orrery --audit`.
    private static func thisPackageHasTests(_ audit: Auditor) {
        audit.section("Run — this package has a swift test target")
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/" &&
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Package.swift").path) {
            root.deleteLastPathComponent()
        }
        let manifest = (try? String(contentsOf: root.appendingPathComponent("Package.swift"),
                                    encoding: .utf8)) ?? ""
        let testsDir = root.appendingPathComponent("Tests")
        audit.check("this package declares a test target so swift test is not an empty suite",
                    manifest.contains(".testTarget")
                    && FileManager.default.fileExists(atPath: testsDir.path),
                    "Package.swift at \(root.path)")

        // The XCTest gate runs --audit as a child. Waiting for exit before
        // draining the combined stdout/stderr pipe deadlocks once output
        // exceeds Darwin's 64 KiB pipe — which ~1000 PASS lines do.
        let gateURL = root.appendingPathComponent("Tests/OrreryTests/AuditGateTests.swift")
        let gate = (try? String(contentsOf: gateURL, encoding: .utf8)) ?? ""
        let drainAt = gate.range(of: "readDataToEndOfFile")?.lowerBound
        let waitAt = gate.range(of: "waitUntilExit")?.lowerBound
        audit.check("the acceptance-gate test drains --audit output before waitUntilExit",
                    drainAt != nil && (waitAt == nil || drainAt! < waitAt!),
                    "AuditGateTests.swift")
        pipeCapacity(audit)
    }

    /// Darwin's pipe is 64 KiB. A child that writes more than that blocks until
    /// the parent reads; waiting for exit first is a deadlock.
    private static func pipeCapacity(_ audit: Auditor) {
        func spawn() throws -> (Process, Pipe, DispatchSemaphore) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/dd")
            process.arguments = ["if=/dev/zero", "bs=65536", "count=4"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            return (process, pipe, finished)
        }
        do {
            let (blocked, unread, unreadDone) = try spawn()
            let waited = unreadDone.wait(timeout: .now() + 1)
            // Exit is observed through the handler; `isRunning` can lag.
            let stalled = waited == .timedOut
            blocked.terminate()
            _ = unreadDone.wait(timeout: .now() + 2)
            _ = unread.fileHandleForReading.readDataToEndOfFile()
            audit.check("a child that writes more than the pipe buffer blocks until drained",
                        stalled,
                        "timedOut=\(waited == .timedOut)")

            let (ok, out, done) = try spawn()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let exited = done.wait(timeout: .now() + 5) == .success
            audit.check("draining stdout before waiting lets a 256 KiB child exit",
                        exited && ok.terminationStatus == 0 && data.count >= 256 * 1024,
                        "exited=\(exited) status=\(ok.terminationStatus) bytes=\(data.count)")
        } catch {
            audit.check("a child that writes more than the pipe buffer blocks until drained",
                        false, "\(error)")
            audit.check("draining stdout before waiting lets a 256 KiB child exit",
                        false, "\(error)")
        }
    }
}

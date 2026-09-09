import Foundation

@MainActor
enum AuditExecutionPolicy {
    static func run(_ audit: Auditor) async {
        audit.section("Execution — host write confinement and migration")
        audit.equal("new provider settings confine local writes", AgentSessionSettings().executionPolicy, .confinedWrites)
        let legacy = try? JSONDecoder().decode(AgentSessionSettings.self, from: Data(#"{"model":"saved","networkAccess":true}"#.utf8))
        audit.equal("legacy settings preserve their prior access", legacy?.executionPolicy, .fullAccess)
        audit.equal("legacy model survives migration", legacy?.model, "saved")
        audit.equal("legacy network choice survives migration", legacy?.networkAccess, true)
        let encoded = try? JSONEncoder().encode(AgentSessionSettings())
        let restored = encoded.flatMap { try? JSONDecoder().decode(AgentSessionSettings.self, from: $0) }
        audit.equal("confinement survives settings save and restore", restored?.executionPolicy, .confinedWrites)
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let keychains = home.appendingPathComponent("Library/Keychains").standardizedFileURL
        // Claude Code signs in through the macOS Keychain; a keychain deny makes every Claude turn
        // report "Not logged in" while the handshake still succeeds.
        audit.check("Claude keeps access to its Keychain sign-in", !AgentExecutionBoundary.protectedPaths(provider: .claude, home: home).contains(keychains))
        for provider in [Provider.grok, .codex] {
            audit.check("\(provider.displayName) cannot read the keychain database", AgentExecutionBoundary.protectedPaths(provider: provider, home: home).contains(keychains))
            audit.check("\(provider.displayName) cannot read Claude's file credentials", AgentExecutionBoundary.protectedPaths(provider: provider, home: home).contains(home.appendingPathComponent(".claude/.credentials.json").standardizedFileURL))
        }
        audit.check("Claude cannot read Grok's credentials", AgentExecutionBoundary.protectedPaths(provider: .claude, home: home).contains(home.appendingPathComponent(".grok/auth.json").standardizedFileURL))
        do {
            try await Auditor.withTemporaryDirectory { base in
                let workspace = base.appendingPathComponent("execution space \"quoted\"")
                let outside = base.appendingPathComponent("original")
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                try Data("keep".utf8).write(to: outside.appendingPathComponent("sentinel"))
                let request = AgentExecutionRequest(policy: .confinedWrites, workspace: workspace, provider: .grok)
                do {
                    _ = try AgentExecutionBoundary.prepare(executable: "/bin/sh", arguments: [], environment: [:],
                                                            execution: request, sandboxPath: base.appendingPathComponent("missing-sandbox").path)
                    audit.check("unavailable sandbox refuses launch", false)
                } catch { audit.check("unavailable sandbox refuses launch", true) }
                let unrestricted = try AgentExecutionBoundary.prepare(executable: "/bin/echo", arguments: ["literal"], environment: [:],
                    execution: AgentExecutionRequest(policy: .fullAccess, workspace: workspace, provider: .grok))
                audit.equal("explicit full access preserves executable", unrestricted.executable, "/bin/echo")
                audit.equal("explicit full access preserves arguments", unrestricted.arguments, ["literal"])
                guard AgentExecutionBoundary.isAvailable else {
                    audit.check("kernel confinement required for live execution tests", false, "sandbox-exec unavailable; confined launches remain blocked")
                    return
                }
                let script = #"""
                set -eu
                printf 'allowed' > "$1/allowed"
                printf 'private' > "$TMPDIR/private"
                test "$(cat "$2/sentinel")" = keep
                if (printf 'bad' > "$2/direct") 2>/dev/null; then exit 41; fi
                if /bin/sh -c 'printf bad > "$1/child"' audit "$2" 2>/dev/null; then exit 42; fi
                if /bin/rm "$2/sentinel" 2>/dev/null; then exit 43; fi
                if /bin/mv "$2/sentinel" "$1/stolen" 2>/dev/null; then exit 44; fi
                /bin/ln -s "$2" "$1/link"
                if (printf 'bad' > "$1/link/escaped") 2>/dev/null; then exit 45; fi
                printf 'sandbox-ok\n'
                """#
                var launch: AgentExecutionLaunch? = try AgentExecutionBoundary.prepare(executable: "/bin/sh",
                    arguments: ["-c", script, "audit", workspace.path, outside.path],
                    environment: AgentEnvironment.sanitized(ProcessInfo.processInfo.environment), execution: request)
                let privateDirectory = launch!.lease!.directory
                let result = await execute(launch!)
                audit.equal("kernel permits workspace writes and blocks outside writes, children, deletion, rename and symlink escape", result.status, 0)
                audit.check("kernel probe completed every step", result.output.contains("sandbox-ok"), result.output)
                audit.equal("original file remained unchanged", try? String(contentsOf: outside.appendingPathComponent("sentinel")), "keep")
                audit.check("outside direct write never occurred", !FileManager.default.fileExists(atPath: outside.appendingPathComponent("direct").path))
                audit.check("outside child write never occurred", !FileManager.default.fileExists(atPath: outside.appendingPathComponent("child").path))
                audit.check("symlink did not expand the write grant", !FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped").path))
                audit.check("private temporary writes work", FileManager.default.fileExists(atPath: privateDirectory.appendingPathComponent("private").path))
                launch = nil
                audit.check("launch temporary files are removed with their lease", !FileManager.default.fileExists(atPath: privateDirectory.path))

                let terminal = TerminalSession(directory: workspace)
                terminal.start(executable: "/bin/sh", arguments: ["-c", #"printf terminal-ok; if (printf bad > "$1/terminal-escape") 2>/dev/null; then exit 9; fi"#, "audit", outside.path],
                               environment: ProcessInfo.processInfo.environment, execution: request)
                for _ in 0..<100 where terminal.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
                audit.equal("raw CLI terminal uses the same inherited boundary", terminal.exitStatus, 0)
                audit.check("terminal writes outside the execution folder stay blocked", !FileManager.default.fileExists(atPath: outside.appendingPathComponent("terminal-escape").path))
                terminal.terminate()

                let protected = workspace.appendingPathComponent("credentials")
                try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
                try Data("private".utf8).write(to: protected.appendingPathComponent("token"))
                let protectedProfile = try AgentExecutionBoundary.profile(workspace: workspace.resolvingSymlinksInPath(),
                    temporary: workspace.resolvingSymlinksInPath(), protectedPaths: [protected.resolvingSymlinksInPath()])
                let protectedLaunch = AgentExecutionLaunch(executable: AgentExecutionBoundary.sandboxExecutable,
                    arguments: ["-p", protectedProfile, "/bin/sh", "-c", #"if /bin/cat "$1/token" 2>/dev/null; then exit 8; fi; if (printf bad > "$1/token") 2>/dev/null; then exit 9; fi"#, "audit", protected.path],
                    environment: ProcessInfo.processInfo.environment, lease: nil)
                audit.equal("credential deny overrides a surrounding workspace grant", await execute(protectedLaunch).status, 0)
                audit.equal("blocked credential contents stay unchanged", try? String(contentsOf: protected.appendingPathComponent("token")), "private")

                audit.equal("under confinement Codex runs without its own sandbox: the IDE boundary is the sandbox",
                            CodexBackend.sandboxParameter(policy: .confinedWrites, confinementAvailable: true, planMode: false, setting: "workspace-write"), "danger-full-access")
                audit.equal("plan mode under confinement relies on the read-only IDE boundary",
                            CodexBackend.sandboxParameter(policy: .confinedWrites, confinementAvailable: true, planMode: true, setting: "workspace-write"), "danger-full-access")
                audit.equal("with full access Codex keeps its own sandbox setting",
                            CodexBackend.sandboxParameter(policy: .fullAccess, confinementAvailable: true, planMode: false, setting: "workspace-write"), "workspace-write")
                audit.equal("with full access plan mode uses Codex's read-only sandbox",
                            CodexBackend.sandboxParameter(policy: .fullAccess, confinementAvailable: true, planMode: true, setting: "workspace-write"), "read-only")
                let nested = AgentExecutionLaunch(executable: AgentExecutionBoundary.sandboxExecutable,
                    arguments: ["-p", protectedProfile, AgentExecutionBoundary.sandboxExecutable, "-p", "(version 1)(allow default)", "/usr/bin/true"],
                    environment: ProcessInfo.processInfo.environment, lease: nil)
                let nestedResult = await execute(nested)
                audit.check("macOS refuses a sandbox nested inside the confinement profile, which is why Codex's own sandbox is off there",
                            nestedResult.status != 0 && nestedResult.output.contains("sandbox_apply"), "status \(nestedResult.status): \(nestedResult.output)")
                let readOnly = try AgentExecutionBoundary.prepare(executable: "/bin/sh",
                    arguments: ["-c", #"test "$(cat "$1/allowed")" = allowed || exit 7; if (printf bad > "$1/plan-write") 2>/dev/null; then exit 8; fi; printf ok > "$TMPDIR/plan-tmp" || exit 9; printf 'read-only-ok\n'"#, "audit", workspace.path],
                    environment: AgentEnvironment.sanitized(ProcessInfo.processInfo.environment),
                    execution: AgentExecutionRequest(policy: .confinedWrites, workspace: workspace, provider: .codex, readOnlyWorkspace: true))
                let readOnlyResult = await execute(readOnly)
                audit.check("a read-only workspace boundary reads the project, refuses writes to it and keeps the private temporary folder", readOnlyResult.status == 0, "status \(readOnlyResult.status): \(readOnlyResult.output)")
                audit.check("no plan-mode write reached the workspace", !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("plan-write").path))
                let extra = base.appendingPathComponent("extra", isDirectory: true)
                try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
                let extraLaunch = try AgentExecutionBoundary.prepare(executable: "/bin/sh",
                    arguments: ["-c", #"printf ok > "$1/extra-write" && printf 'extra-ok\n'"#, "audit", extra.path],
                    environment: AgentEnvironment.sanitized(ProcessInfo.processInfo.environment),
                    execution: AgentExecutionRequest(policy: .confinedWrites, workspace: workspace, provider: .codex, additionalDirectories: [extra]))
                audit.equal("an additional writable folder is writable inside the boundary", await execute(extraLaunch).status, 0)
                let scratchProbe = #"d="$1/orrery-audit-$$"; /bin/mkdir -p "$d" && /bin/rmdir "$d" && printf 'scratch-ok\n'"#
                let claudeScratch = try AgentExecutionBoundary.prepare(executable: "/bin/sh",
                    arguments: ["-c", scratchProbe, "audit", AgentExecutionBoundary.claudeScratchRoot.path],
                    environment: AgentEnvironment.sanitized(ProcessInfo.processInfo.environment),
                    execution: AgentExecutionRequest(policy: .confinedWrites, workspace: workspace, provider: .claude))
                audit.equal("Claude's /tmp/claude-<uid> scratch root is writable inside its boundary (its Bash tool needs it)", await execute(claudeScratch).status, 0)
                let codexScratch = try AgentExecutionBoundary.prepare(executable: "/bin/sh",
                    arguments: ["-c", scratchProbe, "audit", AgentExecutionBoundary.claudeScratchRoot.path],
                    environment: AgentEnvironment.sanitized(ProcessInfo.processInfo.environment),
                    execution: AgentExecutionRequest(policy: .confinedWrites, workspace: workspace, provider: .codex))
                audit.check("that scratch root stays closed to the other providers", await execute(codexScratch).status != 0)
                let cwdProbe = #"f="/private/tmp/claude-1ab8-cwd-audit$$"; (printf x > "$f") 2>/dev/null || exit 5; /bin/rm "$f" || exit 6; if (printf x > "/private/tmp/orrery-other-$$") 2>/dev/null; then exit 7; fi; printf 'cwd-ok\n'"#
                let claudeCwd = try AgentExecutionBoundary.prepare(executable: "/bin/sh", arguments: ["-c", cwdProbe],
                    environment: AgentEnvironment.sanitized(ProcessInfo.processInfo.environment),
                    execution: AgentExecutionRequest(policy: .confinedWrites, workspace: workspace, provider: .claude))
                let claudeCwdResult = await execute(claudeCwd)
                audit.check("Claude's /tmp/claude-<hex>-cwd tracking files are writable, other names under /tmp are not", claudeCwdResult.status == 0, "status \(claudeCwdResult.status): \(claudeCwdResult.output)")
                let codexCwd = try AgentExecutionBoundary.prepare(executable: "/bin/sh", arguments: ["-c", #"printf x > "/private/tmp/claude-1ab8-cwd-audit$$" && /bin/rm "/private/tmp/claude-1ab8-cwd-audit$$""#],
                    environment: AgentEnvironment.sanitized(ProcessInfo.processInfo.environment),
                    execution: AgentExecutionRequest(policy: .confinedWrites, workspace: workspace, provider: .codex))
                audit.check("those tracking files stay closed to the other providers", await execute(codexCwd).status != 0)
                audit.check("a missing additional folder is ignored rather than blocking the launch",
                            (try? AgentExecutionBoundary.prepare(executable: "/bin/sh", arguments: ["-c", "true"], environment: [:],
                                                                 execution: AgentExecutionRequest(policy: .confinedWrites, workspace: workspace, provider: .codex,
                                                                                                  additionalDirectories: [base.appendingPathComponent("nope")]))) != nil)
            }
        } catch { audit.check("host execution policy audit completed", false, error.localizedDescription) }
    }

    private static func execute(_ launch: AgentExecutionLaunch) async -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: launch.executable)
            process.arguments = launch.arguments
            process.environment = launch.environment
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(data: output, encoding: .utf8) ?? "")
            } catch { return (-1, error.localizedDescription) }
        }.value
    }
}

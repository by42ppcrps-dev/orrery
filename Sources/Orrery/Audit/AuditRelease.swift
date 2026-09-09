import Foundation

/// The build script's release path: it refuses a distributable build without a Developer ID
/// identity, says plainly when a bundle is ad-hoc signed, and describes notarization only when
/// a profile is set. `--plan` exercises the decisions without building anything.
@MainActor
enum AuditRelease {
    static func run(_ audit: Auditor) async {
        audit.section("Release — build-app.sh signs honestly and refuses an undistributable release")
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/" && !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) { root.deleteLastPathComponent() }
        let script = root.appendingPathComponent("build-app.sh").path
        let installer = (try? String(contentsOfFile: script, encoding: .utf8)) ?? ""
        audit.check("the installer keeps one previous copy and prunes the rest (Launch Services once launched a stale copy for open -a)",
                    installer.contains("build/previous.* 2>/dev/null | tail -n +2") && installer.contains("rm -rf \"$old\""))
        audit.check("the installer re-registers the installed app with Launch Services", installer.contains("lsregister -f \"$DESTINATION\""))
        func plan(_ arguments: [String], environment: [String: String] = [:], bashOptions: [String] = []) -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = bashOptions + [script] + arguments
            var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
            env.merge(environment) { _, new in new }
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = pipe
            do { try process.run() } catch { return (-1, "\(error)") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let exportRoot = root
        let packageCheck = await Task.detached { () -> (Bool, String) in
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["Tests/test_public_export.py", "PublicExportTests.test_relay_is_deployable_without_including_local_dependencies"]
            process.currentDirectoryURL = exportRoot
            process.environment = ["PATH": "/usr/bin:/bin"]
            process.standardOutput = output; process.standardError = output
            do { try process.run() } catch { return (false, error.localizedDescription) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak process] in
                if let process, process.isRunning { process.terminate() }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
        }.value
        audit.check("the source archive includes deployable relay code and excludes private local state", packageCheck.0, packageCheck.1)
        let syntax = plan([], bashOptions: ["-n"])
        audit.check("the script parses", syntax.status == 0 && syntax.output.isEmpty, syntax.output)
        let adHoc = plan(["--plan"], environment: ["ORRERY_AUTO_SIGN": "0"])
        audit.check("a plain build says it is ad-hoc signed and where it goes",
                    adHoc.status == 0 && adHoc.output.contains("ad-hoc") && adHoc.output.contains("build/Orrery.app") && adHoc.output.contains("app.orrery.studio"), adHoc.output)
        let install = plan(["--install", "--plan"])
        audit.check("an install names /Applications and the running-app refusal", install.status == 0 && install.output.contains("/Applications/Orrery.app") && install.output.contains("refused while"), install.output)
        let refused = plan(["--release", "--plan"])
        audit.check("a release without a Developer ID identity is refused, not ad-hoc signed", refused.status == 2 && refused.output.contains("ORRERY_SIGN_IDENTITY"), refused.output)
        let signed = plan(["--release", "--plan"], environment: ["ORRERY_SIGN_IDENTITY": "Developer ID Application: Example (TEAMID)"])
        audit.check("a public binary without notarization is refused", signed.status == 2 && signed.output.contains("ORRERY_NOTARY_PROFILE"), signed.output)
        let notarized = plan(["--release", "--plan"], environment: ["ORRERY_SIGN_IDENTITY": "Developer ID Application: Example (TEAMID)", "ORRERY_NOTARY_PROFILE": "orrery"])
        audit.check("a notary profile plans submission and stapling", notarized.status == 0 && notarized.output.contains("notarytool") && notarized.output.contains("stapled"), notarized.output)
        audit.check("an unknown option is an error", plan(["--bogus"]).status == 2)
        let text = (try? String(contentsOfFile: script, encoding: .utf8)) ?? ""
        audit.check("the plist takes its version from one place", text.contains("VERSION=\"") && text.contains("<string>$VERSION</string>") && text.contains("<string>$BUILD</string>"))
        audit.check("release signing uses the hardened runtime and a timestamp", text.contains("--options runtime --timestamp --sign \"$SIGN_IDENTITY\""))
    }
}

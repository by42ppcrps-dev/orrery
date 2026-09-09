import AppKit
import SwiftUI

@MainActor enum AuditStudioExperience {
    static func run(_ audit: Auditor) async {
        await onboardingAndUnlock(audit)
        let emptySelection = QuickOpenSelection.shifted(0, by: 1, count: 0)
        audit.check("Down on an empty file search cannot produce a negative selection", emptySelection == 0)
        audit.check("Return with no file results has nothing to open", QuickOpenSelection.match(at: emptySelection, in: []) == nil)
        let match = FuzzyMatch(url: URL(fileURLWithPath: "/tmp/fixture.md"), display: "fixture.md", score: 1, highlights: [])
        audit.check("file search clamps both ends and opens only a valid result", QuickOpenSelection.shifted(0, by: -1, count: 1) == 0 && QuickOpenSelection.shifted(0, by: 1, count: 1) == 0 && QuickOpenSelection.match(at: 0, in: [match]) == match && QuickOpenSelection.match(at: 1, in: [match]) == nil)
        audit.section("AI studio — native transcript, navigation and installed CLI options")
        audit.check("loopback addresses use HTTP without downgrading lookalike remote hosts", BrowserAddress.normalized("localhost:8765") == "http://localhost:8765" && BrowserAddress.normalized("127.0.0.1.example.com") == "https://127.0.0.1.example.com" && BrowserAddress.normalized("https://localhost:8765") == "https://localhost:8765")
        await Auditor.withTemporaryDirectory { root in
            let table = Roundtable()
            table.installed = [.claude]; table.participants = [.claude]; table.rounds = 1
            var created: [ScriptedBackend] = []
            var authenticationFailures: [Provider] = []
            table.onAuthenticationFailure = { authenticationFailures.append($0) }
            table.makeBackend = { provider in
                let events: [BackendEvent] = created.isEmpty
                    ? [.failure("401 OAuth access token expired"), .turnFinished(stopReason: "error", costUSD: nil)]
                    : [.assistantDelta("Recovered session"), .turnFinished(stopReason: "end_turn", costUSD: nil)]
                let backend = ScriptedBackend(provider: provider, scripts: [events]); created.append(backend); return backend
            }
            table.attach(project: root, storeDirectory: root.appendingPathComponent("history"))
            await table.send("First message")
            audit.check("authentication failure releases the poisoned Roundtable session and exposes sign-in recovery", created.count == 1 && !created[0].isRunning && authenticationFailures == [.claude])
            await table.send("Try after login refresh")
            audit.check("the next Roundtable message uses a fresh session after an authentication failure", created.count == 2 && table.entries.last?.text == "Recovered session")
            table.stop()
        }
        let rustHelp = """
        Options:
              --model <MODEL>
                  The chosen model
          -c, --config <key=value>
                  An override, repeatable
              --fullscreen
                  Full screen mode
        Commands:
          run  Execute a task
        """
        let flags = CLIOption.parse(rustHelp)
        audit.check("Rust-style multiline help discovers every flag without treating commands as flags", flags.map(\.flag) == ["--model", "--config", "--fullscreen"])
        audit.check("CLI option values are distinguished from switches", flags[0].takesValue && !flags[2].takesValue)
        audit.check("CLI values remain one literal argv element; no shell interpolation", flags[1].arguments(value: "key=a b; $(echo nope)") == ["--config", "key=a b; $(echo nope)"])
        let aliases = CLIOption.parse("Options:\n  --allowedTools, --allowed-tools <tools...>\n      Allowed tools\n  -r, --resume [session]  Resume a session\n")
        audit.check("Commander aliases and optional values are discovered", aliases.count == 2 && aliases[0].takesValue && aliases[1].argument == "[session]")
        for provider in Provider.allCases {
            let executable: String?
            switch provider { case .grok: executable = GrokBackend.locate(); case .claude: executable = ClaudeBackend.locate(); case .codex: executable = CodexBackend.locate() }
            if let executable, let result = try? await ProcessRunner.run(executable, ["--help"], timeout: 12) {
                let parsed = CLIOption.parse(result.standardOutput)
                audit.check("\(provider.displayName) installed CLI exposes \(parsed.count) searchable options", result.status == 0 && parsed.count > 10)
                audit.check("\(provider.displayName) live model flag has an editable value", parsed.contains { $0.flag == "--model" && $0.takesValue })
            }
        }
        let model = AppModel()
        model.workspaceLayout = .assistant
        model.showBrowser()
        audit.check("Browser opens beside the AI conversation", model.editorSurface == .browser && model.workspaceLayout == .workspace)
        model.workspaceLayout = .editor
        audit.check("choosing the Code workspace reveals code rather than leaving a browser visible", model.editorSurface == .code)
        model.showSimulator()
        audit.check("Simulator shares the full workspace surface", model.editorSurface == .simulator)
        model.bottomPane = .browser
        model.showCode()
        audit.check("Returning to Code removes the obsolete browser bottom panel", model.editorSurface == .code && model.bottomPane == .hidden)
        model.showBrowser(); model.bottomPane = .search
        audit.check("Search surfaces its panel even when the browser was covering the editor", model.editorSurface == .code && model.bottomPane == .search)
        model.workspaceLayout = .assistant; model.bottomPane = .output
        audit.check("Output reveals the workspace from Focus mode", model.workspaceLayout == .workspace && model.editorSurface == .code)

        // Representative maximum retained history, with long paragraphs, multilingual text and
        // code. Exercise the actual native renderer, preserving selection during streaming.
        let entries = (0..<300).map { index in
            Roundtable.Entry(speaker: index % 3 == 0 ? "human" : "codex",
                             text: "Message \(index) — 日本語 👩🏽‍💻\n" + String(repeating: "A long response with code let value = 42; and wrapping text. ", count: 25))
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 480))
        let text = NSTextView(frame: scroll.bounds)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        let coordinator = RoundtableTranscript.Coordinator()
        coordinator.scroll = scroll; coordinator.latestEntries = entries
        let start = Date()
        coordinator.render()
        audit.check("Native transcript retains all 300 messages, including Unicode", text.string.contains("Message 299") && text.string.contains("Message 0"))
        text.setSelectedRange(NSRange(location: 4, length: 12))
        coordinator.latestThinking = [.claude]; coordinator.latestLive = [.claude: "Streaming response"]
        coordinator.render()
        audit.check("Streaming updates preserve selected transcript text", text.string.contains("Streaming response") && text.selectedRange() == NSRange(location: 4, length: 12))
        for width in [360.0, 520.0, 900.0, 360.0] {
            scroll.frame.size.width = width
            text.frame.size.width = width
            if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        }
        audit.check("300-message transcript renders, streams and resizes below the eight-second hang threshold", Date().timeIntervalSince(start) < 6)
        coordinator.latestThinking = []; coordinator.latestLive = [:]; coordinator.render()
        audit.check("Stopped or completed streams leave no stale live reply", !text.string.contains("Streaming response"))
        model.shutdown()
    }
    static func onboardingAndUnlock(_ audit: Auditor) async {
        audit.section("First run — private projects and device authentication")
        audit.check("setup distinguishes missing, installed, connected and expired accounts",
            ProjectSetup.agentStatus(installed: false, connected: false, needsSignIn: false).contains("Install this agent")
            && ProjectSetup.agentStatus(installed: true, connected: false, needsSignIn: false).contains("Installed")
            && ProjectSetup.agentStatus(installed: true, connected: true, needsSignIn: false).contains("ready")
            && ProjectSetup.agentStatus(installed: true, connected: true, needsSignIn: true).contains("again"))
        await Auditor.withTemporaryDirectory { root in
            let folder = root.appendingPathComponent("My project")
            do {
                try ProjectSetup.createEmptyFolder(at: folder)
                audit.check("new project creates an empty owner-only directory", try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty && (try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
                let marker = folder.appendingPathComponent("keep.txt")
                try "preserve me".write(to: marker, atomically: true, encoding: .utf8)
                do { try ProjectSetup.createEmptyFolder(at: folder); audit.check("existing project refused", false) }
                catch { audit.check("creating a project never overwrites an existing folder", (try? String(contentsOf: marker, encoding: .utf8)) == "preserve me") }
            } catch { audit.check("project setup fixture", false, error.localizedDescription) }
        }
        await Auditor.withTemporaryDirectory { project in
            let model = AppModel(trust: .forAudit)
            model.openProject(project); model.provider = .codex
            defer { model.shutdown(); try? FileManager.default.removeItem(at: AgentSettingsStore.location(project)) }
            model.handleForTest(.models([.init(id: "sample-model", name: "Sample model")], current: "sample-model"), from: .codex)
            model.backends[.codex]?.stop(); model.backends[.codex] = nil
            audit.equal("reported model options remain selectable when the idle process is released", model.models.map(\.id), ["sample-model"])
            await model.setModel("sample-model")
            await model.setEffort("high")
            let saved = AgentSettingsStore.load(project)[.codex]
            audit.check("an idle model/effort selection is saved for the next session rather than discarded", saved?.model == "sample-model" && saved?.effort == "high" && model.currentModel == "sample-model")
        }
        audit.check("idle installed agents can be used without another sign-in", ProjectSetup.canUseAgent(installed: true, needsSignIn: false))
        audit.check("missing and expired agents require setup", !ProjectSetup.canUseAgent(installed: false, needsSignIn: false) && !ProjectSetup.canUseAgent(installed: true, needsSignIn: true))
        let item = CredentialUnlock.Item(service: "audit-only", account: "fake-account")
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var count = 0
            func called() -> Bool { lock.lock(); defer { lock.unlock() }; count += 1; return true }
        }
        let counter = Counter()
        let cancelled = await CredentialUnlock.unlock([item], authenticate: { false }, read: { _ in counter.called() })
        audit.check("cancelling device authentication never reads a credential or opens Keychain UI", cancelled == .cancelled && counter.count == 0)
        let unavailable = await CredentialUnlock.unlock([item], authenticate: { nil }, read: { _ in counter.called() })
        audit.check("unavailable device authentication does not read credentials", unavailable == .unavailable && counter.count == 0)
        let accepted = await CredentialUnlock.unlock([item], authenticate: { true }, read: { _ in counter.called() })
        audit.check("accepted authentication unlocks the requested credential", accepted == .unlocked(1) && counter.count == 1)
        let legacy = await CredentialUnlock.unlock([item], authenticate: { true }, read: { _ in false })
        audit.equal("a locked legacy item requests a separate explicit access action", legacy, .needsKeychainPermission(0))
        for provider in Provider.allCases {
            audit.check("\(provider.displayName) setup links to HTTPS installation instructions", ProjectSetup.installationURL(for: provider).scheme == "https")
        }
    }

}

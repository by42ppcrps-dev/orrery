import AppKit
import Foundation

/// Plugins: manifests parse strictly, discovery honors enable/disable and project consent,
/// commands run as processes with a sanitized environment and apply to the editor with undo,
/// save hooks fire after a write, MCP servers reach the session settings, and loading never
/// runs anything. Temporary folders throughout; the global snapshots are cleared afterwards.
@MainActor
enum AuditPlugins {
    static func run(_ audit: Auditor) async {
        defer { PluginSnapshot.install(.empty); RegistrySnapshot.install(.empty) }
        audit.section("Plugins — manifests parse strictly and name every problem")
        let manifest = """
        {"id": "tools", "name": "Tools", "version": "1.2", "description": "Test plugin",
         "commands": [{"id": "upper", "title": "Uppercase Selection", "command": "tr", "arguments": ["a-z", "A-Z"], "input": "selection", "output": "replaceSelection"},
                      {"id": "count", "title": "Word Count", "command": "wc", "arguments": ["-w"], "input": "buffer", "output": "show", "languages": ["python"]},
                      {"id": "stamp", "title": "Stamp", "command": "./stamp.sh", "input": "file", "output": "none"}],
         "onSave": [{"command": "./on-save.sh", "arguments": ["{file}"], "languages": ["python"]}],
         "mcpServers": {"tools_mcp": {"command": "./server.sh", "args": ["--stdio"]}, "studio_computer": {"command": "x"}},
         "registry": {"tasks": [{"id": "tools-lint", "title": "tools lint", "command": "/usr/bin/true", "fileExists": "lint.cfg"}]}}
        """
        let parsed = PluginManifest.parse(Data(manifest.utf8), source: "test")
        audit.check("a manifest yields commands, a hook, a server and a registry",
                    parsed.manifest?.commands.count == 3 && parsed.manifest?.saveHooks.count == 1 && parsed.manifest?.mcpServers.count == 1 && parsed.manifest?.registry?.tasks.count == 1,
                    parsed.problems.joined(separator: " | "))
        audit.check("studio_computer stays reserved", parsed.problems.contains { $0.contains("studio_computer") } && parsed.manifest?.mcpServers.first?.name == "tools_mcp")
        let broken = PluginManifest.parse(Data("""
        {"id": "Bad", "name": "x"}
        """.utf8), source: "test")
        audit.check("a bad id refuses the whole plugin", broken.manifest == nil && broken.problems.first?.contains("ids are lowercase") == true)
        let partial = PluginManifest.parse(Data("""
        {"id": "p", "name": "P", "commands": [{"id": "ok", "title": "Ok", "command": "true"}, {"id": "x", "title": "Bad input", "command": "true", "input": "clipboard"}, {"title": "no id"}],
         "onSave": [{"arguments": ["x"]}], "mcpServers": {"nothing": {}}}
        """.utf8), source: "test")
        audit.check("bad entries are skipped and named while the good command stays",
                    partial.manifest?.commands.count == 1 && partial.problems.count == 4 && partial.problems.contains { $0.contains("input must be") }, partial.problems.joined(separator: " | "))
        audit.check("a non-object manifest is refused", PluginManifest.parse(Data("[]".utf8), source: "t").manifest == nil)

        audit.section("Plugins — discovery, consent, enable/disable, and nothing runs on load")
        await Auditor.withTemporaryDirectory { base in
            let userDir = base.appendingPathComponent("Plugins")
            let toolsDir = userDir.appendingPathComponent("tools")
            try? FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)
            try? manifest.write(to: toolsDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            func script(_ name: String, _ body: String, in directory: URL) {
                let url = directory.appendingPathComponent(name)
                try? ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
            script("stamp.sh", "touch \"$ORRERY_PLUGIN_DIR/stamped\"; printf 'key=%s' \"${ANTHROPIC_API_KEY:-}\"", in: toolsDir)
            script("on-save.sh", "printf 'saved %s\\n' \"$1\" >> \"$ORRERY_PLUGIN_DIR/saves.log\"; printf 'hook ran'", in: toolsDir)
            script("server.sh", "exit 0", in: toolsDir)
            let offDir = userDir.appendingPathComponent("off")
            try? FileManager.default.createDirectory(at: offDir, withIntermediateDirectories: true)
            try? """
            {"id": "off", "name": "Off", "commands": [{"id": "boom", "title": "Boom", "command": "/usr/bin/touch", "arguments": ["\(base.path)/boom"]}],
             "mcpServers": {"off_mcp": {"command": "/usr/bin/true"}}}
            """.write(to: offDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            let suiteName = "local.orrery.audit-plugins-\(UUID().uuidString)"
            let suite = UserDefaults(suiteName: suiteName)!
            defer { suite.removePersistentDomain(forName: suiteName) }
            let manager = PluginManager(userDirectory: userDir, preferences: suite)
            manager.load(project: nil, projectAllowed: false)
            audit.equal("both user plugins are discovered", manager.plugins.map(\.id).sorted(), ["off", "tools"])
            audit.check("the reserved-name problem is reported at load", manager.problems.contains { $0.contains("studio_computer") })
            audit.check("nothing ran while loading", !FileManager.default.fileExists(atPath: toolsDir.appendingPathComponent("stamped").path) && !FileManager.default.fileExists(atPath: base.appendingPathComponent("boom").path))
            audit.equal("enabled plugins contribute their commands", PluginSnapshot.shared.commands.map(\.command.id).sorted(), ["boom", "count", "stamp", "upper"])
            audit.check("plugin MCP servers reach every session's settings, with relative commands resolved",
                        (AgentSessionSettings().mcpServers["tools_mcp"] as? [String: Any])?["command"] as? String == toolsDir.appendingPathComponent("server.sh").path
                        && AgentSessionSettings().mcpServers["off_mcp"] != nil)
            var explicit = AgentSessionSettings()
            explicit.mcpConfiguration = "{\"tools_mcp\": {\"command\": \"/usr/bin/env\"}}"
            audit.check("a project's explicit server wins over a plugin's by name", (explicit.mcpServers["tools_mcp"] as? [String: Any])?["command"] as? String == "/usr/bin/env")
            manager.setEnabled(false, pluginID: "off")
            audit.check("a disabled plugin drops out of commands and servers and stays listed",
                        !PluginSnapshot.shared.commands.contains { $0.pluginID == "off" } && AgentSessionSettings().mcpServers["off_mcp"] == nil && manager.plugins.contains { $0.id == "off" && !$0.enabled })
            let again = PluginManager(userDirectory: userDir, preferences: suite)
            again.load(project: nil, projectAllowed: false)
            audit.check("the disabled state is remembered", again.plugins.first { $0.id == "off" }?.enabled == false)
            manager.setEnabled(true, pluginID: "off")

            let project = base.appendingPathComponent("project")
            let projectPlugin = project.appendingPathComponent(PluginManager.projectRelativePath).appendingPathComponent("local")
            try? FileManager.default.createDirectory(at: projectPlugin, withIntermediateDirectories: true)
            try? "{\"id\": \"local\", \"name\": \"Local\", \"commands\": [{\"id\": \"hello\", \"title\": \"Hello\", \"command\": \"/usr/bin/true\"}]}".write(to: projectPlugin.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            manager.load(project: project, projectAllowed: false)
            audit.check("a project plugin is counted but not loaded without consent", manager.projectPluginsPresent == 1 && !manager.plugins.contains { $0.id == "local" } && manager.problems.contains { $0.contains("not loaded") })
            manager.load(project: project, projectAllowed: true)
            audit.check("with consent the project plugin loads and is marked as the project's", manager.plugins.first { $0.id == "local" }?.source == .project && PluginSnapshot.shared.commands.contains { $0.command.id == "hello" })
            var refusal = ""
            do { try manager.remove(manager.plugins.first { $0.id == "local" }!) } catch { refusal = error.localizedDescription }
            audit.check("Remove refuses project plugins", refusal.contains("project"))

            audit.section("Plugins — commands act on the editor, hooks fire after a save")
            let installFolder = base.appendingPathComponent("incoming")
            try? FileManager.default.createDirectory(at: installFolder, withIntermediateDirectories: true)
            try? "{\"id\": \"incoming\", \"name\": \"Incoming\"}".write(to: installFolder.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            let installed = try? manager.install(from: installFolder)
            audit.check("Install copies a folder into the user plugins folder", installed?.id == "incoming" && FileManager.default.fileExists(atPath: userDir.appendingPathComponent("incoming/plugin.json").path))
            var duplicate = ""
            do { _ = try manager.install(from: installFolder) } catch { duplicate = error.localizedDescription }
            audit.check("installing the same id twice is refused", duplicate.contains("already installed"))
            var missingManifest = ""
            do { _ = try manager.install(from: base) } catch { missingManifest = error.localizedDescription }
            audit.check("a folder without plugin.json is refused", missingManifest.contains("plugin.json"))

            let model = AppModel(trust: .forAudit)
            defer { model.shutdown() }
            try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let file = project.appendingPathComponent("script.py")
            try? "b\na\n".write(to: file, atomically: true, encoding: .utf8)
            model.openProject(project)
            model.open(file: file)
            guard let document = model.activeDocument else { audit.check("the file opened", false); return }
            manager.load(project: project, projectAllowed: true)
            let revision = model.extensionsRevision
            model.reloadExtensions()
            audit.check("a reload bumps the revision the Plugins menu observes", model.extensionsRevision == revision + 1)
            manager.load(project: project, projectAllowed: true)
            audit.check("language-limited commands show only for matching files",
                        model.pluginMenuCommands.contains { $0.command.id == "count" } && model.pluginMenuCommands.contains { $0.command.id == "upper" })
            let upper = PluginSnapshot.shared.commands.first { $0.command.id == "upper" }!
            let outcome = try? await PluginRunner.run(upper.command.command, arguments: upper.command.arguments, pluginDirectory: upper.directory,
                                                       context: PluginRunner.Context(project: project, file: file, languageID: "python", stdin: "b\na\n"))
            audit.equal("a selection command receives the selection on stdin and answers on stdout", outcome?.stdout, "B\nA\n")
            document.selection = NSRange(location: 0, length: 4)
            audit.check("apply replaces exactly the given range", model.applyPluginText("B\nA\n", to: document, range: NSRange(location: 0, length: 4), expecting: "b\na\n", textView: nil) && document.text == "B\nA\n")
            audit.check("a stale range is refused", !model.applyPluginText("Z", to: document, range: NSRange(location: 0, length: 4), expecting: "b\na\n", textView: nil))
            let stamp = PluginSnapshot.shared.commands.first { $0.command.id == "stamp" }!
            let stamped = try? await PluginRunner.run(stamp.command.command, arguments: [], pluginDirectory: stamp.directory,
                                                       context: PluginRunner.Context(project: project, file: file, languageID: "python", stdin: nil))
            audit.check("a relative command resolves inside the plugin folder and sees ORRERY_PLUGIN_DIR", stamped?.status == 0 && FileManager.default.fileExists(atPath: toolsDir.appendingPathComponent("stamped").path))
            audit.check("the plugin environment carries no inherited API key", stamped?.stdout == "key=")
            var escape = ""
            do { _ = try await PluginRunner.run("../../outside.sh", arguments: [], pluginDirectory: toolsDir, context: PluginRunner.Context()) } catch { escape = error.localizedDescription }
            audit.check("a relative command cannot escape the plugin folder", escape.contains("not installed"))
            var slow = ""
            do { let o = try await PluginRunner.run("/bin/sleep", arguments: ["5"], pluginDirectory: toolsDir, context: PluginRunner.Context(), timeout: 0.3); slow = o.timedOut ? "timed out" : "finished" } catch { slow = error.localizedDescription }
            audit.equal("a runaway command is stopped by the timeout", slow, "timed out")

            model.taskRun.appendExternal("hello\nworld", source: "Tools")
            audit.check("plugin output lands in the Output pane", model.taskRun.lines.suffix(3).map(\.text) == ["── Tools", "hello", "world"])

            document.selection = NSRange(location: 0, length: 0)
            audit.check("the document is dirty before the save", document.isDirty)
            let saved = model.documents.save(document)
            let hookRan = await waitUntil(3) { FileManager.default.fileExists(atPath: toolsDir.appendingPathComponent("saves.log").path) }
            audit.check("a save hook runs after a successful save with the file path", saved && hookRan && ((try? String(contentsOf: toolsDir.appendingPathComponent("saves.log"), encoding: .utf8)) ?? "").contains(file.path))
            let markdown = project.appendingPathComponent("notes.md")
            try? "# x\n".write(to: markdown, atomically: true, encoding: .utf8)
            model.open(file: markdown)
            if let notes = model.activeDocument {
                notes.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "!")
                _ = model.documents.save(notes)
                try? await Task.sleep(nanoseconds: 300_000_000)
                let log = (try? String(contentsOf: toolsDir.appendingPathComponent("saves.log"), encoding: .utf8)) ?? ""
                audit.check("a hook limited to Python ignores a Markdown save", !log.contains("notes.md"), log)
            }
            manager.setEnabled(false, pluginID: "tools")
            audit.check("disabling the plugin removes its save hook", PluginSnapshot.shared.saveHooks.isEmpty)
            PluginManager.shared.load(project: nil, projectAllowed: false)
        }
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/" && !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) { root.deleteLastPathComponent() }
        let app = (try? String(contentsOf: root.appendingPathComponent("Sources/Orrery/OrreryApp.swift"), encoding: .utf8)) ?? ""
        audit.check("the Plugins menu lists commands and offers reload and settings", app.contains("CommandMenu(\"Plugins\")") && app.contains("runPluginCommand(reference)") && app.contains("Plugin Settings…"))
    }

    private static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

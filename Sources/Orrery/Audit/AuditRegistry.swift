import Foundation

/// The registry: a JSON file adds languages, servers, checkers and tasks as data; bad entries
/// are named and skipped; project registries load only with trust and consent; loading never
/// runs a command. Everything happens in temporary folders and the global snapshot is cleared
/// afterwards so later audits see only built-in languages.
@MainActor
enum AuditRegistry {
    static func run(_ audit: Auditor) async {
        defer { RegistrySnapshot.install(.empty) }
        audit.section("Registry — parsing is strict, bounded and names every problem")
        let good = """
        {"version": 1,
         "languages": [{"id": "gleam", "name": "Gleam", "extensions": ["gleam"], "lineComments": ["//"], "blockComment": null,
                        "strings": [{"open": "\\"", "close": "\\""}], "keywords": ["fn", "let", "case", "pub"], "types": ["Int", "String"]}],
         "servers": [{"language": "gleam", "command": "definitely-missing-lsp-zz", "arguments": ["lsp"], "name": "gleam lsp"}],
         "checkers": [{"language": "gleam", "name": "gleam check", "command": "definitely-missing-tool-zz", "arguments": ["check", "{file}"],
                       "pattern": "^(?<file>[^:]+):(?<line>\\\\d+):(?<column>\\\\d+):\\\\s*(?<severity>error|warning):\\\\s*(?<message>.+)$"}],
         "tasks": [{"id": "gleam-test", "title": "gleam test", "command": "definitely-missing-tool-zz", "arguments": ["test"], "kind": "test", "fileExists": "gleam.toml"},
                   {"id": "gleam-run", "title": "gleam run {name}", "command": "definitely-missing-tool-zz", "arguments": ["run", "--module", "{stem}"], "languages": ["gleam"]},
                   {"id": "touch", "title": "touch", "command": "/usr/bin/touch", "arguments": ["{project}/ran.txt"], "fileExists": "gleam.toml"}],
         "future": {"ignored": true}}
        """
        let parsed = RegistryFile.parse(Data(good.utf8), source: "test")
        audit.check("a well-formed file parses with no problems", parsed.problems.isEmpty, parsed.problems.joined(separator: " | "))
        audit.check("it yields one language, one server, one checker and three tasks",
                    parsed.file.languages.count == 1 && parsed.file.servers.count == 1 && parsed.file.checkers.count == 1 && parsed.file.tasks.count == 3)
        audit.check("unknown keys are ignored", parsed.problems.isEmpty)
        let bad = """
        {"languages": [{"id": "Bad Id", "name": "x", "extensions": ["b"]}, {"id": "noext", "name": "x"}, {"name": "missing id"}],
         "checkers": [{"language": "a", "name": "no file placeholder", "command": "x", "arguments": ["check"], "pattern": "(?<line>\\\\d+)(?<message>.*)"},
                      {"language": "a", "name": "bad regex", "command": "x", "arguments": ["{file}"], "pattern": "(?<line>[)"},
                      {"language": "a", "name": "no groups", "command": "x", "arguments": ["{file}"], "pattern": "^(.+)$"}],
         "tasks": [{"id": "escape", "title": "t", "command": "x", "fileExists": "../outside"}, {"id": "kind", "title": "t", "command": "x", "kind": "deploy", "languages": ["a"]},
                   {"id": "neither", "title": "t", "command": "x"}],
         "servers": [{"language": "a"}]}
        """
        let broken = RegistryFile.parse(Data(bad.utf8), source: "test")
        audit.check("nothing from the bad entries is accepted", broken.file.languages.isEmpty && broken.file.checkers.isEmpty && broken.file.tasks.isEmpty && broken.file.servers.isEmpty)
        for needle in ["ids are lowercase", "names no extension", "needs \"id\"", "contains {file}", "pattern must be", "inside the project", "kind must be", "needs \"languages\"", "needs \"language\" and \"command\""] {
            audit.check("problem named: \(needle)", broken.problems.contains { $0.contains(needle) }, broken.problems.joined(separator: " | "))
        }
        audit.check("a non-object file is refused with a reason", RegistryFile.parse(Data("[1,2]".utf8), source: "t").problems.first?.contains("not a JSON object") == true)
        let huge = Data(repeating: 0x20, count: RegistryFile.byteLimit + 1)
        audit.check("an oversized file is refused before parsing", RegistryFile.parse(huge, source: "t").problems.first?.contains("larger than") == true)
        audit.check("a newer version is read with a warning", RegistryFile.parse(Data("{\"version\": 9}".utf8), source: "t").problems.first?.contains("newer") == true)

        audit.section("Registry — entries become languages, servers, checkers and tasks without running anything")
        await Auditor.withTemporaryDirectory { base in
            let userURL = base.appendingPathComponent("user/registry.json")
            try? FileManager.default.createDirectory(at: userURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? good.write(to: userURL, atomically: true, encoding: .utf8)
            let project = base.appendingPathComponent("project")
            try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try? "name = \"app\"\n".write(to: project.appendingPathComponent("gleam.toml"), atomically: true, encoding: .utf8)
            let registry = Registry(userURL: userURL)
            registry.load(project: project, projectAllowed: false)
            audit.check("the user registry loads without problems", registry.problems.isEmpty, registry.problems.joined(separator: " | "))
            guard let gleam = Languages.byID("gleam") else { audit.check("the registry language is registered", false); return }
            audit.equal("the registry language is registered", gleam.name, "Gleam")
            audit.equal("its extension resolves to it", Languages.forFile(URL(fileURLWithPath: "/tmp/x.gleam")).id, "gleam")
            audit.check("built-in detection is untouched", Languages.forFile(URL(fileURLWithPath: "/tmp/x.py")).id == "python")
            let kinds = Set(Tokenizer.tokens(for: "// note\nfn main() { \"text\" }\n", language: gleam).map(\.kind))
            audit.check("the registry language highlights from its own rules", kinds.isSuperset(of: [.comment, .keyword, .string]), "\(kinds.map(\.rawValue).sorted())")
            audit.equal("the server is wired by the registry", LSPManager.serverName(for: gleam), "gleam lsp")
            let manager = LSPManager()
            audit.check("a missing registry server is named", manager.unavailableNote(for: gleam)?.contains("gleam lsp") == true && manager.unavailableNote(for: gleam)?.contains("not installed") == true, manager.unavailableNote(for: gleam) ?? "nil")
            manager.shutdownAll()
            guard let checker = Checkers.candidates(for: gleam).first else { audit.check("the registry checker is a candidate", false); return }
            audit.equal("the registry checker is a candidate", checker.name, "gleam check")
            audit.check("its missing tool is named instead of a clean report", Checkers.unavailableNote(for: gleam).contains("gleam check") && Checkers.unavailableNote(for: gleam).contains("not installed"))
            let file = project.appendingPathComponent("src/a.gleam")
            audit.equal("{file} is substituted in the checker's arguments", checker.arguments(file), ["check", file.path])
            let output = ProcessRunner.Result(status: 1, standardOutput: "", standardError: "src/a.gleam:3:7: error: Unknown variable\nsrc/a.gleam:9:1: warning: Unused import\nsrc/other.gleam:2:2: error: Elsewhere\n", timedOut: false)
            let found = checker.parse(output, file)
            audit.check("named groups map to line, column, severity and message, and other files' lines are dropped",
                        found.count == 2 && found[0].line == 3 && found[0].column == 7 && found[0].severity == .error && found[0].message == "Unknown variable" && found[1].severity == .warning, "\(found)")
            audit.check("a checker without {file} is accepted when its pattern names the file",
                        RegistryFile.parse(Data("{\"checkers\": [{\"language\": \"a\", \"name\": \"n\", \"command\": \"x\", \"arguments\": [\"check\"], \"pattern\": \"^(?<file>[^:]+):(?<line>\\\\d+): (?<message>.+)$\"}]}".utf8), source: "t").file.checkers.count == 1)
            let tasks = TaskCatalog.tasks(project: project, activeFile: file, language: gleam)
            let titles = tasks.map(\.title)
            audit.check("the project task appears because gleam.toml exists", titles.contains("gleam test") && tasks.first { $0.title == "gleam test" }?.kind == .test, titles.joined(separator: ", "))
            audit.check("the file task appears with its placeholders filled",
                        tasks.contains { $0.title == "gleam run a.gleam" && $0.arguments == ["run", "--module", "a"] }, titles.joined(separator: ", "))
            audit.check("a missing command is named on the task", tasks.first { $0.title == "gleam test" }?.missingTool == "definitely-missing-tool-zz")
            audit.check("a task with an existing absolute command resolves it", tasks.first { $0.title == "touch" }?.executable == "/usr/bin/touch")
            audit.check("loading and listing never ran a command", !FileManager.default.fileExists(atPath: project.appendingPathComponent("ran.txt").path))
            audit.check("project tasks are absent without a project", TaskCatalog.tasks(project: nil, activeFile: file, language: gleam).allSatisfy { $0.title != "gleam test" })

            let projectRegistryDir = project.appendingPathComponent(".orrery")
            try? FileManager.default.createDirectory(at: projectRegistryDir, withIntermediateDirectories: true)
            try? """
            {"tasks": [{"id": "proj-lint", "title": "project lint", "command": "/usr/bin/true", "fileExists": "gleam.toml"}],
             "languages": [{"id": "python", "name": "Not Python", "extensions": ["py"]}, {"id": "gleam", "name": "Again", "extensions": ["gl"]}]}
            """.write(to: projectRegistryDir.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)
            registry.load(project: project, projectAllowed: false)
            audit.check("a project registry is seen but not loaded until allowed",
                        registry.projectFileExists && registry.projectFile == nil && registry.problems.contains { $0.contains("not loaded") }, registry.problems.joined(separator: " | "))
            audit.check("…so its task is absent", !TaskCatalog.tasks(project: project, activeFile: nil, language: nil).contains { $0.title == "project lint" })
            registry.load(project: project, projectAllowed: true)
            audit.check("allowed, the project task appears", TaskCatalog.tasks(project: project, activeFile: nil, language: nil).contains { $0.title == "project lint" && $0.executable == "/usr/bin/true" })
            audit.check("a project registry cannot replace a built-in language", registry.problems.contains { $0.contains("\"python\"") && $0.contains("built in") } && Languages.forFile(URL(fileURLWithPath: "/tmp/x.py")).id == "python", registry.problems.joined(separator: " | "))
            audit.check("nor redefine one from the user registry", registry.problems.contains { $0.contains("\"gleam\"") && $0.contains("already defined") } && Languages.byID("gleam")?.name == "Gleam")

            try? FileManager.default.removeItem(at: projectRegistryDir.appendingPathComponent("registry.json"))
            try? FileManager.default.createSymbolicLink(at: projectRegistryDir.appendingPathComponent("registry.json"), withDestinationURL: userURL)
            registry.load(project: project, projectAllowed: true)
            audit.check("a symlinked registry file is refused", registry.projectFile == nil && registry.problems.contains { $0.contains("symbolic link") }, registry.problems.joined(separator: " | "))

            try? "{ not json".write(to: userURL, atomically: true, encoding: .utf8)
            registry.load(project: nil, projectAllowed: false)
            audit.check("a broken user registry installs nothing and says why", Languages.byID("gleam") == nil && registry.problems.contains { $0.contains("not a JSON object") })

            try? FileManager.default.removeItem(at: userURL)
            audit.check("the example is written only when no registry exists", registry.writeExampleIfMissing() && !registry.writeExampleIfMissing())
            let mode = (try? FileManager.default.attributesOfItem(atPath: userURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            audit.equal("the example file is owner-only", mode & 0o777, 0o600)
            registry.load(project: nil, projectAllowed: false)
            audit.check("the example loads cleanly", registry.problems.isEmpty && registry.userFile?.languages.first?.id == "gleam" && registry.userFile?.tasks.count == 2, registry.problems.joined(separator: " | "))

            let defaults = UserDefaults(suiteName: "local.orrery.audit-registry-consent")!
            defaults.removePersistentDomain(forName: "local.orrery.audit-registry-consent")
            audit.check("consent starts off", !RegistryConsent.isAllowed(project, defaults: defaults))
            RegistryConsent.setAllowed(project, true, defaults: defaults)
            audit.check("consent is remembered for the folder", RegistryConsent.isAllowed(project, defaults: defaults))
            audit.check("consent does not spill onto a sibling", !RegistryConsent.isAllowed(base, defaults: defaults))
            RegistryConsent.setAllowed(project, false, defaults: defaults)
            audit.check("consent can be withdrawn", !RegistryConsent.isAllowed(project, defaults: defaults))
            defaults.removePersistentDomain(forName: "local.orrery.audit-registry-consent")

            let model = AppModel(trust: .forAudit)
            defer { model.shutdown() }
            model.openProject(project)
            audit.check("opening a project reloads the registry for it", Registry.shared.projectRoot == project)
            audit.check("a trusted project still needs explicit consent", !model.projectRegistryAllowed)
            model.projectRegistryAllowed = true
            audit.check("consent through the model takes effect", model.projectRegistryAllowed && Registry.shared.projectAllowed)
            model.projectRegistryAllowed = false
            Registry.shared.load(project: nil, projectAllowed: false)
        }
        audit.check("the audit left no registry language behind", Languages.byID("gleam") == nil)
    }
}

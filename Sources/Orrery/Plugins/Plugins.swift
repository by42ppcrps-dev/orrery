import AppKit
import Foundation

// MARK: - Manifest

/// A plugin is a folder with `plugin.json` and whatever scripts it ships. Plugins are processes,
/// never code loaded into the app: a command runs as a child with a sanitized environment, so
/// signing, the hardened runtime and write confinement stay what they are. A plugin can add
/// menu commands that act on the selection or the file, hooks that run after a save, MCP
/// servers that every agent session receives, and a registry (languages, servers, checkers,
/// tasks) in the same format as `registry.json`.
struct PluginManifest: Equatable {
    enum Input: String { case none, selection, buffer, file }
    enum Output: String { case none, replaceSelection, insertAtCursor, show }

    struct Command: Equatable {
        var id: String
        var title: String
        var command: String
        var arguments: [String] = []
        var input: Input = .none
        var output: Output = .show
        var languages: [String] = []
        var description: String?
    }
    struct SaveHook: Equatable {
        var command: String
        var arguments: [String] = []
        var languages: [String] = []
        var reloadIfChanged = true
    }
    struct MCPServer: Equatable {
        var name: String
        var command: String?
        var arguments: [String] = []
        var url: String?
        var environment: [String: String] = [:]
    }

    var id: String
    var name: String
    var version: String
    var description: String
    var commands: [Command] = []
    var saveHooks: [SaveHook] = []
    var mcpServers: [MCPServer] = []
    var registry: RegistryFile?

    static let byteLimit = 256 * 1024

    static func parse(_ data: Data, source: String) -> (manifest: PluginManifest?, problems: [String]) {
        var problems: [String] = []
        guard data.count <= byteLimit else { return (nil, ["\(source): plugin.json is larger than \(byteLimit / 1024) KB; ignored."]) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, ["\(source): plugin.json is not a JSON object."]) }
        let idPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,31}$")
        func validID(_ id: String) -> Bool { idPattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil }
        func strings(_ any: Any?, _ limit: Int = 64, each: Int = 512) -> [String]? {
            guard any != nil else { return [] }
            guard let list = any as? [String] else { return nil }
            return Array(list.prefix(limit)).filter { !$0.isEmpty && $0.count <= each }
        }
        guard let id = object["id"] as? String, let name = object["name"] as? String, !name.isEmpty else { return (nil, ["\(source): plugin.json needs \"id\" and \"name\"."]) }
        guard validID(id) else { return (nil, ["\(source): plugin id \"\(id)\": ids are lowercase letters, digits, - and _ (32 max)."]) }
        var manifest = PluginManifest(id: id, name: String(name.prefix(48)), version: String(((object["version"] as? String) ?? "0").prefix(24)),
                                      description: String(((object["description"] as? String) ?? "").prefix(300)))
        for (index, raw) in ((object["commands"] as? [Any]) ?? []).prefix(32).enumerated() {
            guard let entry = raw as? [String: Any], let commandID = entry["id"] as? String, let title = entry["title"] as? String, let command = entry["command"] as? String,
                  !title.isEmpty, !command.isEmpty, command.count <= 512 else {
                problems.append("\(source): commands[\(index)] needs \"id\", \"title\" and \"command\"."); continue
            }
            guard validID(commandID) else { problems.append("\(source): command \"\(commandID)\": ids are lowercase letters, digits, - and _."); continue }
            guard let arguments = strings(entry["arguments"]), let languages = strings(entry["languages"], 32, each: 32) else { problems.append("\(source): command \"\(commandID)\": arguments and languages must be strings."); continue }
            guard let input = Input(rawValue: (entry["input"] as? String) ?? "none") else { problems.append("\(source): command \"\(commandID)\": input must be none, selection, buffer or file."); continue }
            guard let output = Output(rawValue: (entry["output"] as? String) ?? "show") else { problems.append("\(source): command \"\(commandID)\": output must be none, replaceSelection, insertAtCursor or show."); continue }
            if manifest.commands.contains(where: { $0.id == commandID }) { problems.append("\(source): command \"\(commandID)\" is listed twice; the first one wins."); continue }
            manifest.commands.append(Command(id: commandID, title: String(title.prefix(64)), command: command, arguments: arguments, input: input, output: output,
                                             languages: languages, description: (entry["description"] as? String).map { String($0.prefix(200)) }))
        }
        for (index, raw) in ((object["onSave"] as? [Any]) ?? []).prefix(16).enumerated() {
            guard let entry = raw as? [String: Any], let command = entry["command"] as? String, !command.isEmpty, command.count <= 512 else {
                problems.append("\(source): onSave[\(index)] needs \"command\"."); continue
            }
            guard let arguments = strings(entry["arguments"]), let languages = strings(entry["languages"], 32, each: 32) else { problems.append("\(source): onSave[\(index)]: arguments and languages must be strings."); continue }
            manifest.saveHooks.append(SaveHook(command: command, arguments: arguments, languages: languages, reloadIfChanged: entry["reloadIfChanged"] as? Bool ?? true))
        }
        if let servers = object["mcpServers"] as? [String: Any] {
            for (serverName, raw) in servers.sorted(by: { $0.key < $1.key }).prefix(16) {
                guard serverName != "studio_computer" else { problems.append("\(source): the MCP server name studio_computer is reserved for the IDE."); continue }
                guard let entry = raw as? [String: Any], serverName.count <= 64 else { problems.append("\(source): MCP server \"\(serverName)\" must be an object."); continue }
                let command = entry["command"] as? String, url = entry["url"] as? String
                guard (command != nil && !command!.isEmpty) || (url != nil && !url!.isEmpty) else { problems.append("\(source): MCP server \"\(serverName)\" needs a command or a URL."); continue }
                guard let arguments = strings(entry["args"] ?? entry["arguments"]) else { problems.append("\(source): MCP server \"\(serverName)\": args must be strings."); continue }
                let environment = (entry["env"] as? [String: String]) ?? [:]
                manifest.mcpServers.append(MCPServer(name: serverName, command: command, arguments: arguments, url: url, environment: environment))
            }
        }
        if let registry = object["registry"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: registry) {
            let parsed = RegistryFile.parse(data, source: "\(source) registry")
            manifest.registry = parsed.file
            problems += parsed.problems
        }
        return (manifest, problems)
    }
}

struct Plugin: Identifiable, Equatable {
    enum Source: String { case user, project }
    let manifest: PluginManifest
    let directory: URL
    let source: Source
    var enabled: Bool
    var id: String { manifest.id }
    var summary: String {
        var parts: [String] = []
        if !manifest.commands.isEmpty { parts.append("\(manifest.commands.count) command\(manifest.commands.count == 1 ? "" : "s")") }
        if !manifest.saveHooks.isEmpty { parts.append("\(manifest.saveHooks.count) save hook\(manifest.saveHooks.count == 1 ? "" : "s")") }
        if !manifest.mcpServers.isEmpty { parts.append("\(manifest.mcpServers.count) agent tool server\(manifest.mcpServers.count == 1 ? "" : "s")") }
        if let registry = manifest.registry {
            let n = registry.languages.count + registry.servers.count + registry.checkers.count + registry.tasks.count
            if n > 0 { parts.append("\(n) registry entr\(n == 1 ? "y" : "ies")") }
        }
        return parts.isEmpty ? "nothing to add" : parts.joined(separator: ", ")
    }
}

// MARK: - Snapshot read from any thread

struct PluginCommandRef: Identifiable, Equatable {
    let pluginID: String
    let pluginName: String
    let directory: URL
    let command: PluginManifest.Command
    var id: String { pluginID + "/" + command.id }
    var menuTitle: String { command.title }
}

final class PluginSnapshot: @unchecked Sendable {
    static let empty = PluginSnapshot(commands: [], saveHooks: [], mcpServers: [:])
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: PluginSnapshot = .empty
    static var shared: PluginSnapshot { lock.lock(); defer { lock.unlock() }; return current }
    static func install(_ snapshot: PluginSnapshot) { lock.lock(); current = snapshot; lock.unlock() }

    let commands: [PluginCommandRef]
    let saveHooks: [(directory: URL, hook: PluginManifest.SaveHook, pluginName: String)]
    /// In the same shape as the settings' "Additional MCP servers" object, keyed by server name.
    let mcpServers: [String: Any]

    init(commands: [PluginCommandRef], saveHooks: [(directory: URL, hook: PluginManifest.SaveHook, pluginName: String)], mcpServers: [String: Any]) {
        self.commands = commands
        self.saveHooks = saveHooks
        self.mcpServers = mcpServers
    }
}

// MARK: - Running a plugin command

enum PluginRunner {
    struct Context {
        var project: URL?
        var file: URL?
        var languageID: String?
        var stdin: String?
    }
    struct Outcome {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }
    static let timeout: TimeInterval = 60
    static let outputLimit = 4 * 1024 * 1024

    /// `./script` resolves inside the plugin folder, a bare name on PATH, an absolute path as is.
    static func resolve(_ command: String, pluginDirectory: URL) -> String? {
        if command.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
        if command.contains("/") {
            let candidate = pluginDirectory.appendingPathComponent(command).standardizedFileURL
            guard candidate.path.hasPrefix(pluginDirectory.standardizedFileURL.path + "/") else { return nil }
            return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate.path : nil
        }
        return Executables.find([], orNamed: command)
    }

    static func run(_ command: String, arguments: [String], pluginDirectory: URL, context: Context, timeout: TimeInterval = timeout) async throws -> Outcome {
        guard let executable = resolve(command, pluginDirectory: pluginDirectory) else {
            throw ComputerError("\(command) is not installed or not executable (looked in the plugin folder and on PATH).")
        }
        let root = context.project ?? context.file?.deletingLastPathComponent() ?? pluginDirectory
        let substituted = arguments.map { RegistryCommands.substitute($0, file: context.file, project: root) }
        var environment: [String: String] = [
            "ORRERY_PLUGIN_DIR": pluginDirectory.path, "ORRERY_PROJECT": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin",
        ]
        if let file = context.file { environment["ORRERY_FILE"] = file.path }
        if let language = context.languageID { environment["ORRERY_LANGUAGE"] = language }
        let result = try await ProcessRunner.run(executable, substituted, cwd: root, environment: environment, timeout: timeout, stdin: context.stdin)
        guard result.standardOutput.utf8.count <= outputLimit else {
            throw ComputerError("\(command) produced more than \(outputLimit / (1024 * 1024)) MB; refusing to apply it.")
        }
        return Outcome(status: result.status, stdout: result.standardOutput, stderr: result.standardError, timedOut: result.timedOut)
    }
}

// MARK: - Discovery, consent, enable/disable

@MainActor @Observable
final class PluginManager {
    static let shared = PluginManager()
    static let projectRelativePath = ".orrery/plugins"
    static let disabledKey = "plugins.disabled.v1"

    let userDirectory: URL
    private let preferences: UserDefaults
    private(set) var plugins: [Plugin] = []
    private(set) var problems: [String] = []
    private(set) var projectRoot: URL?
    private(set) var projectAllowed = false
    private(set) var projectPluginsPresent = 0

    init(userDirectory: URL? = nil, preferences: UserDefaults? = nil) {
        self.userDirectory = userDirectory ?? PrivateProjectFile.defaultDirectory("Plugins")
        self.preferences = preferences ?? AppModel.preferences
    }

    var disabledIDs: Set<String> {
        get { Set(preferences.stringArray(forKey: Self.disabledKey) ?? []) }
        set { preferences.set(Array(newValue).sorted(), forKey: Self.disabledKey) }
    }

    func setEnabled(_ enabled: Bool, pluginID: String) {
        var ids = disabledIDs
        if enabled { ids.remove(pluginID) } else { ids.insert(pluginID) }
        disabledIDs = ids
        load(project: projectRoot, projectAllowed: projectAllowed)
    }

    /// Registry files contributed by enabled plugins, for `Registry.load`.
    var registryContributions: [(RegistryFile, String)] {
        plugins.compactMap { plugin in plugin.enabled ? plugin.manifest.registry.map { ($0, "plugin \(plugin.manifest.name)") } : nil }
    }

    func load(project: URL?, projectAllowed: Bool) {
        projectRoot = project
        self.projectAllowed = projectAllowed
        var found: [Plugin] = []
        var problems: [String] = []
        let disabled = disabledIDs
        func scan(_ directory: URL, source: Plugin.Source) -> Int {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return 0 }
            var count = 0
            for folder in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(64) {
                let manifestURL = folder.appendingPathComponent("plugin.json")
                guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
                count += 1
                let sourceName = "\(source == .user ? "plugin" : "project plugin") \(folder.lastPathComponent)"
                if (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    problems.append("\(sourceName): the folder is a symbolic link; refused."); continue
                }
                guard let data = try? Data(contentsOf: manifestURL) else { problems.append("\(sourceName): plugin.json could not be read."); continue }
                let parsed = PluginManifest.parse(data, source: sourceName)
                problems += parsed.problems
                guard let manifest = parsed.manifest else { continue }
                if found.contains(where: { $0.id == manifest.id }) { problems.append("\(sourceName): id \"\(manifest.id)\" is already used by another plugin; skipped."); continue }
                found.append(Plugin(manifest: manifest, directory: folder, source: source, enabled: !disabled.contains(manifest.id)))
            }
            return count
        }
        _ = scan(userDirectory, source: .user)
        projectPluginsPresent = 0
        if let project {
            let directory = project.appendingPathComponent(Self.projectRelativePath, isDirectory: true)
            if projectAllowed {
                projectPluginsPresent = scan(directory, source: .project)
            } else if let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                projectPluginsPresent = entries.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("plugin.json").path) }.count
                if projectPluginsPresent > 0 {
                    problems.append("\(projectPluginsPresent) project plugin\(projectPluginsPresent == 1 ? "" : "s") in \(Self.projectRelativePath) not loaded: allow this project's registry and plugins in Agent settings → Tools once you have read them.")
                }
            }
        }
        plugins = found
        var commands: [PluginCommandRef] = []
        var hooks: [(directory: URL, hook: PluginManifest.SaveHook, pluginName: String)] = []
        var servers: [String: Any] = [:]
        for plugin in found where plugin.enabled {
            for command in plugin.manifest.commands {
                commands.append(PluginCommandRef(pluginID: plugin.id, pluginName: plugin.manifest.name, directory: plugin.directory, command: command))
            }
            for hook in plugin.manifest.saveHooks { hooks.append((plugin.directory, hook, plugin.manifest.name)) }
            for server in plugin.manifest.mcpServers {
                guard servers[server.name] == nil else { problems.append("plugin \(plugin.manifest.name): MCP server \"\(server.name)\" is already provided by another plugin; skipped."); continue }
                var entry: [String: Any] = [:]
                if let command = server.command {
                    entry["command"] = PluginRunner.resolve(command, pluginDirectory: plugin.directory) ?? command
                    entry["args"] = server.arguments
                }
                if let url = server.url { entry["url"] = url }
                if !server.environment.isEmpty { entry["env"] = server.environment }
                servers[server.name] = entry
            }
        }
        PluginSnapshot.install(PluginSnapshot(commands: commands, saveHooks: hooks, mcpServers: servers))
        self.problems = problems
    }

    /// Copies a folder that holds plugin.json into the user plugins folder.
    func install(from folder: URL) throws -> PluginManifest {
        let manifestURL = folder.appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw ComputerError("That folder has no plugin.json.") }
        let parsed = PluginManifest.parse(data, source: folder.lastPathComponent)
        guard let manifest = parsed.manifest else { throw ComputerError(parsed.problems.first ?? "plugin.json could not be read.") }
        let destination = userDirectory.appendingPathComponent(manifest.id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ComputerError("A plugin with id \"\(manifest.id)\" is already installed; remove it first.") }
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: folder, to: destination)
        load(project: projectRoot, projectAllowed: projectAllowed)
        return manifest
    }

    /// Moves a user plugin to the Trash; project plugins belong to the project and stay.
    func remove(_ plugin: Plugin) throws {
        guard plugin.source == .user else { throw ComputerError("Project plugins live in the project; delete the folder there.") }
        try FileManager.default.trashItem(at: plugin.directory, resultingItemURL: nil)
        load(project: projectRoot, projectAllowed: projectAllowed)
    }

    static let exampleID = "example-tools"
    static let exampleManifest = """
    {
      "id": "example-tools",
      "name": "Example Tools",
      "version": "1.0",
      "description": "Three small commands that show what a plugin can do. Edit or delete freely.",
      "commands": [
        {"id": "sort-lines", "title": "Sort Selected Lines", "command": "./sort-lines.sh", "input": "selection", "output": "replaceSelection",
         "description": "Sorts the selected lines (or the whole file when nothing is selected)."},
        {"id": "upper", "title": "Uppercase Selection", "command": "tr", "arguments": ["a-z", "A-Z"], "input": "selection", "output": "replaceSelection"},
        {"id": "wc", "title": "Word Count", "command": "wc", "arguments": ["-lwc"], "input": "buffer", "output": "show"}
      ],
      "onSave": [],
      "mcpServers": {},
      "registry": {}
    }

    """
    static let exampleScript = """
    #!/bin/sh
    # Reads the selection on stdin, writes the sorted lines to stdout.
    sort

    """

    @discardableResult
    func writeExampleIfMissing() -> Bool {
        let folder = userDirectory.appendingPathComponent(Self.exampleID, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Self.exampleManifest.write(to: folder.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            let script = folder.appendingPathComponent("sort-lines.sh")
            try Self.exampleScript.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            load(project: projectRoot, projectAllowed: projectAllowed)
            return true
        } catch { problems.append("Could not write the example plugin: \(error.localizedDescription)"); return false }
    }
}

// MARK: - The app's side: menu commands, save hooks, output

extension AppModel {
    /// Loads plugins, then the registry with the plugins' contributions. Called on project open,
    /// trust and consent changes, and Reload.
    func reloadExtensions() {
        PluginManager.shared.load(project: projectURL, projectAllowed: projectRegistryAllowed)
        Registry.shared.load(project: projectURL, projectAllowed: projectRegistryAllowed, contributions: PluginManager.shared.registryContributions)
        extensionsRevision += 1
    }

    /// Commands the Plugins menu shows for the active document's language (commands with no
    /// language list show always).
    var pluginMenuCommands: [PluginCommandRef] {
        _ = extensionsRevision
        let languageID = activeDocument?.language.id
        return PluginSnapshot.shared.commands.filter { reference in
            reference.command.languages.isEmpty || languageID.map { reference.command.languages.contains($0) } == true
        }
    }

    func appendPluginOutput(_ text: String, source: String) {
        taskRun.appendExternal(text, source: source)
        if bottomPane == .hidden { bottomPane = .output }
    }

    func runPluginCommand(_ reference: PluginCommandRef) {
        let command = reference.command
        let document = activeDocument
        var context = PluginRunner.Context(project: projectURL, file: document?.url, languageID: document?.language.id)
        var selectionRange: NSRange?
        var selectedText: String?
        weak var textView = NSApp.keyWindow?.firstResponder as? CodeTextView
        if let document, command.input == .selection || command.input == .buffer {
            let text = document.storage.string as NSString
            var range = document.selection
            if let textView, textView.textStorage === document.storage { range = textView.selectedRange() }
            if command.input == .buffer || range.length == 0 || NSMaxRange(range) > text.length { range = NSRange(location: 0, length: text.length) }
            selectionRange = range
            selectedText = text.substring(with: range)
            context.stdin = selectedText
        } else if command.input != .none, document == nil {
            editorNote = "\(command.title) needs an open file."; return
        }
        editorNote = "Running \(command.title)…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let outcome = try await PluginRunner.run(command.command, arguments: command.arguments, pluginDirectory: reference.directory, context: context)
                if outcome.timedOut { editorNote = "\(command.title) timed out after \(Int(PluginRunner.timeout)) s."; return }
                guard outcome.status == 0 else {
                    editorNote = "\(command.title) failed (exit \(outcome.status))."
                    appendPluginOutput(outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr, source: reference.pluginName)
                    return
                }
                switch command.output {
                case .none:
                    editorNote = "\(command.title) finished."
                case .show:
                    appendPluginOutput(outcome.stdout + (outcome.stderr.isEmpty ? "" : "\n" + outcome.stderr), source: reference.pluginName)
                    editorNote = "\(command.title) finished; see Output."
                case .replaceSelection, .insertAtCursor:
                    guard let document, let range = selectionRange, let original = selectedText else { editorNote = "\(command.title) needs an open file."; return }
                    let applied = applyPluginText(outcome.stdout, to: document, range: command.output == .insertAtCursor ? NSRange(location: NSMaxRange(range), length: 0) : range,
                                                  expecting: command.output == .insertAtCursor ? "" : original, textView: textView)
                    editorNote = applied ? "\(command.title) applied. ⌘Z undoes it." : "\(command.title): the text changed while it ran, so nothing was applied."
                }
            } catch {
                editorNote = "\(command.title): \(error.localizedDescription)"
            }
        }
    }

    /// Replaces through the text view when it is showing this document (so ⌘Z works), else
    /// through the storage; refuses when the range no longer holds what the plugin was given.
    @discardableResult
    func applyPluginText(_ text: String, to document: CodeDocument, range: NSRange, expecting original: String, textView: CodeTextView?) -> Bool {
        let storage = document.storage
        guard NSMaxRange(range) <= storage.length, (storage.string as NSString).substring(with: range) == original else { return false }
        if let textView, textView.textStorage === storage {
            return textView.replaceForInlineEdit(range: range, expecting: original, with: text)
        }
        storage.replaceCharacters(in: range, with: text)
        return true
    }

    /// After a successful save: run matching hooks; reload the document if a hook rewrote the file.
    func pluginsDidSave(_ document: CodeDocument) {
        let hooks = PluginSnapshot.shared.saveHooks.filter { $0.hook.languages.isEmpty || $0.hook.languages.contains(document.language.id) }
        guard !hooks.isEmpty else { return }
        let url = document.url
        let before = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let context = PluginRunner.Context(project: projectURL, file: url, languageID: document.language.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            for entry in hooks {
                do {
                    let outcome = try await PluginRunner.run(entry.hook.command, arguments: entry.hook.arguments, pluginDirectory: entry.directory, context: context)
                    if outcome.status != 0 || outcome.timedOut {
                        editorNote = "\(entry.pluginName) save hook \(outcome.timedOut ? "timed out" : "failed (exit \(outcome.status))")."
                        appendPluginOutput(outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr, source: entry.pluginName)
                    } else if !outcome.stdout.isEmpty {
                        appendPluginOutput(outcome.stdout, source: entry.pluginName)
                    }
                } catch {
                    editorNote = "\(entry.pluginName) save hook: \(error.localizedDescription)"
                }
            }
            let after = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if hooks.contains(where: { $0.hook.reloadIfChanged }), let before, let after, after != before, !document.isDirty {
                document.reload()
            }
        }
    }
}

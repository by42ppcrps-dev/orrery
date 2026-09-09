import Foundation
import Security

/// Connectors are MCP servers every agent gets. Add one once and Grok, Claude and Codex all
/// see it in their next sessions (Claude through `--mcp-config`, Codex through `-c
/// mcp_servers.*`, Grok through the ACP session). Import pulls in what the Claude Code and
/// Codex CLIs already have in their own configs, so the three agents connect to the same
/// things. Secret environment values (tokens, keys) live in the Keychain, never in the file.
struct Connector: Codable, Identifiable, Equatable {
    enum Transport: String, Codable, CaseIterable, Identifiable {
        case command, http, sse
        var id: String { rawValue }
        var title: String { self == .command ? "Command" : rawValue.uppercased() }
    }

    var id: String
    var name: String
    var transport: Transport = .command
    var command = ""
    var arguments: [String] = []
    var url = ""
    /// Plain environment; secret keys are listed in `secretKeys` and their values are in the Keychain.
    var environment: [String: String] = [:]
    var secretKeys: [String] = []
    var headers: [String: String] = [:]
    var providers: Set<Provider> = Set(Provider.allCases)
    var enabled = true
    /// "orrery" for hand-made ones, "claude" or "codex" when imported from that CLI's config.
    var source = "orrery"
    var note = ""

    init(id: String = UUID().uuidString, name: String, transport: Transport = .command, command: String = "", arguments: [String] = [],
         url: String = "", environment: [String: String] = [:], secretKeys: [String] = [], headers: [String: String] = [:],
         providers: Set<Provider> = Set(Provider.allCases), enabled: Bool = true, source: String = "orrery", note: String = "") {
        self.id = id; self.name = name; self.transport = transport; self.command = command; self.arguments = arguments
        self.url = url; self.environment = environment; self.secretKeys = secretKeys; self.headers = headers
        self.providers = providers; self.enabled = enabled; self.source = source; self.note = note
    }

    var summary: String {
        switch transport {
        case .command: return ([command] + arguments).joined(separator: " ")
        case .http, .sse: return url
        }
    }

    /// A usable name is required, and a command or a URL to match the transport.
    var problem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Give the connector a name." }
        if trimmed == "studio_computer" { return "studio_computer is reserved for the IDE." }
        if trimmed.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" && $0 != "." }) { return "Names use letters, digits, - _ and . only." }
        switch transport {
        case .command:
            if command.trimmingCharacters(in: .whitespaces).isEmpty { return "A command connector needs a command." }
        case .http, .sse:
            guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else { return "A remote connector needs an http(s) URL." }
        }
        return nil
    }

    /// Environment keys that look like credentials go to the Keychain.
    static func looksSecret(_ key: String) -> Bool {
        let upper = key.uppercased().replacingOccurrences(of: "-", with: "_")
        return upper == "KEY" || ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "APIKEY", "_KEY", "AUTH", "CREDENTIAL"].contains { upper.contains($0) }
    }
}

extension Connector {
    /// The MCP-config object for this connector. `secret` supplies the values kept out of the
    /// file; a secret that cannot be read is left out, so the server can say what it needs
    /// instead of being handed an empty string.
    func serverConfig(secret: (String) -> String?) -> [String: Any] {
        var config: [String: Any] = [:]
        switch transport {
        case .command:
            config["command"] = command
            config["args"] = arguments
            var resolved = environment
            for key in secretKeys { if let value = secret(key) { resolved[key] = value } }
            if !resolved.isEmpty { config["env"] = resolved }
        case .http, .sse:
            config["type"] = transport.rawValue
            config["url"] = url
            var resolved = headers
            for key in secretKeys { if let value = secret(key) { resolved[key] = value } }
            if !resolved.isEmpty { config["headers"] = resolved }
        }
        return config
    }
}

/// Secret values for connectors: the Keychain in the app, memory in headless runs.
struct ConnectorSecretStore: Sendable {
    var read: @Sendable (String) -> String?
    var write: @Sendable (String, String) throws -> Void
    var delete: @Sendable (String) -> Void

    static let service = "app.orrery.studio.connector"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static let keychain = ConnectorSecretStore(
        read: { account in
            KeychainAccess.read(service: service, account: account)
        },
        write: { account, value in
            KeychainAccess.forget(service: service, account: account)
            let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            let status = SecItemUpdate(base(account) as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                let added = SecItemAdd(base(account).merging(attributes) { _, new in new } as CFDictionary, nil)
                guard added == errSecSuccess else { throw ComputerError("The Keychain refused to store the value (\(added)).") }
            } else if status != errSecSuccess {
                throw ComputerError("The Keychain refused to update the value (\(status)).")
            }
        },
        delete: { account in
            KeychainAccess.forget(service: service, account: account)
            SecItemDelete(base(account) as CFDictionary)
        })

    /// Reads nothing: the empty snapshot before any list has been published.
    static let none = ConnectorSecretStore(read: { _ in nil }, write: { _, _ in }, delete: { _ in })

    static func memory() -> ConnectorSecretStore {
        final class Box: @unchecked Sendable { var values: [String: String] = [:]; let lock = NSLock() }
        let box = Box()
        return ConnectorSecretStore(
            read: { account in box.lock.lock(); defer { box.lock.unlock() }; return box.values[account] },
            write: { account, value in box.lock.lock(); box.values[account] = value; box.lock.unlock() },
            delete: { account in box.lock.lock(); box.values[account] = nil; box.lock.unlock() })
    }
}

/// The servers sessions actually receive, resolved with secrets, thread-safe like `PluginSnapshot`.
final class ConnectorSnapshot: @unchecked Sendable {
    static let empty = ConnectorSnapshot(byProvider: [:], secrets: ConnectorSecretStore.none)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: ConnectorSnapshot = .empty
    static var shared: ConnectorSnapshot { lock.lock(); defer { lock.unlock() }; return current }
    static func install(_ snapshot: ConnectorSnapshot) { lock.lock(); current = snapshot; lock.unlock() }

    private let byProvider: [Provider: [Connector]]
    private let secrets: ConnectorSecretStore
    /// Resolved values for this snapshot, misses included. The Keychain asks the user once when
    /// the app's signature is new to it; without this, every session start would ask again.
    private let cacheLock = NSLock()
    private var cache: [String: String?] = [:]
    private var reading: Set<String> = []

    init(byProvider: [Provider: [Connector]], secrets: ConnectorSecretStore) {
        self.byProvider = byProvider
        self.secrets = secrets
    }

    /// How long a secret read may take before the session starts without it. A Keychain read is
    /// instant unless macOS decides to ask the user (it does that when the app's signature is new
    /// to the item, which an ad-hoc rebuild makes it). That question must never freeze the IDE,
    /// so the read runs off this thread and the caller gives up on it.
    static var secretDeadline: TimeInterval = 3

    private func secret(_ id: String, _ key: String) -> String? {
        let account = id + "/" + key
        cacheLock.lock()
        if let known = cache[account] { cacheLock.unlock(); return known }
        if reading.contains(account) { cacheLock.unlock(); return nil }
        reading.insert(account)
        cacheLock.unlock()
        let box = ValueBox()
        let done = DispatchSemaphore(value: 0)
        let read = secrets.read
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let value = read(account)
            box.set(value)
            cacheLock.lock()
            cache.updateValue(value, forKey: account)
            reading.remove(account)
            cacheLock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.secretDeadline) == .success else {
            // The in-flight read owns its eventual result. Other sessions must not issue
            // duplicate Keychain requests while it finishes.
            return nil
        }
        let value = box.get()
        return value
    }

    private final class ValueBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ new: String?) { lock.lock(); value = new; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Servers for one provider, keyed by name, in the settings' "Additional MCP servers" shape.
    /// Secrets are read here, when a session is being started — not when the list was published.
    /// Without a provider (a settings object that is not bound to one) nothing is added: a
    /// connector limited to Codex must never reach Claude by accident.
    func servers(for provider: Provider?) -> [String: Any] {
        guard let provider, let connectors = byProvider[provider] else { return [:] }
        var result: [String: Any] = [:]
        for connector in connectors {
            guard connector.secretKeys.allSatisfy({ secret(connector.id, $0) != nil }) else { continue }
            result[connector.name] = connector.serverConfig { secret(connector.id, $0) }
        }
        return result
    }

    /// The names a provider would get, without reading any secret. For anything that only needs
    /// to know which connectors apply.
    func names(for provider: Provider?) -> [String] {
        guard let provider else { return [] }
        return (byProvider[provider] ?? []).map(\.name).sorted()
    }
}

@MainActor @Observable
final class ConnectorStore {
    static let shared = ConnectorStore()
    private(set) var connectors: [Connector] = []
    private(set) var lastError: String?
    private let directory: URL
    private let secrets: ConnectorSecretStore

    init(directory: URL = PrivateProjectFile.defaultDirectory("Connectors"), secrets: ConnectorSecretStore? = nil) {
        self.directory = directory
        self.secrets = secrets ?? (AppModel.persistsPreferences ? .keychain : .memory())
        load()
    }

    var fileURL: URL { directory.appendingPathComponent("connectors.json") }

    func load() {
        if let data = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([Connector].self, from: data) { connectors = list }
        installSnapshot()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(connectors)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastError = nil
        } catch { lastError = "Connectors could not be saved: \(error.localizedDescription)" }
        installSnapshot()
    }

    // MARK: Editing

    /// Adds or replaces (by id) a connector; secret values are taken from `secretValues` and
    /// stored in the Keychain, never in the connector itself.
    @discardableResult
    func upsert(_ connector: Connector, secretValues: [String: String] = [:]) -> Bool {
        var clean = connector
        guard clean.problem == nil else { lastError = clean.problem; return false }
        for key in clean.secretKeys {
            clean.environment.removeValue(forKey: key)
            clean.headers.removeValue(forKey: key)
        }
        do {
            for (key, value) in secretValues where clean.secretKeys.contains(key) && !value.isEmpty {
                try secrets.write(account(clean.id, key), value)
            }
        } catch {
            lastError = "Credentials could not be saved to the Keychain. The connector was not changed."
            return false
        }
        if let index = connectors.firstIndex(where: { $0.id == clean.id }) { connectors[index] = clean } else { connectors.append(clean) }
        save()
        return lastError == nil
    }

    func unlockWithDeviceAuthentication() async -> CredentialUnlock.Result {
        let items = connectors.filter(\.enabled).flatMap { connector in
            connector.secretKeys.map { CredentialUnlock.Item(service: ConnectorSecretStore.service, account: connector.id + "/" + $0) }
        }
        let result = await CredentialUnlock.unlock(items)
        installSnapshot()
        return result
    }

    /// Invoked by a person from Connections, never by startup or an agent tool call.
    func unlockCredentials() async -> String {
        let accounts = connectors.filter(\.enabled).flatMap { connector in connector.secretKeys.map { connector.id + "/" + $0 } }
        let count = await Task.detached {
            var unlocked = 0
            for account in accounts {
                if KeychainAccess.read(service: ConnectorSecretStore.service, account: account, interactive: true) != nil { unlocked += 1 }
                else { break } // Cancel means stop; never fan out more system prompts.
            }
            return unlocked
        }.value
        installSnapshot()
        return count == accounts.count ? "Saved credentials are available. Start a new agent session to reconnect." : "Some credentials remain locked. Existing connections and the saved keys were kept."
    }

    func remove(_ id: String) {
        if let connector = connectors.first(where: { $0.id == id }) {
            for key in connector.secretKeys { secrets.delete(account(id, key)) }
        }
        connectors.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = connectors.firstIndex(where: { $0.id == id }) else { return }
        connectors[index].enabled = enabled
        save()
    }

    func setProviders(_ providers: Set<Provider>, id: String) {
        guard let index = connectors.firstIndex(where: { $0.id == id }) else { return }
        connectors[index].providers = providers
        save()
    }

    func hasSecret(_ id: String, key: String) -> Bool { secrets.read(account(id, key)) != nil }

    func checkSetup(_ connector: Connector) -> String {
        if let problem = connector.problem { return problem }
        if connector.providers.isEmpty { return "Choose at least one agent for this connection." }
        if connector.transport == .command, Executables.find([connector.command], orNamed: connector.command) == nil {
            return "Install \(connector.command), or choose its full path in Edit."
        }
        if !connector.secretKeys.allSatisfy({ hasSecret(connector.id, key: $0) }) {
            return "Unlock saved credentials, or add the missing value in Edit."
        }
        return connector.enabled ? "Setup ready. Start a new agent session to connect; the server may still require a sign-in." : "Setup ready. Enable the connection when you want to use it."
    }

    private func account(_ id: String, _ key: String) -> String { id + "/" + key }

    // MARK: What sessions receive

    /// The MCP-config object for one connector, secrets resolved.
    func serverConfig(_ connector: Connector) -> [String: Any] {
        connector.serverConfig { secrets.read(account(connector.id, $0)) }
    }

    /// Publishes the list agents read. Secrets are **not** read here: the snapshot resolves them
    /// when a session actually asks for its servers, so opening Orrery never touches the
    /// Keychain (an ad-hoc rebuild would otherwise ask for the login password at launch).
    func installSnapshot() {
        var byProvider: [Provider: [Connector]] = [:]
        for connector in connectors where connector.enabled && connector.problem == nil {
            for provider in connector.providers { byProvider[provider, default: []].append(connector) }
        }
        ConnectorSnapshot.install(ConnectorSnapshot(byProvider: byProvider, secrets: secrets))
    }

    // MARK: Import from the CLIs

    /// Adds what the CLIs already have; an entry with the same name and source is refreshed,
    /// not duplicated. Returns a short report.
    @discardableResult
    func importFromCLIs(project: URL?, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> String {
        let found = ConnectorImport.discover(project: project, home: home)
        guard !found.isEmpty else { return "Nothing to import: the Claude Code and Codex configs on this Mac have no MCP servers." }
        var added = 0, refreshed = 0
        for (connector, secretValues) in found {
            if let existing = connectors.first(where: { $0.name == connector.name && $0.source == connector.source }) {
                var updated = connector
                updated.id = existing.id
                updated.providers = existing.providers
                updated.enabled = existing.enabled
                upsert(updated, secretValues: secretValues)
                refreshed += 1
            } else {
                upsert(connector, secretValues: secretValues)
                added += 1
            }
        }
        return "Imported \(added) connector\(added == 1 ? "" : "s")\(refreshed > 0 ? ", refreshed \(refreshed)" : "") from the CLIs' own configs."
    }
}

// MARK: - Reading the CLIs' configs

enum ConnectorImport {
    /// Everything the Claude Code and Codex configs list. Values that look like credentials are
    /// returned separately so the store can put them in the Keychain.
    static func discover(project: URL?, home: URL) -> [(Connector, [String: String])] {
        var result: [(Connector, [String: String])] = []
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")), let json = JSON(data: data) {
            result += fromClaude(json, project: project)
        }
        if let project, let data = try? Data(contentsOf: project.appendingPathComponent(".mcp.json")), let json = JSON(data: data) {
            result += fromClaude(JSON(["mcpServers": json["mcpServers"].raw ?? [:]]), project: nil, source: "claude", note: "from this project's .mcp.json")
        }
        if let toml = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) {
            result += fromCodex(toml)
        }
        return result
    }

    /// `~/.claude.json`: user-scope `mcpServers`, plus the current project's entry.
    static func fromClaude(_ json: JSON, project: URL?, source: String = "claude", note: String = "from Claude Code's config") -> [(Connector, [String: String])] {
        var result: [(Connector, [String: String])] = []
        var scopes: [([String: Any], String)] = []
        if let user = json["mcpServers"].raw as? [String: Any] { scopes.append((user, note)) }
        if let project, let projects = json["projects"].raw as? [String: Any] {
            for (path, value) in projects {
                guard URL(fileURLWithPath: path).standardizedFileURL == project.standardizedFileURL,
                      let servers = (value as? [String: Any])?["mcpServers"] as? [String: Any] else { continue }
                scopes.append((servers, "from Claude Code's config for this project"))
            }
        }
        for (servers, scopeNote) in scopes {
            for (name, raw) in servers {
                guard let server = raw as? [String: Any] else { continue }
                if let made = make(name: name, server: server, source: source, note: scopeNote) { result.append(made) }
            }
        }
        return result
    }

    /// `~/.codex/config.toml`: `[mcp_servers.NAME]` tables with `[mcp_servers.NAME.env]`.
    static func fromCodex(_ toml: String) -> [(Connector, [String: String])] {
        let tables = TOMLTables.parse(toml)
        var result: [(Connector, [String: String])] = []
        for (path, values) in tables where path.count == 2 && path[0] == "mcp_servers" {
            let name = path[1]
            var server = values
            if let env = tables[["mcp_servers", name, "env"]] { server["env"] = env }
            if let enabled = values["enabled"] as? Bool, !enabled { continue }
            guard var made = make(name: name, server: server, source: "codex", note: "from Codex's config") else { continue }
            // Servers that belong to the Codex app itself (its bundled node runtime, its computer-use
            // client) only make sense for Codex.
            let command = made.0.command
            if command.hasPrefix("/Applications/ChatGPT.app") || command.hasPrefix("./") || command.contains("/.codex/") || (server["env"] as? [String: Any])?["CODEX_HOME"] != nil {
                made.0.providers = [.codex]
                made.0.note += " · part of the Codex app, so Codex only"
            }
            result.append(made)
        }
        return result
    }

    private static func make(name: String, server: [String: Any], source: String, note: String) -> (Connector, [String: String])? {
        var secretValues: [String: String] = [:]
        if let command = server["command"] as? String, !command.isEmpty {
            var environment: [String: String] = [:]
            var secretKeys: [String] = []
            for (key, value) in server["env"] as? [String: Any] ?? [:] {
                let text = value as? String ?? "\(value)"
                if Connector.looksSecret(key) { secretKeys.append(key); secretValues[key] = text } else { environment[key] = text }
            }
            let connector = Connector(name: name, transport: .command, command: command, arguments: server["args"] as? [String] ?? [],
                                      environment: environment, secretKeys: secretKeys.sorted(), source: source, note: note)
            return connector.problem == nil ? (connector, secretValues) : nil
        }
        if let url = server["url"] as? String, !url.isEmpty {
            let type = (server["type"] as? String)?.lowercased() == "sse" ? Connector.Transport.sse : .http
            var headers: [String: String] = [:]
            var secretKeys: [String] = []
            for (key, value) in server["headers"] as? [String: Any] ?? [:] {
                let text = value as? String ?? "\(value)"
                if Connector.looksSecret(key) || text.lowercased().hasPrefix("bearer ") { secretKeys.append(key); secretValues[key] = text } else { headers[key] = text }
            }
            let connector = Connector(name: name, transport: type, url: url, secretKeys: secretKeys.sorted(), headers: headers, source: source, note: note)
            return connector.problem == nil ? (connector, secretValues) : nil
        }
        return nil
    }

    struct Template: Identifiable {
        let id: String
        let name: String
        let description: String
        let connector: Connector
        let secretPrompt: String?
    }

    /// A few well-known servers, prefilled; the user still reviews the form before adding.
    static let catalog: [Template] = [
        Template(id: "filesystem", name: "Filesystem", description: "Read and write files in a folder you choose (the project by default).",
                 connector: Connector(name: "filesystem", command: "npx", arguments: ["-y", "@modelcontextprotocol/server-filesystem", "."]), secretPrompt: nil),
        Template(id: "github", name: "GitHub", description: "Issues, pull requests and repositories through the official GitHub MCP server.",
                 connector: Connector(name: "github", command: "npx", arguments: ["-y", "@modelcontextprotocol/server-github"], secretKeys: ["GITHUB_PERSONAL_ACCESS_TOKEN"]),
                 secretPrompt: "GITHUB_PERSONAL_ACCESS_TOKEN"),
        Template(id: "fetch", name: "Fetch", description: "Fetch web pages as text for the agent to read.",
                 connector: Connector(name: "fetch", command: "uvx", arguments: ["mcp-server-fetch"]), secretPrompt: nil),
        Template(id: "playwright", name: "Playwright browser", description: "Drive a real browser through Playwright.",
                 connector: Connector(name: "playwright", command: "npx", arguments: ["@playwright/mcp@latest"]), secretPrompt: nil),
        Template(id: "memory", name: "Memory", description: "A small knowledge graph the agents can remember things in.",
                 connector: Connector(name: "memory", command: "npx", arguments: ["-y", "@modelcontextprotocol/server-memory"]), secretPrompt: nil),
        Template(id: "cloudflare-docs", name: "Cloudflare docs", description: "Cloudflare's documentation server (remote, no sign-in).",
                 connector: Connector(name: "cloudflare-docs", transport: .http, url: "https://docs.mcp.cloudflare.com/mcp"), secretPrompt: nil),
    ]
}

/// The little TOML the Codex CLI writes: `[a.b]` / `[a.b.c]` tables, `key = "string"`,
/// `key = ["a", "b"]`, `key = true`, `key = 12`. Enough to read `mcp_servers`.
enum TOMLTables {
    static func parse(_ text: String) -> [[String]: [String: Any]] {
        var tables: [[String]: [String: Any]] = [:]
        var current: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]"), !line.hasPrefix("[[") {
                current = String(line.dropFirst().dropLast()).split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                if tables[current] == nil { tables[current] = [:] }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, let parsed = parseValue(value) else { continue }
            tables[current, default: [:]][key] = parsed
        }
        return tables
    }

    private static func parseValue(_ text: String) -> Any? {
        if text == "true" { return true }
        if text == "false" { return false }
        if let number = Double(text) { return number.truncatingRemainder(dividingBy: 1) == 0 ? Int(number) : number }
        if text.hasPrefix("\"") || text.hasPrefix("'") {
            let quote = text.first!
            guard let end = text.dropFirst().firstIndex(of: quote) else { return nil }
            return String(text[text.index(after: text.startIndex)..<end])
        }
        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = text.dropFirst().dropLast()
            var items: [String] = []
            var buffer = ""
            var quote: Character?
            for character in inner {
                if let open = quote {
                    if character == open { quote = nil; items.append(buffer); buffer = "" } else { buffer.append(character) }
                } else if character == "\"" || character == "'" { quote = character }
            }
            return items
        }
        return nil
    }
}

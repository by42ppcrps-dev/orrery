import Foundation

struct LSPCompletionItem: Equatable {
    var label: String
    var detail: String?
    var kind: String
    var insertText: String
    var editRange: NSRange?
    var sortText: String?
}

struct LSPLocation: Equatable {
    var url: URL
    var line: Int
    var column: Int
}

/// Distinguishes a genuine empty reply from "no server", a timeout, or an error.
/// Empty `value` plus `outcome == .success` is a clean miss; a timeout must not look like one.
enum LSPQueryOutcome: Equatable {
    case success
    case noServer
    case timedOut
    case error
}

struct LSPQueryResult<Value: Equatable>: Equatable {
    var value: Value
    var outcome: LSPQueryOutcome
    var note: String?
}

/// One language server per (language family, project root), started lazily on first use.
///
/// Swift → sourcekit-lsp; C / C++ / Objective-C → clangd. Every other language reports
/// "no language server wired" rather than a silent empty completion list. Diagnostics
/// published by a live server replace the one-shot checker results for that document.
@MainActor
final class LSPManager {
    static let changeDebounceSeconds: Double = 0.3

    var onDiagnostics: ((URL, [Diagnostic]) -> Void)?
    /// `server` is the display name (`sourcekit-lsp` / `clangd`); nil means the document is
    /// no longer live-covered (closed, or the child died).
    var onCoverageChange: ((URL, String?) -> Void)?
    /// Named failure for the notes channel. Never a silent empty list.
    var onFailureNote: ((URL, String) -> Void)?

    /// Test seam so the audit can exercise the missing-binary path without hiding /usr/bin.
    var executableOverride: ((Language) -> String?)?
    /// Test seam: awaited at the start of `startSession` after the epoch check. Production is nil.
    var auditBeforeStartSession: (() async -> Void)?
    /// Test seam: process arguments replacing the server-specific ones. Production is nil.
    var auditProcessArguments: [String]?
    /// Test seam: skip initialize/initialized so a dummy child can stand in for a server.
    var auditSkipHandshake = false
    /// Test seam: awaited after `sessions[key] = session` and before `initialize`. Production is nil.
    var auditAfterSessionStored: (() async -> Void)?

    private struct Key: Hashable {
        var kind: ServerKind
        var root: URL
    }

    /// Raw values are the display names. Servers beyond the two Apple toolchain ones are used
    /// only when their binary is installed; otherwise the language reports the missing name.
    /// A language server: its display name (also the audit's name), the executable's usual
    /// locations and PATH name, and the arguments that make it speak LSP over stdio. Built-in
    /// servers are the static members; the registry adds its own.
    struct ServerKind: Hashable {
        let rawValue: String
        let arguments: [String]
        let paths: [String]
        let executableName: String

        init(_ name: String, arguments: [String] = [], paths: [String] = [], executableName: String? = nil) {
            self.rawValue = name
            self.arguments = arguments
            self.paths = paths
            self.executableName = executableName ?? name
        }

        var candidates: (paths: [String], name: String) { (paths, executableName) }

        private static let home = NSHomeDirectory()
        private static func brew(_ name: String) -> [String] { ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] }

        static let sourcekit = ServerKind("sourcekit-lsp", paths: LSPManager.sourcekitCandidates)
        static let clangd = ServerKind("clangd", arguments: ["--background-index=false", "--clang-tidy=false"], paths: LSPManager.clangdCandidates)
        static let gopls = ServerKind("gopls", paths: ["\(home)/go/bin/gopls"] + brew("gopls"))
        static let rustAnalyzer = ServerKind("rust-analyzer", paths: ["\(home)/.cargo/bin/rust-analyzer"] + brew("rust-analyzer"))
        static let pyright = ServerKind("pyright-langserver", arguments: ["--stdio"], paths: brew("pyright-langserver") + ["\(home)/.local/bin/pyright-langserver"])
        static let typescript = ServerKind("typescript-language-server", arguments: ["--stdio"], paths: brew("typescript-language-server"))
        static let lua = ServerKind("lua-language-server", paths: brew("lua-language-server"))
        static let zls = ServerKind("zls", paths: brew("zls") + ["\(home)/.local/bin/zls"])
        static let solargraph = ServerKind("solargraph", arguments: ["stdio"], paths: brew("solargraph"))
        static let dart = ServerKind("dart language-server", arguments: ["language-server", "--protocol=lsp"], paths: brew("dart"), executableName: "dart")
        static let haskell = ServerKind("haskell-language-server", arguments: ["--lsp"], paths: ["\(home)/.ghcup/bin/haskell-language-server-wrapper"] + brew("haskell-language-server-wrapper"), executableName: "haskell-language-server-wrapper")
        static let kotlin = ServerKind("kotlin-language-server", paths: brew("kotlin-language-server"))
        static let bash = ServerKind("bash-language-server", arguments: ["start"], paths: brew("bash-language-server"))
        static let fortls = ServerKind("fortls", paths: brew("fortls") + ["\(home)/.local/bin/fortls"])
        static let nim = ServerKind("nimlangserver", paths: ["\(home)/.nimble/bin/nimlangserver"] + brew("nimlangserver"))
        static let crystalline = ServerKind("crystalline", arguments: ["--stdio"], paths: brew("crystalline"))
        static let texlab = ServerKind("texlab", paths: brew("texlab") + ["\(home)/.cargo/bin/texlab"])
        static let solidity = ServerKind("nomicfoundation-solidity-language-server", arguments: ["--stdio"], paths: brew("nomicfoundation-solidity-language-server"))
        static let ada = ServerKind("ada_language_server", paths: brew("ada_language_server") + ["\(home)/.alire/bin/ada_language_server"])
        static let pascal = ServerKind("pasls", paths: brew("pasls"))
        static let cmake = ServerKind("cmake-language-server", paths: brew("cmake-language-server") + ["\(home)/.local/bin/cmake-language-server"])
        static let verible = ServerKind("verible-verilog-ls", paths: brew("verible-verilog-ls"))
        static let vhdl = ServerKind("vhdl_ls", paths: brew("vhdl_ls") + ["\(home)/.cargo/bin/vhdl_ls"])

        /// A server the registry described for a language id.
        static func registry(_ description: RegistrySnapshot.ServerDescription) -> ServerKind {
            let command = description.command
            return ServerKind(description.name, arguments: description.arguments,
                              paths: command.hasPrefix("/") ? [command] : [],
                              executableName: command.hasPrefix("/") ? (command as NSString).lastPathComponent : command)
        }
    }

    private final class Session {
        let key: Key
        let name: String
        let client: LSPClient
        var initializeResult: JSON?
        var documents: [URL: OpenDoc] = [:]
        var dead = false

        init(key: Key, name: String, client: LSPClient) {
            self.key = key
            self.name = name
            self.client = client
        }
    }

    private struct OpenDoc {
        var version: Int
        var languageId: String
        var debounce: Task<Void, Never>?
        var pendingText: String?
    }

    private var sessions: [Key: Session] = [:]
    private var starting: [Key: Task<Session?, Never>] = [:]
    private var epoch = 0
    /// Strong refs for sessions the audit detached from the map so their delayed
    /// `onExit` can still run `handleDeath` (production: `shutdown()` holds them in `all`).
    private var auditRetainedSessions: [Session] = []
    /// Bumped on ensureOpen and didClose so a handshake that finishes after the tab
    /// closed cannot `didOpen` a document the user already left.
    private var openGeneration: [URL: Int] = [:]

    func isSupported(_ language: Language) -> Bool {
        Self.kind(for: language) != nil
    }

    /// nil when a live server covers this language; otherwise the honest "no language server wired" / "binary missing" sentence.
    func unavailableNote(for language: Language) -> String? {
        guard let kind = Self.kind(for: language) else {
            return "No language server wired for \(language.name)."
        }
        if isLive(kind) { return nil }
        if executable(for: language) == nil {
            return Self.missingNote(server: kind.rawValue)
        }
        return "\(kind.rawValue) is not running. An empty list here is not a clean bill of health."
    }

    /// Ensures a server for this document's (language, root) is started and the document is open on it.
    func ensureOpen(_ document: CodeDocument, root: URL) async {
        guard document.isReadable else { return }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let docURL = document.url.resolvingSymlinksInPath().standardizedFileURL
        let generation = (openGeneration[docURL] ?? 0) + 1
        openGeneration[docURL] = generation
        guard let kind = Self.kind(for: document.language) else {
            if let note = unavailableNote(for: document.language) {
                onFailureNote?(document.url, note)
            }
            return
        }
        if executable(for: document.language) == nil {
            onFailureNote?(document.url, Self.missingNote(server: kind.rawValue))
            return
        }
        let captured = epoch
        guard let session = await session(kind: kind, root: root, language: document.language) else {
            if captured == epoch, openGeneration[docURL] == generation {
                onFailureNote?(document.url, Self.stoppedNote(server: kind.rawValue))
            }
            return
        }
        guard captured == epoch, !session.dead, openGeneration[docURL] == generation else { return }
        open(document, on: session)
    }

    func didChange(_ document: CodeDocument) {
        guard let session = session(containing: document.url) else { return }
        guard var open = session.documents[document.url] else { return }
        open.version += 1
        open.pendingText = document.text
        open.debounce?.cancel()
        let url = document.url
        let version = open.version
        let text = document.text
        open.debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds:
                UInt64(Self.changeDebounceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.sendDidChange(url, version: version, text: text, on: session)
        }
        session.documents[document.url] = open
    }

    /// Sends any pending didChange immediately so the audit does not wait out the debounce.
    /// No-ops when nothing is pending, so a second hover/completion does not reuse a version.
    func flush(_ document: CodeDocument) {
        guard let session = session(containing: document.url),
              var open = session.documents[document.url] else { return }
        open.debounce?.cancel()
        open.debounce = nil
        guard let text = open.pendingText else {
            session.documents[document.url] = open
            return
        }
        open.pendingText = nil
        session.documents[document.url] = open
        sendDidChange(document.url, version: open.version, text: text, on: session)
    }

    func didClose(_ document: CodeDocument) {
        let docURL = document.url.resolvingSymlinksInPath().standardizedFileURL
        openGeneration[docURL] = (openGeneration[docURL] ?? 0) + 1
        guard let session = session(containing: document.url),
              let open = session.documents.removeValue(forKey: document.url) else {
            onCoverageChange?(document.url, nil)
            return
        }
        open.debounce?.cancel()
        session.client.notify("textDocument/didClose", [
            "textDocument": ["uri": LSPMapping.uri(for: document.url)],
        ])
        onCoverageChange?(document.url, nil)
    }

    /// Seconds allowed for completion / hover / definition. Production is 5; the audit shortens it.
    var queryDeadline: TimeInterval = 5

    /// line/column are 1-based, matching Diagnostic.
    func completions(for document: CodeDocument, line: Int, column: Int) async -> LSPQueryResult<[LSPCompletionItem]> {
        flush(document)
        guard let session = liveSession(for: document) else {
            return noServerResult([], language: document.language)
        }
        do {
            let result = try await session.client.request(
                "textDocument/completion",
                positionParams(document, line: line, column: column),
                deadline: queryDeadline)
            let items = LSPMapping.completions(from: result, text: document.text)
            return LSPQueryResult(value: items, outcome: .success, note: nil)
        } catch {
            return queryFailure([], error: error)
        }
    }

    func hover(for document: CodeDocument, line: Int, column: Int) async -> LSPQueryResult<String?> {
        flush(document)
        guard let session = liveSession(for: document) else {
            return noServerResult(nil, language: document.language)
        }
        do {
            let result = try await session.client.request(
                "textDocument/hover",
                positionParams(document, line: line, column: column),
                deadline: queryDeadline)
            return LSPQueryResult(value: LSPMapping.hoverText(from: result), outcome: .success, note: nil)
        } catch {
            return queryFailure(nil, error: error)
        }
    }

    func definition(for document: CodeDocument, line: Int, column: Int) async -> LSPQueryResult<LSPLocation?> {
        flush(document)
        guard let session = liveSession(for: document) else {
            return noServerResult(nil, language: document.language)
        }
        do {
            let result = try await session.client.request(
                "textDocument/definition",
                positionParams(document, line: line, column: column),
                deadline: queryDeadline)
            return LSPQueryResult(value: LSPMapping.definition(from: result), outcome: .success, note: nil)
        } catch {
            return queryFailure(nil, error: error)
        }
    }

    private func noServerResult<Value: Equatable>(_ empty: Value,
                                                  language: Language) -> LSPQueryResult<Value> {
        let note = unavailableNote(for: language)
            ?? "No language server is running for this file."
        return LSPQueryResult(value: empty, outcome: .noServer, note: note)
    }

    private func queryFailure<Value: Equatable>(_ empty: Value,
                                                error: Error) -> LSPQueryResult<Value> {
        if let lsp = error as? LSPError {
            switch lsp {
            case .timedOut:
                return LSPQueryResult(value: empty, outcome: .timedOut,
                                      note: lsp.errorDescription ?? "The language server timed out.")
            default:
                return LSPQueryResult(value: empty, outcome: .error,
                                      note: lsp.errorDescription ?? error.localizedDescription)
            }
        }
        return LSPQueryResult(value: empty, outcome: .error, note: error.localizedDescription)
    }

    /// Graceful `shutdown`/`exit` per child, then SIGTERM/SIGKILL. Window close cannot
    /// await the handshake, so this returns immediately and the sequence runs in a Task.
    func shutdownAll() {
        epoch += 1
        let all = Array(sessions.values) + auditRetainedSessions
        auditRetainedSessions.removeAll()
        sessions.removeAll()
        starting.removeAll()
        for session in all {
            for url in session.documents.keys { onCoverageChange?(url, nil) }
            session.documents.removeAll()
            Task { await session.client.shutdown() }
        }
    }

    /// Protocol `shutdown`/`exit` then reap. Used by the audit so children do not leak.
    func shutdown() async {
        epoch += 1
        let all = Array(sessions.values) + auditRetainedSessions
        auditRetainedSessions.removeAll()
        sessions.removeAll()
        starting.removeAll()
        for session in all {
            for url in session.documents.keys { onCoverageChange?(url, nil) }
            session.documents.removeAll()
            await session.client.shutdown()
        }
    }

    func childProcessID(for document: CodeDocument) -> Int32? {
        session(containing: document.url)?.client.processIdentifier
    }

    func initializeResult(for document: CodeDocument) -> JSON? {
        session(containing: document.url)?.initializeResult
    }

    func isServerRunning(for document: CodeDocument) -> Bool {
        session(containing: document.url)?.client.isRunning == true
    }

    func client(for document: CodeDocument) -> LSPClient? {
        liveSession(for: document)?.client
    }

    func hasPendingChange(for document: CodeDocument) -> Bool {
        session(containing: document.url)?.documents[document.url]?.pendingText != nil
    }

    var hasActiveOrStartingServer: Bool {
        !starting.isEmpty || sessions.values.contains { !$0.dead }
    }

    /// Test seam: true while a start task for this (language, root) occupies the slot.
    func auditHasStartingTask(language: Language, root: URL) -> Bool {
        guard let kind = Self.kind(for: language) else { return false }
        let key = Key(kind: kind, root: root.resolvingSymlinksInPath().standardizedFileURL)
        return starting[key] != nil
    }

    /// Test seam: identity of the live session covering this document, if any.
    func auditSessionIdentity(for document: CodeDocument) -> ObjectIdentifier? {
        session(containing: document.url).map { ObjectIdentifier($0) }
    }

    /// Test seam: drop this session from the map without running `handleDeath`, so a
    /// replacement can start while the old client's `onExit` is still pending.
    func auditDetachSession(for document: CodeDocument) {
        guard let session = session(containing: document.url) else { return }
        if sessions[session.key] === session {
            auditRetainedSessions.append(session)
            sessions[session.key] = nil
        }
    }

    // MARK: - Servers

    private static func kind(for language: Language) -> ServerKind? {
        if let described = RegistrySnapshot.shared.servers[language.id] { return .registry(described) }
        switch language.id {
        case "swift": return .sourcekit
        case "c", "cpp", "objc": return .clangd
        case "go": return .gopls
        case "rust": return .rustAnalyzer
        case "python": return .pyright
        case "javascript", "typescript": return .typescript
        case "lua": return .lua
        case "zig": return .zls
        case "ruby": return .solargraph
        case "dart": return .dart
        case "haskell": return .haskell
        case "kotlin": return .kotlin
        case "shell": return .bash
        case "fortran": return .fortls
        case "nim": return .nim
        case "crystal": return .crystalline
        case "latex": return .texlab
        case "solidity": return .solidity
        case "ada": return .ada
        case "pascal": return .pascal
        case "cmake": return .cmake
        case "verilog": return .verible
        case "vhdl": return .vhdl
        default: return nil
        }
    }

    /// The server's display name for a language, for audits and status text.
    static func serverName(for language: Language) -> String? { kind(for: language)?.rawValue }

    private static func languageId(for language: Language) -> String {
        switch language.id {
        case "swift": return "swift"
        case "c": return "c"
        case "cpp": return "cpp"
        case "objc": return "objective-c"
        case "shell": return "shellscript"
        case "verilog": return "systemverilog"
        default: return language.id
        }
    }

    nonisolated private static let sourcekitCandidates = [
        "/usr/bin/sourcekit-lsp",
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp",
    ]
    nonisolated private static let clangdCandidates = [
        "/usr/bin/clangd",
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clangd",
        "/opt/homebrew/bin/clangd",
        "/usr/local/bin/clangd",
    ]

    func executable(for language: Language) -> String? {
        if let executableOverride { return executableOverride(language) }
        guard let kind = Self.kind(for: language) else { return nil }
        let candidates = kind.candidates
        return Executables.find(candidates.paths, orNamed: candidates.name)
    }

    private func session(kind: ServerKind, root: URL, language: Language) async -> Session? {
        let key = Key(kind: kind, root: root)
        if let existing = sessions[key] {
            if !existing.dead, existing.client.isRunning { return existing }
            sessions[key] = nil
        }
        if let task = starting[key] {
            return await task.value
        }
        let captured = epoch
        let task = Task<Session?, Never> { [weak self] in
            await self?.startSession(kind: kind, root: root, language: language, epoch: captured)
        }
        starting[key] = task
        let session = await task.value
        // A waiter only clears the slot it owns. After shutdown + restart, epoch no
        // longer matches and a newer start task must stay.
        if epoch == captured {
            starting[key] = nil
        }
        return session
    }

    private func startSession(kind: ServerKind, root: URL, language: Language,
                              epoch captured: Int) async -> Session? {
        let key = Key(kind: kind, root: root)
        guard captured == epoch else { return nil }
        if let auditBeforeStartSession {
            await auditBeforeStartSession()
            guard captured == epoch else { return nil }
        }
        guard let path = executable(for: language) else {
            return nil
        }
        let client = LSPClient()
        let session = Session(key: key, name: kind.rawValue, client: client)
        client.onNotification = { [weak self, weak session] method, params in
            guard let self, let session else { return }
            self.handleNotification(method, params, session: session)
        }
        client.onExit = { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.handleDeath(of: session)
        }
        var arguments: [String] = []
        if let auditProcessArguments {
            arguments = auditProcessArguments
        } else if kind == .sourcekit {
            let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("orrery-lsp-\(ProcessInfo.processInfo.processIdentifier)")
                .appendingPathComponent(String(root.path.hashValue))
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            arguments = ["--scratch-path", scratch.path]
        } else {
            arguments = kind.arguments
        }
        do {
            try client.start(executable: path, arguments: arguments, cwd: root)
        } catch {
            noteFailure(session, extra: error.localizedDescription)
            return nil
        }
        guard captured == epoch else {
            client.stop()
            return nil
        }
        sessions[key] = session
        if auditSkipHandshake {
            session.initializeResult = JSON(["capabilities": [:] as [String: Any]])
            return session
        }
        if let auditAfterSessionStored {
            await auditAfterSessionStored()
        }
        let params = Self.initializeParams(root: root)
        do {
            let result = try await client.request("initialize", params, deadline: 12)
            guard captured == epoch, !session.dead else {
                client.stop()
                if sessions[key] === session {
                    sessions[key] = nil
                }
                return nil
            }
            session.initializeResult = result
            client.notify("initialized", [:])
            return session
        } catch {
            if sessions[key] === session {
                sessions[key] = nil
                noteFailure(session, extra: error.localizedDescription)
            }
            await client.shutdown()
            return nil
        }
    }

    static func initializeParams(root: URL) -> [String: Any] {
        let rootURI = LSPMapping.uri(for: root)
        return [
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "rootUri": rootURI,
            "rootPath": root.path,
            "clientInfo": ["name": "Orrery", "version": "0.1"],
            "capabilities": [
                "workspace": [
                    "workspaceFolders": true,
                    "configuration": true,
                    "didChangeConfiguration": ["dynamicRegistration": false],
                    "applyEdit": false,
                ],
                "textDocument": [
                    "synchronization": [
                        "dynamicRegistration": false,
                        "willSave": false,
                        "willSaveWaitUntil": false,
                        "didSave": false,
                    ],
                    "publishDiagnostics": ["relatedInformation": false],
                    "completion": [
                        "dynamicRegistration": false,
                        "completionItem": [
                            "snippetSupport": false,
                            "documentationFormat": ["plaintext", "markdown"],
                        ],
                        "contextSupport": true,
                    ],
                    "hover": [
                        "dynamicRegistration": false,
                        "contentFormat": ["markdown", "plaintext"],
                    ],
                    "definition": [
                        "dynamicRegistration": false,
                        "linkSupport": true,
                    ],
                ],
                "window": ["workDoneProgress": true],
            ],
            "workspaceFolders": [
                ["uri": rootURI, "name": root.lastPathComponent],
            ],
        ]
    }

    private func open(_ document: CodeDocument, on session: Session) {
        let url = document.url
        if session.documents[url] != nil {
            onCoverageChange?(url, session.name)
            return
        }
        let languageId = Self.languageId(for: document.language)
        session.documents[url] = OpenDoc(version: 1, languageId: languageId,
                                         debounce: nil, pendingText: nil)
        session.client.notify("textDocument/didOpen", [
            "textDocument": [
                "uri": LSPMapping.uri(for: url),
                "languageId": languageId,
                "version": 1,
                "text": document.text,
            ],
        ])
        onCoverageChange?(url, session.name)
    }

    private func sendDidChange(_ url: URL, version: Int, text: String, on session: Session) {
        guard session.documents[url] != nil, session.client.isRunning else { return }
        if var open = session.documents[url] {
            open.pendingText = nil
            session.documents[url] = open
        }
        session.client.notify("textDocument/didChange", [
            "textDocument": [
                "uri": LSPMapping.uri(for: url),
                "version": version,
            ],
            "contentChanges": [["text": text]],
        ])
    }

    private func handleNotification(_ method: String, _ params: JSON, session: Session) {
        if method == "textDocument/publishDiagnostics" {
            handlePublish(params, session: session)
            return
        }
        // Other notifications (`window/logMessage`, `$/progress`, …) are delivered here
        // rather than dropped; there is nothing to persist for them.
        if method == "window/logMessage", let message = params["message"].string, !message.isEmpty {
            session.client.onLog?(message)
        }
    }

    private func handlePublish(_ params: JSON, session: Session) {
        let uri = params["uri"].string ?? ""
        guard let parsed = LSPMapping.url(fromURI: uri) else { return }
        let url = session.documents.keys.first {
            $0.resolvingSymlinksInPath().standardizedFileURL == parsed
        } ?? parsed
        guard session.documents[url] != nil || session.documents.keys.contains(where: {
            $0.resolvingSymlinksInPath().standardizedFileURL == parsed
        }) else { return }
        let file = session.documents.keys.first {
            $0.resolvingSymlinksInPath().standardizedFileURL == parsed
        } ?? url
        if let version = params["version"].int,
           let open = session.documents[file],
           open.version != version {
            return
        }
        let diagnostics = LSPMapping.diagnostics(from: params, file: file, source: session.name)
        onDiagnostics?(file, diagnostics)
    }

    private func handleDeath(of session: Session) {
        guard !session.dead else { return }
        session.dead = true
        let urls = Array(session.documents.keys)
        session.documents.removeAll()
        guard sessions[session.key] === session else { return }
        sessions[session.key] = nil
        let note = Self.stoppedNote(server: session.name)
        for url in urls {
            onCoverageChange?(url, nil)
            onFailureNote?(url, note)
        }
    }

    private func noteFailure(_ session: Session, extra: String? = nil) {
        session.dead = true
        var note = Self.stoppedNote(server: session.name)
        if let extra, !extra.isEmpty { note += " (\(extra))" }
        for url in session.documents.keys {
            onCoverageChange?(url, nil)
            onFailureNote?(url, note)
        }
    }

    static func stoppedNote(server: String) -> String {
        let fallback: String
        switch server {
        case "clangd": fallback = "clang -fsyntax-only"
        case "sourcekit-lsp": fallback = "swiftc -parse"
        default: fallback = "the one-shot checker for this language, when one is installed"
        }
        return "\(server) stopped; falling back to \(fallback). An empty list here is not a clean bill of health."
    }

    static func missingNote(server: String) -> String {
        "\(server) is not installed. An empty list here is not a clean bill of health."
    }

    private func session(containing url: URL) -> Session? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        for session in sessions.values where !session.dead {
            if session.documents[url] != nil { return session }
            if session.documents.keys.contains(where: {
                $0.resolvingSymlinksInPath().standardizedFileURL == resolved
            }) {
                return session
            }
        }
        return nil
    }

    private func liveSession(for document: CodeDocument) -> Session? {
        guard let session = session(containing: document.url),
              session.client.isRunning, !session.dead else { return nil }
        return session
    }

    private func isLive(_ kind: ServerKind) -> Bool {
        sessions.values.contains { $0.key.kind == kind && !$0.dead && $0.client.isRunning }
    }

    private func positionParams(_ document: CodeDocument, line: Int, column: Int) -> [String: Any] {
        [
            "textDocument": ["uri": LSPMapping.uri(for: document.url)],
            "position": [
                "line": max(0, line - 1),
                "character": max(0, column - 1),
            ],
        ]
    }
}

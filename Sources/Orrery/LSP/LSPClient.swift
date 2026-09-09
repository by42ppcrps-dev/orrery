import Darwin
import Foundation

/// JSON-RPC 2.0 over a child process's stdio, framed with `Content-Length` headers.
///
/// LSP is **not** NDJSON. `LineProcess` splits on newlines and would corrupt any payload that
/// contains one (hover markdown, diagnostic messages, file text in didChange). This client
/// parses the byte stream incrementally so a header, a body, or several messages can arrive
/// split across reads or packed into one.
struct LSPFramer {
    private var buffer = Data()
    private static let maxBuffer = 64 * 1024 * 1024
    private static let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
    private static let lflf = Data([0x0A, 0x0A])

    enum Event: Equatable {
        case message(Data)
        /// The stream exceeded the cap — the buffer was dropped rather than grown without bound.
        case overflow
    }

    mutating func reset() { buffer.removeAll(keepingCapacity: false) }

    /// Bytes currently held waiting for a complete header+body. Exposed so the audit can
    /// assert split reads actually accumulate.
    var bufferedCount: Int { buffer.count }

    mutating func ingest(_ data: Data) -> [Event] {
        buffer.append(data)
        if buffer.count > Self.maxBuffer {
            buffer.removeAll(keepingCapacity: false)
            return [.overflow]
        }
        var events: [Event] = []
        while let event = extractOne() {
            if case .overflow = event {
                events.append(event)
                return events
            }
            events.append(event)
        }
        return events
    }

    private mutating func extractOne() -> Event? {
        guard let (headerEnd, termLength) = findHeaderTerminator() else { return nil }
        let header = buffer[buffer.startIndex..<headerEnd]
        guard let length = Self.contentLength(in: header), length >= 0 else {
            // Malformed headers: drop through the terminator and keep scanning.
            let dropTo = headerEnd + termLength
            if dropTo <= buffer.endIndex {
                buffer.removeSubrange(buffer.startIndex..<dropTo)
            } else {
                buffer.removeAll(keepingCapacity: false)
            }
            return nil
        }
        if length > Self.maxBuffer {
            buffer.removeAll(keepingCapacity: false)
            return .overflow
        }
        let bodyStart = headerEnd + termLength
        let needed = buffer.distance(from: buffer.startIndex, to: bodyStart) + length
        guard buffer.count >= needed else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return .message(body)
    }

    private func findHeaderTerminator() -> (end: Data.Index, termLength: Int)? {
        if let range = buffer.firstRange(of: Self.crlfcrlf) {
            return (range.lowerBound, 4)
        }
        if let range = buffer.firstRange(of: Self.lflf) {
            return (range.lowerBound, 2)
        }
        return nil
    }

    /// Unknown headers are ignored. `Content-Type` (or anything else) may be present.
    static func contentLength(in header: Data) -> Int? {
        guard let text = String(data: header, encoding: .utf8)
                ?? String(data: header, encoding: .ascii) else { return nil }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if name == "content-length" {
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                return Int(value)
            }
        }
        return nil
    }

    static func frame(_ object: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object, options: [])
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }
}

enum LSPError: LocalizedError, Equatable {
    case notRunning
    case timedOut(method: String, seconds: TimeInterval)
    case stopped
    case rpc(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "The language server is not running."
        case let .timedOut(method, seconds):
            return "The language server did not reply to \(method) within \(Int(seconds))s."
        case .stopped:
            return "The language server stopped."
        case let .rpc(code, message):
            return "\(message) (\(code))"
        }
    }
}

/// Speaks LSP (JSON-RPC 2.0, Content-Length framing) to one language-server child.
///
/// Every outbound request has a deadline. A wedged server resumes the caller with a timeout
/// and drops the pending entry — it cannot hang the app or leak a continuation. Resuming a
/// continuation twice is a crash, so the pending slot is the single owner.
@MainActor
final class LSPClient {
    nonisolated static let defaultDeadline: TimeInterval = 10

    private var process: Process?
    private var stdinPipe: Pipe?
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var framer = LSPFramer()
    private var died = false
    private var stopping = false
    /// Serial stdin writer so a full pipe cannot block the main actor — and so a request
    /// deadline can still fire while a previous write is stuck.
    private let writeQueue = DispatchQueue(label: "orrery.lsp.stdin")
    /// Serializes stdout callbacks so split frames stay in order and EOF cannot overtake
    /// a response that already arrived on the pipe.
    private let inboundQueue = DispatchQueue(label: "orrery.lsp.stdout")
    /// Audit-only. Production leaves this off so full-text didChange payloads are not retained.
    var recordOutbound = false
    private(set) var outbound: [JSON] = []
    func clearOutbound() { outbound.removeAll() }

    var onNotification: ((String, JSON) -> Void)?
    var onLog: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var hasPendingRequest: Bool { !pending.isEmpty }
    var hasDied: Bool { died }
    /// Test seam: the readability callback waits this long before enqueueing a stdout
    /// read, so `terminationHandler` can drain unread bytes first. Production is 0.
    var auditDelayStdoutRead: TimeInterval = 0
    /// Test seam: `onExit` is invoked after this delay instead of immediately. Production is 0.
    var auditDeferOnExit: TimeInterval = 0

    var isRunning: Bool { process?.isRunning ?? false }
    var processIdentifier: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    // MARK: - Lifecycle

    func start(executable: String, arguments: [String] = [], cwd: URL? = nil,
               environment extra: [String: String] = [:]) throws {
        stop()
        died = false
        stopping = false
        nextID = 1
        outbound.removeAll()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let cwd { proc.currentDirectoryURL = cwd }

        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["SOURCEKIT_LOGGING"] = "0"
        env["PATH"] = ProcessRunner.extendedPATH(env["PATH"])
        for (key, value) in extra { env[key] = value }
        proc.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let inbound = inboundQueue
        let stdoutHandle = outPipe.fileHandleForReading
        let stdoutReadDelay = auditDelayStdoutRead
        // Disarm in the callback so the pipe cannot spin, then read on inboundQueue so
        // terminationHandler can drain leftover bytes before death fails pendings.
        func armStdout() {
            stdoutHandle.readabilityHandler = { [weak self] handle in
                handle.readabilityHandler = nil
                if stdoutReadDelay > 0 {
                    Thread.sleep(forTimeInterval: stdoutReadDelay)
                }
                inbound.async { [weak self] in
                    let data = handle.availableData
                    if data.isEmpty {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self?.handleDeath() }
                        }
                        return
                    }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.ingest(data) }
                    }
                    if handle.readabilityHandler == nil {
                        DispatchQueue.main.async { armStdout() }
                    }
                }
            }
        }
        armStdout()
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            inbound.async {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.onLog?(text) }
                }
            }
        }
        proc.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            inbound.async { [weak self] in
                stdoutHandle.readabilityHandler = nil
                let leftover = stdoutHandle.availableData
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if !leftover.isEmpty {
                            self?.ingest(leftover)
                        }
                        self?.handleDeath(status: status)
                    }
                }
            }
        }

        try proc.run()
        // A write after the child dies must not kill the app (default SIGPIPE).
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process = proc
        stdinPipe = inPipe
    }

    /// Best-effort `shutdown`/`exit`, then SIGTERM, then SIGKILL. Window close cannot await
    /// the handshake, but an uncooperative child must not outlive the window.
    func stop() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        let proc = process
        let pipe = stdinPipe
        stopping = true
        died = true
        if let pipe {
            writeQueue.async {
                if let data = try? LSPFramer.frame(["jsonrpc": "2.0", "id": 0,
                                                    "method": "shutdown",
                                                    "params": [:] as [String: Any]]) {
                    try? pipe.fileHandleForWriting.write(contentsOf: data)
                }
                if let data = try? LSPFramer.frame(["jsonrpc": "2.0", "method": "exit",
                                                    "params": [:] as [String: Any]]) {
                    try? pipe.fileHandleForWriting.write(contentsOf: data)
                }
                try? pipe.fileHandleForWriting.close()
            }
        }
        if let proc, proc.isRunning {
            DispatchQueue.global(qos: .utility).async {
                Thread.sleep(forTimeInterval: 0.4)
                if proc.isRunning { proc.terminate() }
                Thread.sleep(forTimeInterval: 0.4)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
        failAllPending(with: LSPError.stopped)
        process = nil
        stdinPipe = nil
        framer.reset()
    }

    /// Test seam: feed bytes as if they arrived on stdout (already on the main actor).
    func receive(_ data: Data) { ingest(data) }

    /// Same FIFO hop the FileHandle callback uses, so the audit can prove inbound order.
    func enqueueStdout(_ data: Data) {
        inboundQueue.async { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ingest(data) }
            }
        }
    }

    func enqueueEOF() {
        inboundQueue.async { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleDeath() }
            }
        }
    }

    func waitForWrites() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeQueue.async { continuation.resume() }
        }
    }

    /// `shutdown` request, then `exit` notification, then close stdin. SIGTERM→SIGKILL is
    /// scheduled independently of the serial writer — a wedged server that stopped reading
    /// stdin cannot prevent us from reaping the child. Always returns in bounded time.
    func shutdown() async {
        guard !stopping else { return }
        stopping = true
        let proc = process
        let pipe = stdinPipe
        if let proc, proc.isRunning {
            DispatchQueue.global(qos: .utility).async {
                Thread.sleep(forTimeInterval: 0.4)
                if proc.isRunning { proc.terminate() }
                Thread.sleep(forTimeInterval: 0.4)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
        if proc?.isRunning == true, !died {
            _ = try? await request("shutdown", [:], deadline: 1.5)
            notify("exit")
            // Enqueue the close; never await the writer — it may be blocked on a full pipe.
            if let pipe {
                writeQueue.async {
                    try? pipe.fileHandleForWriting.close()
                }
            }
            stdinPipe = nil
        }
        let waitUntil = Date().addingTimeInterval(1.2)
        while let proc, proc.isRunning, Date() < waitUntil {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        (self.process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (self.process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        failAllPending(with: LSPError.stopped)
        process = nil
        stdinPipe = nil
        framer.reset()
        died = true
    }

    // MARK: - Sending

    @discardableResult
    func request(_ method: String, _ params: [String: Any] = [:],
                 deadline: TimeInterval = LSPClient.defaultDeadline) async throws -> JSON {
        guard isRunning, let stdinPipe, !died else { throw LSPError.notRunning }
        let id = nextID
        nextID += 1
        let seconds = min(max(deadline, 0.05), 3600)
        return try await withCheckedThrowingContinuation { continuation in
            let pending = Pending(continuation)
            self.pending[id] = pending
            pending.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
                guard !Task.isCancelled else { return }
                self?.failTimedOut(id: id, method: method, seconds: seconds)
            }
            do {
                try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params],
                          to: stdinPipe)
            } catch {
                self.pending.removeValue(forKey: id)
                pending.resume(throwing: error)
            }
        }
    }

    func notify(_ method: String, _ params: [String: Any] = [:]) {
        guard let stdinPipe, isRunning else { return }
        try? write(["jsonrpc": "2.0", "method": method, "params": params], to: stdinPipe)
    }

    private func respond(id: Any, result: Any) {
        guard let stdinPipe, isRunning else { return }
        try? write(["jsonrpc": "2.0", "id": id, "result": result], to: stdinPipe)
    }

    private func respond(id: Any, errorCode: Int, message: String) {
        guard let stdinPipe, isRunning else { return }
        try? write(["jsonrpc": "2.0", "id": id,
                    "error": ["code": errorCode, "message": message]], to: stdinPipe)
    }

    private func write(_ object: [String: Any], to pipe: Pipe) throws {
        let data = try LSPFramer.frame(object)
        if recordOutbound { outbound.append(JSON(object)) }
        // Enqueue; never write on the main actor. A wedged server that stops reading
        // stdin fills the pipe and would otherwise freeze the window before a deadline.
        writeQueue.async {
            try? pipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    // MARK: - Receiving

    private func ingest(_ data: Data) {
        let events = framer.ingest(data)
        for event in events {
            switch event {
            case .overflow:
                onLog?("dropped an oversized protocol message")
            case let .message(body):
                handle(body: body)
            }
        }
    }

    private func handle(body: Data) {
        guard let message = JSON(data: body) else {
            onLog?("dropped a non-JSON LSP message")
            return
        }
        let dict = message.raw as? [String: Any]

        // Response to one of our requests. `result` may be JSON null — `JSON.exists` is false
        // for NSNull, so we look at the key, not the value.
        if dict?.keys.contains("result") == true || message["error"].exists,
           dict?["method"] == nil,
           let id = message["id"].int {
            guard let pending = pending.removeValue(forKey: id) else { return }
            if message["error"].exists {
                let error = message["error"]
                pending.resume(throwing: LSPError.rpc(
                    code: error["code"].int ?? -1,
                    message: error["message"].string ?? "RPC error"))
            } else {
                pending.resume(returning: message["result"])
            }
            return
        }

        guard let method = message["method"].string else { return }
        let params = message["params"]

        // Server → client request: must be answered or the server stalls.
        if let id = message["id"].raw, !(id is NSNull) {
            handleServerRequest(method: method, id: id, params: params)
            return
        }

        onNotification?(method, params)
    }

    private func handleServerRequest(method: String, id: Any, params: JSON) {
        switch method {
        case "workspace/configuration":
            let items = params["items"].array
            respond(id: id, result: items.map { _ in NSNull() })
        case "client/registerCapability", "client/unregisterCapability",
             "window/workDoneProgress/create":
            respond(id: id, result: NSNull())
        default:
            respond(id: id, errorCode: -32601, message: "Method not found: \(method)")
        }
    }

    private func failTimedOut(id: Int, method: String, seconds: TimeInterval) {
        guard let pending = pending.removeValue(forKey: id) else { return }
        pending.resume(throwing: LSPError.timedOut(method: method, seconds: seconds))
    }

    /// Audit seam for the crash above: hand in a Process in any state — never launched, mid
    /// termination — and death handling must survive it and report -1.
    func auditSimulateEOFDeath(with proc: Process) {
        process = proc
        handleDeath(status: nil)
    }

    private func handleDeath(status: Int32? = nil) {
        guard !died else { return }
        died = true
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        failAllPending(with: LSPError.stopped)
        // NEVER read `terminationStatus` here. Foundation's `isRunning` and
        // `terminationStatus` do not flip atomically: after the child dies there is a real
        // window where `isRunning` is already false and `terminationStatus` still throws
        // NSInvalidArgumentException — it crashed the app four times (2026-08-31, SIGABRT in
        // handleDeath) before this was understood. The only safe source of a status is the
        // terminationHandler, which passes it in; the EOF path reports -1 (unknown), honestly.
        let code = status ?? -1
        let callback = onExit
        let delay = auditDeferOnExit
        if delay > 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64((delay * 1_000_000_000).rounded()))
                callback?(code)
            }
        } else {
            callback?(code)
        }
        stdinPipe = nil
        // EOF without a termination status: the child may still be alive. Reap it so
        // dropping the session cannot orphan a running server.
        if let process, process.isRunning {
            process.terminate()
            let proc = process
            DispatchQueue.global(qos: .utility).async {
                Thread.sleep(forTimeInterval: 0.4)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
    }

    private func failAllPending(with error: Error) {
        let items = pending.values
        pending.removeAll()
        for item in items { item.resume(throwing: error) }
    }

    /// Owns the continuation so timeout and reply cannot both resume it.
    private final class Pending {
        private var continuation: CheckedContinuation<JSON, Error>?
        var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<JSON, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: JSON) {
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation?.resume(returning: value)
            continuation = nil
        }

        func resume(throwing error: Error) {
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

// MARK: - Payload mapping (LSP 0-based UTF-16 → Diagnostic 1-based)

enum LSPMapping {
    static func url(fromURI uri: String) -> URL? {
        if uri.hasPrefix("file:") {
            if let url = URL(string: uri) {
                return url.resolvingSymlinksInPath().standardizedFileURL
            }
            return nil
        }
        if uri.isEmpty { return nil }
        return URL(fileURLWithPath: uri).resolvingSymlinksInPath().standardizedFileURL
    }

    static func uri(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.absoluteString
    }

    /// LSP `Position.character` is UTF-16, matching `NSString` / `Diagnostic.range(in:)`.
    static func diagnostics(from params: JSON, file: URL, source: String) -> [Diagnostic] {
        params["diagnostics"].array.compactMap { item in
            let start = item["range"]["start"]
            let end = item["range"]["end"]
            let line0 = max(0, start["line"].int ?? 0)
            let char0 = max(0, start["character"].int ?? 0)
            let line1 = max(0, end["line"].int ?? line0)
            let char1 = max(0, end["character"].int ?? char0)
            let length = line0 == line1 ? max(0, char1 - char0) : 0
            let severity: Diagnostic.Severity
            switch item["severity"].int ?? 1 {
            case 1: severity = .error
            case 2: severity = .warning
            default: severity = .info
            }
            let message = item["message"].string ?? ""
            guard !message.isEmpty else { return nil }
            return Diagnostic(file: file, line: line0 + 1, column: char0 + 1, length: length,
                              severity: severity, message: message, source: source)
        }
    }

    static func completions(from result: JSON, text: String) -> [LSPCompletionItem] {
        guard result.exists else { return [] }
        let items: [JSON]
        if result.raw is [String: Any] {
            items = result["items"].array
        } else {
            items = result.array
        }
        return items.compactMap { item in
            let label = item["label"].string ?? ""
            guard !label.isEmpty else { return nil }
            let textEdit = item["textEdit"]
            let insertFromEdit = textEdit["newText"].string
            // Spec: when both are present, textEdit takes precedence.
            let insert = insertFromEdit ?? item["insertText"].string ?? label
            var editRange: NSRange?
            if textEdit.exists {
                let range = textEdit["range"].exists ? textEdit["range"] : textEdit["insert"]
                editRange = nsRange(from: range, in: text)
            }
            return LSPCompletionItem(
                label: label,
                detail: item["detail"].string,
                kind: kindName(item["kind"]),
                insertText: insert,
                editRange: editRange,
                sortText: item["sortText"].string)
        }
    }

    static func hoverText(from result: JSON) -> String? {
        guard result.exists else { return nil }
        let contents = result["contents"].exists ? result["contents"] : result
        if let text = marked(contents) { return text }
        let parts = contents.array.compactMap(marked)
        let joined = parts.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    static func definition(from result: JSON) -> LSPLocation? {
        guard result.exists else { return nil }
        if let loc = location(from: result) { return loc }
        if let loc = locationLink(from: result) { return loc }
        if let first = result.array.first {
            return location(from: first) ?? locationLink(from: first)
        }
        return nil
    }

    static func nsRange(from range: JSON, in text: String) -> NSRange? {
        utf16Range(in: text,
                   startLine: range["start"]["line"].int ?? 0,
                   startChar: range["start"]["character"].int ?? 0,
                   endLine: range["end"]["line"].int ?? 0,
                   endChar: range["end"]["character"].int ?? 0)
    }

    static func utf16Range(in text: String, startLine: Int, startChar: Int,
                           endLine: Int, endChar: Int) -> NSRange? {
        let ns = text as NSString
        func startOfLine(_ n: Int) -> Int? {
            var line = 0, index = 0
            while line < n {
                if index >= ns.length { return nil }
                let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
                index = lineRange.location + lineRange.length
                line += 1
            }
            return min(index, ns.length)
        }
        func contentLength(at offset: Int) -> Int {
            guard offset < ns.length else { return 0 }
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: offset, length: 0))
            return max(0, contentsEnd - start)
        }
        guard let startOffset = startOfLine(max(0, startLine)),
              let endOffset = startOfLine(max(0, endLine)) else { return nil }
        let start = startOffset + min(max(0, startChar), contentLength(at: startOffset))
        let end = endOffset + min(max(0, endChar), contentLength(at: endOffset))
        let loc = min(max(0, start), ns.length)
        let len = max(0, min(end, ns.length) - loc)
        return NSRange(location: loc, length: len)
    }

    private static func marked(_ json: JSON) -> String? {
        if let s = json.string { return s.isEmpty ? nil : s }
        if let value = json["value"].string { return value.isEmpty ? nil : value }
        return nil
    }

    private static func location(from json: JSON) -> LSPLocation? {
        guard let uri = json["uri"].string, let url = url(fromURI: uri) else { return nil }
        let start = json["range"]["start"]
        return LSPLocation(url: url,
                           line: (start["line"].int ?? 0) + 1,
                           column: (start["character"].int ?? 0) + 1)
    }

    private static func locationLink(from json: JSON) -> LSPLocation? {
        guard let uri = json["targetUri"].string, let url = url(fromURI: uri) else { return nil }
        let start = json["targetSelectionRange"].exists
            ? json["targetSelectionRange"]["start"]
            : json["targetRange"]["start"]
        return LSPLocation(url: url,
                           line: (start["line"].int ?? 0) + 1,
                           column: (start["character"].int ?? 0) + 1)
    }

    static func kindName(_ value: JSON) -> String {
        if let s = value.string, !s.isEmpty { return s }
        switch value.int ?? 1 {
        case 1: return "text"
        case 2: return "method"
        case 3: return "function"
        case 4: return "constructor"
        case 5: return "field"
        case 6: return "variable"
        case 7: return "class"
        case 8: return "interface"
        case 9: return "module"
        case 10: return "property"
        case 11: return "unit"
        case 12: return "value"
        case 13: return "enum"
        case 14: return "keyword"
        case 15: return "snippet"
        case 16: return "color"
        case 17: return "file"
        case 18: return "reference"
        case 19: return "folder"
        case 20: return "enumMember"
        case 21: return "constant"
        case 22: return "struct"
        case 23: return "event"
        case 24: return "operator"
        case 25: return "typeParameter"
        default: return "text"
        }
    }
}

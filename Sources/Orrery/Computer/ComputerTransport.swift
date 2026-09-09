import Foundation
import Darwin

struct ComputerConnection {
    let socketPath: String
    let token: String
    let provider: Provider
    var command: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }
    var arguments: [String] { ["--computer-mcp", socketPath, token, provider.rawValue] }
    var mcp: [String: Any] { ["command": command, "args": arguments] }
    var acp: [String: Any] { ["name": "studio_computer", "command": command, "args": arguments, "env": []] }
    var claudeArguments: [String] {
        ["--mcp-config", JSON(["mcpServers": ["studio_computer": mcp]]).compact]
    }
    var codexArguments: [String] {
        ["-c", "mcp_servers.studio_computer.command=\(TOMLArgument.value(command))",
         "-c", "mcp_servers.studio_computer.args=\(TOMLArgument.value(arguments))",
         "-c", "mcp_servers.studio_computer.default_tools_approval_mode=\"approve\"",
         "-c", "mcp_servers.studio_computer.tool_timeout_sec=125"]
    }
}

/// Private, same-user Unix socket. No TCP listener, shell commands, saved provider config,
/// or persistent computer grant. Each connection is one bounded request and one reply.
final class ComputerSocketServer: @unchecked Sendable {
    let path: String
    private let directory: URL
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "studio.computer.socket")
    private let lock = NSLock()
    private var stopped = false
    var handler: (([String: Any], @escaping ([String: Any]) -> Void) -> Void)?

    init() throws {
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("grok-computer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        // Darwin sockaddr_un paths are at most 103 bytes; /tmp keeps this independent of
        // the longer per-user temporary path while the private directory protects the socket.
        path = directory.path + "/rpc"
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ComputerError("Could not create the local tool connection.") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var address = try Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor); try? FileManager.default.removeItem(at: directory)
            throw ComputerError("Could not bind the private computer tool connection.")
        }
        chmod(path, 0o600)
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            while self.isEnabled {
                let peer = accept(self.descriptor, nil, nil)
                guard peer >= 0 else { break }
                _ = fcntl(peer, F_SETFD, FD_CLOEXEC)
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(peer, &uid, &gid) == 0, uid == getuid() else { close(peer); continue }
                Self.setTimeout(peer, seconds: 125)
                if let data = try? Self.readLine(peer, limit: 65_536),
                   let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    let reply = ComputerReply()
                    self.handler?(payload) { value in reply.finish(value) }
                    if reply.signal.wait(timeout: .now() + 120) == .success,
                       let value = reply.value,
                       let data = try? JSONSerialization.data(withJSONObject: value) {
                        try? Self.writeAll(data + Data([10]), to: peer)
                    }
                }
                close(peer)
            }
        }
    }

    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    func stop() {
        lock.lock(); let already = stopped; stopped = true; lock.unlock()
        guard !already else { return }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        // Close on the accept queue after its current request, avoiding descriptor reuse.
        queue.async { [descriptor, directory] in
            close(descriptor)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ComputerError("Local socket path is too long.") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        return address
    }
    static func setTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
    static func readLine(_ fd: Int32, limit: Int) throws -> Data {
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while result.count <= limit {
            let count = read(fd, &buffer, min(buffer.count, limit + 1 - result.count))
            guard count > 0 else { throw ComputerError("Computer tool connection ended.") }
            if let end = buffer[..<count].firstIndex(of: 10) {
                result.append(contentsOf: buffer[..<end]); return result
            }
            result.append(contentsOf: buffer[..<count])
        }
        throw ComputerError("Computer tool message is too large.")
    }
    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw ComputerError("Could not write computer tool response.") }
                offset += count
            }
        }
    }
}

private final class ComputerReply: @unchecked Sendable {
    let signal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: [String: Any]?
    var value: [String: Any]? { lock.lock(); defer { lock.unlock() }; return stored }
    func finish(_ value: [String: Any]) {
        lock.lock(); let first = stored == nil; if first { stored = value }; lock.unlock()
        if first { signal.signal() }
    }
}
struct ComputerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The CLI launches this stateless stdio bridge as an MCP server. Only the already-running
/// IDE can approve or execute actions. Losing the IDE connection fails closed.
enum ComputerMCPBridge {
    static func run() -> Never {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--computer-mcp"), args.count > index + 3 else { exit(2) }
        let path = args[index + 1], token = args[index + 2], provider = args[index + 3]
        var buffer = Data()
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { exit(0) }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard line.count <= 65_536 else { exit(2) }
                guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      request["id"] != nil else { continue }
                let response: [String: Any]
                do {
                    response = try call(path: path, payload: ["token": token, "provider": provider, "request": request])
                } catch {
                    response = ["jsonrpc": "2.0", "id": request["id"]!,
                                "error": ["code": -32000, "message": "Computer control is unavailable. Enable it in the IDE for this project."]]
                }
                if let data = try? JSONSerialization.data(withJSONObject: response) {
                    FileHandle.standardOutput.write(data + Data([10]))
                }
            }
            if buffer.count > 65_536 { exit(2) }
        }
    }

    static func call(path: String, payload: [String: Any]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ComputerError("Socket unavailable") }
        defer { close(fd) }
        ComputerSocketServer.setTimeout(fd, seconds: 125)
        var address = try ComputerSocketServer.address(path)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0 else { throw ComputerError("IDE unavailable") }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try ComputerSocketServer.writeAll(data + Data([10]), to: fd)
        let reply = try ComputerSocketServer.readLine(fd, limit: 16 * 1024 * 1024)
        guard let result = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else { throw ComputerError("Invalid reply") }
        return result
    }
}

import Foundation

/// Keep connector credentials out of process arguments. Claude expands environment references;
/// Codex supports inherited stdio variables and environment-backed HTTP headers.
enum MCPLaunchCredentials {
    static func claude(arguments: [String], environment: inout [String: String]) -> [String] {
        var arguments = arguments
        for index in arguments.indices where arguments[index] == "--mcp-config" && index + 1 < arguments.count {
            guard let config = try? AgentSessionSettings.object(arguments[index + 1]),
                  var servers = config["mcpServers"] as? [String: Any] else { continue }
            for (name, raw) in servers {
                guard var server = raw as? [String: Any] else { continue }
                for field in ["env", "headers"] {
                    guard var values = server[field] as? [String: String] else { continue }
                    for (key, value) in values where !value.contains("${") {
                        let variable = "ORRERY_MCP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        environment[variable] = value
                        values[key] = "${" + variable + "}"
                    }
                    server[field] = values
                }
                servers[name] = server
            }
            var updated = config; updated["mcpServers"] = servers
            arguments[index + 1] = JSON(updated).compact
        }
        return arguments
    }

    static func codexServers(_ input: [String: Any]) -> [String: Any] {
        input.mapValues { raw in
            guard var server = raw as? [String: Any] else { return raw }
            if let headers = server.removeValue(forKey: "headers") { server["http_headers"] = headers }
            return server
        }
    }

    static func codexNative(_ input: [String: Any], environment: inout [String: String]) throws -> [String: Any] {
        var result = codexServers(input)
        for (name, raw) in result {
            guard var server = raw as? [String: Any] else { continue }
            if let values = server["env"] as? [String: String] {
                var names = server["env_vars"] as? [String] ?? []
                for (key, value) in values {
                    if let previous = environment[key], previous != value {
                        throw ComputerError("Two CLI settings require different values for \(key). Use the provider's configuration to scope this variable per connection.")
                    }
                    environment[key] = value
                    if !names.contains(key) { names.append(key) }
                }
                server.removeValue(forKey: "env"); server["env_vars"] = names
            }
            if let headers = server["http_headers"] as? [String: String] {
                var names = server["env_http_headers"] as? [String: String] ?? [:]
                for (key, value) in headers {
                    let variable = "ORRERY_MCP_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    environment[variable] = value; names[key] = variable
                }
                server.removeValue(forKey: "http_headers"); server["env_http_headers"] = names
            }
            result[name] = server
        }
        return result
    }
}

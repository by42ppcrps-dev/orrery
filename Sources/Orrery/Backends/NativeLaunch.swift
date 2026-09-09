import Foundation

/// Arguments for the native CLI pane. The studio tool server is added to interactive launches
/// — no launch options, or flags only such as `--resume <id>` — and never to a subcommand:
/// `claude auth login`, `codex login` or `grok update` do not take server flags, and decorating
/// them broke the sign-in launch once the tool server was on for every trusted project.
enum NativeLaunch {
    static func isSubcommand(_ explicit: [String]) -> Bool {
        guard let first = explicit.first else { return false }
        return !first.hasPrefix("-")
    }

    /// `auth login`, `login`, `logout`: the user's own account actions, not agent work. They
    /// need the browser and the CLI's credential store, and the write-confinement profile
    /// cannot open a browser at all (Launch Services is outside it), so they run unconfined.
    static func isAccountCommand(_ explicit: [String]) -> Bool {
        guard let first = explicit.first?.lowercased() else { return false }
        return ["auth", "login", "logout"].contains(first)
    }

    static func executionPolicy(configured: AgentExecutionPolicy, explicit: [String]) -> AgentExecutionPolicy {
        isAccountCommand(explicit) ? .fullAccess : configured
    }

    static func arguments(provider: Provider, explicit: [String], defaults: [String],
                          mcpServers: [String: Any], connection: ComputerConnection?) -> [String] {
        var args = explicit.isEmpty ? defaults : explicit
        guard let connection, !isSubcommand(explicit) else { return args }
        switch provider {
        case .claude:
            if explicit.isEmpty, let index = args.firstIndex(of: "--mcp-config"), index + 1 < args.count {
                args.removeSubrange(index...index + 1)
            }
            var servers = explicit.isEmpty ? mcpServers : [:]
            servers["studio_computer"] = connection.mcp
            args += ["--mcp-config", JSON(["mcpServers": servers]).compact]
        case .codex:
            args += connection.codexArguments
        case .grok:
            break
        }
        return args
    }
}

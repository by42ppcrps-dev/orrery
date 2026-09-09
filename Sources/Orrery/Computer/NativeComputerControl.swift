import Foundation
import AppKit

/// Provider-native runtimes are installed and authorized by their provider. Orrery never
/// copies their helpers, credentials or live desktop sockets into its own configuration.
enum NativeComputerControl {
    static let codexServiceIdentifier = "com.openai.sky.CUAService"
    @MainActor private static var serviceLaunch: Task<Void, Error>?

    /// Launch the provider-owned helper from the host before starting a confined CLI.
    /// Its own app/OS permissions still apply; no helper is copied and no sandbox is widened.
    @MainActor static func prepareCodexService() async throws {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: codexServiceIdentifier).isEmpty { return }
        if let serviceLaunch { try await serviceLaunch.value; return }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let installed = home.appendingPathComponent("computer-use/Codex Computer Use.app")
        let candidates = [installed, NSWorkspace.shared.urlForApplication(withBundleIdentifier: codexServiceIdentifier)].compactMap { $0 }
        guard let url = candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == codexServiceIdentifier }) else {
            throw ComputerError("Codex Computer Use is not installed. Install or enable Computer Use in the Codex desktop app, then reconnect Codex.")
        }
        let task = Task { @MainActor in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        serviceLaunch = task
        defer { serviceLaunch = nil }
        try await task.value
    }

    static func guidance(for provider: Provider, preferred: Bool) -> String {
        guard preferred, provider != .grok else {
            return "For desktop work use Orrery's studio_computer tools when granted. These are Orrery's controls, not a provider-native computer-use system."
        }
        let common = "Use your provider's native computer-control tools for desktop work. Do not silently substitute studio_computer desktop tools or shell UI automation. If native control is unavailable, report the actual limitation. Orrery's ide_*, browser_* and simulator_* tools remain available for their separate IDE surfaces when granted. Provider-native permissions still apply."
        switch provider {
        case .codex:
            return common + " Codex native desktop control is supplied by the installed Computer Use plugin, commonly through mcp__cua_repl js. Discover and use its documented API. A feature flag or a listed plugin alone is not proof of a working connection; verify an actual native tool result."
        case .claude:
            return common + " Claude's built-in computer-use MCP server is currently available only in interactive Claude Code sessions, enabled in /mcp. It is not supported in non-interactive -p sessions used by Orrery Solo, Team and Roundtable. In those sessions, explain that desktop work needs Orrery's Claude CLI pane; do not claim native desktop access. Claude in Chrome is a separate browser integration."
        case .grok: return common
        }
    }

    static func hasCodexTools(_ inventory: JSON) -> Bool {
        inventory["data"].array.contains { server in
            guard let name = server["name"].string,
                  ["cua_repl", "computer-use"].contains(name),
                  let tools = server["tools"].raw as? [String: Any] else { return false }
            return !tools.isEmpty
        }
    }
}

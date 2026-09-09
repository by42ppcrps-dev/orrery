import Foundation
import AppKit
import SwiftUI

/// Checks only the public release feed. No project paths or account data are sent.
@MainActor
@Observable
final class OrreryUpdates {
    static let shared = OrreryUpdates()
    static let releasesURL = URL(string: "https://github.com/by42ppcrps-dev/orrery/releases/latest")!
    private(set) var checking = false
    private(set) var message = ""

    static func releaseVersion(_ data: Data) -> String? {
        guard data.count <= 256 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool == false, object["prerelease"] as? Bool == false,
              let tag = object["tag_name"] as? String,
              tag.range(of: #"^v?[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    func check() async {
        guard !checking else { return }
        checking = true; defer { checking = false }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/by42ppcrps-dev/orrery/releases/latest")!, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        var hasRelease = false
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ComputerError("No release response was received.") }
            if response.statusCode == 404 { throw ComputerError("No public release is available yet.") }
            guard response.statusCode == 200, let latest = Self.releaseVersion(data) else {
                throw ComputerError("The release service could not be checked. Try again later.")
            }
            hasRelease = true
            if let current {
                message = ToolchainWatch.compareVersions(latest, current) > 0 ? "Orrery \(latest) is available. You have \(current)." : "Orrery \(current) is up to date."
            } else { message = "The latest public release is Orrery \(latest). This is a development build." }
        } catch { message = error.localizedDescription }
        let alert = NSAlert()
        alert.messageText = "Orrery updates"
        alert.informativeText = message + (hasRelease ? "\n\nDownload the source release and run Install.command to update. Your projects and settings are retained." : "")
        alert.addButton(withTitle: "OK")
        if hasRelease { alert.addButton(withTitle: "View release") }
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(Self.releasesURL) }
    }
}

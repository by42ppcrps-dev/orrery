import SwiftUI
import AppKit

/// macOS grants are separate from Orrery's tool-approval preference. Only an explicit button
/// asks the OS; rendering this view and returning from Settings only perform silent checks.
struct DesktopPermissionsView: View {
    @State private var missing = ComputerControl.missingDesktopPermissions
    private func refresh() { missing = ComputerControl.missingDesktopPermissions }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if missing.isEmpty {
                Label("macOS access ready", systemImage: "checkmark.shield").foregroundStyle(.green)
            } else {
                Label("macOS access needed: " + missing.joined(separator: ", "), systemImage: "lock.shield")
                    .foregroundStyle(.orange)
                Text("These are one-time macOS permissions for Orrery. Your choice to run agent actions without asking remains separate.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if missing.contains("Accessibility") {
                        Button("Allow keyboard & mouse") {
                            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            refresh()
                        }
                    }
                    if missing.contains("Screen Recording") {
                        Button("Allow screen capture") { _ = CGRequestScreenCaptureAccess(); refresh() }
                    }
                    Button("Check again") { refresh() }
                }.controlSize(.small)
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }
}

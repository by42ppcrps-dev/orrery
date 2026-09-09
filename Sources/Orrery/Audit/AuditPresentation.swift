import AppKit
import SwiftUI

@MainActor enum AuditPresentation {
    static func run(_ audit: Auditor) async {
        audit.section("Presentation — usable action targets and window-owned file pickers")
        let view = NSHostingView(rootView: PaneIconButton(title: "Inspect action", symbol: "paperclip") {}.fixedSize())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 90),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        let size = view.fittingSize
        audit.check("pane actions have at least a 32-point click target", size.width >= 32 && size.height >= 32, "\(size)")
        audit.check("pane actions remain compact enough for narrow toolbars", size.width <= 44 && size.height <= 44, "\(size)")
        window.contentView = nil

        // Record the real presenter's dispatch without opening a system dialog during audits.
        final class Panel: NSOpenPanel {
            var recordedWindow: NSWindow?
            var usedStandalone = false
            var response: NSApplication.ModalResponse = .cancel
            override func beginSheetModal(for window: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
                recordedWindow = window; handler?(response)
            }
            override func begin(completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
                usedStandalone = true; handler?(response)
            }
        }
        let panel = Panel()
        var replies: [NSApplication.ModalResponse] = []
        WorkspaceFilePicker.present(panel, from: window) { replies.append($0) }
        audit.check("attachments stay attached to the requesting workspace window", panel.recordedWindow === window && !panel.usedStandalone)
        audit.check("cancelling a file chooser is delivered once without accepting files", replies == [.cancel])
        let standalone = Panel(); standalone.response = .OK
        WorkspaceFilePicker.present(standalone, from: nil) { replies.append($0) }
        audit.check("a chooser without a window remains asynchronous and delivers its result", standalone.usedStandalone && standalone.recordedWindow == nil && replies == [.cancel, .OK])
    }
}

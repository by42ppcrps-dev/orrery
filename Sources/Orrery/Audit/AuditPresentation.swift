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

        // Host the shipping rows at narrow and wide pane sizes. A short strip can pass a
        // screenshot check while clipping controls or leaving no inset above the picker.
        for width: CGFloat in [420, 620] {
            let bar = NSHostingView(rootView: AssistantModeBar(provider: .constant(.codex),
                mode: .constant(.team), showsAgent: false).frame(width: width).fixedSize())
            window.contentView = bar
            window.layoutIfNeeded(); bar.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
            let barHeight = bar.fittingSize.height
            audit.check("mode controls have breathing room at \(Int(width))-point pane width",
                        barHeight >= 48 && barHeight <= 64, "height \(barHeight)")
            @MainActor func segments(in view: NSView) -> [NSSegmentedControl] {
                ((view as? NSSegmentedControl).map { [$0] } ?? []) + view.subviews.flatMap { segments(in: $0) }
            }
            // AppKit frames can include decoration beyond the visible layout edges.
            // Compare the native alignment rect so different macOS control styles agree.
            let pickerFrame = segments(in: bar).first.flatMap { control -> NSRect? in
                guard let parent = control.superview else { return nil }
                return bar.convert(control.alignmentRect(forFrame: control.frame), from: parent)
            }
            audit.check("mode picker has space above and below at \(Int(width))-point pane width",
                        pickerFrame.map { $0.minY >= 10 && bar.bounds.maxY - $0.maxY >= 10 } == true,
                        "picker \(String(describing: pickerFrame)), row \(bar.bounds)")
            window.contentView = nil

            let status = NSHostingView(rootView: ComputerControlStatus {}.frame(width: width).fixedSize())
            window.contentView = status
            window.layoutIfNeeded(); status.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
            let statusHeight = status.fittingSize.height
            audit.check("computer-control status has room for a usable Stop action at \(Int(width))-point pane width",
                        statusHeight >= 44 && statusHeight <= 56, "height \(statusHeight)")
            window.contentView = nil
        }

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

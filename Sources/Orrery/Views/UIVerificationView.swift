import SwiftUI
import WebKit

/// The local UI preview sheet. Every control maps to a fixed controller action: local-only
/// navigation, DOM inspection, selector-based click/type and bounded PNG evidence. There is no
/// address bar for outside sites and no script console.
struct UIVerificationView: View {
    @Bindable var controller: UIVerificationController
    @Environment(\.dismiss) private var dismiss
    @State private var selector = ""
    @State private var typedText = ""
    @State private var busy = false
    @State private var result = ""

    private var pageReady: Bool { controller.webView != nil && !controller.isLoading && !busy }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            HSplitView {
                preview.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                inspector.frame(minWidth: 270, idealWidth: 310, maxWidth: 400, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, idealWidth: 1080, maxWidth: 1500, minHeight: 520, idealHeight: 720, maxHeight: 1000)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Verify project UI", systemImage: "macwindow").font(.headline)
                Text("Local servers only").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stop preview") { controller.stop() }
                    .disabled(controller.webView == nil)
                    .help("Release the preview's web process; the sheet stays open")
                Button("Close") { controller.stop(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                TextField("http://127.0.0.1:3000", text: $controller.urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(open)
                    .disabled(busy || controller.isLoading)
                    .accessibilityLabel("Local server URL")
                Button("Open") { open() }
                    .disabled(busy || controller.isLoading || controller.urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
                Picker("Viewport", selection: $controller.viewport) {
                    ForEach(UIVerificationViewport.allCases) { viewport in Text(viewport.label).tag(viewport) }
                }
                .labelsHidden().frame(width: 190)
                .help("Preview size. Change it before capturing evidence.")
            }
        }
    }

    private var preview: some View {
        ZStack {
            if controller.webView != nil {
                UIPreviewHost(webView: controller.webView, size: controller.viewport.size)
            } else {
                ContentUnavailableView("No local preview open", systemImage: "macwindow",
                    description: Text("Start your project's development server, enter its address on localhost, 127.0.0.1 or [::1], then choose Open. Outside sites are refused."))
            }
            if controller.isLoading { ProgressView().controlSize(.large) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(controller.status)
                    .font(.callout).foregroundStyle(controller.hasErrors ? .orange : .secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Inspect") { run { try await controller.inspect() } }
                    Button("Capture screenshot") { run { try await Self.summary(controller.capture()) } }
                }
                .disabled(!pageReady)
                TextField("CSS selector matching one element", text: $selector)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Selector")
                HStack(spacing: 8) {
                    Button("Click") { let target = selector; run { try await controller.click(selector: target) } }
                        .disabled(!pageReady || selector.isEmpty)
                    Spacer(minLength: 0)
                }
                TextField("Text to type into the selected field", text: $typedText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Text to type")
                Button("Type") { let target = selector, value = typedText; run { try await controller.type(selector: target, text: value) } }
                    .disabled(!pageReady || selector.isEmpty || typedText.isEmpty)
                Text("Password and file fields are refused. Loading and inspection are not an end-to-end test pass by themselves.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                if !result.isEmpty {
                    GroupBox("Last result") {
                        ScrollView {
                            Text(result).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 170)
                    }
                }
                GroupBox("Console and navigation events · \(controller.events.count)") {
                    if controller.events.isEmpty {
                        Text("No events recorded yet.").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(controller.events.suffix(40).reversed()) { event in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(event.kind).font(.caption2.weight(.semibold))
                                        .foregroundStyle(["error", "navigation error", "blocked"].contains(event.kind) ? .red : .secondary)
                                        .frame(width: 84, alignment: .leading)
                                    Text(event.message).font(.caption).textSelection(.enabled).lineLimit(4)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let capture = controller.lastCapture {
                    GroupBox("Last capture") {
                        VStack(alignment: .leading, spacing: 6) {
                            if let image = NSImage(data: capture.png) {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 150)
                                    .border(.quaternary)
                                    .accessibilityLabel("Captured page screenshot")
                            }
                            Text("\(capture.url) · \(capture.viewport.label) · \(ByteCountFormatter.string(fromByteCount: Int64(capture.png.count), countStyle: .file))")
                                .font(.caption).textSelection(.enabled)
                            Text(capture.date.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                            if let evidence = capture.evidenceURL {
                                Text("Evidence: \(evidence.path)").font(.caption2).foregroundStyle(.secondary)
                                    .textSelection(.enabled).lineLimit(3)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(14)
        }
    }

    private func open() {
        let text = controller.urlText
        run {
            try await controller.open(text)
            return "Opened. Inspect the page or run an action."
        }
    }

    private func run(_ operation: @escaping () async throws -> String) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { result = try await operation() } catch { result = error.localizedDescription }
        }
    }

    private static func summary(_ capture: UIVerificationCapture) -> String {
        "Saved a \(ByteCountFormatter.string(fromByteCount: Int64(capture.png.count), countStyle: .file)) screenshot of \(capture.url) at \(capture.viewport.label) with \(capture.events.count) recorded event(s)."
    }
}

/// Hosts the controller's web view. The controller owns the view; this only places it in a
/// scrollable, top-anchored container sized to the selected viewport.
private struct UIPreviewHost: NSViewRepresentable {
    let webView: WKWebView?
    let size: CGSize

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.documentView = TopAnchoredContainer(frame: CGRect(origin: .zero, size: size))
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let container = scroll.documentView as? TopAnchoredContainer else { return }
        container.frame = CGRect(origin: .zero, size: size)
        if let webView {
            if webView.superview !== container {
                container.subviews.forEach { $0.removeFromSuperview() }
                webView.autoresizingMask = []
                container.addSubview(webView)
            }
            webView.frame = container.bounds
        } else {
            container.subviews.forEach { $0.removeFromSuperview() }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
        // Leave the controller's web view alive; the sheet may reopen while the agent works.
        (scroll.documentView as? TopAnchoredContainer)?.subviews.forEach { $0.removeFromSuperview() }
    }
}

private final class TopAnchoredContainer: NSView {
    override var isFlipped: Bool { true }
}

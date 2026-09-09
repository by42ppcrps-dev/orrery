import SwiftUI
import WebKit

enum BrowserAddress {
    static func normalized(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("://") else { return text }
        let host = URLComponents(string: "http://" + text)?.host?.lowercased() ?? ""
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        return (local ? "http://" : "https://") + text
    }
}

/// The IDE's browser: yours to use (sign in to grok.com, read docs, try a site), and the agents'
/// when you allow it. Navigation is limited to the allowed sites plus local servers.
struct BrowserPaneView: View {
    @Bindable var model: AppModel
    @State private var address = ""
    private var controller: UIVerificationController? { model.browser }
    @State private var problem: String?
    @State private var showAccess = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { controller?.webView?.goBack() } label: { Image(systemName: "chevron.left") }.disabled(controller?.webView?.canGoBack != true)
                Button { controller?.webView?.goForward() } label: { Image(systemName: "chevron.right") }.disabled(controller?.webView?.canGoForward != true)
                Button { controller?.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }.disabled(controller?.webView == nil)
                TextField(model.blanketApproval ? "Website address" : "Address (an allowed site, or your local server)", text: $address)
                    .textFieldStyle(.roundedBorder).onSubmit(open).accessibilityLabel("Browser address")
                Button("Go") { open() }.disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                PaneIconButton(title: "Open in Browser", symbol: "arrow.up.right.square") {
                    do { try controller?.openInSystemBrowser() } catch { problem = error.localizedDescription }
                }.disabled(controller?.webView == nil)
                PaneIconButton(title: "Browser access settings", symbol: "lock.shield") { showAccess.toggle() }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            if showAccess {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.blanketApproval ? "All websites allowed — bypass is on" : "Allowed sites").font(.caption).foregroundStyle(.secondary)
                TextField("grok.com, docs.example.com", text: Binding(
                    get: { model.browserAllowedHosts.joined(separator: ", ") },
                    set: { model.browserAllowedHosts = $0.split(separator: ",").map(String.init) }))
                    .textFieldStyle(.roundedBorder).font(.caption).accessibilityLabel("Allowed sites")
                Toggle(model.blanketApproval ? "Agents may use this browser (on: blanket bypass)" : "Agents may use this browser", isOn: Binding(get: { model.agentsMayUseBrowser }, set: { model.browserAgentsAllowed = $0 }))
                    .toggleStyle(.checkbox).font(.caption).disabled((model.browserAllowedHosts.isEmpty || !model.isProjectTrusted) && !model.blanketApproval || model.blanketApproval)
                    .help(model.blanketApproval ? "The blanket bypass gives every agent this browser; all HTTP and HTTPS websites are available" : model.browserAllowedHosts.isEmpty ? "Name at least one site first" : "On the sites above an agent acts as you")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            }
            if controller?.externalAuthenticationURL != nil {
                HStack {
                    Text("Google sign-in needs your regular browser. Sign in and continue there; it won’t sign in this pane.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open in Browser") {
                        do { try controller?.openInSystemBrowser() } catch { problem = error.localizedDescription }
                    }
                }.padding(.horizontal, 10).padding(.vertical, 8)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange).padding(.horizontal, 10).padding(.bottom, 4) }
            else if let status = controller?.status, !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 4) }
            Divider()
            if let controller {
                BrowserWebHost(controller: controller).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "globe").font(.system(size: 44, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("See your ideas take shape").font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("Build with your agents on the left. Explore and test the result here.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("Open local preview") { address = "http://127.0.0.1:3000"; open() }
                            .buttonStyle(.borderedProminent)
                        Button("Choose allowed sites") { showAccess = true }.buttonStyle(.bordered)
                    }
                    Text(model.blanketApproval ? "Bypass is on. Enter any website address above." : "Use the address bar for another port or website. Manage website access with the shield button.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(28).frame(maxWidth: 540)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if let existing = model.browser { address = existing.urlText } }
        .onChange(of: model.browser?.urlText) { _, url in
            if let url, !url.isEmpty { address = url; problem = nil }
        }
    }

    private func open() {
        let text = BrowserAddress.normalized(address)
        address = text
        problem = nil
        do {
            let controller = try model.browserController()
            Task {
                do { try await controller.open(text) } catch { problem = error.localizedDescription }
            }
        } catch { problem = error.localizedDescription }
    }
}

/// Hosts the controller's web view filling the pane; the view is created by the controller's
/// first `open`, so the host attaches it when it appears.
struct BrowserWebHost: NSViewRepresentable {
    let controller: UIVerificationController

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard let webView = controller.webView else { return }
        if webView.superview !== view {
            view.subviews.forEach { $0.removeFromSuperview() }
            webView.frame = view.bounds
            webView.autoresizingMask = [.width, .height]
            view.addSubview(webView)
        }
    }
}

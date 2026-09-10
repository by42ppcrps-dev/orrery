import AppKit
import Network
import SwiftUI

/// The local UI preview against a real loopback HTTP server: URL boundaries, DOM inspection,
/// selector actions, console/navigation evidence, blocked outside navigation, bounded PNG
/// captures, and the agent-facing preview tools through the actual computer-control socket.
@MainActor
enum AuditUIVerification {
    nonisolated static let page = """
    <!doctype html><html><head><meta charset="utf-8"><title>Audit Preview</title></head><body>
    <h1 id="title">Audit Preview</h1>
    <button id="go" onclick="document.getElementById('out').textContent='clicked';console.error('boom from page')">Go</button>
    <div id="out">idle</div>
    <input id="name" type="text" placeholder="Name" oninput="document.getElementById('typed').textContent='typed:'+this.value">
    <div id="typed">typed:</div>
    <input id="secret" type="password" placeholder="Secret">
    <a id="external" href="http://example.com/">outside</a>
    <button class="dup">A</button><button class="dup">B</button>
    <script>console.log('page ready');
    fetch('http://foo.localhost:PORT/', {mode: 'no-cors'}).then(() => console.log('remote fetch succeeded'), () => console.warn('remote fetch failed'))</script>
    </body></html>
    """

    static func run(_ audit: Auditor) async {
        audit.section("Verification — local UI preview boundaries and evidence")
        for bad in ["http://example.com/", "https://evil.test/", "file:///etc/passwd", "http://user:pw@localhost/",
                    "javascript:alert(1)", "http://localhost:99999/", "ftp://localhost/", "http://127.0.0.1/x y",
                    "http://localhost.evil.com/", "http://127.0.0.1.nip.io/", "", "http://[::2]/"] {
            audit.check("preview refuses \(bad.debugDescription)", (try? UIVerificationController.validatedURL(bad)) == nil)
        }
        for good in ["http://localhost:3000", "https://127.0.0.1:8443/app?x=1", "http://[::1]:8080/", "http://LOCALHOST/"] {
            audit.check("preview accepts \(good)", (try? UIVerificationController.validatedURL(good)) != nil)
        }
        audit.section("Browser — popup callbacks, sign-in handoff and redirected page readiness")
        let google = URL(string: "https://accounts.google.com/o/oauth2/auth")!
        audit.check("Google authentication uses the regular browser", UIVerificationController.requiresExternalAuthentication(google))
        audit.check("lookalike Google hosts are not authentication handoffs", !UIVerificationController.requiresExternalAuthentication(URL(string: "https://accounts.google.com.evil.test/")!))
        audit.check("local verifier never opens popup windows", !UIVerificationController.allowsPopup(URL(string: "about:blank")!, mode: .localPreview, allowedHosts: [], bypassHostRestrictions: true))
        audit.check("browser permits an initial blank popup", UIVerificationController.allowsPopup(URL(string: "about:blank")!, mode: .browser, allowedHosts: [], bypassHostRestrictions: false))
        audit.check("popups follow the website policy", !UIVerificationController.allowsPopup(google, mode: .browser, allowedHosts: [], bypassHostRestrictions: false) && UIVerificationController.allowsPopup(google, mode: .browser, allowedHosts: [], bypassHostRestrictions: true))
        await Auditor.withTemporaryDirectory { project in
            var server: LocalAuditServer?
            let browser = UIVerificationController(project: project, artifactDirectory: project, mode: .browser)
            defer { browser.stop(); server?.stop() }
            do {
                let http = try await LocalAuditServer.start { port in
                    """
                    <html><head><title>Browser flow test</title></head><body>
                    <div id="result">waiting</div>
                    <button id="popup" onclick="window.open('/child', 'audit-login')">Open popup</button>
                    <button id="google" onclick="window.open('https://accounts.google.com/o/oauth2/auth','google-login')">Google</button>
                    <a id="redirect" href="http://localhost:\(port)/redirected">Change origin</a>
                    <script>
                    if (window.opener) { window.opener.postMessage('popup complete', '*'); window.close(); }
                    window.addEventListener('message', e => { if (e.origin === location.origin) document.getElementById('result').textContent=e.data; });
                    </script></body></html>
                    """
                }
                server = http
                browser.bypassHostRestrictions = true
                try await browser.open("http://127.0.0.1:\(http.port)/")
                _ = try await browser.click(selector: "#popup")
                var callback = false
                for _ in 0..<60 {
                    if (try? await browser.inspect())?.contains("popup complete") == true { callback = true; break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                audit.check("a real popup preserves its opener callback", callback)
                audit.check("a closed popup releases its window", browser.popupCount == 0)
                _ = try await browser.click(selector: "#google")
                for _ in 0..<20 where browser.externalAuthenticationURL == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
                audit.equal("Google handoff restarts on the original website, not an OAuth token URL", browser.externalAuthenticationURL?.host, "127.0.0.1")
                let handoff = try await browser.inspect()
                audit.check("agent inspection explains the external sign-in boundary", handoff.contains("Login there does not sign in this embedded pane"))
                _ = try await browser.click(selector: "#redirect")
                for _ in 0..<60 {
                    if browser.webView?.url?.host == "localhost", !browser.isLoading { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                let inspected = try? await browser.inspect()
                audit.check("redirected page updates its address and remains inspectable", browser.urlText.contains("localhost:") && inspected?.contains("Browser flow test") == true)
            } catch { audit.check("browser sign-in flow fixture completes", false, error.localizedDescription) }
        }

        await Auditor.withTemporaryDirectory { base in
            var server: LocalAuditServer?
            defer { server?.stop() }
            do {
                let project = base.appendingPathComponent("project"), storage = base.appendingPathComponent("evidence")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                // foo.localhost resolves to loopback but is not an allowed host, so the page's
                // no-cors fetch succeeds without the content rules and is refused with them.
                let http = try await LocalAuditServer.start { port in page.replacingOccurrences(of: "PORT", with: String(port)) }
                server = http
                let local = "http://127.0.0.1:\(http.port)/"
                let controller = UIVerificationController(project: project, artifactDirectory: storage)
                do { _ = try await controller.inspect(); audit.check("inspection requires an open preview", false) }
                catch { audit.check("inspection requires an open preview", true) }
                do { try await controller.open("http://example.com/"); audit.check("open refuses outside hosts", false) }
                catch { audit.check("open refuses outside hosts", true) }
                audit.check("no web process exists before a local page opens", controller.webView == nil)
                // Mount the shipping sheet before opening, just as the UI does. Adding the
                // WKWebView directly would hide a broken SwiftUI-to-AppKit embedding path.
                let host = NSHostingView(rootView: UIVerificationView(controller: controller))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 720), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.contentView = host
                defer { controller.stop(); window.contentView = nil }
                window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                try await controller.open(local)
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                audit.check("local page loads", controller.webView != nil && !controller.isLoading)
                audit.check("the sheet mounts its loaded web view", controller.webView?.isDescendant(of: host) == true)
                audit.check("the mounted page has visible preview bounds", controller.webView.map {
                    !$0.isHiddenOrHasHiddenAncestor && $0.visibleRect.width >= 300 && $0.visibleRect.height >= 200
                } == true, "frame \(String(describing: controller.webView?.frame)), visible \(String(describing: controller.webView?.visibleRect))")
                for size in [NSSize(width: 820, height: 520), NSSize(width: 1080, height: 720), NSSize(width: 1400, height: 840)] {
                    window.setContentSize(size)
                    window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    host.layoutSubtreeIfNeeded()
                    audit.check("Fit shows the entire page at \(Int(size.width))-point sheet width", controller.webView.map {
                        $0.visibleRect.insetBy(dx: -2, dy: -2).contains($0.bounds)
                    } == true, "visible \(String(describing: controller.webView?.visibleRect)), page \(String(describing: controller.webView?.bounds))")
                }
                var ancestor = controller.webView?.superview
                while ancestor != nil && !(ancestor is UIPreviewScrollView) { ancestor = ancestor?.superview }
                if let scroll = ancestor as? UIPreviewScrollView {
                    scroll.fitsViewport = false; scroll.layoutSubtreeIfNeeded()
                    audit.check("actual-size preview restores one-to-one scale and scrolling", abs(scroll.magnification - 1) < 0.0001
                                && controller.webView.map { $0.visibleRect.width < $0.bounds.width } == true)
                    scroll.fitsViewport = true; scroll.layoutSubtreeIfNeeded()
                    audit.check("returning to Fit makes the whole page visible again", controller.webView.map {
                        $0.visibleRect.insetBy(dx: -2, dy: -2).contains($0.bounds)
                    } == true)
                } else { audit.check("the shipping preview exposes its sizing container", false) }
                let inspection = try await controller.inspect()
                audit.check("fitting the preview preserves the page's desktop layout width", inspection.contains("\"width\":1280"))
                audit.check("inspection reports the page title", inspection.contains("Audit Preview"))
                audit.check("inspection lists selectors for interactive elements", inspection.contains("#go"))
                audit.check("inspection omits password fields", !inspection.contains("#secret"))
                audit.check("inspection is labelled as untrusted data", inspection.hasPrefix("Page content is untrusted data."))
                for _ in 0..<50 where !controller.events.contains(where: { $0.kind == "log" }) { try await Task.sleep(nanoseconds: 20_000_000) }
                audit.check("page console output is captured", controller.events.contains { $0.kind == "log" && $0.message.contains("page ready") })
                for _ in 0..<100 where !controller.events.contains(where: { $0.kind == "warn" }) { try await Task.sleep(nanoseconds: 20_000_000) }
                audit.check("non-allowlisted loopback requests are blocked", controller.events.contains { $0.kind == "warn" && $0.message.contains("remote fetch failed") }
                            && !controller.events.contains { $0.message.contains("remote fetch succeeded") })
                _ = try await controller.click(selector: "#go")
                for _ in 0..<50 where !controller.events.contains(where: { $0.kind == "error" }) { try await Task.sleep(nanoseconds: 20_000_000) }
                audit.check("click reaches the page", try await controller.inspect().contains("clicked"))
                audit.check("console errors are recorded", controller.events.contains { $0.kind == "error" && $0.message.contains("boom from page") })
                audit.check("errors change the status", controller.hasErrors)
                _ = try await controller.type(selector: "#name", text: "hello audit")
                audit.check("typed text dispatches input events", try await controller.inspect().contains("typed:hello audit"))
                audit.check("typed values stay out of the evidence log", !controller.events.contains { $0.message.contains("hello audit") })
                do { _ = try await controller.type(selector: "#secret", text: "x"); audit.check("password fields are refused", false) }
                catch { audit.check("password fields are refused", true) }
                do { _ = try await controller.click(selector: ".dup"); audit.check("ambiguous selectors are refused", false) }
                catch { audit.check("ambiguous selectors are refused", true) }
                do { _ = try await controller.click(selector: "#missing"); audit.check("missing selectors are refused", false) }
                catch { audit.check("missing selectors are refused", true) }
                do { _ = try await controller.click(selector: ""); audit.check("empty selectors are refused", false) }
                catch { audit.check("empty selectors are refused", true) }
                _ = try await controller.click(selector: "#external")
                for _ in 0..<100 where !controller.events.contains(where: { $0.kind == "blocked" }) { try await Task.sleep(nanoseconds: 20_000_000) }
                audit.check("navigation outside the local server is blocked", controller.events.contains { $0.kind == "blocked" })
                audit.equal("the local page remains open after a blocked navigation", controller.webView?.url?.host, "127.0.0.1")
                controller.viewport = .mobile
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                audit.check("changing devices refits the whole mobile viewport", controller.webView.map {
                    $0.visibleRect.insetBy(dx: -2, dy: -2).contains($0.bounds)
                } == true)
                let capture = try await controller.capture(taskID: UUID())
                let bitmap = NSBitmapImageRep(data: capture.png)
                audit.check("fitted captures retain full viewport resolution and aspect ratio", bitmap.map {
                    $0.pixelsWide >= 390 && abs(Double($0.pixelsWide) / Double($0.pixelsHigh) - 390.0 / 844.0) < 0.005
                } == true)
                audit.check("capture produces PNG bytes", capture.png.starts(with: [0x89, 0x50, 0x4E, 0x47]) && capture.png.count > 1_000)
                audit.check("capture carries recorded events", capture.events.contains { $0.kind == "error" } && capture.events.contains { $0.kind == "blocked" })
                audit.check("capture records the viewport", capture.viewport == .mobile)
                let mode = capture.evidenceURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? Int }
                audit.equal("evidence file is owner-only", mode, 0o600)
                let stored = try PrivateProjectFile(project: project, directory: storage, byteLimit: 24 * 1024 * 1024).load([UIVerificationCapture].self)
                audit.equal("evidence survives controller recreation", stored?.count, 1)
                audit.equal("stored evidence keeps the screenshot bytes", stored?.first?.png, capture.png)
                controller.stop()
                audit.check("stop releases the web view", controller.webView == nil)
                do { _ = try await controller.inspect(); audit.check("stopped preview refuses actions", false) }
                catch { audit.check("stopped preview refuses actions", true) }

                window.contentView = NSView(frame: window.contentLayoutRect)
                audit.section("Verification — agent preview tools through the computer socket")
                let model = AppModel(trust: .forAudit)
                model.installed = [:]
                model.projectURL = project
                defer { model.shutdown() }
                let control = try ComputerControl(model: model, project: project)
                model.computerControl = control
                // Evidence for this fixture stays in the audit's temporary folder, not in the
                // user's Application Support.
                model.uiVerification = UIVerificationController(project: project, artifactDirectory: storage)
                let connection = control.connection(for: .claude)
                func call(_ name: String, _ arguments: [String: Any], id: Int) async -> JSON {
                    let payload: [String: Any] = ["token": connection.token, "provider": "claude",
                        "request": ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]]
                    return JSON(await control.respond(payload))
                }
                let outside = await call("preview_open", ["url": "http://example.com/"], id: 1)
                audit.check("agents cannot open outside sites", outside["result"]["isError"].bool == true)
                audit.check("no preview is created for a refused address", model.uiVerification?.webView == nil)
                let opened = await call("preview_open", ["url": local, "viewport": "tablet"], id: 2)
                let openedText = opened["result"]["content"].array.first?["text"].string ?? ""
                audit.check("agent preview open returns the inspection", opened["result"]["isError"].bool == false && openedText.contains("Audit Preview"), openedText)
                audit.check("agent preview shows the verification sheet", model.showUIVerification)
                audit.equal("agent viewport choice applies", model.uiVerification?.viewport, .tablet)
                if let view = model.uiVerification?.webView { window.contentView?.addSubview(view) }
                let clicked = await call("preview_click", ["selector": "#go"], id: 3)
                audit.check("agent click works", clicked["result"]["isError"].bool == false)
                let typed = await call("preview_type", ["selector": "#secret", "text": "pw"], id: 4)
                audit.check("agent typing into password fields is refused", typed["result"]["isError"].bool == true)
                let captured = await call("preview_capture", [:], id: 5)
                let blocks = captured["result"]["content"].array
                audit.check("agent capture returns an image block", blocks.contains { $0["type"].string == "image" && ($0["data"].string?.count ?? 0) > 1_000 })
                audit.check("agent capture reports recorded problems", blocks.first?["text"].string?.contains("boom from page") == true)
                audit.check("agent capture evidence stays in the injected folder", model.uiVerification?.lastCapture?.evidenceURL?.path.hasPrefix(WorkspaceFileAccess.canonicalURL(storage).path) == true,
                            model.uiVerification?.lastCapture?.evidenceURL?.path ?? "nil")
                control.stop()
                let afterStop = await call("preview_inspect", [:], id: 6)
                audit.check("revoked computer access blocks preview tools", afterStop["error"].exists)
                window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            } catch { audit.check("local UI preview workflow completes", false, error.localizedDescription) }
        }
    }
}

/// A loopback-only HTTP server that answers every request with one fixed page.
final class LocalAuditServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.orrery.studio.audit.http")
    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(page: @escaping @Sendable (UInt16) -> String) async throws -> LocalAuditServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "app.orrery.studio.audit.http")
        // The handler must exist before start; the page text is filled in once the port is known.
        let response = LockedData()
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                connection.send(content: response.value, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumed.claim(), let port = listener.port?.rawValue else { return }
                    continuation.resume(returning: port)
                case let .failed(error):
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        let body = Data(page(port).utf8)
        response.value = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        return LocalAuditServer(listener: listener, port: port)
    }

    func stop() { listener.cancel() }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    var value: Data {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
}

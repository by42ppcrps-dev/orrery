import Foundation
import AppKit

/// The iOS Simulator, driven the way Xcode's own tools drive it: `xcrun simctl` for devices,
/// booting, installing, launching and screenshots; the Simulator app's window for touches
/// (events are posted to that app at the window's screen position, so it may sit behind
/// Orrery). Nothing here is private API.
struct SimulatorDevice: Equatable, Identifiable, Sendable {
    let udid: String
    let name: String
    let runtime: String      // "iOS 26.2"
    let state: String        // "Booted", "Shutdown"
    let isAvailable: Bool
    var id: String { udid }
    var isBooted: Bool { state == "Booted" }
    var title: String { "\(name) · \(runtime)" }
}

/// Where the device screen is on the Mac's display and how big the device is in points.
struct SimulatorScreen: Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    /// The device screen's rectangle in global (top-left origin) screen coordinates.
    let frame: CGRect
    /// The screenshot's pixel size for the same screen.
    let pixelSize: CGSize

    /// A point in screenshot pixels → the screen point to click.
    func screenPoint(forPixel x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: frame.minX + x * frame.width / pixelSize.width, y: frame.minY + y * frame.height / pixelSize.height)
    }
    /// A point in the pane's image (size `imageSize`) → screenshot pixels.
    static func pixel(forView point: CGPoint, imageSize: CGSize, pixelSize: CGSize) -> CGPoint {
        CGPoint(x: point.x * pixelSize.width / max(imageSize.width, 1), y: point.y * pixelSize.height / max(imageSize.height, 1))
    }
}

enum SimulatorError: LocalizedError {
    case notInstalled, noDevice, noWindow(String), failed(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Xcode's simulator tools (xcrun simctl) are not available on this Mac."
        case .noDevice: return "No simulator is booted. Boot one in the iPhone pane first."
        case let .noWindow(name): return "The Simulator app is not showing \(name). Open it (the iPhone pane's Show button) and try again."
        case let .failed(text): return text
        }
    }
}

final class SimulatorControl: @unchecked Sendable {
    static let shared = SimulatorControl()

    /// How `xcrun` is run; audits inject fixtures.
    var run: @Sendable ([String], TimeInterval) throws -> (status: Int32, stdout: Data, stderr: String) = SimulatorControl.xcrun
    /// Where the Simulator app's windows are; audits inject fixtures.
    var windows: @Sendable () -> [(id: CGWindowID, pid: pid_t, title: String, bounds: CGRect)] = SimulatorControl.simulatorWindows
    /// How events reach the Simulator app. Posting straight to its process is not enough — the
    /// Simulator only takes touches that arrive through the system event tap while it is the
    /// front app — so `deliver` brings it forward for the instant of the touch and hands focus
    /// back afterwards. Audits inject fakes for all three.
    var post: @Sendable (CGEvent, pid_t) -> Void = { event, _ in event.post(tap: .cghidEventTap) }
    var bringToFront: @Sendable (pid_t) -> Void = { pid in
        // Activation only takes effect from the main thread; touches arrive from background
        // tasks (the pane) and from the tool actor alike, so hop when needed.
        let activate = { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
        if Thread.isMainThread { activate() } else { DispatchQueue.main.sync { activate() } }
        usleep(200_000)
    }
    var giveFocusBack: @Sendable () -> Void = {
        usleep(120_000)
        // A plain activate from a background app is ignored by macOS once another app is in
        // front; ignoringOtherApps is what actually brings Orrery back over the Simulator.
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Every touch and key goes through here: front, events, back.
    private func deliver(_ events: [CGEvent], to pid: pid_t, gap: UInt32 = 30_000) {
        bringToFront(pid)
        for event in events { post(event, pid); usleep(gap) }
        giveFocusBack()
    }

    static let xcrun: @Sendable ([String], TimeInterval) throws -> (status: Int32, stdout: Data, stderr: String) = { arguments, timeout in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        deadline.cancel()
        return (process.terminationStatus, data, errorText)
    }

    static let simulatorWindows: @Sendable () -> [(id: CGWindowID, pid: pid_t, title: String, bounds: CGRect)] = {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowOwnerName as String] as? String == "Simulator",
                  (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard rect.width > 100, rect.height > 100 else { return nil }
            return (id, pid, info[kCGWindowName as String] as? String ?? "", rect)
        }
    }

    // MARK: Devices

    /// `simctl list devices -j` → devices, booted first, then by runtime and name.
    static func parseDevices(_ data: Data) -> [SimulatorDevice] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["devices"] as? [String: Any] else { return [] }
        var result: [SimulatorDevice] = []
        for (runtimeID, value) in runtimes {
            guard let list = value as? [[String: Any]] else { continue }
            let runtime = runtimeID.components(separatedBy: ".").last?.replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: #"^(iOS|watchOS|tvOS|xrOS|visionOS) (\d+) (\d+)$"#, with: "$1 $2.$3", options: .regularExpression) ?? runtimeID
            for device in list {
                guard let udid = device["udid"] as? String, let name = device["name"] as? String else { continue }
                result.append(SimulatorDevice(udid: udid, name: name, runtime: runtime, state: device["state"] as? String ?? "Shutdown",
                                              isAvailable: device["isAvailable"] as? Bool ?? false))
            }
        }
        return result.filter(\.isAvailable).sorted { a, b in
            if a.isBooted != b.isBooted { return a.isBooted }
            if a.runtime != b.runtime { return a.runtime > b.runtime }
            return a.name < b.name
        }
    }

    func devices() throws -> [SimulatorDevice] {
        let result = try run(["simctl", "list", "devices", "-j"], 20)
        guard result.status == 0 else { throw SimulatorError.failed(result.stderr.isEmpty ? "simctl list failed" : result.stderr) }
        return Self.parseDevices(result.stdout)
    }

    func booted() throws -> SimulatorDevice? { try devices().first(where: \.isBooted) }

    private func simctl(_ arguments: [String], timeout: TimeInterval = 60) throws -> Data {
        let result = try run(["simctl"] + arguments, timeout)
        guard result.status == 0 else { throw SimulatorError.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "simctl \(arguments.first ?? "") failed" : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return result.stdout
    }

    func boot(_ udid: String) throws { _ = try simctl(["boot", udid], timeout: 120) }
    func shutdown(_ udid: String) throws { _ = try simctl(["shutdown", udid]) }
    func install(_ udid: String, appPath: String) throws { _ = try simctl(["install", udid, appPath], timeout: 180) }
    func launch(_ udid: String, bundleID: String) throws -> String { String(decoding: try simctl(["launch", udid, bundleID]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    func terminate(_ udid: String, bundleID: String) throws { _ = try simctl(["terminate", udid, bundleID]) }
    func openURL(_ udid: String, url: String) throws { _ = try simctl(["openurl", udid, url]) }
    func listApps(_ udid: String) throws -> String { String(decoding: try simctl(["listapps", udid]), as: UTF8.self) }

    /// A PNG of the device screen, straight from the simulator (no window needed).
    func screenshot(_ udid: String) throws -> Data {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orrery-sim-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try simctl(["io", udid, "screenshot", "--type=png", file.path], timeout: 30)
        return try Data(contentsOf: file)
    }

    /// Brings the Simulator app up showing this device (it is also how touches become possible).
    func show(_ udid: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]
        try? process.run()
    }

    // MARK: Touches

    /// The device screen's place on the display: the Simulator window for this device, minus
    /// its title bar, matched to the screenshot's pixel size.
    func screen(for device: SimulatorDevice, pixelSize: CGSize) throws -> SimulatorScreen {
        guard let window = windows().first(where: { $0.title.contains(device.name) }) ?? windows().first else { throw SimulatorError.noWindow(device.name) }
        return Self.screen(window: window, pixelSize: pixelSize)
    }

    /// The window shows the device screen below a title bar; the screen keeps the device's
    /// aspect ratio inside what is left, centred.
    static func screen(window: (id: CGWindowID, pid: pid_t, title: String, bounds: CGRect), pixelSize: CGSize) -> SimulatorScreen {
        let titleBar: CGFloat = 28
        let content = CGRect(x: window.bounds.minX, y: window.bounds.minY + titleBar, width: window.bounds.width, height: max(window.bounds.height - titleBar, 1))
        let scale = min(content.width / max(pixelSize.width, 1), content.height / max(pixelSize.height, 1))
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        let frame = CGRect(x: content.midX - size.width / 2, y: content.midY - size.height / 2, width: size.width, height: size.height)
        return SimulatorScreen(windowID: window.id, pid: window.pid, frame: frame, pixelSize: pixelSize)
    }

    func tap(_ screen: SimulatorScreen, pixelX: Double, pixelY: Double) {
        let point = screen.screenPoint(forPixel: pixelX, pixelY)
        let events = [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp].compactMap { type -> CGEvent? in
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            return event
        }
        deliver(events, to: screen.pid)
    }

    func swipe(_ screen: SimulatorScreen, from: (Double, Double), to: (Double, Double), duration: TimeInterval = 0.3) {
        let start = screen.screenPoint(forPixel: from.0, from.1), end = screen.screenPoint(forPixel: to.0, to.1)
        let steps = 12
        var events: [CGEvent] = []
        if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) { events.append(down) }
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) { events.append(drag) }
        }
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) { events.append(up) }
        deliver(events, to: screen.pid, gap: UInt32(duration * 1_000_000 / Double(steps)))
    }

    func type(_ screen: SimulatorScreen, text: String) {
        let characters = Array(text.utf16)
        var events: [CGEvent] = []
        for start in stride(from: 0, to: characters.count, by: 64) {
            let chunk = Array(characters[start..<min(start + 64, characters.count)])
            for down in [true, false] {
                if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) {
                    event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    events.append(event)
                }
            }
        }
        deliver(events, to: screen.pid, gap: 5_000)
    }

    /// Hardware buttons the Simulator app exposes as shortcuts: Home ⇧⌘H, Lock ⌘L.
    func button(_ screen: SimulatorScreen, name: String) throws {
        let (key, flags): (CGKeyCode, CGEventFlags) = switch name.lowercased() {
        case "home": (4, [.maskCommand, .maskShift])
        case "lock": (37, [.maskCommand])
        default: throw SimulatorError.failed("Unknown button \(name); use home or lock.")
        }
        let events = [true, false].compactMap { down -> CGEvent? in
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = flags
            return event
        }
        deliver(events, to: screen.pid)
    }

    static func pngSize(_ data: Data) -> CGSize? {
        guard let image = NSBitmapImageRep(data: data) else { return nil }
        return CGSize(width: image.pixelsWide, height: image.pixelsHigh)
    }
}

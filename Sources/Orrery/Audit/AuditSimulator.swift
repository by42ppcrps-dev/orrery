import Foundation
import AppKit

/// The iPhone simulator: the device list as simctl prints it, the arithmetic that turns a click
/// on the pane into a touch on the device, the events that reach the Simulator app, the tool
/// group agents get — and, when a simulator is booted on this Mac, a real screenshot.
@MainActor
enum AuditSimulator {
    static func run(_ audit: Auditor) async {
        audit.section("Simulator — the device list is read the way simctl prints it")
        let fixture = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
            {"udid": "AAAA-1", "name": "iPhone 16", "state": "Booted", "isAvailable": true, "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16"},
            {"udid": "AAAA-2", "name": "iPad Pro 11-inch (M4)", "state": "Shutdown", "isAvailable": true}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-18-4": [
            {"udid": "BBBB-1", "name": "iPhone 15", "state": "Shutdown", "isAvailable": true},
            {"udid": "BBBB-2", "name": "iPhone Old", "state": "Shutdown", "isAvailable": false, "availabilityError": "runtime profile not found"}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-11-4": []
        }}
        """
        let devices = SimulatorControl.parseDevices(Data(fixture.utf8))
        audit.equal("available devices, booted first, newest runtime next, by name", devices.map(\.udid), ["AAAA-1", "AAAA-2", "BBBB-1"])
        audit.check("the runtime reads as a version", devices.first?.runtime == "iOS 26.2" && devices.last?.runtime == "iOS 18.4", devices.map(\.runtime).description)
        audit.check("the booted one is marked and titled", devices.first?.isBooted == true && devices.first?.title == "iPhone 16 · iOS 26.2")
        audit.check("garbage parses to an empty list", SimulatorControl.parseDevices(Data("not json".utf8)).isEmpty)

        audit.section("Simulator — a click on the pane lands on the device")
        // A 402-point-wide Simulator window at (100, 50) with a 28-pt title bar showing an
        // iPhone screenshot of 1179×2556 pixels.
        let window = (id: CGWindowID(7), pid: pid_t(4242), title: "iPhone 16 – iOS 26.2", bounds: CGRect(x: 100, y: 50, width: 402, height: 900))
        let screen = SimulatorControl.screen(window: window, pixelSize: CGSize(width: 1179, height: 2556))
        audit.check("the device screen keeps its aspect inside the window below the title bar",
                    abs(screen.frame.width / screen.frame.height - 1179.0 / 2556.0) < 0.001 && screen.frame.minY >= 78 && screen.frame.maxY <= 950 && screen.frame.minX >= 100 && screen.frame.maxX <= 502,
                    "\(screen.frame)")
        let topLeft = screen.screenPoint(forPixel: 0, 0), bottomRight = screen.screenPoint(forPixel: 1179, 2556), centre = screen.screenPoint(forPixel: 589.5, 1278)
        audit.check("pixel (0,0) is the screen's top-left and the last pixel its bottom-right", topLeft == CGPoint(x: screen.frame.minX, y: screen.frame.minY) && abs(bottomRight.x - screen.frame.maxX) < 0.01 && abs(bottomRight.y - screen.frame.maxY) < 0.01)
        audit.check("the centre pixel is the centre of the screen", abs(centre.x - screen.frame.midX) < 0.01 && abs(centre.y - screen.frame.midY) < 0.01)
        let pixel = SimulatorScreen.pixel(forView: CGPoint(x: 150, y: 325), imageSize: CGSize(width: 300, height: 650), pixelSize: CGSize(width: 1179, height: 2556))
        audit.check("a click in the middle of the pane's picture is the middle pixel", abs(pixel.x - 589.5) < 0.01 && abs(pixel.y - 1278) < 0.01, "\(pixel)")

        audit.section("Simulator — touches and keys go to the Simulator app, not the screen in front")
        final class Posted: @unchecked Sendable { let lock = NSLock(); var events: [(CGEventType, CGPoint, pid_t)] = [] }
        let posted = Posted()
        let control = SimulatorControl()
        final class Focus: @unchecked Sendable { let lock = NSLock(); var log: [String] = [] }
        let focus = Focus()
        control.bringToFront = { pid in focus.lock.lock(); focus.log.append("front:\(pid)"); focus.lock.unlock() }
        control.giveFocusBack = { focus.lock.lock(); focus.log.append("back"); focus.lock.unlock() }
        control.post = { event, pid in
            posted.lock.lock(); posted.events.append((event.type, event.location, pid)); posted.lock.unlock()
            focus.lock.lock(); focus.log.append("event"); focus.lock.unlock()
        }
        control.windows = { [window] }
        let device = SimulatorDevice(udid: "AAAA-1", name: "iPhone 16", runtime: "iOS 26.2", state: "Booted", isAvailable: true)
        let found = try? control.screen(for: device, pixelSize: CGSize(width: 1179, height: 2556))
        audit.check("the device's window is found by its title", found?.pid == 4242 && found?.windowID == 7)
        control.tap(screen, pixelX: 589.5, pixelY: 1278)
        let tap = posted.events
        audit.check("a tap is move, down, up at the same point, addressed to the Simulator's pid",
                    tap.map(\.0) == [.mouseMoved, .leftMouseDown, .leftMouseUp] && tap.allSatisfy { $0.2 == 4242 && abs($0.1.x - centre.x) < 0.01 && abs($0.1.y - centre.y) < 0.01 }, tap.map { "\($0.0.rawValue)@\($0.1)" }.description)
        audit.equal("the Simulator app is brought to the front before the touch and Orrery gets focus back after it",
                    focus.log, ["front:4242", "event", "event", "event", "back"])
        posted.lock.lock(); posted.events = []; posted.lock.unlock()
        control.swipe(screen, from: (589.5, 2000), to: (589.5, 500), duration: 0.05)
        let swipe = posted.events
        audit.check("a swipe is down, a run of drags, then up, ending where the finger lifted",
                    swipe.first?.0 == .leftMouseDown && swipe.last?.0 == .leftMouseUp && swipe.dropFirst().dropLast().allSatisfy { $0.0 == .leftMouseDragged } && swipe.count >= 8
                    && (swipe.last.map { abs($0.1.y - screen.screenPoint(forPixel: 589.5, 500).y) < 0.01 } ?? false), "\(swipe.count) events")
        posted.lock.lock(); posted.events = []; posted.lock.unlock()
        control.type(screen, text: "hello")
        audit.check("typing posts key down/up pairs to the same app", posted.events.count == 2 && posted.events.allSatisfy { $0.0 == .keyDown || $0.0 == .keyUp } && posted.events.allSatisfy { $0.2 == 4242 })
        posted.lock.lock(); posted.events = []; posted.lock.unlock()
        try? control.button(screen, name: "home")
        audit.check("Home is the Simulator's ⇧⌘H", posted.events.count == 2 && posted.events.first?.0 == .keyDown)
        audit.check("an unknown button is refused", (try? control.button(screen, name: "volume")) == nil)
        control.windows = { [] }
        audit.check("without the Simulator window a touch is refused with advice", (try? control.screen(for: device, pixelSize: CGSize(width: 1, height: 1))) == nil
                    && (SimulatorError.noWindow("iPhone 16").errorDescription ?? "").contains("Show"))

        audit.section("Simulator — agents get the tools only when the pane's switch is on")
        audit.equal("simulator_* tools form their own group", ComputerControl.group(of: "simulator_tap"), .simulator)
        let names = ComputerControl.tools(for: [.simulator]).compactMap { $0["name"] as? String }
        audit.check("the group lists the whole set", ["simulator_list", "simulator_boot", "simulator_screenshot", "simulator_tap", "simulator_swipe", "simulator_type", "simulator_launch", "simulator_install", "simulator_open_url", "simulator_button"].allSatisfy(names.contains), names.description)
        audit.check("without the group none of them is offered", ComputerControl.tools(for: [.ide, .desktop, .browser]).compactMap { $0["name"] as? String }.allSatisfy { !$0.hasPrefix("simulator_") })
        audit.check("listing and screenshots are read-only, taps are not",
                    (ComputerControl.tools(for: [.simulator]).first { $0["name"] as? String == "simulator_screenshot" }?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true
                    && (ComputerControl.tools(for: [.simulator]).first { $0["name"] as? String == "simulator_tap" }?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == false)
        let model = AppModel(trust: .forAudit)
        audit.check("the switch is off for a new project", !model.simulatorAgentsAllowed)
        audit.check("the switch is what adds the group", !model.baseToolGroups.contains(.simulator) && { model.simulatorAgentsAllowed = true; return model.baseToolGroups.contains(.simulator) }())
        model.simulatorAgentsAllowed = false   // the headless preferences are shared with the sections that follow
        audit.check("…and switching it off removes it", !model.baseToolGroups.contains(.simulator))

        audit.section("Simulator — the real simctl on this Mac")
        let real = SimulatorControl()
        if let list = try? real.devices() {
            audit.check("simctl lists this Mac's simulators", !list.isEmpty, "\(list.count) devices")
            if let booted = list.first(where: \.isBooted) {
                let data = try? real.screenshot(booted.udid)
                let size = data.flatMap(SimulatorControl.pngSize)
                audit.check("a booted simulator gives a PNG screenshot with a size", (data?.count ?? 0) > 1_000 && (size?.width ?? 0) > 100, "\(booted.title): \(data?.count ?? 0) bytes \(size.map { "\($0)" } ?? "")")
            } else {
                audit.check("no simulator is booted, so the screenshot path is not exercised here", true)
            }
        } else {
            audit.check("simctl is not available on this Mac, so the live path is not exercised", true)
        }
    }
}

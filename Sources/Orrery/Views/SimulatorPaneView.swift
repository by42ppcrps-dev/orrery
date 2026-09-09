import SwiftUI
import AppKit

/// The iPhone pane: a booted simulator's screen, live, in the editor area. Click and drag on
/// it to tap and swipe; the keyboard types into it. The picture comes from `simctl` (no
/// screen-recording permission needed); touches go to the Simulator app's window.
struct SimulatorPaneView: View {
    @Bindable var model: AppModel
    @State private var devices: [SimulatorDevice] = []
    @State private var selected: String = ""
    @State private var image: NSImage?
    @State private var pixelSize = CGSize.zero
    @State private var problem: String?
    @State private var status = "Looking for simulators…"
    @State private var refreshing = false
    @State private var dragStart: CGPoint?
    @State private var focused = false
    @FocusState private var keyboardFocus: Bool

    private let control = SimulatorControl.shared
    private let timer = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()

    private var device: SimulatorDevice? { devices.first { $0.udid == selected } ?? devices.first(where: \.isBooted) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            screen
            Divider()
            footer
        }
        .onAppear(perform: reloadDevices)
        .onReceive(timer) { _ in refresh() }
        .onChange(of: selected) { _, _ in
            image = nil; pixelSize = .zero; problem = nil
            status = "Loading screen…"
            refresh()
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Device", selection: $selected) {
                    ForEach(devices) { device in Text(device.title + (device.isBooted ? " · booted" : "")).tag(device.udid) }
                }
                .labelsHidden().frame(maxWidth: .infinity)
                .help("Simulators Xcode has on this Mac")
                Button { reloadDevices() } label: { Image(systemName: "arrow.clockwise") }.help("Reload the device list")
            }
            HStack(spacing: 8) {
                if let device, !device.isBooted {
                    Button("Boot") { act("Booting \(device.name)…") { try control.boot(device.udid) } }
                }
                Button("Show") { if let device { control.show(device.udid) } }
                    .disabled(device == nil)
                    .help("Open the Simulator app on this device; touches from this pane need its window")
                Button("Home") { press("home") }.disabled(device?.isBooted != true)
                Button("Lock") { press("lock") }.disabled(device?.isBooted != true)
                Spacer(minLength: 0)
                Toggle(model.blanketApproval ? "Agent access · automatic" : "Agent access",
                       isOn: Binding(get: { model.agentsMayUseSimulator }, set: { model.simulatorAgentsAllowed = $0 }))
                    .toggleStyle(.checkbox).font(.caption).disabled(!model.isProjectTrusted || model.blanketApproval)
                    .help("Gives every agent simulator_* tools: list, boot, install, launch, screenshot, tap, swipe, type, open URL. The blanket bypass switches this on everywhere.")
            }
        }.controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var screen: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.85)
                if let image, pixelSize.width > 0 {
                    let fit = fitted(in: geometry.size)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(focused ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: focused ? 2 : 1))
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in if dragStart == nil { dragStart = value.startLocation } }
                            .onEnded { value in
                                defer { dragStart = nil }
                                keyboardFocus = true
                                let from = SimulatorScreen.pixel(forView: value.startLocation, imageSize: fit, pixelSize: pixelSize)
                                let to = SimulatorScreen.pixel(forView: value.location, imageSize: fit, pixelSize: pixelSize)
                                let moved = hypot(value.translation.width, value.translation.height)
                                touch(from: from, to: to, isTap: moved < 6)
                            })
                        .focusable()
                        .focused($keyboardFocus)
                        .onKeyPress(phases: .down) { press in
                            guard let text = keyText(press) else { return .ignored }
                            typeText(text)
                            return .handled
                        }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "iphone").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text(status).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(30)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onChange(of: keyboardFocus) { _, on in focused = on }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let problem { Text(problem).font(.caption).foregroundStyle(.red).lineLimit(2) }
            else { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Text("Click to tap, drag to swipe, type to type. The picture refreshes about every second.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private func fitted(in size: CGSize) -> CGSize {
        let scale = min((size.width - 24) / max(pixelSize.width, 1), (size.height - 24) / max(pixelSize.height, 1))
        return CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    }

    private func reloadDevices() {
        Task.detached {
            do {
                let list = try control.devices()
                await MainActor.run {
                    devices = list
                    if selected.isEmpty || !list.contains(where: { $0.udid == selected }) { selected = list.first(where: \.isBooted)?.udid ?? list.first?.udid ?? "" }
                    status = list.isEmpty ? "No simulators found. Install a platform in Xcode → Settings → Components." : (list.contains(where: \.isBooted) ? "Live" : "Pick a device and press Boot.")
                    problem = nil
                }
            } catch {
                await MainActor.run { problem = error.localizedDescription; status = "" }
            }
        }
    }

    private func refresh() {
        guard !refreshing, let device, device.isBooted else { return }
        refreshing = true
        let udid = device.udid
        Task.detached {
            defer { Task { @MainActor in refreshing = false } }
            do {
                let data = try control.screenshot(udid)
                guard let picture = NSImage(data: data), let size = SimulatorControl.pngSize(data) else {
                    throw ComputerError("The simulator did not return a readable screenshot.")
                }
                await MainActor.run {
                    guard selected == udid else { return }
                    image = picture; pixelSize = size; problem = nil; status = "Live · \(device.title)"
                }
            } catch {
                await MainActor.run {
                    guard selected == udid else { return }
                    problem = error.localizedDescription; status = "Screen unavailable"
                }
            }
        }
    }

    private func act(_ text: String, _ work: @escaping @Sendable () throws -> Void) {
        status = text; problem = nil
        Task.detached {
            do { try work(); await MainActor.run { reloadDevices() } }
            catch { await MainActor.run { problem = error.localizedDescription } }
        }
    }

    private func touch(from: CGPoint, to: CGPoint, isTap: Bool) {
        guard let device, pixelSize.width > 0 else { return }
        let size = pixelSize
        Task.detached {
            do {
                let screen = try control.screen(for: device, pixelSize: size)
                let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                if isTap { control.tap(screen, pixelX: from.x, pixelY: from.y) }
                else { control.swipe(screen, from: (from.x, from.y), to: (to.x, to.y)) }
                let after = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                let point = screen.screenPoint(forPixel: from.x, from.y)
                await MainActor.run {
                    problem = nil
                    status = "\(isTap ? "Tapped" : "Swiped") pixel (\(Int(from.x)), \(Int(from.y))) → screen (\(Int(point.x)), \(Int(point.y))) in window \(screen.windowID); front \(before) → \(after)"
                }
            } catch { await MainActor.run { problem = error.localizedDescription } }
        }
    }

    private func typeText(_ text: String) {
        guard let device, pixelSize.width > 0 else { return }
        let size = pixelSize
        Task.detached {
            do { let screen = try control.screen(for: device, pixelSize: size); control.type(screen, text: text) }
            catch { await MainActor.run { problem = error.localizedDescription } }
        }
    }

    private func press(_ name: String) {
        guard let device, pixelSize.width > 0 else { return }
        let size = pixelSize
        Task.detached {
            do { let screen = try control.screen(for: device, pixelSize: size); try control.button(screen, name: name) }
            catch { await MainActor.run { problem = error.localizedDescription } }
        }
    }

    private func keyText(_ press: KeyPress) -> String? {
        if press.key == .return { return "\n" }
        if press.key == .delete { return "\u{8}" }
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) { return nil }
        let text = press.characters
        return text.isEmpty ? nil : text
    }
}

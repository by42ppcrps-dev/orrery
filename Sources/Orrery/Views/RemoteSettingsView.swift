import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import OrreryRemoteProtocol

/// Agent settings → Remote: the switch, the pairing code, and the paired phones.
struct RemoteSettingsView: View {
    @Bindable var model: AppModel
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var remote: RemoteControl { model.remote }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remote control").font(.headline)
            Text("Control this Mac's Orrery from your iPhone with the Orrery Remote app: switch open projects, read conversations, send messages, approve or deny tool requests and stop work. Off by default. Everything travels sealed between the two devices with keys made at pairing; nothing goes through a server of ours. Same Wi‑Fi, or a VPN such as Tailscale when you are away.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Allow control from paired devices", isOn: Binding(get: { remote.enabled }, set: { remote.enabled = $0 }))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Relay").font(.callout.weight(.semibold))
                    TextField("https://orrery-relay.<you>.workers.dev (leave empty for LAN or VPN only)", text: Binding(get: { remote.relayURL }, set: { remote.relayURL = $0.trimmingCharacters(in: .whitespaces) }))
                        .textFieldStyle(.roundedBorder)
                    if !remote.relayURL.isEmpty { Text(remote.relayPhoneConnected ? "phone connected" : remote.relayStatus).font(.caption).foregroundStyle(.secondary) }
                }
                Text("A relay lets the phone reach this Mac from any network. Deploy Remote/OrreryRelay to your own Cloudflare account (npx wrangler deploy), paste its URL here, then pair the phone again so its code carries the room. Frames stay sealed end to end; the relay only checks the room token.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if remote.enabled {
                HStack(spacing: 8) {
                    Circle().fill(remote.listening ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(remote.listening ? "Listening on port \(remote.port) · \(remote.connectedDevices.count) connected" : (remote.lastError ?? "Starting…"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(remote.offer == nil ? "Pair a Device…" : "New Pairing Code") { remote.model = model; remote.startPairing() }.disabled(!remote.listening)
                }
                if let offer = remote.offer {
                    pairingCard(offer)
                }
            }
            if !remote.devices.isEmpty {
                Text("Paired devices").font(.headline)
                ForEach(remote.devices) { device in
                    HStack {
                        Image(systemName: remote.connectedDevices.contains(device.id) ? "iphone.radiowaves.left.and.right" : "iphone")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))" + (device.lastSeen.map { " · last seen \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { remote.revoke(device.id) }.controlSize(.small)
                    }
                }
            } else if remote.enabled {
                Text("No device is paired yet. Tap Pair in Orrery Remote on your iPhone and scan the code.").font(.caption).foregroundStyle(.secondary)
            }
            Text("A paired phone can do exactly what this window can: send, approve, stop. It cannot enable computer control, change the approval rules or edit settings. Remove a device here to revoke it at once.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onReceive(clock) { now = $0 }
    }

    private func pairingCard(_ offer: PairingOffer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                if let image = Self.qrImage(offer.qrString) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                        .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Pairing code")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scan with Orrery Remote").font(.callout.weight(.semibold))
                    Text("Reachable at " + (offer.hosts.isEmpty ? "no network address" : offer.hosts.map { "\($0):\(offer.port)" }.joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.secondary)
                    let left = max(0, Int(offer.expires.timeIntervalSince(now)))
                    Text(left > 0 ? "Expires in \(left / 60):\(String(format: "%02d", left % 60)) · one use" : "Expired — make a new code")
                        .font(.caption).foregroundStyle(left > 0 ? Color.secondary : Color.orange)
                    HStack {
                        Button("Copy Code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(offer.qrString, forType: .string) }.controlSize(.small)
                        Button("Cancel") { remote.cancelPairing() }.controlSize(.small)
                    }
                    Text("The code carries this Mac's public key and a one-time secret. Anyone who sees it within its lifetime could pair, so keep it on this screen.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

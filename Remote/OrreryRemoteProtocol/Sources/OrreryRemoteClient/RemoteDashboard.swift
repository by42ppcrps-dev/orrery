import SwiftUI
import OrreryRemoteProtocol
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum RemoteDeviceName {
    static var current: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
}

/// Shared on Mac, iPhone and iPad. Each destination observes its own client, so one offline
/// host never prevents the others updating. No transcript or credential is copied to a cloud account.
public struct RemoteDashboard: View {
    @ObservedObject private var hub: RemoteHub
    private var localState: RemoteState?
    private var localSelect: ((RemoteState.Activity) -> Void)?
    @State private var query = ""
    @State private var scope: ActivityScope = .all
    @State private var pairing: RemoteClient?
    public init(hub: RemoteHub, localState: RemoteState? = nil, localSelect: ((RemoteState.Activity) -> Void)? = nil) {
        self.hub = hub; self.localState = localState; self.localSelect = localSelect
    }
    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("All your Orrery work, together").font(.title2.weight(.semibold))
                    Text("Follow open projects and agents on your paired Macs. Select a conversation to read, send, approve or stop.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Picker("Show activity", selection: $scope) {
                        ForEach(ActivityScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
                if let localState {
                    Section {
                        Label("This Mac · live", systemImage: "desktopcomputer").font(.headline)
                        activityRows(localState, query: query, scope: scope, enabled: true) { localSelect?($0) }
                    }
                }
                ForEach(hub.clients.filter { $0.mac?.deviceID.isEmpty == false }) { client in
                    DeviceActivitySection(client: client, query: query, scope: scope)
                }
                if hub.clients.allSatisfy({ $0.mac?.deviceID.isEmpty != false }) {
                    Section {
                        Label("Pair your first Mac", systemImage: "laptopcomputer.and.iphone").font(.headline)
                        Text("On the Mac you want to follow, open Agent settings → Remote. Turn on remote control and choose Pair a Device. Add that code here.")
                            .foregroundStyle(.secondary)
                        Button("Add a Mac") { pairing = hub.add() }.buttonStyle(.borderedProminent)
                    }
                }
                if let error = hub.error { Section { Text(error).foregroundStyle(.orange); Button("Try again") { hub.load() } } }
                Section {
                    Text("Only work started in Orrery appears here. Macs must stay awake with Orrery open. Native CLI status is visible; its terminal and provider-owned prompts stay on the host Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Activity")
            .searchable(text: $query, prompt: "Project, agent or task")
            .toolbar {
                ToolbarItem { Button { hub.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") } }
                ToolbarItem { Button { pairing = hub.add() } label: { Label("Add a Mac", systemImage: "plus") } }
            }
            .sheet(item: $pairing, onDismiss: {
                for client in hub.clients where client.mac?.deviceID.isEmpty != false { hub.cancelPairing(client) }
            }) { client in
                RemotePairingView(client: client) { pairing = nil }
            }
            .task { hub.load() }
        }
    }
}

private struct DeviceActivitySection: View {
    @ObservedObject var client: RemoteClient
    let query: String
    let scope: ActivityScope
    var body: some View {
        Section {
            HStack {
                Label(client.state?.macName ?? client.mac?.name ?? "Mac", systemImage: "desktopcomputer").font(.headline)
                Spacer()
                Text(client.connectionLabel).font(.caption.weight(.medium)).foregroundStyle(client.isLive ? Color.green : Color.orange)
            }
            if !client.isLive {
                if let date = client.lastReceived { Text("Last received \(date.formatted(date: .abbreviated, time: .shortened)). Showing saved activity.").font(.caption).foregroundStyle(.secondary) }
                if let error = client.lastError { Text(error).font(.caption).foregroundStyle(.secondary) }
                Button("Reconnect this Mac") { client.connect() }
            }
            if let state = client.state {
                if let rows = state.activities {
                    ForEach(state.matchingActivities(query: query, scope: scope)) { row in
                        NavigationLink {
                            SessionView().environmentObject(client).task { client.selectActivity(row) }
                        } label: { ActivityRow(row: row, live: client.isLive) }
                        .disabled(!client.isLive || client.sending || client.selecting)
                    }
                    activityLimitNotice(state)
                    if !rows.isEmpty && state.matchingActivities(query: query, scope: scope).isEmpty { Text("No matching activity.").foregroundStyle(.secondary) }
                    if rows.isEmpty { Text("No projects open. Open a project on this Mac to begin.").foregroundStyle(.secondary) }
                } else {
                    Text("Update Orrery on this Mac to see activity across all agents.").foregroundStyle(.secondary)
                }
            }
            NavigationLink("Connection and conversation") { SessionView().environmentObject(client) }
        }
    }
}

@ViewBuilder
private func activityRows(_ state: RemoteState, query: String, scope: ActivityScope, enabled: Bool, select: @escaping (RemoteState.Activity) -> Void) -> some View {
    ForEach(state.matchingActivities(query: query, scope: scope)) { row in
        Button { select(row) } label: { ActivityRow(row: row, live: enabled) }.buttonStyle(.plain)
    }
    activityLimitNotice(state)
    if state.activities?.isEmpty != false { Text("Open a project on this Mac to begin.").foregroundStyle(.secondary) }
}

@ViewBuilder
private func activityLimitNotice(_ state: RemoteState) -> some View {
    if let count = state.activityCount, count > (state.activities?.count ?? 0) {
        Text("Showing \(state.activities?.count ?? 0) of \(count) activities. Open the host Mac to see the rest.").font(.caption).foregroundStyle(.secondary)
    }
}

private struct ActivityRow: View {
    let row: RemoteState.Activity
    let live: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.mode == "cli" ? "terminal" : row.mode == "team" ? "person.3" : "bubble.left.and.bubble.right")
                .frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text("\(row.project) · \(row.mode == "cli" ? "CLI" : row.mode.capitalized)").font(.caption).foregroundStyle(.secondary)
                Text(row.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            if live && row.approvalCount > 0 {
                Label("\(row.approvalCount)", systemImage: "hand.raised.fill").font(.caption).foregroundStyle(.orange)
                    .accessibilityLabel("\(row.approvalCount) project decisions waiting")
            } else if live && row.isBusy {
                Label(row.mode == "cli" ? "Open" : "Working", systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
            } else if !live { Text("Offline").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 6).contentShape(Rectangle())
    }
}

private struct RemotePairingView: View {
    @ObservedObject var client: RemoteClient
    var done: () -> Void
    @State private var code = ""
    @State private var scanning = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Connect securely") {
                    Text("On the Mac you want to follow, open Agent settings → Remote → Pair a Device.")
                    Text("Pair each Mac once on this device. Use the same Wi-Fi, your VPN, or a relay configured on that Mac.").foregroundStyle(.secondary)
                    #if os(iOS)
                    Button { scanning = true } label: { Label("Scan the code", systemImage: "qrcode.viewfinder") }
                        .disabled(client.phase == .connecting)
                    #endif
                    TextField("Paste pairing code", text: $code, axis: .vertical).lineLimit(2...5)
                        .font(.caption.monospaced()).privacySensitive().autocorrectionDisabled()
                        .accessibilityIdentifier("pairing-code")
                    Button("Connect") { client.pair(with: code, deviceName: RemoteDeviceName.current); code = "" }
                        .buttonStyle(.borderedProminent).disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || client.phase == .connecting)
                    if client.phase == .connecting { ProgressView("Connecting to your Mac…") }
                    if let error = client.lastError { Text(error).foregroundStyle(.orange) }
                }
                Section { Text("A paired device can read open projects, send messages, approve tools and stop work. Remove it in the host Mac's Remote settings to revoke access.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Add a Mac")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { client.cancelPairing(); done() } } }
            .onChange(of: client.phase) { _, phase in if phase == .connected { done() } }
            #if os(iOS)
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    ScannerView { code in scanning = false; client.pair(with: code, deviceName: RemoteDeviceName.current) }
                        .navigationTitle("Scan Mac's code")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
                }
            }
            #endif
        }
        #if os(macOS)
        .frame(width: 520, height: 470)
        #endif
    }
}

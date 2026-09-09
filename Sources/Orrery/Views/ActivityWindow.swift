import SwiftUI
import AppKit
import OrreryRemoteProtocol
import OrreryRemoteClient

@MainActor
final class ActivityWindowSupport: NSObject, NSWindowDelegate {
    static let shared = ActivityWindowSupport()
    private var window: NSWindow?
    private let hub = RemoteHub()
    func open() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 880, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Orrery — Activity"
        window.contentMinSize = NSSize(width: 640, height: 520)
        window.contentView = NSHostingView(rootView: ActivityWorkspaceView(hub: hub))
        window.isReleasedWhenClosed = false; window.delegate = self
        self.window = window; hub.setActive(true)
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        hub.setActive(false); window = nil
    }
}

private struct ActivityWorkspaceView: View {
    @ObservedObject var hub: RemoteHub
    @State private var selected: RemoteState.Activity?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            RemoteDashboard(hub: hub, localState: RemoteControl.shared.snapshot().boundedForTransport()) { selected = $0 }
        }
        .sheet(item: $selected) { LocalActivityConversation(activity: $0) }
    }
}

private struct LocalActivityConversation: View {
    let activity: RemoteState.Activity
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var error: String?
    @State private var sending = false
    private var control: RemoteControl { .shared }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let state = control.snapshot(projectID: activity.projectID, mode: activity.mode, provider: activity.provider)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(activity.title).font(.title2.weight(.semibold))
                        Text(state.project ?? "Project closed").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.isBusy {
                        Button("Stop", role: .destructive) {
                            Task { error = await control.perform(.init(kind: .stop, target: activity.mode, provider: activity.provider.isEmpty ? nil : activity.provider, projectID: activity.projectID)) }
                        }
                    }
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Text(state.status).font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(state.permissions) { permission in
                            VStack(alignment: .leading, spacing: 6) {
                                Label(permission.title, systemImage: "hand.raised.fill").foregroundStyle(.orange)
                                Text(permission.detail).font(.caption.monospaced()).textSelection(.enabled)
                                HStack {
                                    ForEach(permission.options) { option in
                                        Button(option.name) { Task { error = await control.perform(.init(kind: .approve, text: option.id, target: permission.id, projectID: activity.projectID)) } }
                                    }
                                }
                            }.padding().background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        ForEach(state.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.speaker).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if state.entries.isEmpty { Text(activity.mode == "cli" ? "Open the terminal in the host workspace to see its output." : "No messages yet.").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                if activity.mode != "cli" {
                    HStack(alignment: .bottom) {
                        TextField("Message this conversation", text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                        Button(sending ? "Sending…" : "Send") {
                            let text = draft
                            sending = true
                            Task {
                                error = await control.perform(.init(kind: .send, text: text, target: activity.mode, provider: activity.provider.isEmpty ? nil : activity.provider, projectID: activity.projectID))
                                if error == nil, draft == text { draft = "" }; sending = false
                            }
                        }.disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.projectID == nil)
                    }
                }
            }.padding(24)
        }.frame(width: 700, height: 600)
    }
}

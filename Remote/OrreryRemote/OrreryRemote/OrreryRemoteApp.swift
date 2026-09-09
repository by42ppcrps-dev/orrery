import SwiftUI
import OrreryRemoteProtocol

private enum StudioStyle {
    static let background = Color(red: 0.035, green: 0.045, blue: 0.075)
    static let panel = Color(red: 0.075, green: 0.09, blue: 0.135)
    static let accent = Color(red: 0.66, green: 0.58, blue: 1)
    static let mint = Color(red: 0.43, green: 0.91, blue: 0.77)
}

@main
struct OrreryRemoteApp: App {
    @StateObject private var client = RemoteClient()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(client).tint(StudioStyle.accent).preferredColorScheme(.dark) }
    }
}

struct RootView: View {
    @EnvironmentObject private var client: RemoteClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = false
    var body: some View {
        NavigationStack {
            Group {
                if client.mac?.deviceID.isEmpty != false { PairingView() }
                else { SessionView() }
            }
            .background(StudioStyle.background.ignoresSafeArea())
        }
        .overlay {
            if scenePhase != .active {
                ZStack { StudioStyle.background.ignoresSafeArea(); OrbitMark().frame(width: 80, height: 80) }
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: scenePhase) { _, phase in client.setActive(phase == .active) }
        .task {
            guard !started else { return }; started = true
            client.setActive(true)
            #if DEBUG
            // Development-only simulator hooks. Release builds do not consume pairing tokens
            // or send instructions from launch arguments.
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--pair"), index + 1 < arguments.count, client.mac?.deviceID.isEmpty != false {
                client.pair(with: arguments[index + 1], deviceName: UIDeviceName.current)
            }
            #endif
        }
    }
}

private struct OrbitMark: View {
    var body: some View {
        ZStack {
            Circle().fill(StudioStyle.accent.opacity(0.12))
            Ellipse().stroke(StudioStyle.accent.opacity(0.8), lineWidth: 1.5).padding(12).rotationEffect(.degrees(-35))
            Ellipse().stroke(StudioStyle.mint.opacity(0.65), lineWidth: 1).padding(20).rotationEffect(.degrees(35))
            Circle().fill(StudioStyle.mint).frame(width: 12, height: 12).offset(x: 23, y: -21)
            Circle().fill(.white).frame(width: 6, height: 6)
        }.accessibilityHidden(true)
    }
}

struct PairingView: View {
    @EnvironmentObject private var client: RemoteClient
    @State private var pasted = ""
    @State private var scanning = false
    @State private var showPaste = false
    @FocusState private var editing: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack { Label("ORRERY", systemImage: "sparkle").font(.caption.weight(.bold)).tracking(3); Spacer(); Text("REMOTE").font(.caption2.weight(.semibold)).foregroundStyle(StudioStyle.mint) }
                VStack(alignment: .leading, spacing: 16) {
                    OrbitMark().frame(width: 96, height: 96)
                    Text("Your ideas.\nStill in motion.").font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("Keep building with your AI team, wherever you are. Your Mac does the work. You stay in control.")
                        .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 12)
                VStack(alignment: .leading, spacing: 18) {
                    setupStep("1", "Open Orrery on your Mac", "Go to Agent settings → Remote.")
                    setupStep("2", "Turn on remote control", "Choose Pair a Device to show a private code.")
                    setupStep("3", "Connect this iPhone", "Same Wi-Fi or your VPN — or, if the Mac has a relay set up, from anywhere.")
                }.padding(20).background(StudioStyle.panel, in: RoundedRectangle(cornerRadius: 24))
                VStack(spacing: 12) {
                    Button { scanning = true; editing = false } label: {
                        Label("Scan your Mac's code", systemImage: "qrcode.viewfinder").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).disabled(client.phase == .connecting)
                    Button("Paste a pairing code instead") { withAnimation { showPaste.toggle() } }.font(.callout)
                    if showPaste {
                        TextField("Pairing code", text: $pasted, axis: .vertical)
                            .lineLimit(2...4).font(.caption.monospaced()).padding(14)
                            .background(StudioStyle.panel, in: RoundedRectangle(cornerRadius: 14))
                            .autocorrectionDisabled().textInputAutocapitalization(.never).focused($editing)
                            .accessibilityIdentifier("pairing-code")
                        Button("Connect securely") {
                            editing = false; client.pair(with: pasted, deviceName: UIDeviceName.current)
                        }.buttonStyle(.borderedProminent)
                            .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || client.phase == .connecting)
                    }
                    if client.phase == .connecting {
                        ProgressView("Finding your Mac…").font(.callout)
                        Button("Cancel connection") { client.cancelPairing() }.font(.caption)
                    }
                    if let error = client.lastError { Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
                Label("Paired only with you. Encrypted between devices. No relay account.", systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(24).frame(maxWidth: 560)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $scanning) {
            NavigationStack {
                ScannerView { code in scanning = false; client.pair(with: code, deviceName: UIDeviceName.current) }
                    .ignoresSafeArea(edges: .bottom).navigationTitle("Pair with your Mac").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
            }
        }
    }
    private func setupStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.caption.weight(.bold)).foregroundStyle(StudioStyle.mint)
                .frame(width: 28, height: 28).background(StudioStyle.mint.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SessionView: View {
    @EnvironmentObject private var client: RemoteClient
    @State private var drafts: [String: String] = [:]
    @State private var target = "solo"
    @State private var provider = ""
    @State private var showProjects = false
    @State private var showConnection = false
    @State private var showPermissions = false
    @State private var showForget = false
    @State private var followLatest = true
    @FocusState private var editing: Bool
    private var state: RemoteState? { client.state }
    private var draftKey: String { state?.projectID ?? "default" }
    private var draft: Binding<String> { Binding(get: { drafts[draftKey] ?? "" }, set: { drafts[draftKey] = $0 }) }

    var body: some View {
        VStack(spacing: 0) {
            projectHeader
            if client.phase != .connected { connectionBanner }
            if let permissions = state?.permissions, !permissions.isEmpty {
                Button { editing = false; showPermissions = true } label: {
                    HStack {
                        Image(systemName: "hand.raised.fill")
                        Text("\(permissions.count) decision\(permissions.count == 1 ? "" : "s") waiting").fontWeight(.medium)
                        Spacer(); Image(systemName: "chevron.right")
                    }.font(.callout).padding(14).foregroundStyle(.orange)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            transcript
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer.background(.ultraThinMaterial) }
        .navigationTitle("Orrery")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { editing = false; showConnection = true } label: {
                    Image(systemName: client.phase == .connected ? "wifi" : "wifi.exclamationmark")
                        .foregroundStyle(client.phase == .connected ? StudioStyle.mint : .orange)
                }.accessibilityLabel(client.phase == .connected ? "Connected to your Mac" : "Not connected")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = false; showConnection = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Connection settings")
            }
        }
        .sheet(isPresented: $showProjects) { projectsSheet }
        .sheet(isPresented: $showConnection) { connectionSheet }
        .sheet(isPresented: $showPermissions) { permissionsSheet }
        .onAppear { updateMode(); provider = state?.provider ?? "" }
        .onChange(of: state?.projectID) { _, _ in updateMode(); provider = state?.provider ?? ""; followLatest = true }
        .onChange(of: state?.mode) { _, _ in updateMode() }
        .onChange(of: state?.provider) { _, name in provider = name ?? "" }
    }

    private func updateMode() {
        let mode = state?.mode.lowercased()
        target = mode == "roundtable" ? "roundtable" : (mode == "team" ? "team" : "solo")
    }

    private var projectHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { editing = false; showProjects = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(StudioStyle.accent)
                        .frame(width: 42, height: 42).background(StudioStyle.panel, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state?.project ?? "Choose a project").font(.headline).foregroundStyle(.primary).lineLimit(1)
                        Text(state?.isBusy == true ? "Your AI is working" : "Ready for your next idea").font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }.accessibilityLabel("Projects, \(state?.project ?? "none selected")")
            Spacer(minLength: 0)
            if state?.isBusy == true {
                Button { Task { await client.stop() } } label: {
                    Image(systemName: "stop.fill").frame(width: 42, height: 42)
                }.buttonStyle(.bordered).tint(.orange).disabled(client.phase != .connected).accessibilityLabel("Stop current work")
            }
        }.padding(16)
    }

    private var connectionBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 5) {
                Text(client.phase == .connecting ? "Reconnecting to your Mac…" : "Your Mac is out of reach").font(.subheadline.weight(.semibold))
                Text("Keep Orrery open. Same Wi-Fi, your VPN, or the Mac's relay. Your draft stays here.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Retry") { client.connect() }.font(.caption.weight(.semibold))
        }.padding(14).background(StudioStyle.panel, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let entries = state?.entries, !entries.isEmpty {
                        Text("RECENT CONVERSATION").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                        ForEach(entries) { entry in entryView(entry) }
                    } else {
                        VStack(spacing: 16) {
                            OrbitMark().frame(width: 72, height: 72)
                            Text("What should we build?").font(.title2.weight(.semibold))
                            Text("Give your AI a direction. Follow its progress here, and step in whenever you need.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Find a useful improvement") { draft.wrappedValue = "Review this project and suggest the most useful improvement. Explain your plan before making changes."; editing = true }
                                .font(.callout).buttonStyle(.bordered)
                        }.padding(.vertical, 40).frame(maxWidth: .infinity)
                    }
                    if state?.isBusy == true {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text(state?.status ?? "Working…").font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in followLatest = false })
            .overlay(alignment: .bottomTrailing) {
                if !followLatest {
                    Button { followLatest = true; withAnimation { proxy.scrollTo("latest", anchor: .bottom) } } label: {
                        Label("Latest", systemImage: "arrow.down").font(.caption.weight(.semibold))
                    }.buttonStyle(.borderedProminent).padding(16)
                }
            }
            .onChange(of: state?.entries) { _, _ in if followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
            .onChange(of: state?.projectID) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
        }
    }

    private func entryView(_ entry: RemoteState.Entry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: entry.kind == "user" ? "person.crop.circle" : "sparkle").foregroundStyle(entry.kind == "user" ? StudioStyle.mint : StudioStyle.accent)
                Text(entry.speaker).font(.caption.weight(.semibold))
                Spacer()
                if let cost = entry.costUSD { Text(String(format: "$%.3f", cost)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            }
            Text(.init(entry.text)).font(entry.kind == "system" ? .callout : .body)
                .foregroundStyle(entry.kind == "failure" ? Color.orange : Color.primary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16).background(entry.kind == "user" ? StudioStyle.accent.opacity(0.10) : StudioStyle.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    private var composer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(["solo", "team", "roundtable"], id: \.self) { mode in
                    Button { target = mode; client.selectMode(mode) } label: {
                        Text(mode == "roundtable" ? "Roundtable" : mode.capitalized).font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(target == mode ? StudioStyle.accent.opacity(0.23) : .clear, in: Capsule())
                    }.foregroundStyle(target == mode ? .primary : .secondary)
                        .accessibilityAddTraits(target == mode ? .isSelected : [])
                        .disabled(client.phase != .connected || client.sending || state?.projectID == nil)
                }
                Spacer(minLength: 0)
                if target == "solo" {
                    Menu {
                        ForEach(state?.providers ?? [], id: \.self) { name in Button(name.capitalized) { provider = name; client.selectProvider(name) } }
                    } label: { Image(systemName: "cpu").padding(8) }.accessibilityLabel("Choose agent, \(provider)")
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(target == "roundtable" && state?.isBusy == true ? "Steer the conversation…" : "Give your AI a direction…", text: draft, axis: .vertical)
                    .lineLimit(1...5).padding(14).background(StudioStyle.panel, in: RoundedRectangle(cornerRadius: 18)).focused($editing)
                    .accessibilityIdentifier("message-draft")
                Button {
                    let key = draftKey
                    let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let selectedTarget = target; let selectedProvider = provider
                    editing = false; followLatest = true
                    Task {
                        if await client.sendMessage(text, target: selectedTarget, provider: selectedProvider.isEmpty ? nil : selectedProvider), drafts[key]?.trimmingCharacters(in: .whitespacesAndNewlines) == text { drafts[key] = "" }
                    }
                } label: {
                    Group { if client.sending { ProgressView().tint(.white) } else { Image(systemName: "arrow.up").font(.headline) } }
                        .frame(width: 48, height: 48).background(StudioStyle.accent, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white)
                }.disabled(client.phase != .connected || state?.projectID == nil || client.sending || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(client.phase != .connected || state?.projectID == nil || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
                    .accessibilityLabel(client.sending ? "Waiting for delivery confirmation" : "Send message")
            }
            if let error = client.lastError {
                HStack(alignment: .top) { Text(error).font(.caption).foregroundStyle(.orange); Spacer(minLength: 0); Button { client.clearError() } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss error") }
            } else {
                HStack(spacing: 5) { Image(systemName: "lock.fill"); Text(target == "solo" ? "\((provider.isEmpty ? state?.provider : provider)?.capitalized ?? "AI") · Runs on your Mac" : "\(target.capitalized) · Runs on your Mac") }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    private var projectsSheet: some View {
        NavigationStack {
            List {
                Section("Open on your Mac") {
                    ForEach(state?.projects ?? []) { project in
                        Button {
                            client.selectProject(project.id); showProjects = false
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder").foregroundStyle(StudioStyle.accent)
                                Text(project.name).foregroundStyle(.primary)
                                Spacer()
                                if project.isBusy { ProgressView() }
                                if state?.projectID == project.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(StudioStyle.mint) }
                            }.padding(.vertical, 8)
                        }.disabled(client.phase != .connected || client.sending)
                    }
                }
                Section { Text("Open or create projects on your Mac. Messages and approvals stay with the project you select here.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Projects").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showProjects = false } } }
        }.presentationDetents([.medium, .large])
    }

    private var connectionSheet: some View {
        NavigationStack {
            List {
                Section("Your Mac") {
                    Label(client.mac?.name ?? "Mac", systemImage: "desktopcomputer")
                    LabeledContent("Connection", value: client.phase == .connected ? "Encrypted & connected" : "Disconnected")
                    if let date = client.lastReceived { LabeledContent("Last update") { Text(date, style: .time) } }
                    Button("Reconnect") { client.connect() }
                }
                Section("Connecting away from home") {
                    Text("Keep the Mac awake and Orrery open. Connect both devices to your private VPN, such as Tailscale. Orrery does not provide a cloud relay or ask you to expose a port to the internet.").font(.callout)
                }
                Section("Control & privacy") {
                    Text("Use Solo, Team or Roundtable from your phone. Native CLI conversations and provider-owned desktop permission prompts stay on the Mac. Project trust, model settings and access policies are managed there too.").font(.callout)
                    Text("Your phone stores its pairing key in the Keychain. Remove this phone in Orrery's Remote settings to revoke its access.").font(.callout)
                    Button("Forget this Mac", role: .destructive) { showForget = true }
                }
            }.navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showConnection = false } } }
                .confirmationDialog("Forget this Mac?", isPresented: $showForget) {
                    Button("Forget Mac", role: .destructive) { client.forget(); showConnection = false }
                } message: { Text("You'll need a new pairing code. Revoke this phone on the Mac too.") }
        }
    }

    private var permissionsSheet: some View {
        NavigationStack {
            List {
                if state?.permissions.isEmpty != false { Text("All caught up. No decisions waiting.") }
                ForEach(state?.permissions ?? []) { permission in
                    Section(permission.provider.capitalized) {
                        Text(permission.title).font(.headline)
                        if !permission.detail.isEmpty { Text(permission.detail).font(.caption.monospaced()).textSelection(.enabled) }
                        ForEach(permission.options) { option in
                            Button(option.name) { Task { await client.approve(permission.id, option: option.id) } }
                                .tint(option.kind.hasPrefix("reject") ? .orange : StudioStyle.accent)
                                .disabled(client.phase != .connected)
                        }
                    }
                }
            }.navigationTitle("Decisions").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showPermissions = false } } }
        }
    }
}

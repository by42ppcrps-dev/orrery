import SwiftUI
import AppKit

enum WorkspaceLayout: String, CaseIterable, Identifiable {
    case editor = "Editor", workspace = "Split", assistant = "Assistant"
    var id: Self { self }
    var title: String {
        switch self { case .editor: return "Code"; case .workspace: return "Studio"; case .assistant: return "Focus" }
    }
    var symbol: String {
        switch self {
        case .editor: return "doc.text"
        case .workspace: return "rectangle.split.2x1"
        case .assistant: return "bubble.left.and.text.bubble.right"
        }
    }
}

enum AssistantMode: String, CaseIterable, Identifiable {
    case chat = "Solo", team = "Team", roundtable = "Roundtable", cli = "CLI"
    var id: Self { self }
}

struct AssistantPane: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 9) { OrbitMark(size: 27); Text("Workspace").font(.headline) }
                Spacer(minLength: 0)
                Button { ActivityWindowSupport.shared.open() } label: { Label("Activity", systemImage: "laptopcomputer.and.iphone") }
                    .buttonStyle(.borderless).font(.caption).help("Follow every open project across your paired Macs")
                Button("Set up") { model.showSetup = true }.buttonStyle(.borderless).font(.caption)
                    .help("Connect your subscriptions or API keys and check project setup")
                    .accessibilityLabel("Workspace setup")
                Button {
                    model.requestedSettingsSection = "Connectors"
                    model.showAgentSettings = true
                } label: { Label("Connections", systemImage: "puzzlepiece.extension") }
                    .buttonStyle(.borderless).font(.caption).help("Manage the tools and plugins available to your agents")
                PaneIconButton(title: "Agent settings", symbol: "slider.horizontal.3") { model.showAgentSettings = true }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 8)
            AssistantModeBar(provider: $model.provider, mode: $model.assistantMode,
                             showsAgent: model.showsSoloAgentControls)
            Divider()
            ToolchainUpdateBanner(watch: ToolchainWatch.shared)
            ForEach(Provider.allCases.filter { model.needsSignIn.contains($0) }) { provider in
                HStack(spacing: 8) {
                    Label("\(provider.displayName) is signed out: its login expired or was revoked. Nothing works for it until you sign in again.", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption).lineLimit(2)
                    Spacer()
                    Button("Sign In with the CLI") { model.signIn(provider) }.controlSize(.small).buttonStyle(.borderedProminent)
                    Button("Dismiss") { model.dismissSignIn(provider) }.controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 6).background(Color.red.opacity(0.12))
                .accessibilityElement(children: .combine)
            }
            if model.computerControl?.desktopEnabled == true {
                ComputerControlStatus { model.disableComputerControl() }
                Divider()
                if model.assistantMode == .cli && model.provider == .grok {
                    Text("The built-in computer tools are available in Grok Chat and Team. This CLI uses its own MCP configuration.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
            switch model.assistantMode {
            case .chat: ChatView(model: model)
            case .team: OrchestratorView(model: model)
            case .roundtable: RoundtableView(model: model)
            case .cli: NativeAgentView(model: model)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))

    }
}

/// Mode selection keeps its spacing independent of each conversation's content.
struct AssistantModeBar: View {
    @Binding var provider: Provider
    @Binding var mode: AssistantMode
    let showsAgent: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsAgent {
                Picker("Agent", selection: $provider) {
                    ForEach(Provider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden().frame(width: 110)
                .help("Choose the agent for Solo or CLI. Team and Roundtable have their own seats.")
            }
            Spacer(minLength: 0)
            Picker("Assistant mode", selection: $mode) {
                ForEach(AssistantMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .labelsHidden().pickerStyle(.segmented).controlSize(.large).frame(maxWidth: 300)
            .help("Solo: one agent and one model work on this project. Team: several agents plan, write and review. Roundtable: every agent and you in one thread. CLI: the provider’s own terminal interface.")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.bar)
    }
}

struct ComputerControlStatus: View {
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Computer control on", systemImage: "desktopcomputer")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button("Stop", action: stop)
                .font(.caption).buttonStyle(StudioActionButtonStyle())
                .help("Turn off desktop control for this project")
                .accessibilityLabel("Stop computer control")
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
    }
}

/// A visible, consistent target for secondary pane actions.
struct PaneIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 20, height: 20)
        }
        .buttonStyle(StudioActionButtonStyle()).help(title).accessibilityLabel(title)
    }
}

/// Secondary actions keep a steady target and highlight without moving nearby content.
struct StudioActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration)
    }

    private struct ActionBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(minHeight: 32)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .background(StudioStyle.accent.opacity(enabled && (hovered || configuration.isPressed) ? 0.16 : 0.04),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioStyle.border))
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovered = $0 }
        }
    }
}

/// A file chooser belongs to the window that opened it, including secondary workspaces.
@MainActor enum WorkspaceFilePicker {
    static func present(_ panel: NSOpenPanel, from window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

import SwiftUI

struct RoundtableView: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @State private var showSeats = false
    @State private var missingDesktopPermissions = ComputerControl.missingDesktopPermissions
    @FocusState private var composerFocused: Bool

    private var table: Roundtable { model.roundtable }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .onAppear { missingDesktopPermissions = ComputerControl.missingDesktopPermissions }
        .onChange(of: model.showAgentSettings) { _, showing in
            if !showing { missingDesktopPermissions = ComputerControl.missingDesktopPermissions }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            missingDesktopPermissions = ComputerControl.missingDesktopPermissions
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label("Roundtable", systemImage: "person.3").font(.callout.weight(.semibold)).lineLimit(1).fixedSize()
                Spacer()
                Button("Clear") { table.clear() }.controlSize(.small).disabled(table.isRunning || (table.entries.isEmpty && table.workspace == nil))
                    .help("Clear this discussion and start fresh; running work must be stopped first")
            }
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { table.mode }, set: { table.mode = $0 })) {
                    ForEach(Roundtable.Mode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented).controlSize(.small).fixedSize().labelsHidden()
                .disabled(table.isRunning)
                .help("Discuss: agents talk and never change files. Work: agents edit a shared working copy, run tasks and use their tools.")
                Picker("Replies", selection: Binding(
                    get: { table.unlimitedReplies ? 0 : table.rounds },
                    set: { value in
                        if value == 0 { table.unlimitedReplies = true }
                        else { table.unlimitedReplies = false; table.rounds = value }
                    })) {
                    Text("1 reply").tag(1)
                    Text("2 replies").tag(2)
                    Text("3 replies").tag(3)
                    Text("Unlimited").tag(0)
                }
                    .pickerStyle(.menu).controlSize(.small).fixedSize().disabled(table.isRunning)
                    .accessibilityLabel("Replies")
                    .help("Reply rounds continue until every agent says it has nothing further, or you press Stop; hard stop after \(table.unlimitedCeiling) rounds.")
                Spacer()
            }
            seats
            HStack(spacing: 8) {
                if table.mode == .discuss {
                    Text("Discussion only. Choose Work to use browser and computer tools.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Browser \(model.computerControl?.groups.contains(.browser) == true ? "on" : "off") · Computer \(model.computerControl?.desktopEnabled == true ? (missingDesktopPermissions.isEmpty ? "on" : "needs macOS access") : "off")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Tool access") {
                    model.requestedSettingsSection = "Computer"
                    model.showAgentSettings = true
                }.controlSize(.small).help("Review browser and desktop permissions for this project")
            }
            // The long explanation earns its space only while the table is empty; afterwards the
            // transcript needs the room, and the text lives in the header's help.

            if table.mode == .work {
                HStack(spacing: 8) {
                    if let workspace = table.workspace {
                        Text("Working copy \(workspace.id.uuidString.prefix(8)) — nothing reaches the project until you apply it.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Changes") { model.reviewingWorkspace = workspace }.controlSize(.small).disabled(table.isRunning)
                    } else {
                        Text("The first message makes a shared working copy of the project for the agents.").font(.caption).foregroundStyle(.secondary)
                    }
                    ApprovalMenu(model: model) {
                        Text(model.blanketApproval ? "Every approval bypassed." : model.autoApprove ? "Tools run without asking." : "Tool approvals appear in this window.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let notice = table.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            if table.isRunning {
                Text("You can talk to them while they work: type below and press Steer. Your message joins the conversation now and every agent answers it in its next turn.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// One row per ticked agent: its model and reasoning effort for this roundtable.
    private var seats: some View {
        DisclosureGroup(isExpanded: $showSeats) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                ForEach(Provider.allCases) { provider in
                    Toggle(provider.displayName, isOn: Binding(
                        get: { table.participants.contains(provider) },
                        set: { on in if on { table.participants.insert(provider) } else { table.participants.remove(provider) } }))
                        .toggleStyle(.checkbox).font(.caption)
                        .disabled(table.isRunning || model.installed[provider] != true)
                        .help(model.installed[provider] == true ? "\(provider.displayName) takes part" : "\(provider.displayName) CLI is not installed")
                }
                }
                ForEach(Provider.allCases.filter { table.participants.contains($0) && model.installed[$0] == true }) { provider in
                    HStack(spacing: 8) {
                        Text(provider.displayName).font(.caption).frame(width: 52, alignment: .leading)
                        Picker("", selection: Binding(get: { table.seatModels[provider] ?? "" }, set: { table.setSeat(model: $0, for: provider) })) {
                            Text("Inherit (\(inheritedModelName(provider)))").tag("")
                            ForEach(model.modelChoices(for: provider)) { option in Text(option.name).tag(option.id) }
                        }
                        .labelsHidden().controlSize(.small).frame(maxWidth: 230)
                        .help("\(provider.displayName)'s model in this roundtable")
                        Picker("", selection: Binding(get: { table.seatEfforts[provider] ?? "" }, set: { table.setSeat(effort: $0, for: provider) })) {
                            Text("Inherit effort").tag("")
                            ForEach(ModelCatalog.efforts(provider, model: table.seatModels[provider]), id: \.self) { effort in Text(effort).tag(effort) }
                        }
                        .labelsHidden().controlSize(.small).frame(maxWidth: 150)
                        .help("\(provider.displayName)'s reasoning effort in this roundtable")
                        Toggle("Leads", isOn: Binding(get: { table.leader == provider }, set: { table.setLeader($0 ? provider : nil) }))
                            .toggleStyle(.checkbox).font(.caption)
                            .help("\(provider.displayName) speaks first each round and runs the plan; saying \"\(provider.displayName), you lead\" in a message does the same")
                        Spacer(minLength: 0)
                    }
                }
                Text("Per seat, this roundtable only. Changes apply from that agent's next message, even mid-run. Leads: goes first and runs the plan.")
                    .help("Inherit uses the provider's Agent settings. Writing \"Claude, you lead\" in a message ticks Leads too; with nobody leading the order is Grok, Claude, Codex.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } label: {
            Text("Agents, models & leader").font(.caption)
        }
    }

    private func inheritedModelName(_ provider: Provider) -> String {
        let configured = model.agentSettings[provider]?.model ?? ""
        if configured.isEmpty { return "provider default" }
        return ModelCatalog.name(provider, of: configured)
    }

    private var description: String {
        let replies = table.unlimitedReplies
            ? "with Unlimited on they keep answering each other until everyone has nothing further, or you press Stop"
            : "with Replies above 1, each then answers the others"
        switch table.mode {
        case .discuss:
            return "Everyone reads the same thread. Send a message and every ticked agent answers at once; \(replies). Start with @Grok, @Claude or @Codex to ask one of them. Agents read your project but never change it here."
        case .work:
            return "Everyone works in one shared working copy: agents take turns, may edit files, run tasks and use the IDE, browser and computer tools they have been given; \(replies). Review and apply their edits from Changes."
        }
    }

    private var transcript: some View {
        RoundtableTranscript(entries: table.entries, live: table.live, thinking: table.thinking)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(table.isRunning ? "Add direction while they work" : "What should we work on?")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(size: 14)).scrollContentBackground(.hidden)
                .frame(height: 68).focused($composerFocused)
                .padding(.horizontal, 4).padding(.vertical, 8)
                .accessibilityLabel("Roundtable message")
            HStack {
                Text("@ an agent to address them · ⌘↩ to send").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if table.isRunning {
                    Button("Stop") { table.stop() }.buttonStyle(.bordered)
                    Button("Steer", action: send).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command).disabled(isDraftEmpty)
                } else {
                    Button("Send", action: send).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(isDraftEmpty || model.projectURL == nil || !model.isProjectTrusted || table.enabledTargets.isEmpty)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
        .padding(14)
        .transaction { $0.animation = nil }
    }

    private var isDraftEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let text = draft
        guard !isDraftEmpty else { return }
        if table.isRunning {
            if table.steer(text) { draft = "" }
            return
        }
        draft = ""
        Task { await table.send(text) }
    }
}

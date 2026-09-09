import SwiftUI
import AppKit

struct ChatView: View {
    @Bindable var model: AppModel
    @FocusState private var composerFocused: Bool
    @State private var showImagine = false
    @State private var attachmentError: String?
    private var hasConversation: Bool { model.entries.contains { $0.kind == .user || $0.kind == .assistant } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .alert("Could not attach file", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
            Button("OK") { attachmentError = nil }
        } message: { Text(attachmentError ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
            Text(model.sessionTitle)
                .font(.callout).fontWeight(.medium)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            PaneIconButton(title: "Task history", symbol: "clock.arrow.circlepath") { model.showTaskHistory = true }
            PaneIconButton(title: "Verify project UI", symbol: "macwindow") {
                do { _ = try model.previewController(); model.showUIVerification = true }
                catch { model.taskNotice = error.localizedDescription }
            }
            .disabled(!model.isProjectTrusted)
            if let workspace = model.currentTaskWorkspace {
                PaneIconButton(title: "Review task changes", symbol: "square.stack.3d.up") { model.reviewingWorkspace = workspace }
            }
            if !model.isBusy {
                PaneIconButton(title: "New conversation (⌘N)", symbol: "square.and.pencil") {
                    Task { await model.newSession() }
                }
            }
            if model.isBusy {
                ProgressView().controlSize(.small)
                Button("Stop") { model.cancel() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !hasConversation {
                        VStack(alignment: .leading, spacing: 14) {
                            OrbitMark(size: 68).padding(.bottom, 6)
                            Text("What will you create?").font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-0.8)
                            Text("Start with an idea, a problem, or something you wish existed. \(model.provider.displayName) will help you build it.")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(["Build something from an idea", "Understand this project", "Find and fix a problem"], id: \.self) { suggestion in
                                Button {
                                    model.chatDraft = suggestion
                                    composerFocused = true
                                } label: {
                                    HStack {
                                        Text(suggestion)
                                        Spacer()
                                        Image(systemName: "arrow.up.left").foregroundStyle(.secondary)
                                    }.padding(10).contentShape(Rectangle())
                                }
                                .buttonStyle(StudioActionButtonStyle())
                                .help("Put this suggestion in the message box without sending it")
                                .background(StudioStyle.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioStyle.border))
                            }
                            Text("Suggestions fill the message box. You decide when to send.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 560, alignment: .leading)
                        .padding(.vertical, 20)
                    }
                    ForEach(model.entries) { entry in
                        EntryView(entry: entry, project: model.projectURL).id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
            }
            // Streaming fires this per token — animating each one makes long replies stutter.
            .onChange(of: model.entries.last?.text) { _, _ in
                guard hasConversation else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: model.entries.count) { _, _ in
                guard hasConversation else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = model.taskNotice ?? model.documents.recoveryNotice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).foregroundStyle(.orange).lineLimit(3)
                    Spacer(minLength: 0)
                    Button { model.dismissNotices() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss notice")
                }
            }
            if let queued = model.taskQueues[model.provider], !queued.isEmpty {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(queued) { prompt in
                            Button("Remove: " + String(prompt.text.prefix(60))) {
                                model.taskQueues[model.provider]?.removeAll { $0.id == prompt.id }
                                model.saveTaskHistoryNow()
                            }
                        }
                        Divider()
                        Button("Clear queue") { model.taskQueues[model.provider] = []; model.saveTaskHistoryNow() }
                    } label: { Label("\(queued.count) queued", systemImage: "text.badge.plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    Text(model.queuePaused.contains(model.provider) ? "Paused" : "Sends after this turn").foregroundStyle(.secondary)
                    Spacer()
                    Button(model.queuePaused.contains(model.provider) ? "Resume queue" : "Pause queue") {
                        let target = model.provider
                        if model.queuePaused.contains(target) {
                            model.queuePaused.remove(target)
                            Task { await model.sendNextQueued(for: target) }
                        } else { model.queuePaused.insert(target) }
                    }.buttonStyle(.borderless)
                }.font(.caption)
            }
            if !model.slashCommands.isEmpty, model.chatDraft.hasPrefix("/") {
                let query = model.chatDraft.dropFirst().lowercased()
                let matches = model.slashCommands.filter { $0.lowercased().hasPrefix(query) }.prefix(6)
                if !matches.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(matches), id: \.self) { command in
                                Button("/\(command)") { model.chatDraft = "/\(command) " }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
            if !(model.chatAttachments[model.provider] ?? []).isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.chatAttachments[model.provider] ?? []) { attachment in
                            HStack(spacing: 4) {
                                Label(attachment.name, systemImage: attachment.isImage ? "photo" : "doc")
                                    .lineLimit(1)
                                PaneIconButton(title: "Remove \(attachment.name)", symbol: "xmark") {
                                    model.chatAttachments[model.provider]?.removeAll { $0.id == attachment.id }
                                }
                            }.padding(.leading, 8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }.font(.caption)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                PaneIconButton(title: "Attach image or text file", symbol: "paperclip") { attach() }
                if model.provider == .grok {
                    PaneIconButton(title: "Imagine: generate or edit an image, or animate one into a video", symbol: "sparkles") { showImagine = true }
                        .popover(isPresented: $showImagine, arrowEdge: .top) { ImagineComposer(model: model, isPresented: $showImagine) }
                }
                Menu {
                    Button("Selected code") { model.attachEditorContext(selectionOnly: true) }
                        .disabled(model.documents.active?.selection.length ?? 0 == 0)
                    Button("Current file, including unsaved edits") { model.attachEditorContext(selectionOnly: false) }
                        .disabled(model.documents.active == nil)
                    Button("Editor problems") { model.attachProblemContext() }
                    Button("Latest run/test output") { model.attachOutputContext() }
                    Divider()
                    ForEach(Provider.allCases.filter { $0 != model.provider && model.installed[$0] == true }) { target in
                        Button("Hand off context to \(target.displayName)") { model.handoffContext(to: target) }
                    }
                } label: { Image(systemName: "doc.text.magnifyingglass").frame(width: 24, height: 32) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Add editor context")
                TextField("Message \(model.provider.displayName)…", text: $model.chatDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(2...7)
                    .focused($composerFocused)
                    .onSubmit(send)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25)))

                Button(action: send) {
                    Image(systemName: model.state.isBusy ? "text.badge.plus" : "arrow.up.circle.fill").font(.system(size: 26)).frame(width: 36, height: 40)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(model.state.isBusy ? "Queue message" : "Send message")
                .help(model.state.isBusy ? "Queue for the next turn (⌘Return)" : "Send message (⌘Return)")
                .disabled((model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (model.chatAttachments[model.provider] ?? []).isEmpty)
                          || !model.isProjectTrusted || model.installed[model.provider] != true || model.taskPreparing.contains(model.provider) || model.taskMutationBusy)
            }
            HStack(spacing: 6) {
                ApprovalMenu(model: model) {
                    HStack(spacing: 6) {
                        Image(systemName: model.isProjectTrusted ? (model.autoApprove ? "bolt.fill" : "checkmark.shield") : "lock.shield")
                        Text(!model.isProjectTrusted ? "Trust this project to send messages" :
                             (model.taskPreparing.contains(model.provider) ? "Preparing isolated working copy…" : !model.isConnected ? model.status : (model.state.isBusy ? "Working — send to queue a follow-up" :
                              (model.blanketApproval ? "Every tool approval is bypassed (blanket)" : model.autoApprove ? "Tools are automatically approved" : "Tool approvals are on"))))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if model.isBusy, model.backend?.supportsSteering == true {
                    Button("Send now") { Task { await model.steerDraft() } }
                        .buttonStyle(.borderless)
                        .disabled(model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(model.chatAttachments[model.provider] ?? []).isEmpty)
                        .help("Send a text correction to the current turn immediately. The main send button queues a follow-up.")
                }
                Text("⌘↩ Send").fixedSize()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private func send() {
        guard model.isProjectTrusted else { return }
        Task { await model.submitDraft() }
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        let project = model.projectURL, provider = model.provider
        WorkspaceFilePicker.present(panel, from: NSApp.keyWindow) { response in
            guard response == .OK, !model.isShutDown,
                  model.projectURL == project, model.provider == provider else { return }
            attach(panel.urls, to: provider)
        }
    }

    private func attach(_ urls: [URL], to provider: Provider) {
        do {
            guard urls.count + (model.chatAttachments[provider]?.count ?? 0) <= 8 else {
                throw ComputerError("Attach up to 8 files per message.")
            }
            let attachments = try urls.map { try MessageAttachment(url: $0) }
            let combined = (model.chatAttachments[provider] ?? []) + attachments
            guard combined.count <= 8, combined.reduce(0, { $0 + $1.data.count }) <= MessageAttachment.limit else {
                throw ComputerError("Attach up to 8 files, with a combined size of 8 MB.")
            }
            model.chatAttachments[provider] = combined
        } catch { attachmentError = error.localizedDescription }
    }

}

// MARK: - One transcript entry

struct EntryView: View {
    let entry: Entry
    var project: URL? = nil
    @State private var expanded = false

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(entry.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

        case .assistant:
            RichText(text: entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .thought:
            DisclosureGroup(isExpanded: $expanded) {
                Text(entry.text)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Thinking", systemImage: "brain")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case .tool:
            ToolView(entry: entry, project: project)

        case .plan:
            VStack(alignment: .leading, spacing: 4) {
                Label("Plan", systemImage: "checklist").font(.caption).foregroundStyle(.secondary)
                Text(entry.text).font(.callout).textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .failure:
            Label { Text(entry.text).textSelection(.enabled) } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .system:
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ToolView: View {
    let entry: Entry
    var project: URL? = nil
    @State private var expanded = false

    private var detail: ToolDetail { entry.tool ?? ToolDetail() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                    Text(entry.title).font(.callout).fontWeight(.medium)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if detail.status == "in_progress" || detail.status == "pending" {
                        ProgressView().controlSize(.mini)
                    }
                    Text(detail.status)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(color.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(color)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // A file change is the most important thing a tool call produces, so it is never
            // hidden behind a disclosure.
            ForEach(detail.diffs) { diff in
                VStack(alignment: .leading, spacing: 2) {
                    Text(diff.path).font(.caption2).foregroundStyle(.secondary)
                    DiffBlock(old: diff.oldText, new: diff.newText)
                }
            }
            // Generated or referenced media is shown, not just named.
            ForEach(detail.mediaPaths, id: \.self) { path in MediaPreview(path: path, project: project) }
            if expanded {
                if !detail.rawInput.isEmpty { codeBlock(detail.rawInput, label: "input") }
                if !detail.output.isEmpty { codeBlock(detail.output, label: "output") }
            } else if let first = detail.locations.first, detail.diffs.isEmpty {
                Text(first).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func codeBlock(_ text: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
        }
    }

    private var icon: String {
        switch detail.kind {
        case "read": return "doc.text.magnifyingglass"
        case "edit": return "pencil"
        case "delete": return "trash"
        case "move": return "arrow.right.doc.on.clipboard"
        case "search": return "magnifyingglass"
        case "execute": return "terminal"
        case "think": return "brain"
        case "fetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    private var color: Color {
        switch detail.status {
        case "completed": return .green
        case "failed", "error": return .red
        case "in_progress": return .orange
        default: return .secondary
        }
    }
}

struct DiffBlock: View {
    let old: String
    let new: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(line.added ? Color.green.opacity(0.14)
                                : (line.removed ? Color.red.opacity(0.14) : Color.clear))
                    .foregroundStyle(line.added ? .green : (line.removed ? .red : .primary))
            }
        }
        .textSelection(.enabled)
        .frame(maxHeight: 320)
    }

    private struct Line { let text: String; let added: Bool; let removed: Bool }

    private var lines: [Line] {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var result = oldLines.map { Line(text: "- \($0)", added: false, removed: true) }
        result += newLines.map { Line(text: "+ \($0)", added: true, removed: false) }
        return Array(result.prefix(400))
    }
}

/// Assistant text with fenced code blocks rendered as monospace panels.
struct RichText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.isCode {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(segment.text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if !segment.text.isEmpty {
                    Text(segment.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private struct Segment { let text: String; let isCode: Bool }

    private var segments: [Segment] {
        var result: [Segment] = []
        var isCode = false
        for chunk in text.components(separatedBy: "```") {
            let body = isCode
                ? chunk.drop(while: { $0 != "\n" }).trimmingCharacters(in: .newlines)
                : chunk.trimmingCharacters(in: .newlines)
            result.append(Segment(text: String(body), isCode: isCode))
            isCode.toggle()
        }
        return result
    }
}

/// The approval switches, right where the status is read: this project's rule and the
/// blanket bypass for everything. The label is whatever the caller shows as status.
struct ApprovalMenu<Label: View>: View {
    @Bindable var model: AppModel
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            Toggle("Run tools without asking (this project)", isOn: $model.autoApprove).disabled(model.blanketApproval)
            Toggle("Bypass every approval, everywhere", isOn: $model.blanketApproval)
                .help("Every agent runs every tool without asking, in every project and mode, and also gets the browser, the iPhone simulator and computer control without further switches")
            Divider()
            Text(model.blanketApproval
                 ? "Blanket bypass is on: nothing asks, in any project or mode, computer actions included."
                 : (model.autoApprove ? "This project runs tools without asking; other projects still ask." : "Tools ask before they run."))
        } label: {
            HStack(spacing: 4) {
                label()
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
        .disabled(!model.isProjectTrusted)
        .help("Change how tool approvals work — this project, or everywhere")
    }
}

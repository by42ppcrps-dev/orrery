import SwiftUI
import AppKit

struct TeamContextView: View {
    @Bindable var model: AppModel
    @State private var showSkills = false
    @State private var error: String?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { showSkills = true } label: { Label("Add skills", systemImage: "sparkles") }
                Button { chooseFiles() } label: { Label("Attach files", systemImage: "paperclip") }
                Menu("Editor context") {
                    Button("Current file") {
                        guard let doc = model.documents.active else { return }
                        addText(name: doc.url.lastPathComponent, text: doc.text)
                    }.disabled(model.documents.active == nil)
                    Button("Latest task output") {
                        addText(name: "Latest task output", text: model.taskRun.lines.suffix(300).map(\.text).joined(separator: "\n"))
                    }.disabled(model.taskRun.lines.isEmpty)
                }.menuStyle(.borderlessButton).fixedSize()
                if importing { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }.controlSize(.small)
            ForEach(model.teamAttachments) { attachment in
                HStack(spacing: 8) {
                    Image(systemName: attachment.name.hasSuffix("SKILL.md") ? "sparkles" : "doc.text").foregroundStyle(StudioStyle.accent)
                    Text(attachment.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)).foregroundStyle(.secondary)
                    Button { model.teamAttachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Remove \(attachment.name)")
                }.font(.caption).padding(8).background(StudioStyle.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            Text(model.teamAttachments.isEmpty ? "Choose skills or drop text files here. Sent to every Team role when you start." : "\(model.teamAttachments.count) selected · shared with the planner, authors and reviewers.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .disabled(model.teamPreparing || model.orchestrator.isRunning || importing)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.teamPreparing, !model.orchestrator.isRunning, !importing else { return false }
            importFiles(urls); return true
        }
        .sheet(isPresented: $showSkills) {
            TeamSkillPicker(project: model.isProjectTrusted ? model.projectURL : nil) { importFiles([$0]) }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Attach skills or reference files"
        panel.message = "Choose SKILL.md or UTF-8 text files. Up to 8 files and 128 KB total."
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    private func addText(name: String, text: String) {
        do { try append([MessageAttachment(name: name, text: text)]) }
        catch { self.error = error.localizedDescription }
    }

    private func append(_ items: [MessageAttachment]) throws {
        let combined = model.teamAttachments + items
        try TeamContext.validate(combined)
        model.teamAttachments = combined; error = nil
    }

    private func importFiles(_ urls: [URL]) {
        guard urls.count <= TeamContext.countLimit, urls.allSatisfy(\.isFileURL) else {
            error = "Choose up to 8 local text files."; return
        }
        importing = true
        let selectedProject = model.projectURL
        Task {
            defer { importing = false }
            do {
                let items = try await Task.detached(priority: .userInitiated) { try urls.map { try TeamContext.attachment(at: $0) } }.value
                guard !model.isShutDown, model.projectURL == selectedProject,
                      !model.teamPreparing, !model.orchestrator.isRunning else { return }
                try append(items)
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct TeamSkillPicker: View {
    let project: URL?
    let select: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var skills: [TeamContext.Skill] = []
    @State private var loading = true

    private var matches: [TeamContext.Skill] {
        skills.filter { query.isEmpty || ($0.name + " " + $0.location).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Choose a skill").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search your project and installed skills", text: $query).textFieldStyle(.roundedBorder)
            if loading { ProgressView("Looking for skills…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if matches.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No skills found" : "No matching skills", systemImage: "sparkles",
                    description: Text("Use Attach files to choose a SKILL.md from another folder."))
            } else {
                List(matches) { skill in
                    Button { select(skill.url); dismiss() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skill.name).font(.body.weight(.medium))
                                Text(skill.location).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle")
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(skill.url.path)
                }.listStyle(.inset)
            }
            Text("Only the skills you select are attached. Native agent skill discovery stays available.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 540, height: 480)
        .task {
            let project = project
            skills = await Task.detached(priority: .utility) { TeamContext.discover(project: project) }.value
            loading = false
        }
    }
}

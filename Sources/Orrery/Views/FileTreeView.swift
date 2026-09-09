import SwiftUI
import AppKit

struct FileTreeView: View {
    @Bindable var model: AppModel
    @State private var renaming: URL?
    @State private var newName = ""
    @State private var creating: (parent: URL, isFolder: Bool)?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Files").font(.headline)
                Spacer()
                Menu {
                    ForEach(model.displayedRecentProjects) { entry in
                        Button(entry.name) { model.openRecent(entry) }.disabled(!entry.exists)
                    }
                } label: { Image(systemName: "clock.arrow.circlepath") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Recent projects — opens in a project tab")
                .accessibilityLabel("Recent projects")
            }
            .padding(.horizontal, 14).frame(height: 42)
            Divider()
            if let root = model.fileTree {
                List(selection: Binding(
                    get: { model.documents.active?.url },
                    set: { if let url = $0 { model.open(file: url) } })
                ) {
                    OutlineGroup(root.children ?? [], id: \.self, children: \.children) { node in
                        row(node)
                            .tag(node.url)
                    }
                }
                .listStyle(.sidebar)
                .environment(\.defaultMinListRowHeight, 28)
                .contextMenu {
                    if let projectURL = model.projectURL {
                        Button("New File…") { creating = (projectURL, false); newName = "" }
                        Button("New Folder…") { creating = (projectURL, true); newName = "" }
                    }
                    Button("Refresh") { model.refreshTree() }
                }
            } else {
                ContentUnavailableView("No project open", systemImage: "folder.badge.questionmark",
                                       description: Text("⌘O to choose a folder"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack(spacing: 8) {
                Button { model.refreshTree() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh the file tree and the search index")
                if let projectURL = model.projectURL {
                    Button {
                        creating = (projectURL, false); newName = ""
                    } label: { Image(systemName: "doc.badge.plus") }
                        .buttonStyle(.borderless)
                        .help("New file at the project root")
                        .accessibilityLabel("New file")
                }
                Spacer()
                if model.index.isScanning {
                    ProgressView().controlSize(.mini)
                } else if !model.index.files.isEmpty {
                    Text("\(model.index.files.count) files")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .onChange(of: model.recentOpenError) { _, new in
            if let new {
                error = new
                model.recentOpenError = nil
            }
        }
        .alert("Could not do that", isPresented: Binding(get: { error != nil },
                                                         set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .sheet(isPresented: Binding(get: { renaming != nil },
                                    set: { if !$0 { renaming = nil } })) {
            namePrompt(title: "Rename", confirm: "Rename") {
                guard let url = renaming else { return }
                do {
                    let moved = try FileOperations.rename(url, to: newName)
                    for document in model.documents.documents {
                        let suffix = PathHelper.relative(document.url, toAnyOf: PathHelper.prefixes(for: url))
                        if document.url == url {
                            model.renameDocument(document, to: moved)
                        } else if suffix != document.url.path {
                            model.renameDocument(document, to: moved.appendingPathComponent(suffix))
                        }
                    }
                    model.refreshTree()
                } catch { self.error = error.localizedDescription }
                renaming = nil
            }
        }
        .sheet(isPresented: Binding(get: { creating != nil },
                                    set: { if !$0 { creating = nil } })) {
            namePrompt(title: creating?.isFolder == true ? "New Folder" : "New File",
                       confirm: "Create") {
                guard let request = creating else { return }
                do {
                    if request.isFolder {
                        _ = try FileOperations.createFolder(named: newName, in: request.parent)
                    } else {
                        let url = try FileOperations.createFile(named: newName, in: request.parent)
                        model.open(file: url)
                    }
                    model.refreshTree()
                } catch { self.error = error.localizedDescription }
                creating = nil
            }
        }
    }

    @ViewBuilder
    private var projectsSection: some View {
        let recents = model.displayedRecentProjects
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Projects")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                ForEach(recents) { entry in
                    projectRow(entry)
                }
            }
            Divider()
        }
    }

    private func projectRow(_ entry: RecentProject) -> some View {
        Button {
            if entry.exists {
                model.openRecent(entry)
            } else {
                error = "The folder “\(entry.name)” is no longer there."
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(entry.exists ? Color.accentColor : Color.secondary)
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !entry.exists {
                    Text("missing")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(entry.exists ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .help(entry.path)
        .contextMenu {
            Button("Open in New Window") {
                ExtraWindowSupport.shared.open(project: entry.url)
            }
            .disabled(!entry.exists)
        }
    }

    private func namePrompt(title: String, confirm: String,
                            action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
                .onSubmit(action)
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil; creating = nil }
                    .keyboardShortcut(.cancelAction)
                Button(confirm, action: action)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
    }

    private func row(_ node: FileNode) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let document = model.documents.document(for: node.url), document.isDirty {
                    Circle().fill(Color.orange).frame(width: 5, height: 5)
                }
                if !node.isDirectory, let badge = model.git.badge(for: node.url) {
                    Text(badge).font(.caption2.weight(.bold))
                        .foregroundStyle(badge == "?" || badge == "A" ? Color.green : badge == "D" ? Color.red : Color.orange)
                        .help("git: \(badge == "?" ? "untracked" : badge == "M" ? "modified" : badge == "A" ? "added" : badge == "D" ? "deleted" : badge)")
                }
            }
        } icon: {
            Image(systemName: node.isDirectory ? "folder"
                  : Languages.forFile(node.url).symbol)
                .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
        }
        .contextMenu {
            if node.isDirectory {
                Button("New File…") { creating = (node.url, false); newName = "" }
                Button("New Folder…") { creating = (node.url, true); newName = "" }
                Divider()
            } else {
                Button("Open") { model.open(file: node.url) }
                Divider()
            }
            Button("Rename…") { renaming = node.url; newName = node.name }
            Button("Duplicate") {
                do { _ = try FileOperations.duplicate(node.url); model.refreshTree() }
                catch { self.error = error.localizedDescription }
            }
            Button("Move to Trash", role: .destructive) {
                do {
                    let affected = model.documents.documents.filter {
                        $0.url == node.url || $0.url.path.hasPrefix(node.url.path + "/")
                    }
                    guard model.documents.approveClosing(affected) else { return }
                    try FileOperations.moveToTrash(node.url)
                    for document in affected { model.documents.close(document, approved: true) }
                    model.refreshTree()
                } catch { self.error = error.localizedDescription }
            }
            Divider()
            Button("Reveal in Finder") { FileOperations.revealInFinder(node.url) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
            Button("Copy Relative Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.index.relativePath(node.url), forType: .string)
            }
        }
    }
}

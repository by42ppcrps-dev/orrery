import SwiftUI
import AppKit

/// The Git pane: branch and remote at the top, staged and unstaged changes with stage, unstage
/// and discard, a commit box, push, pull and fetch, and init or clone when there is no
/// repository. Every action is one git command; its outcome is shown in the status line.
struct GitPaneView: View {
    @Bindable var model: AppModel
    @State private var selectedPath: String?
    @State private var diffText = ""
    @State private var discarding: String?
    @State private var cloneURL = ""

    private var git: GitRepository { model.git }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !git.isAvailable {
                Text("git is not installed at /usr/bin/git. Install the Xcode command line tools.")
                    .foregroundStyle(.secondary).padding()
                Spacer()
            } else if !git.status.isRepo {
                notARepository
            } else {
                HSplitView {
                    changes.frame(minWidth: 260)
                    diffPane.frame(minWidth: 200)
                }
            }
            Divider()
            footer
        }
        .confirmationDialog("Discard the changes to \(discarding ?? "")?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
            Button("Discard Changes", role: .destructive) {
                if let path = discarding { Task { await git.discard(path); if selectedPath == path { selectedPath = nil; diffText = "" } } }
                discarding = nil
            }
            Button("Cancel", role: .cancel) { discarding = nil }
        } message: {
            Text("An untracked file is deleted; a tracked file goes back to its last committed or staged version. This cannot be undone from Orrery.")
        }
        .onChange(of: git.status) { _, _ in Task { await reloadDiff() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label(git.status.isRepo ? (git.status.branch.isEmpty ? "no branch" : git.status.branch) : "Git", systemImage: "arrow.triangle.branch")
                    .font(.callout.weight(.semibold)).lineLimit(1).fixedSize()
                if git.status.isRepo {
                    if git.status.ahead > 0 || git.status.behind > 0 {
                        Text("↑\(git.status.ahead) ↓\(git.status.behind)").font(.caption).foregroundStyle(.secondary).fixedSize()
                            .help("Commits ahead of and behind \(git.status.upstream)")
                    }
                    if !git.remote.isEmpty {
                        Text(git.remote).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("no remote").font(.caption).foregroundStyle(.secondary).fixedSize()
                    }
                }
                Spacer(minLength: 0)
                if git.isBusy { ProgressView().controlSize(.small) }
            }
            if git.status.isRepo {
                HStack(spacing: 8) {
                    Button("Refresh") { Task { await git.refresh() } }.controlSize(.small).disabled(git.isBusy)
                    Button("Fetch") { Task { await git.fetch() } }.controlSize(.small).disabled(git.isBusy || git.remote.isEmpty)
                    Button("Pull") { Task { await git.pull() } }.controlSize(.small).disabled(git.isBusy || git.remote.isEmpty)
                    Button("Push") { Task { await git.push() } }.controlSize(.small).disabled(git.isBusy || git.remote.isEmpty)
                        .help(git.status.upstream.isEmpty ? "Pushes and sets the upstream for \(git.status.branch)" : "Pushes to \(git.status.upstream)")
                    if git.remote.isEmpty { Text("Add a remote (git remote add origin …) to fetch, pull or push.").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 0)
                }
            } else {
                HStack { Button("Refresh") { Task { await git.refresh() } }.controlSize(.small).disabled(git.isBusy); Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var notARepository: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This project is not a git repository.").font(.callout)
            HStack {
                Button("Initialize Repository") { Task { await git.initialize() } }.disabled(git.isBusy)
                Text("Creates a repository on branch main; nothing is committed until you commit.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Clone a repository").font(.callout.weight(.semibold))
            HStack {
                TextField("https://github.com/owner/repo.git or git@github.com:owner/repo.git", text: $cloneURL)
                    .textFieldStyle(.roundedBorder)
                Button("Clone…") { chooseAndClone() }.disabled(git.isBusy || cloneURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("You choose the parent folder; the clone lands in a folder named after the repository and opens as a project. Private repositories need credentials git can use without a prompt (a credential helper or an SSH key without a passphrase prompt).")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Commit message", text: Bindable(git).commitMessage, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
                Button("Commit") { Task { await git.commit(all: false) } }.disabled(git.isBusy || git.status.staged.isEmpty || git.commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Commits the staged changes")
                Button("Commit All") { Task { await git.commit(all: true) } }.disabled(git.isBusy || git.status.isClean || git.commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Stages every change, then commits")
            }
            .padding(.horizontal, 10).padding(.top, 8)
            List(selection: $selectedPath) {
                if git.status.isClean {
                    Text("No changes. The working tree matches HEAD.").foregroundStyle(.secondary)
                }
                if !git.status.staged.isEmpty {
                    Section("Staged changes (\(git.status.staged.count))") {
                        ForEach(git.status.staged) { entry in row(entry, staged: true) }
                    }
                }
                if !git.status.unstaged.isEmpty {
                    Section("Changes (\(git.status.unstaged.count))") {
                        ForEach(git.status.unstaged) { entry in row(entry, staged: false) }
                    }
                }
            }
            .onChange(of: selectedPath) { _, _ in Task { await reloadDiff() } }
            if !git.recentCommits.isEmpty {
                DisclosureGroup("Recent commits (\(git.recentCommits.count))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(git.recentCommits, id: \.self) { line in
                            Text(line).font(.caption.monospaced()).lineLimit(1).textSelection(.enabled)
                        }
                    }
                }
                .font(.caption).padding(.horizontal, 10).padding(.bottom, 6)
            }
        }
    }

    private func row(_ entry: GitRepository.Entry, staged: Bool) -> some View {
        HStack(spacing: 8) {
            Text(staged ? String(entry.staged) : entry.label)
                .font(.caption.monospaced().weight(.bold)).frame(width: 14)
                .foregroundStyle(color(for: staged ? String(entry.staged) : entry.label))
            Text(entry.path).lineLimit(1).truncationMode(.middle)
            Spacer()
            if staged {
                Button("Unstage") { Task { await git.unstage([entry.path]) } }.controlSize(.mini).disabled(git.isBusy)
            } else {
                Button("Stage") { Task { await git.stage([entry.path]) } }.controlSize(.mini).disabled(git.isBusy)
                Button("Discard") { discarding = entry.path }.controlSize(.mini).disabled(git.isBusy)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let project = model.projectURL { model.open(file: project.appendingPathComponent(entry.path)) } }
        .onTapGesture { selectedPath = entry.path }
        .tag(entry.path)
        .accessibilityLabel("\(entry.path), \(staged ? "staged" : "changed")")
    }

    private func color(for label: String) -> Color {
        switch label {
        case "A", "?": return .green
        case "D": return .red
        case "M", "R", "T": return .orange
        case "U": return .purple
        default: return .secondary
        }
    }

    private var diffPane: some View {
        ScrollView([.vertical, .horizontal]) {
            if let selectedPath {
                VStack(alignment: .leading, spacing: 0) {
                    Text(selectedPath).font(.caption.weight(.semibold)).padding(.bottom, 4)
                    if diffText.isEmpty {
                        Text("No text diff for this file.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(diffText.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced())
                                .foregroundStyle(line.hasPrefix("+") && !line.hasPrefix("+++") ? .green : line.hasPrefix("-") && !line.hasPrefix("---") ? .red : line.hasPrefix("@@") ? .blue : .primary)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a change to see its diff. Double-click opens the file.").font(.caption).foregroundStyle(.secondary).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(git.lastMessage.isEmpty ? (git.status.isRepo ? "HEAD \(git.status.head.isEmpty ? "(no commits yet)" : git.status.head)" : "") : git.lastMessage)
                .font(.caption).foregroundStyle(git.lastFailed ? .red : .secondary).lineLimit(2).textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func reloadDiff() async {
        guard let selectedPath, let entry = git.status.entries.first(where: { $0.path == selectedPath }) else { diffText = ""; return }
        diffText = await git.diff(selectedPath, staged: entry.isStaged && !entry.hasUnstaged)
    }

    private func chooseAndClone() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Clone Here"
        panel.message = "Choose the folder that will contain the cloned repository."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let url = cloneURL
        Task {
            if let folder = await git.clone(url, into: parent) {
                cloneURL = ""
                _ = model.openProject(folder)
            }
        }
    }
}

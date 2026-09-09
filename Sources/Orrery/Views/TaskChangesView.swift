import SwiftUI
import AppKit

/// Reviews a captured task version. Applying never silently saves an open editor buffer.
struct TaskChangesView: View {
    let workspace: TaskWorkspace
    var canApply: ([String]) -> Bool = { _ in true }
    var didApply: () -> Void = {}
    var operationStateChanged: (Bool) -> Void = { _ in }
    var openFile: (URL) -> Void = { _ in }
    var store: TaskWorkspaceStore = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var changes: [TaskFileChange] = []
    @State private var selection: String?
    @State private var preview: TaskFilePreview?
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?
    @State private var showDetails = false
    @State private var usage: TaskWorkspaceUsage?

    private var selected: TaskFileChange? { changes.first { $0.path == selection } }
    private var allPaths: [String] { changes.map(\.path) }
    private var appliedPaths: [String] { changes.filter(\.applied).map(\.path) }
    private var selectionPaths: [String] { selection.map { [$0] } ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Task changes").font(.title2.weight(.semibold))
                    Text(workspace.projectRoot.lastPathComponent + (workspace.isolated ? " · Independent working copy" : " · Project checkpoint"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { refresh() }.disabled(busy)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }.padding(20)
            Divider()
            if changes.isEmpty {
                ContentUnavailableView(busy ? "Checking task files…" : "No captured changes", systemImage: "doc.text.magnifyingglass",
                    description: Text("Files are compared with the task’s starting files, including any edits you had already made."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(changes) { change in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(change.kind)).foregroundStyle(color(change.kind)).frame(width: 16)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(change.path).lineLimit(2).help(change.path)
                                    Text(change.kind.rawValue.capitalized + (change.isBinary ? " · Binary" : "") + (change.applied ? (change.matchesAppliedVersion ? " · Applied" : " · New edits after apply") : ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 5).tag(change.path)
                        }
                    }.listStyle(.sidebar).frame(minWidth: 180, idealWidth: 245, maxWidth: 360)
                    VStack(alignment: .leading, spacing: 12) {
                        if let selected {
                            HStack {
                                Text(selected.path).font(.headline).lineLimit(2).textSelection(.enabled)
                                Spacer()
                                if selected.kind != .deleted {
                                    Button("Open task file") { openFile(workspace.executionRoot.appendingPathComponent(selected.path)) }
                                }
                            }
                            if selected.beforeMode != selected.afterMode {
                                Text("Permissions: \(selected.beforeMode.map { String($0, radix: 8) } ?? "none") → \(selected.afterMode.map { String($0, radix: 8) } ?? "none")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let preview {
                                if preview.isBinary {
                                    ContentUnavailableView("Binary file", systemImage: "doc",
                                        description: Text("Before: \(ByteCountFormatter.string(fromByteCount: Int64(selected.beforeBytes), countStyle: .file)) · After: \(ByteCountFormatter.string(fromByteCount: Int64(selected.afterBytes), countStyle: .file)). The exact bytes and permissions are preserved."))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                } else {
                                    HSplitView {
                                        version("Before task", text: preview.before, missing: "File did not exist")
                                        version("Captured task version", text: preview.after, missing: "File deleted")
                                    }
                                    if preview.truncated { Text("Preview shortened for performance. Applying/restoring uses the complete captured file.").font(.caption).foregroundStyle(.secondary) }
                                }
                            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                        } else { Text("Select a file to compare versions.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }.padding(16).frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                if let message { Text(message).foregroundStyle(.green).font(.callout) }
                if !canApply(allPaths), !allPaths.isEmpty {
                    Text("Stop running tasks and save or close affected unsaved files before applying or restoring.").font(.callout).foregroundStyle(.orange)
                }
                DisclosureGroup("Checkpoint scope and limits", isExpanded: $showDetails) {
                    ScrollView { VStack(alignment: .leading, spacing: 5) {
                        if let usage {
                            Text("Snapshot storage: \(ByteCountFormatter.string(fromByteCount: Int64(usage.taskSnapshotBytes), countStyle: .file)) for this task · \(ByteCountFormatter.string(fromByteCount: Int64(usage.totalSnapshotBytes), countStyle: .file)) across all tasks.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(workspace.notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding(.top, 5) }.frame(maxHeight: 90)
                }.font(.caption)
                HStack(spacing: 10) {
                    Text("\(changes.count) changed file\(changes.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if workspace.isolated {
                        Button("Undo applied") { perform(.restore, paths: appliedPaths) }
                            .disabled(busy || appliedPaths.isEmpty || !canApply(appliedPaths))
                        Button("Apply selected") { perform(.apply, paths: selectionPaths) }
                            .disabled(busy || selected == nil || !canApply(selectionPaths))
                        Button("Apply all") { perform(.apply, paths: allPaths) }.buttonStyle(.borderedProminent)
                            .disabled(busy || allPaths.isEmpty || !canApply(allPaths))
                    } else {
                        Button("Restore selected") { perform(.restore, paths: selectionPaths) }
                            .disabled(busy || selected == nil || !canApply(selectionPaths))
                        Button("Restore all task changes") { perform(.restore, paths: allPaths) }
                            .disabled(busy || allPaths.isEmpty || !canApply(allPaths))
                    }
                }
            }.padding(20)
        }.frame(minWidth: 800, idealWidth: 1040, maxWidth: 1400, minHeight: 520, idealHeight: 680, maxHeight: 900)
        .task { refresh() }
        .task(id: selection) {
            preview = nil
            guard let selection else { return }
            do { let result = try await store.diff(taskID: workspace.id, path: selection); if !Task.isCancelled { preview = result } }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func version(_ title: String, text: String?, missing: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let text { TaskFileTextPreview(text: text).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { Text(missing).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.frame(minWidth: 150, maxWidth: .infinity, maxHeight: .infinity)
    }
    private func refresh() {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                changes = try await store.capture(taskID: workspace.id)
                usage = try await store.usage(taskID: workspace.id)
                if !changes.contains(where: { $0.path == selection }) { selection = changes.first?.path }
                if let selection { preview = try await store.diff(taskID: workspace.id, path: selection) }
            } catch { self.error = error.localizedDescription }
        }
    }
    private enum Operation { case apply, restore }
    private func perform(_ operation: Operation, paths: [String]) {
        guard !busy, !paths.isEmpty, canApply(paths) else { return }
        busy = true; error = nil; message = nil
        operationStateChanged(true)
        Task {
            defer { busy = false; operationStateChanged(false) }
            do {
                if operation == .apply { try await store.integrate(taskID: workspace.id, paths: paths) }
                else { try await store.restore(taskID: workspace.id, paths: paths) }
                didApply()
                changes = try await store.changes(taskID: workspace.id)
                if let selection { preview = try await store.diff(taskID: workspace.id, path: selection) }
                message = operation == .apply ? "Applied \(paths.count) file(s) to your project." : "Restored \(paths.count) file(s) to their pre-task version."
            } catch { self.error = error.localizedDescription; didApply() }
        }
    }
    private func icon(_ kind: TaskFileChange.Kind) -> String {
        switch kind { case .added: return "plus.circle"; case .modified: return "pencil.circle"; case .deleted: return "minus.circle" }
    }
    private func color(_ kind: TaskFileChange.Kind) -> Color {
        switch kind { case .added: return .green; case .modified: return .orange; case .deleted: return .red }
    }
}

private struct TaskFileTextPreview: NSViewRepresentable {
    var text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView()
        view.isEditable = false; view.isRichText = false; view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = .labelColor; view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isHorizontallyResizable = true; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let textView = view.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }
}

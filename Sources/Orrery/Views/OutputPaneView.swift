import SwiftUI

/// The Output tab of the bottom pane: pick a task, run it, watch the stream, click an error to
/// land on its line.
struct OutputPaneView: View {
    @Bindable var model: AppModel

    private var runner: TaskRunModel { model.taskRun }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear {
            runner.refreshTasks(project: model.projectURL,
                                activeFile: model.activeDocument?.url,
                                language: model.activeDocument?.language)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                if runner.tasks.isEmpty {
                    Text("No tasks for this project")
                }
                ForEach(RunTask.Kind.allCases, id: \.self) { kind in
                    let matching = runner.tasks.filter { $0.kind == kind }
                    if !matching.isEmpty {
                        Section(kind.rawValue.capitalized) {
                            ForEach(matching) { task in
                                Button {
                                    model.runTask(task)
                                } label: {
                                    if let missing = task.missingTool {
                                        Text("\(task.title) — needs \(missing), not installed")
                                    } else {
                                        Text("\(task.title)   (\(task.source))")
                                    }
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Refresh Tasks") {
                    runner.refreshTasks(project: model.projectURL,
                                        activeFile: model.activeDocument?.url,
                                        language: model.activeDocument?.language)
                }
            } label: {
                Label(runner.activeTask?.title ?? "Run a task…",
                      systemImage: "play.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            if runner.isRunning {
                ProgressView().controlSize(.mini)
                Button {
                    runner.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill").font(.caption)
                }
                .buttonStyle(.borderless)
            } else if let task = runner.activeTask, task.missingTool == nil {
                Button {
                    model.runTask(task)
                } label: {
                    Label("Run Again", systemImage: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
            }

            if let status = runner.exitStatus {
                Text(status == 0 ? "exited 0" : "exited \(status)")
                    .font(.caption)
                    .foregroundStyle(status == 0 ? Color.green : .red)
                Text(String(format: "%.1fs", runner.duration))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if runner.problemCount > 0 {
                Text("\(runner.problemCount) errors")
                    .font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var content: some View {
        if let note = runner.note {
            VStack(spacing: 6) {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if runner.lines.isEmpty {
            Text(runner.tasks.isEmpty
                 ? "No tasks: nothing in this project declares how to build, run or test."
                 : "Pick a task to run. ⌘R runs, ⌘⇧B builds, ⌘U tests.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(runner.lines) { line in
                            outputRow(line)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: runner.lines.count) { _, _ in
                    if let last = runner.lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func outputRow(_ line: TaskRunModel.OutputLine) -> some View {
        if let diagnostic = line.diagnostic {
            Button {
                model.open(file: diagnostic.file, atLine: diagnostic.line,
                           column: diagnostic.column)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: diagnostic.severity.symbol)
                        .font(.caption2)
                        .foregroundStyle(diagnostic.severity == .error ? Color.red
                                         : diagnostic.severity == .warning ? .orange : .blue)
                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .underline()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
            .id(line.id)
            .help("\(diagnostic.file.lastPathComponent):\(diagnostic.line) — click to open")
        } else {
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 1)
                .id(line.id)
        }
    }
}

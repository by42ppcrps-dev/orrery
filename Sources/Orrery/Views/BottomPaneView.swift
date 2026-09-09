import SwiftUI

/// The pane under the editor: problems for the open file, and project-wide search.
struct BottomPaneView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ForEach(BottomPane.allCases.filter { $0 != .hidden && $0 != .browser }) { pane in
                    Button {
                        if pane == .terminal { model.showTerminal() } else { model.bottomPane = pane }
                    } label: {
                        Text(pane.title)
                            .font(.callout)
                            .fontWeight(model.bottomPane == pane ? .semibold : .regular)
                            .foregroundStyle(model.bottomPane == pane ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                PaneIconButton(title: "Hide bottom panel (⌘J)", symbol: "xmark") { model.bottomPane = .hidden }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            switch model.bottomPane {
            case .problems: ProblemsList(model: model)
            case .search: ProjectSearchPane(model: model)
            case .terminal: TerminalPane(model: model)
            case .output: OutputPaneView(model: model)
            case .browser:
                Color.clear.onAppear { model.bottomPane = .hidden; model.showBrowser() }
            case .git: GitPaneView(model: model)
            case .hidden: EmptyView()
            }
        }
        .background(.bar)
    }
}

// MARK: - Problems

struct ProblemsList: View {
    @Bindable var model: AppModel

    private var diagnostics: [Diagnostic] {
        (model.documents.active?.diagnostics ?? [])
            .sorted {
                if $0.severity != $1.severity { return $0.severity < $1.severity }
                return $0.line < $1.line
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let document = model.documents.active {
                HStack(spacing: 8) {
                    if model.diagnostics.running.contains(document.url) {
                        ProgressView().controlSize(.mini)
                    }
                    // Always say what ran. "No problems" from a checker that is not installed
                    // would be the most misleading thing this pane could show.
                    Text(model.diagnostics.notes[document.url]
                         ?? model.diagnostics.description(for: document))
                        .font(.caption)
                        .foregroundStyle(model.diagnostics.hasChecker(for: document.language)
                                         ? Color.secondary : Color.orange)
                    Spacer()
                    Button("Re-check") {
                        Task { await model.diagnostics.check(document) }
                    }
                    .controlSize(.small)
                    .disabled(!model.diagnostics.isEnabled || !model.isProjectTrusted)
                    Toggle("On", isOn: Binding(
                        get: { model.diagnostics.isEnabled },
                        set: { on in
                            model.diagnostics.isEnabled = on
                            if on { model.recheckAll() }
                        }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                Divider()
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if model.documents.active == nil {
                message("Open a file to see its problems.")
            } else if diagnostics.isEmpty {
                message("No problems reported.")
            } else {
                List(diagnostics) { diagnostic in
                    Button {
                        if let url = model.documents.active?.url {
                            model.open(file: url, atLine: diagnostic.line,
                                       column: diagnostic.column)
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: diagnostic.severity.symbol)
                                .foregroundStyle(tint(diagnostic.severity))
                                .font(.caption)
                            Text(diagnostic.message)
                                .font(.callout)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Text("\(diagnostic.line):\(diagnostic.column)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(diagnostic.source)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tint(_ severity: Diagnostic.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }
}

// MARK: - Project search

struct ProjectSearchPane: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var replacement = ""
    @State private var options = SearchOptions()
    @State private var showReplace = false
    @State private var showFilters = false
    @State private var confirmReplace = false
    @State private var replaceReport: String?
    @FocusState private var queryFocused: Bool

    init(model: AppModel) {
        self.model = model
        _query = State(initialValue: model.search.queryDraft)
        _replacement = State(initialValue: model.search.replacementDraft)
        _options = State(initialValue: model.search.optionsDraft)
        _showReplace = State(initialValue: model.search.showsReplacement)
        _showFilters = State(initialValue: model.search.showsFilters)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            results
        }
        .onAppear { queryFocused = true }
        .onDisappear {
            model.search.queryDraft = query
            model.search.replacementDraft = replacement
            model.search.optionsDraft = options
            model.search.showsReplacement = showReplace
            model.search.showsFilters = showFilters
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    showReplace.toggle()
                } label: {
                    Image(systemName: showReplace ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless).frame(width: 24, height: 28)
                .accessibilityLabel(showReplace ? "Hide replacement" : "Show replacement")

                TextField("Search the project", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
                    .onSubmit(run)

            }
            HStack(spacing: 6) {
                toggle("Aa", "Match case", $options.caseSensitive)
                toggle("W", "Whole word", $options.wholeWord)
                toggle(".*", "Regular expression", $options.isRegex)
                Button { showFilters.toggle() } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .buttonStyle(.borderless)
                    .help("Include / exclude filters")
                Spacer(minLength: 0)
                Button("Search", action: run)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(query.isEmpty)
            }
            if showReplace {
                HStack(spacing: 6) {
                    Spacer().frame(width: 22)
                    TextField("Replace with", text: $replacement)
                        .textFieldStyle(.roundedBorder)
                    Button("Replace All") { confirmReplace = true }
                        .disabled(model.search.results.isEmpty || model.search.isSearching)
                    Button("Undo Replace") {
                        do {
                            let count = try model.search.undoLastReplacement(protecting: model.documents.dirtyDocuments.map(\.url))
                            model.documents.checkAllOnDisk()
                            _ = model.documents.reloadUnmodifiedFromDisk()
                            run()
                            replaceReport = "Restored \(count) files."
                        } catch { model.documents.notice = error.localizedDescription }
                    }
                    .disabled(!model.search.canUndoReplacement)
                }
            }
            if showFilters {
                HStack(spacing: 6) {
                    Spacer().frame(width: 22)
                    TextField("Include, e.g. *.swift, src/**", text: $options.include)
                        .textFieldStyle(.roundedBorder)
                    TextField("Exclude", text: $options.exclude)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack(spacing: 8) {
                if model.search.isSearching {
                    ProgressView().controlSize(.small)
                    Text("Searching \(model.index.files.count) files…")
                } else if let note = model.search.note {
                    Text(note).foregroundStyle(.orange)
                } else if !model.search.results.isEmpty {
                    Text("\(model.search.totalHits) matches in \(model.search.results.count) files"
                         + String(format: " · %.2fs", model.search.elapsed))
                }
                if let report = replaceReport {
                    Text(report).foregroundStyle(.green)
                }
                if model.index.isScanning {
                    Text("Indexing…").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .confirmationDialog(
            "Replace \(model.search.totalHits) matches in \(model.search.results.count) files?",
            isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace All", role: .destructive) { performReplace() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This rewrites the files on disk. Files open in a tab will reload if you have "
                 + "not edited them.")
        }
    }

    private func toggle(_ label: String, _ help: String, _ binding: Binding<Bool>) -> some View {
        Button {
            binding.wrappedValue.toggle()
            if !query.isEmpty { run() }
        } label: {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 28, height: 26)
                .background(binding.wrappedValue ? Color.accentColor.opacity(0.3) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help).accessibilityLabel(help).accessibilityValue(binding.wrappedValue ? "On" : "Off")
    }

    private func run() {
        replaceReport = nil
        model.runProjectSearch(query, options: options)
    }

    private func performReplace() {
        do {
            let result = try model.search.replaceAll(with: replacement, query: query,
                                                     options: options,
                                                     protecting: model.documents.dirtyDocuments.map(\.url))
            model.documents.checkAllOnDisk()
            _ = model.documents.reloadUnmodifiedFromDisk()
            model.refreshDiff()
            run()
            replaceReport = "Replaced \(result.hits) in \(result.files) files."
        } catch {
            replaceReport = nil
            model.documents.notice = "Replace failed: \(error.localizedDescription)"
        }
    }

    private var results: some View {
        List {
            ForEach(model.search.results) { file in
                Section {
                    ForEach(file.hits) { hit in
                        Button {
                            model.open(file: hit.file, selecting: hit.range)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(hit.lineNumber)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42, alignment: .trailing)
                                Text(preview(hit))
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text(file.relativePath).font(.caption).fontWeight(.medium)
                        Text("\(file.hits.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.search.results.isEmpty, !model.search.isSearching {
                Text(query.isEmpty ? "Search across every indexed file in this project." : "No matches. Try a different search or check your filters.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(16)
            }
        }
    }

    /// Highlight the matched span inside the line.
    private func preview(_ hit: SearchHit) -> AttributedString {
        let trimmed = hit.preview.trimmingCharacters(in: .whitespaces)
        var text = AttributedString(trimmed)
        let leading = hit.preview.prefix { $0 == " " || $0 == "\t" }.count
        let count = text.characters.count
        let start = max(0, hit.previewRange.location - leading)
        let end = min(count, start + hit.previewRange.length)
        guard start < end, start < count else { return text }
        let lower = text.index(text.startIndex, offsetByCharacters: start)
        let upper = text.index(text.startIndex, offsetByCharacters: end)
        text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        text[lower..<upper].backgroundColor = .yellow.opacity(0.35)
        return text
    }
}

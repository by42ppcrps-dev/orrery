import SwiftUI
import AppKit

/// Tabs, the code editor, the diff view, and the pane below them.
struct EditorPane: View {
    @Bindable var model: AppModel
    @State private var tab: Tab = .file
    @State private var dragStartHeight: CGFloat?
    @State private var wrapsLines = EditorTheme.wrapsLines

    enum Tab: String, CaseIterable { case file = "Code", diff = "Diff" }

    private var document: CodeDocument? { model.documents.active }

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            surfaceNavigation
            Divider()
            if model.editorSurface == .browser {
                BrowserPaneView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.editorSurface == .simulator {
                SimulatorPaneView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            if !model.documents.documents.isEmpty {
                TabBar(model: model)
                Divider()
            }
            if document != nil {
                subToolbar
                Divider()
            }
            banner
            Group {
                switch tab {
                case .file: editor
                case .diff: DiffView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.bottomPane != .hidden {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 38, height: 3)
                    .frame(maxWidth: .infinity).frame(height: 10)
                    .background(.bar).contentShape(Rectangle())
                    .help("Drag to resize the bottom panel")
                    .accessibilityLabel("Resize bottom panel")
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("editorPane"))
                        .onChanged { value in
                            if dragStartHeight == nil { dragStartHeight = min(model.bottomPaneHeight, geometry.size.height * 0.65) }
                            model.bottomPaneHeight = min(max(170, (dragStartHeight ?? 260) - value.translation.height), geometry.size.height * 0.65)
                        }.onEnded { _ in dragStartHeight = nil })
                BottomPaneView(model: model)
                    .frame(height: min(model.bottomPaneHeight, geometry.size.height * 0.65))
            }
            }
            Divider()
            if model.editorSurface == .code { statusBar }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: EditorTheme.background))
        .coordinateSpace(name: "editorPane")
        }
    }

    // MARK: Sub-toolbar

    private var surfaceNavigation: some View {
        HStack(spacing: 6) {
            surfaceButton("Browser", symbol: "globe", selected: model.editorSurface == .browser) { model.showBrowser() }
            surfaceButton("Code", symbol: "chevron.left.forwardslash.chevron.right", selected: model.editorSurface == .code) { model.showCode() }
            surfaceButton("Simulator", symbol: "iphone", selected: model.editorSurface == .simulator) { model.showSimulator() }
            Spacer(minLength: 0)
            PaneIconButton(title: "Review project changes", symbol: "square.stack.3d.up") {
                if let workspace = model.currentTaskWorkspace { model.reviewingWorkspace = workspace }
                else { model.showCode(); model.showGit() }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.bar)
    }

    private func surfaceButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(selected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var subToolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .onChange(of: tab) { _, new in
                model.documents.checkAllOnDisk()
                if new == .diff { model.refreshDiff() }
            }

            Spacer()

            if let document {
                Button {
                    wrapsLines.toggle()
                    EditorTheme.wrapsLines = wrapsLines
                } label: {
                    Image(systemName: wrapsLines ? "text.alignleft" : "arrow.left.and.right")
                }
                .help(wrapsLines ? "Wrapping lines" : "Not wrapping lines")
                .buttonStyle(.borderless)

                Button { model.saveActiveFile() } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(!document.isDirty || !document.isReadable)
                .help(document.isReadable ? "Save (⌘S)" : "This file is not editable text")
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Banners

    @ViewBuilder
    private var banner: some View {
        if let notice = model.documents.notice {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(notice).font(.caption).textSelection(.enabled)
                Spacer()
                if model.documents.active?.changedOnDisk == true {
                    Button("Reload") { model.reloadActiveFile(); model.documents.notice = nil }
                        .controlSize(.small)
                    Button("Save Anyway") {
                        _ = model.documents.active?.forceSave()
                        model.documents.notice = nil
                        model.refreshDiff()
                    }
                    .controlSize(.small)
                }
                Button("Dismiss") { model.documents.notice = nil }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.orange.opacity(0.14))
        } else if let document, !document.isReadable, MediaKind.of(url: document.url) == nil {
            notice(document.loadNote ?? "Not editable text.",
                   systemImage: "doc.questionmark", tint: .orange, action: nil)
        } else if let document, document.changedOnDisk {
            notice("\(document.name) changed on disk since you opened it.",
                   systemImage: "arrow.triangle.2.circlepath", tint: .orange) {
                model.reloadActiveFile()
            }
        }
    }

    private func notice(_ text: String, systemImage: String, tint: Color,
                        action: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.caption)
            Spacer()
            if let action { Button("Reload", action: action).controlSize(.small) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12))
    }

    // MARK: Editor

    @ViewBuilder
    private var editor: some View {
        if let document {
            switch MediaKind.of(url: document.url) {
            case .image:
                ImagePreview(url: document.url)
                    .id(document.id)
            case .video:
                VideoPreview(url: document.url)
                    .id(document.id)
            case nil:
                CodeEditorView(document: document, wrapsLines: wrapsLines,
                               request: $model.editorRequest,
                               onSave: { model.saveActiveFile() },
                               onEdit: { model.noteEdit() },
                               model: model,
                               pendingCompletions: model.pendingLSPCompletions,
                               pendingHover: model.pendingLSPHover)
                .id(document.id)
            }
        } else {
            ContentUnavailableView {
                Label("No file open", systemImage: "doc.text")
            } description: {
                Text(model.projectURL == nil ? "Add a project folder to get started." : "Choose a file from the sidebar or find it by name.")
            } actions: {
                if model.projectURL == nil {
                    Button("Add Project…") { model.chooseProject() }.buttonStyle(.borderedProminent)
                } else {
                    VStack(spacing: 10) {
                        Button("Open File…  ⌘P") { model.showQuickOpen = true }.buttonStyle(.borderedProminent)
                        Button("Search Project  ⌘⇧F") { model.bottomPane = .search }.buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        VStack(spacing: 0) {
            if let document {
                HStack(spacing: 10) {
                    caretOrMediaStatus(document)
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(Languages.all) { language in
                            Button(language.name) { model.setLanguage(language, on: document) }
                        }
                    } label: { Text(document.language.name) }
                    .menuStyle(.borderlessButton).fixedSize()
                    if document.isDirty { Text("Edited").foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .help("\(document.lineCount) lines · \(document.language.indentUnit == "\t" ? "Tabs" : "Spaces: \(document.language.indentUnit.count)")")
                if let note = model.editorNote, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.orange).lineLimit(2)
                        .padding(.horizontal, 12).padding(.bottom, 4)
                }
                Divider()
            }
            if model.bottomPane == .hidden {
            HStack(spacing: 4) {
                ForEach([BottomPane.problems, .search, .terminal, .output]) { pane in
                    Button {
                        if model.bottomPane == pane { model.bottomPane = .hidden }
                        else if pane == .terminal { model.showTerminal() }
                        else { model.bottomPane = pane }
                    } label: {
                        Label(pane.title, systemImage: pane.symbol)
                            .font(.caption)
                            .padding(.horizontal, 7).frame(height: 32)
                            .foregroundStyle(model.bottomPane == pane ? Color.accentColor : .secondary)
                            .background(model.bottomPane == pane ? Color.accentColor.opacity(0.12) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain).help(pane.title)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            }
        }
        .background(.bar)
    }

    @ViewBuilder
    private func caretOrMediaStatus(_ document: CodeDocument) -> some View {
        switch MediaKind.of(url: document.url) {
        case .image:
            if let size = MediaInfo.pixelSize(of: document.url) {
                Text("\(size.width)×\(size.height)")
            }
        case .video:
            MediaDurationLabel(url: document.url)
        case nil:
            let line = document.decorator.lineNumber(at: document.selection.location)
            let lineStart = document.decorator.range(ofLine: line)?.location ?? 0
            let column = document.selection.location - lineStart + 1
            Text("Ln \(line), Col \(max(1, column))")
        }
    }
}

// MARK: - Tab bar

struct TabBar: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.documents.documents) { document in
                        tab(document)
                            .id(document.id)
                        Divider().frame(height: 18)
                    }
                }
            }
            .onChange(of: model.documents.activeID) { _, new in
                if let new { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new) } }
            }
        }
        .frame(height: 38)
        .background(.bar)
    }

    private func tab(_ document: CodeDocument) -> some View {
        let isActive = document.id == model.documents.activeID
        return HStack(spacing: 6) {
            Image(systemName: document.language.symbol)
                .font(.caption2)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            Text(document.name)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
            Button {
                model.documents.close(document)
            } label: {
                Image(systemName: document.isDirty ? "circle.fill" : "xmark")
                    .font(.system(size: document.isDirty ? 6 : 8))
                    .foregroundStyle(document.isDirty ? Color.orange : .secondary)
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(document.isDirty ? "Unsaved changes — click to close" : "Close")
            .accessibilityLabel("Close file \(document.name)")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(isActive ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.documents.activeID = document.id }
        .help(document.url.path)
        .contextMenu {
            Button("Close") { model.documents.close(document) }
            Button("Close Others") { model.documents.closeOthers(than: document) }
            Button("Close All") { model.documents.closeAll() }
            Divider()
            Button("Reveal in Finder") { FileOperations.revealInFinder(document.url) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(document.url.path, forType: .string)
            }
        }
    }
}

// MARK: - Diff

struct DiffView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            if model.diffText.isEmpty {
                Text(model.projectIsGitRepo
                     ? "No uncommitted changes for this file."
                     : "This project is not a git repository, so there is nothing to diff against.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.diffText.components(separatedBy: "\n").enumerated()),
                            id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                            .background(background(for: line))
                            .foregroundStyle(foreground(for: line))
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 6)
            }
        }
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color.green.opacity(0.12) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color.red.opacity(0.12) }
        if line.hasPrefix("@@") { return Color.accentColor.opacity(0.10) }
        return .clear
    }

    private func foreground(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .accentColor }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") { return .secondary }
        return .primary
    }
}

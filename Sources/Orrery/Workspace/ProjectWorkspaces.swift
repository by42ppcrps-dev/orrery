import SwiftUI
import AppKit
import Observation

/// A window keeps one model per project. Only the selected project's views are mounted;
/// tasks, agent sessions, editor buffers and terminals belong to models, not to tab views.
@MainActor
@Observable
final class ProjectWorkspaces {
    struct Tab: Identifiable {
        let id = UUID()
        let model: AppModel
        @MainActor var name: String { model.projectURL?.lastPathComponent ?? "Welcome" }
    }
    private(set) var tabs: [Tab] = []
    var activeID: UUID?
    var active: Tab? { tabs.first { $0.id == activeID } ?? tabs.first }
    private let defaults: UserDefaults?
    private let makeModel: @MainActor () -> AppModel

    init(model: AppModel? = nil, defaults: UserDefaults? = nil,
         makeModel: @escaping @MainActor () -> AppModel = { AppModel() }) {
        self.defaults = defaults
        self.makeModel = makeModel
        if let model {
            append(model)
        } else if let paths = defaults?.stringArray(forKey: "workspace.projectTabs.v1") {
            for path in paths.prefix(20) {
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue {
                    let model = makeModel()
                    model.openProject(URL(fileURLWithPath: path))
                    append(model)
                }
            }
        }
        if tabs.isEmpty { append(makeModel()) }
        if let path = defaults?.string(forKey: "workspace.activeProject.v1"),
           let tab = tabs.first(where: { $0.model.projectURL?.path == path }) { activeID = tab.id }
    }

    private func append(_ model: AppModel) {
        model.openProjectInWindow = { [weak self] url in self?.open(url) }
        let tab = Tab(model: model)
        tabs.append(tab)
        activeID = tab.id
    }

    func open(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = tabs.first(where: { $0.model.projectURL?.resolvingSymlinksInPath().standardizedFileURL == resolved }) {
            select(existing.id)
            return
        }
        if tabs.count == 1, let empty = tabs.first, empty.model.projectURL == nil {
            guard empty.model.openProject(url) else { return }
            empty.model.showSetup = !empty.model.isProjectTrusted || !empty.model.installed.values.contains(true)
            Task { await empty.model.startIfNeeded() }
        } else {
            let model = makeModel()
            guard model.openProject(url) else { model.shutdown(); return }
            model.showSetup = !model.isProjectTrusted || !model.installed.values.contains(true)
            append(model)
        }
        persist()
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeID = id
        if let model = active?.model { model.remote.model = model }
        persist()
    }

    func cycle(_ offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex(where: { $0.id == activeID }) ?? 0
        select(tabs[(current + offset % tabs.count + tabs.count) % tabs.count].id)
    }

    @discardableResult
    func close(_ id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return true }
        let model = tabs[index].model
        guard model.documents.approveClosing() else { return false }
        model.shutdown()
        tabs.remove(at: index)
        if activeID == id { activeID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        if tabs.isEmpty { append(makeModel()) }
        persist()
        return true
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Projects"
        if panel.runModal() == .OK { for url in panel.urls { open(url) } }
    }

    func persist() {
        guard let defaults else { return }
        let paths = tabs.compactMap { $0.model.projectURL?.path }.filter { !AppModel.isScratchPath($0) }
        defaults.set(paths, forKey: "workspace.projectTabs.v1")
        defaults.set(active?.model.projectURL?.path, forKey: "workspace.activeProject.v1")
    }
}

struct WorkspaceFocusKey: FocusedValueKey { typealias Value = ProjectWorkspaces }
extension FocusedValues {
    var projectWorkspaces: ProjectWorkspaces? {
        get { self[WorkspaceFocusKey.self] }
        set { self[WorkspaceFocusKey.self] = newValue }
    }
}

/// StateObject's autoclosure constructs this once for the mounted window. Eagerly creating
/// restored projects in a View initializer repeats disk work and side effects on every render.
@MainActor
private final class WorkspaceWindowOwner: ObservableObject {
    let workspaces: ProjectWorkspaces
    init(model: AppModel?, restoreLastProject: Bool) {
        workspaces = ProjectWorkspaces(model: model, defaults: restoreLastProject ? .standard : nil)
    }
}

struct WorkspaceWindowView: View {
    @StateObject private var owner: WorkspaceWindowOwner
    private var workspaces: ProjectWorkspaces { owner.workspaces }
    private let restoreLastProject: Bool

    init(model: AppModel? = nil, restoreLastProject: Bool = true) {
        self.restoreLastProject = restoreLastProject
        _owner = StateObject(wrappedValue: WorkspaceWindowOwner(model: model, restoreLastProject: restoreLastProject))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(workspaces.tabs) { tab in
                            HStack(spacing: 7) {
                                Button {
                                    workspaces.select(tab.id)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "folder")
                                        Text(tab.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220)
                                        if !tab.model.permissionQueue.isEmpty {
                                            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                                        } else if tab.model.taskRun.isRunning || tab.model.states.values.contains(where: \.isBusy) {
                                            ProgressView().controlSize(.mini)
                                        }
                                        if tab.model.documents.hasUnsavedChanges {
                                            Circle().fill(.orange).frame(width: 6, height: 6)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Switch to project \(tab.name)")
                                Button { workspaces.close(tab.id) } label: {
                                    Image(systemName: "xmark").font(.caption2).frame(width: 24, height: 28).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Close project \(tab.name)")
                            }
                            .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
                            .id(tab.id)
                            .background(workspaces.active?.id == tab.id ? Color.accentColor.opacity(0.16) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .help(tab.model.projectURL?.path ?? "Choose a project")
                        }
                    }.padding(.horizontal, 8)
                }
                .onChange(of: workspaces.activeID, initial: true) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                }
                Menu {
                    ForEach(workspaces.tabs) { tab in
                        Button(tab.name) { workspaces.select(tab.id) }
                    }
                } label: { Image(systemName: "list.bullet") }
                .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 8)
                .help("All open projects").accessibilityLabel("All open projects")
                Button { workspaces.chooseProject() } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .padding(.horizontal, 12)
                .accessibilityIdentifier("add-project-tab")
            }
            .frame(height: 46)
            .background(.bar)
            Divider()
            if let active = workspaces.active {
                ContentView(model: active.model, restoreLastProject: restoreLastProject,
                            managesWindowLifecycle: false)
                    .id(active.id)
            }
        }
        .focusedSceneValue(\.projectWorkspaces, workspaces)
        .focusedValue(\.projectWorkspaces, workspaces)
        .background(WindowShutdownHook(models: workspaces.tabs.map(\.model)))
        .onDisappear { workspaces.persist() }
    }
}

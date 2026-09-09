import SwiftUI

/// The Connectors section of the settings sheet: one list of MCP servers that every agent gets,
/// the same idea as the connectors in the Claude and Codex apps.
struct ConnectorsSection: View {
    @Bindable var model: AppModel
    @State private var editing: Connector?
    @State private var status: String?
    @State private var showImport = false
    @State private var unlocking = false
    @State private var search = ""
    @State private var showLegacyUnlock = false

    var store: ConnectorStore = .shared

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            Text("Connect your tools").font(.title2.weight(.semibold))
            Text("Set up a connection once. Share it with all your agents, or choose who gets it. Import your existing connections, pick a template, or paste an MCP setup from the tool's documentation.")
                .font(.callout).foregroundStyle(.secondary)
            if store.connectors.isEmpty {
                Text("No connectors yet. Import what your CLIs already use, pick one from the catalog, or add your own.").font(.callout)
            }
            buttons
            TextField("Find a connection", text: $search).textFieldStyle(.roundedBorder)
            ForEach(store.connectors.filter { search.isEmpty || ($0.name + " " + $0.note).localizedCaseInsensitiveContains(search) }) { connector in
                ConnectorRow(connector: connector, store: store, edit: { editing = connector }, remove: {
                    store.remove(connector.id)
                    status = "Removed \(connector.name)."
                })
                Divider()
            }
            if store.connectors.contains(where: { !$0.secretKeys.isEmpty }) {
                HStack {
                    Button(unlocking ? "Unlocking…" : CredentialUnlock.buttonTitle) {
                        unlocking = true
                        Task {
                            let result = await store.unlockWithDeviceAuthentication()
                            status = result.message
                            switch result { case .needsKeychainPermission, .unavailable: showLegacyUnlock = true; default: showLegacyUnlock = false }
                            unlocking = false
                        }
                    }.disabled(unlocking)
                    Text("Uses macOS authentication, with Touch ID when available. Credentials stay in your Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if showLegacyUnlock {
                Button("Allow existing Keychain access…") {
                    unlocking = true
                    Task { status = await store.unlockCredentials(); unlocking = false }
                }.disabled(unlocking)
            }
            if let status { Text(status).font(.callout).foregroundStyle(.green) }
            if let error = store.lastError { Text(error).font(.callout).foregroundStyle(.red) }
            Text("Sessions pick up changes when they next start: a new conversation, or the next Team or Roundtable run. A remote server that signs you in with OAuth still needs that sign-in once inside the agent's own CLI pane (Claude: /mcp). Connectors are shared by every project and live in \(store.fileURL.path), owner-only.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
        }
        .sheet(item: $editing) { connector in
            ConnectorEditor(connector: connector) { saved, secrets in
                guard store.upsert(saved, secretValues: secrets) else { return false }
                status = "Saved \(saved.name)."
                return true
            }
        }
        .sheet(isPresented: $showImport) { ConnectorSetupSheet() }
    }

    private var buttons: some View {
        HStack {
            Button("Import existing") { status = store.importFromCLIs(project: model.projectURL) }
                .help("Reads ~/.claude.json, this project's .mcp.json and ~/.codex/config.toml, and refreshes anything imported before")
            Menu("Add from Catalog") {
                ForEach(ConnectorImport.catalog) { template in
                    Button(template.name) {
                        var connector = template.connector
                        connector.id = UUID().uuidString
                        if connector.name == "filesystem", let project = model.projectURL,
                           let index = connector.arguments.firstIndex(of: ".") { connector.arguments[index] = project.path }
                        editing = connector
                    }.help(template.description)
                }
            }
            Button("Add Connector…") { editing = Connector(name: "") }
            Button("Paste MCP setup…") { showImport = true }
        }
    }
}

/// One connector in the list: on/off, what it runs, which agents get it.
private struct ConnectorRow: View {
    let connector: Connector
    let store: ConnectorStore
    var edit: () -> Void
    var remove: () -> Void
    @State private var setupStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
            Toggle("Enabled", isOn: Binding(get: { connector.enabled }, set: { store.setEnabled($0, id: connector.id) }))
                .labelsHidden().toggleStyle(.switch).accessibilityLabel("Enable \(connector.name)")
                    Text(connector.name).font(.callout.weight(.medium))
                    Text(connector.transport.title).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                    if connector.source != "orrery" {
                        Text("from \(connector.source == "claude" ? "Claude Code" : "Codex")").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Edit", action: edit)
                        Button("Check setup") { setupStatus = store.checkSetup(connector) }
                        Button("Remove", role: .destructive, action: remove)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(connector.name)")
            }
                Text(connector.summary).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                if !connector.secretKeys.isEmpty { secrets }
                if !connector.note.isEmpty { Text(connector.note).font(.caption2).foregroundStyle(.secondary) }
                agents
                if let setupStatus { Text(setupStatus).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var complete: Bool { connector.secretKeys.allSatisfy { store.hasSecret(connector.id, key: $0) } }

    private var secrets: some View {
        Text("Saved credentials: " + connector.secretKeys.map { "\($0)\(store.hasSecret(connector.id, key: $0) ? "" : " (locked or missing)")" }.joined(separator: ", "))
            .font(.caption2).foregroundStyle(complete ? Color.secondary : Color.orange)
    }

    private var agents: some View {
        HStack(spacing: 8) {
            Button("All agents") { store.setProviders(Set(Provider.allCases), id: connector.id) }.controlSize(.small)
            ForEach(Provider.allCases) { provider in
                Toggle(provider.displayName, isOn: Binding(
                    get: { connector.providers.contains(provider) },
                    set: { on in
                        var set = connector.providers
                        if on { set.insert(provider) } else { set.remove(provider) }
                        store.setProviders(set, id: connector.id)
                    }))
                    .toggleStyle(.checkbox).font(.caption)
            }
            if let problem = connector.problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
    }
}

/// The form for one connector. Secret values typed here go straight to the Keychain.
struct ConnectorEditor: View {
    @State var connector: Connector
    var save: (Connector, [String: String]) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var argumentsText = ""
    @State private var environmentText = ""
    @State private var headersText = ""
    @State private var secretKeysText = ""
    @State private var secretDrafts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(connector.name.isEmpty ? "New connector" : "Connector: \(connector.name)").font(.headline)
            HStack {
                TextField("Name (letters, digits, - _ .)", text: $connector.name).textFieldStyle(.roundedBorder)
                Picker("", selection: $connector.transport) {
                    ForEach(Connector.Transport.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 130)
            }
            if connector.transport == .command {
                TextField("Command (npx, uvx, or a full path)", text: $connector.command).textFieldStyle(.roundedBorder)
                TextField("Arguments, one per line", text: $argumentsText, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
                TextField("Environment, KEY=value per line", text: $environmentText, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
            } else {
                TextField("URL (https://…)", text: $connector.url).textFieldStyle(.roundedBorder)
                TextField("Headers, Name=value per line", text: $headersText, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
            }
            TextField("Secret keys, one per line; their values go to the Keychain", text: $secretKeysText, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            ForEach(secretKeyList, id: \.self) { key in
                SecureField(secretPrompt(key), text: Binding(get: { secretDrafts[key] ?? "" }, set: { secretDrafts[key] = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            agents
            if let problem = preview.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { if save(preview, secretDrafts) { dismiss() } }
                    .buttonStyle(.borderedProminent).disabled(preview.problem != nil)
            }
            if let error = ConnectorStore.shared.lastError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(18)
        .frame(width: 580)
        .onAppear {
            argumentsText = connector.arguments.joined(separator: "\n")
            environmentText = connector.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            headersText = connector.headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            secretKeysText = connector.secretKeys.joined(separator: "\n")
        }
    }

    private var agents: some View {
        HStack(spacing: 10) {
            Text("Agents").font(.caption)
            Button("All") { connector.providers = Set(Provider.allCases) }.controlSize(.small)
            ForEach(Provider.allCases) { provider in
                Toggle(provider.displayName, isOn: Binding(
                    get: { connector.providers.contains(provider) },
                    set: { on in if on { connector.providers.insert(provider) } else { connector.providers.remove(provider) } }))
                    .toggleStyle(.checkbox).font(.caption)
            }
        }
    }

    private func secretPrompt(_ key: String) -> String {
        ConnectorStore.shared.hasSecret(connector.id, key: key) ? "\(key) value (stored; leave empty to keep it)" : "\(key) value"
    }

    private var secretKeyList: [String] {
        AgentSessionSettings.lines(secretKeysText).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// What Save would store: text boxes parsed, secret keys removed from the plain boxes.
    private var preview: Connector {
        var result = connector
        result.name = connector.name.trimmingCharacters(in: .whitespaces)
        result.arguments = AgentSessionSettings.lines(argumentsText).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        result.environment = Self.pairs(environmentText)
        result.headers = Self.pairs(headersText)
        result.secretKeys = secretKeyList
        for key in result.secretKeys { result.environment.removeValue(forKey: key); result.headers.removeValue(forKey: key) }
        return result
    }

    static func pairs(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in AgentSessionSettings.lines(text) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

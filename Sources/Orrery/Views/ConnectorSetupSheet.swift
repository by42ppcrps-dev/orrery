import SwiftUI

extension ConnectorImport {
    static func pasted(_ text: String) throws -> [(Connector, [String: String])] {
        let object = try AgentSessionSettings.object(text)
        let servers = object["mcpServers"] as? [String: Any] ?? object
        guard !servers.isEmpty, servers.count <= 50 else { throw ComputerError("Paste an MCP setup containing between 1 and 50 servers.") }
        for (_, raw) in servers {
            guard let server = raw as? [String: Any],
                  server["args"] == nil || server["args"] is [String],
                  server["env"] == nil || server["env"] is [String: String],
                  server["headers"] == nil || server["headers"] is [String: String] else {
                throw ComputerError("Each server needs a command or URL, a list of arguments, and text values for environment variables and headers.")
            }
        }
        let parsed = fromClaude(JSON(["mcpServers": servers]), project: nil, source: "orrery", note: "Added from MCP setup")
        guard parsed.count == servers.count else { throw ComputerError("One or more servers have an invalid name, command or URL. Nothing was added.") }
        return parsed.sorted { $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
    }
}

struct ConnectorSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var parsed: [(Connector, [String: String])] = []
    @State private var providers = Set(Provider.allCases)
    @State private var problem: String?
    @State private var savedIDs: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect a tool").font(.title2.weight(.semibold))
            Text("Paste the MCP configuration from the tool's setup page. Review what will run, choose your agents, and add it once.")
                .foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced))
                .padding(8).frame(height: 140).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("MCP setup JSON")
                .onChange(of: text) { _, _ in parsed = []; problem = nil }
            HStack {
                Button("Review setup") {
                    do { parsed = try ConnectorImport.pasted(text); problem = nil }
                    catch { problem = error.localizedDescription }
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button("All agents") { providers = Set(Provider.allCases) }
                ForEach(Provider.allCases) { provider in
                    Toggle(provider.displayName, isOn: Binding(get: { providers.contains(provider) }, set: { if $0 { providers.insert(provider) } else { providers.remove(provider) } }))
                        .toggleStyle(.checkbox)
                }
            }
            if !parsed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(parsed.map(\.0)) { connector in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(connector.name).font(.headline)
                                Text(connector.summary).font(.caption.monospaced()).textSelection(.enabled)
                                if !connector.secretKeys.isEmpty {
                                    Text("\(connector.secretKeys.count) credential(s) will be stored in the Keychain.").font(.caption).foregroundStyle(.secondary)
                                }
                                if connector.transport == .command,
                                   Executables.find([connector.command], orNamed: connector.command) == nil {
                                    Text("Install \(connector.command) before starting this connection.").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 150)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            Text("Connections become available in new agent sessions. Command servers run local software; remote servers may require a sign-in. Adding a setup does not claim the server has connected.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add connections") {
                    let store = ConnectorStore.shared
                    for (original, secrets) in parsed {
                        var connector = original
                        connector.providers = providers
                        if let id = savedIDs[connector.name] ?? store.connectors.first(where: { $0.name == connector.name && $0.source == "orrery" })?.id { connector.id = id }
                        guard store.upsert(connector, secretValues: secrets) else {
                            problem = store.lastError ?? "Could not save the connection."
                            return
                        }
                        savedIDs[connector.name] = connector.id
                    }
                    text = ""; parsed = []; dismiss()
                }.buttonStyle(.borderedProminent).disabled(parsed.isEmpty || providers.isEmpty)
            }
        }.padding(24).frame(width: 620)
    }
}

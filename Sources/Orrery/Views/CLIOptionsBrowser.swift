import SwiftUI

/// Discover the installed binary's flags rather than claiming a frozen list is complete.
/// Unknown syntax remains available verbatim in Help and in the raw argument editor.
struct CLIOption: Identifiable, Equatable {
    var id: String { flag }
    let flag: String
    var argument: String
    var detail: String
    var takesValue: Bool { argument.contains("<") || argument.contains("[") }

    static func parse(_ help: String) -> [CLIOption] {
        var options: [CLIOption] = []
        var inOptions = false
        let flags = try! NSRegularExpression(pattern: "--[A-Za-z][A-Za-z0-9-]*")
        let columns = try! NSRegularExpression(pattern: "\\s{2,}")
        for raw in help.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased() == "options:" { inOptions = true; continue }
            if !raw.hasPrefix(" "), line.hasSuffix(":"), !line.isEmpty { inOptions = false }
            guard inOptions else { continue }
            if line.hasPrefix("-"), let match = flags.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let flagRange = Range(match.range, in: line) {
                let tail = String(line[flagRange.upperBound...])
                let pieces = columns.stringByReplacingMatches(in: tail, range: NSRange(tail.startIndex..., in: tail), withTemplate: "\t").components(separatedBy: "\t")
                let signature = pieces.first?.trimmingCharacters(in: .whitespaces) ?? ""
                let argument = signature.range(of: "[<\\[][^>\\]]+[>\\]]", options: .regularExpression).map { String(signature[$0]) } ?? ""
                let option = CLIOption(flag: String(line[flagRange]), argument: argument, detail: pieces.dropFirst().joined(separator: " "))
                if !options.contains(where: { $0.flag == option.flag }) { options.append(option) }
            } else if !line.isEmpty, !options.isEmpty {
                options[options.count - 1].detail += (options.last!.detail.isEmpty ? "" : " ") + line
            }
        }
        return options
    }

    func arguments(value: String) -> [String] {
        guard takesValue else { return [flag] }
        // One value stays one argv element, even with spaces, quotes, or shell metacharacters.
        return value.isEmpty ? [flag] : [flag, value]
    }
}

struct CLIOptionsBrowser: View {
    let provider: Provider
    @Binding var arguments: String
    @State private var help = ""
    @State private var options: [CLIOption] = []
    @State private var query = ""
    @State private var values: [String: String] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var showHelp = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search every installed CLI option", text: $query).textFieldStyle(.roundedBorder)
                Button(showHelp ? "Options" : "Full Help") { showHelp.toggle() }
            }
            Text("For the native \(provider.displayName) CLI. Add options here, then review and launch below. Solo, Team and Roundtable use Agent settings.")
                .font(.caption).foregroundStyle(.secondary)
            if loading { ProgressView("Reading installed CLI options…") }
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                if showHelp {
                    Text(help).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(options.filter { query.isEmpty || ($0.flag + " " + $0.detail).localizedCaseInsensitiveContains(query) }) { option in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(option.flag).font(.system(.callout, design: .monospaced).weight(.semibold))
                                    Spacer()
                                    Button("Add") {
                                        let addition = option.arguments(value: values[option.flag] ?? "").joined(separator: "\n")
                                        arguments += (arguments.isEmpty || arguments.hasSuffix("\n") ? "" : "\n") + addition
                                        notice = "Added \(option.flag). Review the arguments before launching."
                                    }.controlSize(.small)
                                        .disabled(option.argument.hasPrefix("<") && (values[option.flag] ?? "").isEmpty)
                                }
                                Text(option.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                if option.takesValue {
                                    TextField(option.argument, text: Binding(get: { values[option.flag] ?? "" }, set: { values[option.flag] = $0.replacingOccurrences(of: "\n", with: " ") }))
                                        .textFieldStyle(.roundedBorder).accessibilityLabel("Value for \(option.flag)")
                                }
                            }
                            Divider()
                        }
                    }
                }
            }.frame(height: 220)
        }
        .task {
            let executable: String?
            switch provider { case .grok: executable = GrokBackend.locate(); case .claude: executable = ClaudeBackend.locate(); case .codex: executable = CodexBackend.locate() }
            defer { loading = false }
            guard let executable else { error = "Install \(provider.displayName) to discover its CLI options."; return }
            do {
                let result = try await ProcessRunner.run(executable, ["--help"], cwd: FileManager.default.temporaryDirectory, timeout: 12)
                guard !Task.isCancelled else { return }
                guard result.status == 0, !result.timedOut else { error = "The CLI could not return its help. Raw launch options are still available."; return }
                help = String(result.standardOutput.prefix(200_000))
                options = CLIOption.parse(help)
                if options.isEmpty { showHelp = true }
            } catch { self.error = error.localizedDescription }
        }
    }
}

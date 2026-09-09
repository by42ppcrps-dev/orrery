import SwiftUI

enum QuickOpenSelection {
    static func shifted(_ selection: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(count - 1, selection + delta))
    }
    static func match(at index: Int, in matches: [FuzzyMatch]) -> FuzzyMatch? {
        matches.indices.contains(index) ? matches[index] : nil
    }
}

/// ⌘P. Type part of a path, hit return. Also handles `:42` to jump straight to a line.
struct QuickOpenSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var lineSuffix: Int? {
        guard let colon = query.lastIndex(of: ":") else { return nil }
        return Int(query[query.index(after: colon)...])
    }

    private var searchTerm: String {
        guard let colon = query.lastIndex(of: ":"), lineSuffix != nil else { return query }
        return String(query[query.startIndex..<colon])
    }

    private var matches: [FuzzyMatch] {
        model.index.matches(searchTerm, limit: 40)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Go to file…  (add :42 for a line)", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($focused)
                .onChange(of: query) { _, _ in selection = 0 }
                .onSubmit(openSelected)
            Divider()
            if model.index.isScanning && model.index.files.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Indexing the project…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if matches.isEmpty {
                Text(model.index.files.isEmpty ? "No project open." : "No file matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                    List(Array(matches.enumerated()), id: \.element.id) { position, match in
                        Button { selection = position; openSelected() } label: {
                            row(match, isSelected: position == selection).contentShape(Rectangle())
                        }.buttonStyle(.plain).id(position)
                            .accessibilityLabel("Open \(match.display)")
                    }
                    .listStyle(.plain)
                    .frame(height: 340)
                    .onChange(of: selection) { _, new in proxy.scrollTo(new) }
                }
            }
            Divider()
            HStack {
                Text(model.index.truncated
                     ? "Index capped at \(ProjectIndex.fileLimit) files"
                     : "\(model.index.files.count) files indexed")
                Spacer()
                Text("↑↓ to move · ↩ to open · esc to close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 640)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { selection = QuickOpenSelection.shifted(selection, by: -1, count: matches.count); return .handled }
        .onKeyPress(.downArrow) {
            selection = QuickOpenSelection.shifted(selection, by: 1, count: matches.count); return .handled
        }
        .onKeyPress(.escape) { isPresented = false; return .handled }
    }

    private func row(_ match: FuzzyMatch, isSelected: Bool) -> some View {
        let highlights = Set(match.highlights)
        var name = AttributedString()
        for (offset, character) in match.display.enumerated() {
            var piece = AttributedString(String(character))
            if highlights.contains(offset) {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = .accentColor
            }
            name += piece
        }
        return HStack(spacing: 8) {
            Image(systemName: Languages.forFile(match.url).symbol)
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(name).lineLimit(1).truncationMode(.head)
            Spacer()
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
    }

    private func openSelected() {
        guard let match = QuickOpenSelection.match(at: selection, in: matches) else { return }
        if let line = lineSuffix {
            model.open(file: match.url, atLine: line)
        } else {
            model.open(file: match.url)
        }
        isPresented = false
    }
}

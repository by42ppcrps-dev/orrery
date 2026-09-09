import SwiftUI

struct PermissionSheet: View {
    let request: PermissionRequest
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(request.title, systemImage: "hand.raised")
                .font(.headline)

            if !request.detail.isEmpty {
                ScrollView {
                    Text(request.detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Agents write long option labels — Grok's read "Yes, and don't ask again for bash
            // commands". Laid out in a row they truncate to "Yes, and don't…", which hides exactly
            // the distinction that matters, so each option gets its own full-width row.
            VStack(spacing: 8) {
                ForEach(request.questions) { question in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.title).font(.body)
                        let binding = Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 })
                        if !question.options.isEmpty {
                            Picker("Suggested answer", selection: binding) {
                                Text("Choose an answer…").tag("")
                                ForEach(question.options, id: \.self) { option in Text(option).tag(option) }
                            }
                        }
                        if question.isSecret {
                            SecureField("Your answer", text: binding).textFieldStyle(.roundedBorder)
                        } else {
                            TextField("Your answer", text: binding).textFieldStyle(.roundedBorder)
                        }
                    }
                }
                if !request.questions.isEmpty {
                    Button("Send Answers") { request.answer?(answers) }
                        .buttonStyle(.borderedProminent)
                        .disabled(request.questions.contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
                ForEach(request.options.sorted { rank($0) < rank($1) }, id: \.id) { option in
                    Button {
                        request.reply(option.id)
                    } label: {
                        HStack {
                            Image(systemName: icon(option))
                                .foregroundStyle(option.kind.hasPrefix("allow") ? .green : .red)
                            Text(option.name)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .controlSize(.large)
                    .modifier(PrimaryIf(isPrimary: option.kind == "allow_once"))
                }
                Button("Cancel") { request.reply(nil) }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    /// Narrowest "yes" on top as the default; the blanket grant sits below it, and the refusals
    /// below that.
    private func rank(_ option: PermissionOption) -> Int {
        switch option.kind {
        case "allow_once": return 0
        case "allow_always": return 1
        case "reject_once": return 2
        case "reject_always": return 3
        default: return 1
        }
    }

    private func icon(_ option: PermissionOption) -> String {
        switch option.kind {
        case "allow_once": return "checkmark.circle"
        case "allow_always": return "checkmark.circle.fill"
        case "reject_once": return "xmark.circle"
        default: return "xmark.circle.fill"
        }
    }
}

/// `.buttonStyle` returns different types per branch, so the choice is wrapped in a modifier.
private struct PrimaryIf: ViewModifier {
    let isPrimary: Bool
    func body(content: Content) -> some View {
        if isPrimary {
            content.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

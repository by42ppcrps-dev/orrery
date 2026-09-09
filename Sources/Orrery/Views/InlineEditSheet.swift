import SwiftUI

struct InlineEditSheet: View {
    @Bindable var model: AppModel
    @Bindable var session: InlineEditSession
    @FocusState private var instructionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit selection with \(session.provider.displayName)").font(.title3.weight(.semibold))
                    Text("\(session.document.name) · \(session.lineSummary) · \(session.modelID ?? "the provider's default model")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(session.phase == .applied ? "Done" : "Close") { close() }.keyboardShortcut(.cancelAction)
            }
            switch session.phase {
            case .composing, .failed: compose
            case .running: running
            case .reviewing: review
            case .applied: Text(session.appliedThroughEditor ? "Applied. ⌘Z in the editor undoes it." : "Applied to the open document; save it to keep the change.").foregroundStyle(.green)
            }
            Spacer(minLength: 0)
        }
        .padding(20).frame(width: 720, height: 540)
        .onAppear { instructionFocused = true }
    }

    @ViewBuilder private var compose: some View {
        TextField("What should change in the selection?", text: $session.instruction)
            .textFieldStyle(.roundedBorder).focused($instructionFocused).onSubmit(run)
            .accessibilityLabel("Inline edit instruction")
        if case let .failed(message) = session.phase {
            Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            if !session.reply.isEmpty { box("Reply", session.reply, height: 120) }
        }
        box("Selected text", session.original, height: 200)
        HStack {
            Text("The agent gets the selection plus \(InlineEditSession.contextLines) lines of context, may not use tools, and its answer is shown as a diff before anything changes.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Ask \(session.provider.displayName)") { run() }.buttonStyle(.borderedProminent)
                .disabled(session.instruction.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder private var running: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Asking \(session.provider.displayName)… tool requests are refused; only the reply is used.").font(.callout)
            Spacer()
            Button("Cancel") { session.cancel() }
        }
        box("Instruction", session.instruction, height: 60)
    }

    @ViewBuilder private var review: some View {
        Text("Proposed change").font(.headline)
        ScrollView { DiffBlock(old: session.reviewPair.old, new: session.reviewPair.new) }
            .frame(maxHeight: 300).background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        if let cost = session.costUSD { Text(String(format: "Reported cost $%.4f", cost)).font(.caption).foregroundStyle(.secondary) }
        if !session.selectionStillMatches {
            Text("The selection changed since the agent read it; Apply is off. Ask again.").foregroundStyle(.orange).font(.callout)
        }
        if let note = session.applyNote { Text(note).foregroundStyle(.red).font(.callout) }
        HStack {
            Button("Discard") { close() }
            Button("Ask Again") { session.phase = .composing; instructionFocused = true }
            Spacer()
            Button("Apply to Editor") { session.apply() }.buttonStyle(.borderedProminent)
                .disabled(!session.selectionStillMatches)
        }
    }

    private func box(_ title: String, _ text: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ScrollView {
                Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(height: height).background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    private func run() {
        guard !session.isRunning else { return }
        Task { await model.runInlineEdit() }
    }

    private func close() {
        session.cancel()
        model.inlineEdit = nil
    }
}

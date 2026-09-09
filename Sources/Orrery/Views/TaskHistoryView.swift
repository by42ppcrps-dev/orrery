import SwiftUI

struct TaskHistoryView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var deleting: TaskRecord?

    private var filtered: [TaskRecord] {
        model.taskRecords.filter { record in
            query.isEmpty || record.title.localizedCaseInsensitiveContains(query)
                || record.entries.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tasks").font(.title2.weight(.semibold))
                Spacer()
                Button("New \(model.provider.displayName) task") {
                    Task { await model.createTask(); dismiss() }
                }.disabled(model.isBusy || model.taskPreparing.contains(model.provider))
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("History stays on this Mac. Restored queues remain paused until you resume them.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search tasks and conversations", text: $query).textFieldStyle(.roundedBorder)
            if let notice = model.taskNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
            List(filtered) { record in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: record.provider.symbol).frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.title).fontWeight(.medium).lineLimit(2)
                        Text("\(record.provider.displayName) · \(record.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        if record.status == .interrupted { Text("Interrupted — transcript and draft recovered").font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    if model.activeTaskIDs[record.provider] == record.id {
                        Text("Active").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Open") { Task { await model.selectTask(record.id) } }
                        .disabled(model.states[record.provider]?.isBusy == true || model.taskPreparing.contains(record.provider))
                    Button { deleting = record } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).accessibilityLabel("Delete task \(record.title)")
                        .disabled(model.activeTaskIDs[record.provider] == record.id)
                }.padding(.vertical, 7)
            }
        }
        .padding(22).frame(minWidth: 580, idealWidth: 680, minHeight: 430, idealHeight: 560)
        .onAppear { model.saveTaskHistoryNow() }
        .alert("Delete this task and its working copy?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let id = deleting?.id { Task { await model.deleteTask(id) } }
                deleting = nil
            }
        } message: { Text("Your source project is kept. Unapplied changes in this task’s copy will be removed.") }
    }
}

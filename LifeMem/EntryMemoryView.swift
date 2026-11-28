import SwiftData
import SwiftUI

struct EntryMemoryView: View {
    let key: RouteMemoryKey
    let title: String
    let time: String
    let selected: Bool
    @Query private var memories: [RouteMemory]
    @State private var editing = false

    init(key: RouteMemoryKey, title: String, time: String, selected: Bool) {
        self.key = key
        self.title = title
        self.time = time
        self.selected = selected
        let value = key.value
        _memories = Query(filter: #Predicate<RouteMemory> { $0.key == value })
    }

    var body: some View {
        let note = memories.first?.text ?? ""
        if selected || !note.isEmpty || memories.first?.draft != nil {
            Button { editing = true } label: {
                Label(note.isEmpty ? (memories.first?.draft == nil ? "留一句话" : "继续编辑草稿") : note,
                      systemImage: note.isEmpty ? "square.and.pencil" : "quote.opening")
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("entry-note")
            .sheet(isPresented: $editing) {
                EntryNoteEditor(key: key, title: title, time: time, memory: memories.first)
            }
        }
    }
}

private struct EntryNoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let key: RouteMemoryKey
    let title: String
    let time: String
    @State private var text: String
    private enum Write { case draft, close, publish }
    @State private var saveError = false
    @State private var failedWrite: Write = .draft
    @State private var storedDraft: String

    init(key: RouteMemoryKey, title: String, time: String, memory: RouteMemory?) {
        self.key = key
        self.title = title
        self.time = time
        let initial = memory?.draft ?? memory?.text ?? ""
        _text = State(initialValue: initial)
        _storedDraft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                Text(time).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .accessibilityLabel("这次记录的一句话")
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.background, in: .rect(cornerRadius: 12))
                    .onChange(of: text) { _, value in persist(value, operation: .draft) }
            }
            .padding()
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("留一句话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") {
                    if text == storedDraft { dismiss() } else { persist(text, operation: .close) }
                } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { persist(text, operation: .publish) }
                }
            }
            .interactiveDismissDisabled(text != storedDraft)
            .alert("未能保存文字", isPresented: $saveError) {
                Button("重试") { persist(text, operation: failedWrite) }
                Button("继续编辑", role: .cancel) {}
            } message: { Text("请检查可用空间，文字仍在编辑框中。") }
        }
    }

    private func persist(_ value: String, operation: Write) {
        do {
            let memory = try key.memory(in: context)
            if operation != .publish {
                memory.draft = value == memory.text ? nil : value
            } else {
                memory.text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                memory.draft = nil
            }
            try context.save()
            storedDraft = value
            if operation != .draft { dismiss() }
        } catch {
            context.rollback()
            failedWrite = operation
            saveError = true
        }
    }
}

import AVFAudio
import SwiftData
import SwiftUI

private struct EntryNoteTarget: Identifiable {
    let key: RouteMemoryKey
    let title: String
    let time: String
    let initial: String
    var id: String { key.value }
}

private struct EditEntryNoteKey: EnvironmentKey {
    static let defaultValue: (EntryNoteTarget) -> Void = { _ in }
}

private extension EnvironmentValues {
    var editEntryNote: (EntryNoteTarget) -> Void {
        get { self[EditEntryNoteKey.self] }
        set { self[EditEntryNoteKey.self] = newValue }
    }
}

struct EntryNotePresentation: ViewModifier {
    @State private var target: EntryNoteTarget?

    func body(content: Content) -> some View {
        content
            .environment(\.editEntryNote, { target = $0 })
            .sheet(item: $target) { item in
                EntryNoteEditor(key: item.key, title: item.title, time: item.time, initial: item.initial)
            }
    }
}

struct EntryMemoryView: View {
    let key: RouteMemoryKey
    let entry: RouteReviewEntry
    let title: String
    let time: String
    let selected: Bool
    @Query private var memories: [RouteMemory]
    @Environment(\.editEntryNote) private var editNote

    init(entry: RouteReviewEntry, key: RouteMemoryKey, title: String, time: String, selected: Bool) {
        self.entry = entry
        self.key = key
        self.title = title
        self.time = time
        self.selected = selected
        let value = key.value
        _memories = Query(filter: #Predicate<RouteMemory> { $0.key == value })
    }

    var body: some View {
        let note = memories.first?.text ?? ""
        EntryPhotosView(entry: entry, key: key, selected: selected)
        if selected || !note.isEmpty || memories.first?.draft != nil {
            Button {
                editNote(EntryNoteTarget(key: key, title: title, time: time, initial: memories.first?.draft ?? note))
            } label: {
                Label(note.isEmpty ? (memories.first?.draft == nil ? "留一句话" : "继续编辑草稿") : note,
                      systemImage: note.isEmpty ? "square.and.pencil" : "quote.opening")
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("entry-note")
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var dictation = NoteDictation()
    @State private var voiceStart: Task<Void, Never>?
    @FocusState private var typing: Bool
    @State private var failedWrite: Write = .draft
    @State private var storedDraft: String

    init(key: RouteMemoryKey, title: String, time: String, initial: String) {
        self.key = key
        self.title = title
        self.time = time
        _text = State(initialValue: initial)
        _storedDraft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                Text(time).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .focused($typing)
                    .allowsHitTesting(dictation.phase != .listening && dictation.phase != .finishing)
                    .accessibilityLabel("这次记录的一句话")
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.background, in: .rect(cornerRadius: 12))
                    .onChange(of: text) { _, value in persist(value, operation: .draft) }
                if let message = dictation.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("note-dictation-message")
                }
                Button {
                    if dictation.phase == .idle {
                        voiceStart = Task {
                            var prefix: String?
                            await dictation.start { words in
                                let original = prefix ?? text
                                prefix = original
                                text = NoteTranscript.join(original, words)
                            }
                        }
                    } else { dictation.stop() }
                } label: {
                    Label(voiceButtonTitle, systemImage: dictation.phase == .idle ? "mic" : "stop.circle")
                        .frame(minHeight: 44)
                }
                .disabled(dictation.phase == .finishing)
                .accessibilityIdentifier("note-dictation")
            }
            .padding()
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("留一句话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") {
                    endInput()
                    if text == storedDraft { dismiss() } else { persist(text, operation: .close) }
                } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { persist(text, operation: .publish) }
                        .disabled(dictation.phase != .idle)
                }
            }
            .interactiveDismissDisabled(text != storedDraft)
            .alert("未能保存文字", isPresented: $saveError) {
                Button("重试") { persist(text, operation: failedWrite) }
                Button("继续编辑", role: .cancel) {}
            } message: { Text("请检查可用空间，文字仍在编辑框中。") }
        }
        .onChange(of: dictation.phase) { _, phase in
            if phase == .listening { typing = false }
        }
        .onDisappear { endInput() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || (phase == .inactive && dictation.phase == .listening) {
                endInput()
                if text != storedDraft { persist(text, operation: .draft) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue: raw) == .began { endInput() }
        }
    }

    private func endInput() {
        voiceStart?.cancel()
        voiceStart = nil
        dictation.interrupt()
    }

    private var voiceButtonTitle: String {
        switch dictation.phase {
        case .idle: "语音输入"
        case .authorizing: "取消启动语音"
        case .listening: "停止转写"
        case .finishing: "正在整理文字…"
        }
    }

    private func persist(_ value: String, operation: Write) {
        do {
            try key.update(in: context.container) { memory, _ in
                if operation != .publish {
                    memory.draft = value == memory.text ? nil : value
                } else {
                    memory.text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    memory.draft = nil
                }
            }
            storedDraft = value
            if operation != .draft { dismiss() }
        } catch {
            failedWrite = operation
            saveError = true
        }
    }
}

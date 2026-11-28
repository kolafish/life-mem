import AVFAudio
import Speech
import SwiftData
import SwiftUI

@MainActor @Observable
final class MemoPlayback: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private(set) var playing: String?
    var error: String?

    func toggle(_ data: Data?, id: String) {
        let wasPlaying = playing == id
        stop()
        guard !wasPlaying else { return }
        do {
            guard let data else { throw CocoaError(.fileReadCorruptFile) }
            let player = try AVAudioPlayer(data: data)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            self.player = player
            player.delegate = self
            guard player.play() else { throw CocoaError(.fileReadUnknown) }
            playing = id
        } catch {
            stop()
            self.error = "原声暂时无法播放，请检查声音输出后重试。"
        }
    }

    func stop() {
        guard let player else { return }
        player.stop()
        self.player = nil
        playing = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.stop()
            if !flag { self.error = "播放中断，可以重新播放。" }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}

struct MemoPlaybackLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let playback: MemoPlayback

    func body(content: Content) -> some View {
        content
            .onDisappear { playback.stop() }
            .onChange(of: scenePhase) { if scenePhase != .active { playback.stop() } }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in playback.stop() }
            .alert("语音播放", isPresented: Binding(get: { playback.error != nil }, set: { if !$0 { playback.error = nil } })) {
                Button("好") {}
            } message: { Text(playback.error ?? "") }
    }
}

struct MemoPlayButton: View {
    let playback: MemoPlayback
    let id: String
    let duration: Double
    let audio: () -> Data?

    var body: some View {
        Button {
            playback.toggle(audio(), id: id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: playback.playing == id ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                Text(playback.playing == id ? "停止播放" : "播放原声")
                Text("\(max(1, Int(duration.rounded()))) 秒")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium)).frame(minHeight: 44)
        }
        .accessibilityIdentifier("memo-play")
    }
}

@MainActor @Observable
private final class PhotoVoiceDraft: NSObject, AVAudioRecorderDelegate {
    var audio: Data?
    var duration: Double?
    var transcript: String
    var message: String?
    private(set) var recording = false
    private(set) var requestingMic = false
    private(set) var transcribing = false
    private var generation = UUID()
    private var recorder: AVAudioRecorder?
    private var recognition: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var timeout: Task<Void, Never>?
    private var url: URL?

    // Clear abandoned drafts from a previous process before creating a new recording.
    private static let directory: URL = {
        let root = URL.temporaryDirectory.appending(path: "LifeMemVoiceDrafts", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        return root
    }()

    init(photo: MemoryPhoto?) {
        audio = photo?.voiceAudio
        duration = photo?.voiceDuration
        transcript = photo?.voiceTranscript ?? ""
    }

    private func temporaryFile() throws -> URL {
        if let url { return url }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        let file = Self.directory.appending(path: UUID().uuidString + ".m4a")
        url = file
        return file
    }

    func start() async {
        guard !Task.isCancelled, !requestingMic, !recording else { return }
        cancelRecognition()
        let token = generation
        message = nil
        requestingMic = true
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard !Task.isCancelled, token == generation else { return }
        requestingMic = false
        guard allowed else { message = "请在系统设置中允许 Life Mem 使用麦克风，然后重试。"; return }
        do {
            let file = try temporaryFile()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
            ])
            self.recorder = recorder
            recorder.delegate = self
            guard recorder.record(forDuration: 60) else { throw CocoaError(.fileWriteUnknown) }
            recording = true
        } catch {
            self.recorder = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            message = "录音未能开始，请检查麦克风和可用空间后重试。"
        }
    }

    func finish(transcribe: Bool) {
        guard let recorder else { return }
        self.recorder = nil
        recorder.stop()
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        do {
            let file = recorder.url
            let data = try Data(contentsOf: file)
            let seconds = try AVAudioPlayer(data: data).duration
            guard seconds > 0 else { throw CocoaError(.fileReadCorruptFile) }
            audio = data
            duration = seconds
            transcript = ""
            if transcribe { beginTranscription() }
        } catch { message = "未能读取这次录音，可以重新录制。" }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            self.finish(transcribe: flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        audioRecorderDidFinishRecording(recorder, successfully: false)
    }

    func beginTranscription() {
        guard let audio else { return }
        cancelRecognition()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            message = "普通话离线识别当前不可用。可以保存原声，也可以补写文字。"
            return
        }
        let token = generation
        transcribing = true
        message = nil
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard self.generation == token else { return }
                guard status == .authorized else {
                    self.transcribing = false
                    self.message = "语音识别未获授权，可以保存原声或补写文字。"
                    return
                }
                do {
                    let file = try self.temporaryFile()
                    try audio.write(to: file, options: [.atomic, .completeFileProtection])
                    let request = SFSpeechURLRecognitionRequest(url: file)
                    request.requiresOnDeviceRecognition = true
                    request.shouldReportPartialResults = false
                    request.addsPunctuation = true
                    self.recognizer = recognizer
                    self.recognition = recognizer.recognitionTask(with: request) { result, error in
                        let words = result?.bestTranscription.formattedString
                        let final = result?.isFinal == true
                        Task { @MainActor in
                            guard self.generation == token, final || error != nil else { return }
                            self.cancelRecognition()
                            if let words, !words.isEmpty { self.transcript = words }
                            else { self.message = "没有收到转写文字，可以重试、补写或只保存原声。" }
                        }
                    }
                    self.timeout = Task {
                        try? await Task.sleep(for: .seconds(75))
                        guard !Task.isCancelled, self.generation == token else { return }
                        self.cancelRecognition()
                        self.message = "转写超时，可以重试或直接保存原声。"
                    }
                } catch {
                    self.cancelRecognition()
                    self.message = "无法读取录音进行转写，可以补写文字。"
                }
            }
        }
    }

    func cancelRecognition() {
        generation = UUID()
        timeout?.cancel()
        timeout = nil
        recognition?.cancel()
        recognition = nil
        recognizer = nil
        transcribing = false
    }

    func interrupt() {
        cancelRecognition()
        requestingMic = false
        finish(transcribe: false)
    }

    func close() {
        interrupt()
        if let url { try? FileManager.default.removeItem(at: url); self.url = nil }
    }
}

struct PhotoVoiceEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: PhotoVoiceDraft
    @State private var playback = MemoPlayback()
    @State private var failure = false
    @State private var confirmRemove = false
    @State private var micStart: Task<Void, Never>?
    let photo: GalleryPhoto
    let key: RouteMemoryKey

    init(photo: GalleryPhoto, key: RouteMemoryKey) {
        self.photo = photo
        self.key = key
        _draft = State(initialValue: PhotoVoiceDraft(photo: photo.saved))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    photo.image(full: true).frame(height: 180)
                    if let duration = draft.duration, !draft.recording {
                        MemoPlayButton(playback: playback, id: photo.id, duration: duration) { draft.audio }
                    }
                    Button {
                        playback.stop()
                        if draft.recording { draft.finish(transcribe: true) }
                        else { micStart = Task { await draft.start() } }
                    } label: {
                        Label(draft.recording ? "结束录音" : (draft.audio == nil ? "开始录音" : "重新录音"),
                              systemImage: draft.recording ? "stop.fill" : "mic.fill")
                            .frame(minHeight: 44)
                    }
                    .disabled(draft.requestingMic)
                    if draft.recording || draft.audio == nil {
                        Text(draft.recording ? "正在录音，最长一分钟。" : "最多录一分钟，结束后在本机转写普通话。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        if draft.transcribing {
                            HStack { ProgressView(); Text("正在转写普通话…"); Spacer(); Button("停止转写") { draft.cancelRecognition() } }
                        } else {
                            TextField("转写或补写文字", text: $draft.transcript, axis: .vertical)
                                .lineLimit(2...12).textFieldStyle(.roundedBorder)
                            if draft.transcript.isEmpty {
                                Button("转写普通话") { draft.beginTranscription() }.frame(minHeight: 44)
                            }
                        }
                    }
                    if let message = draft.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    if photo.saved?.voiceDuration != nil, !draft.recording {
                        Button("移除留言", role: .destructive) { confirmRemove = true }.frame(minHeight: 44)
                    }
                }.padding(20)
            }
            .navigationTitle("照片语音留言").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(remove: false) }.disabled(draft.audio == nil || draft.recording || draft.requestingMic || draft.transcribing)
                }
            }
            .confirmationDialog("移除这张照片的原声和转写？", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("移除留言", role: .destructive) { save(remove: true) }
            }
            .alert("留言未能保存", isPresented: $failure) { Button("好") {} } message: {
                Text("请确认照片仍在这段记录中，并检查可用空间后重试。")
            }
        }
        .modifier(MemoPlaybackLifecycle(playback: playback))
        .onChange(of: scenePhase) {
            if scenePhase == .background || (scenePhase == .inactive && draft.recording) { micStart?.cancel(); draft.interrupt() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            if let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue: raw) == .began { draft.interrupt() }
        }
        .onDisappear { micStart?.cancel(); draft.close() }
    }

    private func save(remove: Bool) {
        do {
            try key.update(in: context.container) { memory, writer in
                let attachment: MemoryPhoto
                if let id = photo.saved?.id {
                    guard let saved = try writer.fetch(FetchDescriptor<MemoryPhoto>(predicate: #Predicate { $0.id == id })).first,
                          !saved.hidden, saved.memory?.key == key.value else { throw VisitCorrection.Failure.sourceUnavailable }
                    attachment = saved
                } else if let asset = photo.asset {
                    attachment = try memory.attachment(for: asset.localIdentifier, in: writer)
                    guard !attachment.hidden else { throw VisitCorrection.Failure.sourceUnavailable }
                } else { throw VisitCorrection.Failure.sourceUnavailable }
                let text = draft.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if attachment.taken == nil { attachment.taken = photo.taken }
                attachment.setVoice(audio: remove ? nil : draft.audio, duration: remove ? nil : draft.duration,
                                    transcript: remove || text.isEmpty ? nil : text)
            }
            dismiss()
        } catch { failure = true }
    }
}

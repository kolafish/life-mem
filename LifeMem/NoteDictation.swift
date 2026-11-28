import AVFAudio
import Observation
import Speech

@Observable @MainActor
final class NoteDictation {
    enum Phase { case idle, authorizing, listening, finishing }
    private(set) var phase = Phase.idle
    private(set) var message: String?
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var generation = UUID()
    private var receivedText = false
    private var tapInstalled = false
    private var sessionActive = false
    private var timeout: Task<Void, Never>?

    func start(append: @escaping (String) -> Void) async {
        guard !Task.isCancelled, phase == .idle else { return }
        let id = UUID()
        receivedText = false
        generation = id
        message = nil
        phase = .authorizing
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            end(message: "这台设备当前无法离线转写中文，可以先打字。")
            return
        }
        let allowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard !Task.isCancelled, generation == id else { return }
        guard allowed else {
            end(message: "语音识别未获授权。可以打字，或在系统设置中允许语音识别。")
            return
        }
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        guard !Task.isCancelled, generation == id else { return }
        guard micAllowed else {
            end(message: "麦克风未获授权。可以打字，或在系统设置中允许使用麦克风。")
            return
        }
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true)
            sessionActive = true
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                end(message: "麦克风当前不可用，可以继续打字。")
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true
            self.recognizer = recognizer
            self.request = request
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            phase = .listening
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let words = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id else { return }
                    if let words, !words.isEmpty { self.receivedText = true; append(words) }
                    if error != nil || finished {
                        self.end(message: self.receivedText ? nil : "没有识别到文字，可以重说或打字。")
                    }
                }
            }
        } catch {
            end(message: "无法使用麦克风或启动端侧识别，可以重试或打字。")
        }
    }

    func stop() {
        guard phase == .listening else { interrupt(); return }
        phase = .finishing
        stopCapture()
        let id = generation
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.generation == id else { return }
            self.end(message: self.receivedText ? nil : "没有识别到文字，可以重说或打字。")
        }
    }

    func interrupt() {
        guard phase != .idle else { return }
        end(message: "语音输入已结束，已识别的文字保留在草稿中。")
    }

    private func stopCapture() {
        if let engine, engine.isRunning { engine.stop() }
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            request?.endAudio()
        }
        engine = nil
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }

    private func end(message: String?) {
        generation = UUID()
        timeout?.cancel()
        timeout = nil
        stopCapture()
        recognition?.cancel()
        recognition = nil
        request = nil
        recognizer = nil
        phase = .idle
        self.message = message
    }
}

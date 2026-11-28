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
    private var transcript = NoteTranscript()
    private var latestWords = ""
    private var engineChange: NSObjectProtocol?
    private var tapInstalled = false
    private var sessionActive = false
    private var timeout: Task<Void, Never>?

    func start(append: @escaping (String) -> Void) async {
        guard !Task.isCancelled, phase == .idle else { return }
        let id = UUID()
        transcript = NoteTranscript()
        latestWords = ""
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
            observeConfiguration(of: engine, generation: id)
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let words = result?.bestTranscription.formattedString
                let segments = result?.bestTranscription.segments ?? []
                let metadata = result?.speechRecognitionMetadata
                let start = metadata?.speechStartTimestamp ?? segments.first?.timestamp ?? 0
                let stop = metadata.map { $0.speechStartTimestamp + $0.speechDuration }
                    ?? segments.last.map { $0.timestamp + $0.duration } ?? start
                let range = stop > start ? start..<stop : nil
                let finished = result?.isFinal == true
                let settled = finished || metadata != nil || (segments.first?.confidence ?? 0) > 0
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id else { return }
                    self.receive(words, range: range, settled: settled, finished: finished, error: error, append: append)
                }
            }
        } catch {
            end(message: "无法使用麦克风或启动端侧识别，可以重试或打字。")
        }
    }

    private func observeConfiguration(of engine: AVAudioEngine, generation id: UUID) {
        engineChange = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                              object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id, self.phase == .listening else { return }
                self.end(message: "录音设备已变更，现有文字已保留。可重新开始听写。")
            }
        }
    }

    private func receive(_ words: String?, range: Range<TimeInterval>?, settled: Bool, finished: Bool,
                         error: Error?, append: (String) -> Void) {
        if let words, !words.isEmpty {
            let updated = transcript.update(words, range: range, settled: settled)
            if updated != latestWords {
                latestWords = updated
                append(updated)
                if phase == .finishing { waitForFinalResult() }
            }
        }
        if let error {
            end(message: failureMessage(error as NSError))
        } else if finished {
            end(message: latestWords.isEmpty ? "没有识别到文字，可以重说或打字。" : nil)
        }
    }

    func stop() {
        guard phase == .listening else { interrupt(); return }
        phase = .finishing
        stopCapture()
        recognition?.finish()
        waitForFinalResult()
    }

    private func waitForFinalResult() {
        timeout?.cancel()
        let id = generation
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.generation == id else { return }
            self.end(message: self.latestWords.isEmpty ? "未收到转写结果，可以重说或打字。" : "尾句未完成转写，已保留收到的文字。可补写或继续听写。")
        }
    }

    private func failureMessage(_ error: NSError) -> String {
        switch (error.domain, error.code) {
        case ("kLSRErrorDomain", 102): return "设备缺少普通话离线语音资源，可以在系统听写设置中检查语言，或继续打字。"
        case ("kLSRErrorDomain", 201): return "系统听写已关闭。可在「设置 → 通用 → 键盘」启用听写，或继续打字。"
        case ("kAFAssistantErrorDomain", 1700): return "语音识别未获授权。可在系统设置中允许，或继续打字。"
        case ("kAFAssistantErrorDomain", 1110) where latestWords.isEmpty: return "没有识别到文字，可以重说或打字。"
        default: return latestWords.isEmpty ? "语音识别中断，可以重试或打字。" : "语音识别中断，已保留收到的文字。可继续听写或打字。"
        }
    }

    func interrupt() {
        guard phase != .idle else { return }
        end(message: "语音输入已结束，已识别的文字保留在草稿中。")
    }

    private func stopCapture() {
        if let engineChange {
            NotificationCenter.default.removeObserver(engineChange)
            self.engineChange = nil
        }
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

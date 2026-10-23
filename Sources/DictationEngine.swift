import Foundation
import AVFoundation
import Speech

/// Uses the OS's on-device speech model. Never falls back to cloud recognition.
final class DictationEngine {
    var onPartial: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    private var retryCount = 0
    var onStopped: (() -> Void)?
    var onFinished: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Normalized microphone loudness, 0...1, delivered on the main queue.
    var onLevel: ((Float) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var transcript = TranscriptSegments()
    private var segmentNumber = 0
    private var vocabulary: [String] = []
    private let audioFeed = RecognitionAudioFeed()
    private var active = false
    private var stopping = false
    private var sessionNumber = 0
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    /// A ModernTranscriber when the macOS 26 engine runs this session (typed loosely for older systems).
    private var modern: AnyObject?

    static var usesModernEngine: Bool {
        if #available(macOS 26.0, *) { return ModernTranscriber.analyzerFormat != nil }
        return false
    }

    /// Readies the macOS 26 speech model in the background; until then the classic recognizer is used.
    static func prepareModernEngine(localeIdentifier: String = "en-US") {
        guard #available(macOS 26.0, *) else { return }
        Task.detached(priority: .utility) { await ModernTranscriber.prepare(localeIdentifier: localeIdentifier) }
    }

    var isRecording: Bool { active }

    /// Returns an actionable failure, or nil after both authorizations succeed.
    static func requestPermissions(_ completion: @escaping (String?) -> Void) {
        func microphone() {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            Diagnostics.event("Microphone authorization status=\(status.rawValue)")
            func finish(_ allowed: Bool) {
                DispatchQueue.main.async {
                    completion(allowed ? nil : "Microphone access is denied or restricted. Enable Velo in System Settings → Privacy & Security → Microphone. If managed by your organization, contact your administrator. Then start dictation again.")
                }
            }
            if status == .notDetermined { AVCaptureDevice.requestAccess(for: .audio, completionHandler: finish) }
            else { finish(status == .authorized) }
        }
        func speech(_ status: SFSpeechRecognizerAuthorizationStatus) {
            Diagnostics.event("Speech authorization status=\(status.rawValue)")
            guard status == .authorized else {
                DispatchQueue.main.async {
                    completion("Speech Recognition access is denied or restricted. Enable Velo in System Settings → Privacy & Security → Speech Recognition. If managed by your organization, contact your administrator. Then start dictation again. Audio will only be recognized on this Mac.")
                }
                return
            }
            microphone()
        }
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined { SFSpeechRecognizer.requestAuthorization(speech) }
        else { speech(status) }
    }

    static func diagnosticSummary() -> String {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        let supported = recognizer?.supportsOnDeviceRecognition == true
        Diagnostics.event("Status: speech=\(speech.rawValue), microphone=\(microphone.rawValue), onDevice=\(supported)")
        let microphoneLabel: String
        switch microphone {
        case .authorized: microphoneLabel = "authorized"
        case .denied: microphoneLabel = "denied — enable in Privacy & Security → Microphone"
        case .restricted: microphoneLabel = "restricted — contact your administrator"
        case .notDetermined: microphoneLabel = "not requested — start dictation"
        @unknown default: microphoneLabel = "unknown"
        }
        let speechLabel: String
        switch speech {
        case .authorized: speechLabel = "authorized"
        case .denied: speechLabel = "denied — enable in Privacy & Security → Speech Recognition"
        case .restricted: speechLabel = "restricted — contact your administrator"
        case .notDetermined: speechLabel = "not requested — start dictation"
        @unknown default: speechLabel = "unknown"
        }
        return "Microphone: \(microphoneLabel)\nSpeech Recognition: \(speechLabel)\nEnglish (US) on-device support: \(supported ? "available" : "unavailable — install speech language assets in macOS Settings")\nEngine: \(usesModernEngine ? "SpeechAnalyzer (macOS 26 long-form model)" : "classic SFSpeechRecognizer")\nCloud recognition: disabled"
    }

    static func makeRequest(vocabulary: [String]) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = Array(vocabulary.prefix(100))

        return request
    }

    func start(vocabulary: [String], localeIdentifier: String = "en-US") {
        guard !active && !stopping else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            onFailure?("Microphone or Speech Recognition permission changed. Check System Settings → Privacy & Security, then try again.")
            return
        }
        if #available(macOS 26.0, *), let session = ModernTranscriber(vocabulary: vocabulary) {
            startModern(session)
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.supportsOnDeviceRecognition else {
            onFailure?("On-device recognition is unavailable for \(localeIdentifier). Try en-US, or install the required speech language in macOS Settings. Cloud fallback is disabled.")
            return
        }
        Diagnostics.event("On-device recognition supported for \(localeIdentifier); available=\(recognizer.isAvailable)")
        guard recognizer.isAvailable else {
            onFailure?("Speech recognition is currently unavailable. Check the speech language assets in macOS Settings.")
            return
        }

        let engine = AVAudioEngine()
        self.vocabulary = vocabulary

        sessionNumber += 1
        transcript = TranscriptSegments()
        retryCount = 0
        self.recognizer = recognizer
        audioEngine = engine
        active = true
        stopping = false
        beginSegment()

        startCapture(engine)
    }

    @available(macOS 26.0, *)
    private func startModern(_ session: ModernTranscriber) {
        sessionNumber += 1
        let thisSession = sessionNumber
        session.onText = { [weak self] text in
            guard let self, self.active, self.sessionNumber == thisSession else { return }
            self.onPartial?(text)
        }
        modern = session
        audioFeed.route(to: session.append)
        audioEngine = AVAudioEngine()
        active = true
        stopping = false
        Diagnostics.event("Using SpeechAnalyzer engine")
        startCapture(audioEngine!)
    }

    private func startCapture(_ engine: AVAudioEngine) {
        guard installTap(on: engine) else {
            failSession("No usable microphone input was detected.")
            return
        }
        do {
            engine.prepare()
            try engine.start()
            Diagnostics.event("Recording started; on-device recognition required")
        } catch {
            failSession("Couldn't start microphone (code \((error as NSError).code)). Check System Settings → Sound → Input and Microphone permission, then try again.")
            return
        }
        // Plugging in headphones or switching microphones stops the engine without notice.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restartCapture() }
    }

    private func installTap(on engine: AVAudioEngine) -> Bool {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [audioFeed, weak self] buffer, _ in
            audioFeed.append(buffer)
            let level = Self.level(of: buffer)
            DispatchQueue.main.async { self?.onLevel?(level) }
        }
        tapInstalled = true
        return true
    }

    private func restartCapture() {
        guard active, let engine = audioEngine else { return }
        Diagnostics.event("Audio configuration changed; restarting microphone")
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        // The recognizer keeps its words; a request only rejects a changed audio format, so start a fresh one.
        // SpeechAnalyzer converts each buffer itself, so it just keeps listening.
        if modern == nil {
            transcript.commit()
            beginSegment()
        }
        guard installTap(on: engine) else { return }
        do { engine.prepare(); try engine.start() }
        catch { Diagnostics.event("Microphone restart failed code=\((error as NSError).code)") }
    }

    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(1, max(0, (decibels + 50) / 40))
    }

    private func beginSegment() {
        guard active, let recognizer else { return }
        segmentNumber += 1
        let segment = segmentNumber
        let session = sessionNumber
        let request = Self.makeRequest(vocabulary: vocabulary)
        let oldRequest = recognitionRequest
        let oldTask = recognitionTask
        recognitionRequest = request
        audioFeed.replace(with: request)
        oldRequest?.endAudio()
        oldTask?.cancel()
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.sessionNumber == session, self.segmentNumber == segment,
                      self.active || self.stopping else { return }
                if let result {
                    self.retryCount = 0
                    self.transcript.update(result.bestTranscription.formattedString)
                    if self.active { self.onPartial?(self.transcript.text) }
                }
                let nsError = error as NSError?
                guard result?.isFinal == true || nsError != nil else { return }
                // An utterance ending is not the user ending their recording.
                if self.stopping { self.completeSession(); return }
                if result?.isFinal == true || Self.isSilenceError(nsError) {
                    self.transcript.commit()
                    Diagnostics.event("Speech segment ended; continuing user recording")
                    self.beginSegment()
                } else if let nsError {
                    Diagnostics.event("Recognition failed code=\(nsError.code)")
                    self.transcript.commit()
                    self.retryCount += 1
                    self.segmentNumber += 1 // Discard callbacks from the failed task.
                    let recovery = self.segmentNumber
                    self.audioFeed.hold() // Keep speech spoken while reconnecting.
                    self.recognitionRequest?.endAudio()
                    self.recognitionTask?.cancel()
                    self.onStatus?("Reconnecting speech recognition…")
                    let delay = min(5.0, Double(self.retryCount) * 0.5)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, self.active, self.sessionNumber == session,
                              self.segmentNumber == recovery else { return }
                        self.beginSegment()
                    }
                }
            }
        }
    }

    static func isSilenceError(_ error: NSError?) -> Bool {
        error?.domain == "kAFAssistantErrorDomain" && error?.code == 1110
    }

    func stop() {
        guard active && !stopping else { return }
        Diagnostics.event("Recording stopped; waiting for final result")
        active = false
        stopping = true
        onStopped?()
        stopCapture()
        let thisSession = sessionNumber
        if #available(macOS 26.0, *), let session = modern as? ModernTranscriber {
            session.finish { [weak self] text in
                guard let self, self.sessionNumber == thisSession, self.stopping else { return }
                Diagnostics.event("Recognition finished; hasText=\(!text.isEmpty)")
                self.reset()
                self.onFinished?(text)
            }
            return
        }
        recognitionRequest?.endAudio()
        // Usually the final result arrives sooner; this only bounds a recognizer that never answers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.sessionNumber == thisSession, self.stopping else { return }
            self.completeSession()
        }
    }

    /// Discards a recording that was really the start of a keyboard shortcut.
    func cancel() {
        guard active || stopping else { return }
        Diagnostics.event("Recording cancelled for keyboard shortcut")
        reset()
    }

    private func stopCapture() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        audioFeed.replace(with: nil)
        if let engine = audioEngine {
            if engine.isRunning { engine.stop() }
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        tapInstalled = false
        audioEngine = nil
    }

    private func completeSession() {
        guard stopping else { return }
        let output = transcript.text
        Diagnostics.event("Recognition finished; hasText=\(!output.isEmpty)")
        reset()
        onFinished?(output)
    }

    private func failSession(_ message: String) {
        Diagnostics.event("Recognition failed; resources released")
        reset()
        onFailure?(message)
    }

    private func reset() {
        stopCapture()
        if #available(macOS 26.0, *), let session = modern as? ModernTranscriber, active || stopping {
            session.cancel() // Only reached when abandoning a session; finished ones have already delivered.
        }
        modern = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        recognizer = nil
        transcript = TranscriptSegments()
        vocabulary = []
        active = false
        stopping = false
        sessionNumber += 1
    }
}

/// Partial results replace one another; completed utterances survive recognition restarts.
/// After a pause the recognizer may start a fresh utterance inside the same task, so its
/// partials suddenly drop the earlier words. Those words are kept, and if the recognizer
/// later reports the whole text again, the kept copy is dropped instead of duplicated.
struct TranscriptSegments {
    private var completed: [String] = []
    private var carried = 0 // Utterances kept from the current task after it restarted.
    private(set) var partial = ""
    var text: String {
        (completed + [partial]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
    mutating func update(_ next: String) {
        if Self.isRestart(from: partial, to: next) {
            completed.append(partial.trimmingCharacters(in: .whitespacesAndNewlines))
            carried += 1
        } else if carried > 0 {
            let kept = Self.words(completed.suffix(carried).joined(separator: " "))
            if Self.words(next).starts(with: kept) {
                completed.removeLast(carried)
                carried = 0
            }
        }
        partial = next
    }
    mutating func commit() {
        let value = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { completed.append(value) }
        partial = ""
        carried = 0
    }
    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    /// A revision rewrites the tail; a restart shrinks the text and no longer begins like it.
    static func isRestart(from previous: String, to next: String) -> Bool {
        let old = words(previous), new = words(next)
        guard !old.isEmpty, !new.isEmpty, new.count < old.count else { return false }
        return !old.starts(with: new.prefix(2))
    }
}

/// Audio callbacks and recognition callbacks run on different queues.
/// While held, audio is queued instead of dropped and handed to the next request.
private final class RecognitionAudioFeed {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var holding = false
    private var queued: [AVAudioPCMBuffer] = []
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    /// Sends audio to a SpeechAnalyzer session instead of a classic request.
    func route(to next: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        sink = next
    }
    func replace(with next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }
        sink = nil
        request = next
        if let next, holding { queued.forEach(next.append) }
        holding = false
        queued.removeAll()
    }
    func hold() {
        lock.lock(); defer { lock.unlock() }
        request = nil
        holding = true
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if let sink { sink(buffer); return }
        if let request { request.append(buffer); return }
        guard holding, queued.count < 3000, let copy = Self.copy(buffer) else { return }
        queued.append(copy)
    }
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let target = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel], count: Int(buffer.frameLength))
        }
        return copy
    }
}

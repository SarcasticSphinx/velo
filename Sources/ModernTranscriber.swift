import Foundation
import AVFoundation
import Speech

/// macOS 26 SpeechAnalyzer session using Apple's long-form SpeechTranscriber model.
/// Far more accurate than SFSpeechRecognizer on natural, paused speech; still fully on-device.
@available(macOS 26.0, *)
final class ModernTranscriber: @unchecked Sendable {
    /// Set once the model is installed; until then the classic recognizer is used.
    private(set) static var analyzerFormat: AVAudioFormat?
    private(set) static var locale: Locale?

    /// Downloads the speech model if needed and caches its audio format, so sessions start instantly.
    static func prepare(localeIdentifier: String) async {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            Diagnostics.event("SpeechTranscriber unavailable for \(localeIdentifier); using classic recognizer")
            return
        }
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            if await AssetInventory.status(forModules: [probe]) != .installed {
                Diagnostics.event("Downloading SpeechTranscriber model")
                try await AssetInventory.assetInstallationRequest(supporting: [probe])?.downloadAndInstall()
            }
        } catch {
            Diagnostics.event("SpeechTranscriber model install failed code=\((error as NSError).code)")
            return
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else { return }
        await MainActor.run {
            Self.locale = locale
            Self.analyzerFormat = format
        }
        Diagnostics.event("SpeechTranscriber ready; format=\(Int(format.sampleRate)) Hz")
    }

    /// Live text (finalized + in-progress), delivered on the main queue.
    var onText: ((String) -> Void)?

    private let targetFormat: AVAudioFormat
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var finalized = ""
    private var volatile = ""
    private var startTask: Task<Void, Error>?
    private var resultsTask: Task<Void, Never>?
    private var completed = false

    init?(vocabulary: [String]) {
        guard let format = Self.analyzerFormat, let locale = Self.locale else { return nil }
        targetFormat = format
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        analyzer = SpeechAnalyzer(modules: [transcriber],
                                  options: .init(priority: .userInitiated, modelRetention: .lingering))
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = continuation
        listen(to: transcriber)
        // Audio queues in the stream while the analyzer starts, so the first words aren't lost.
        startTask = Task { [analyzer] in
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = Array(vocabulary.prefix(100))
                try? await analyzer.setContext(context)
            }
            try await analyzer.start(inputSequence: stream)
        }
    }

    private func listen(to transcriber: SpeechTranscriber) {
        // Holds self only until the results stream ends at finish or cancel.
        resultsTask = Task { [self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run { self.receive(text, isFinal: result.isFinal) }
                }
            } catch {
                Diagnostics.event("SpeechTranscriber results ended code=\((error as NSError).code)")
            }
        }
    }

    var text: String { Self.join(finalized, volatile) }

    private func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized = Self.join(finalized, text)
            volatile = ""
        } else {
            volatile = text
        }
        onText?(self.text)
    }

    static func join(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }

    /// Called on the audio thread with microphone buffers in whatever format the device uses.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !completed, let converted = convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// Finalizes everything spoken, then reports the full text once on the main queue.
    func finish(completion: @escaping (String) -> Void) {
        lock.lock(); input.finish(); lock.unlock()
        var delivered = false
        let deliver: () -> Void = { [weak self] in
            guard !delivered else { return }
            delivered = true
            completion(self?.text ?? "")
        }
        Task { [analyzer, startTask, resultsTask] in
            _ = try? await startTask?.value
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { Diagnostics.event("SpeechTranscriber finalize failed code=\((error as NSError).code)") }
            await resultsTask?.value
            await MainActor.run { deliver() }
        }
        // Never hold the user's text hostage to a stalled model.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if !delivered { Diagnostics.event("SpeechTranscriber finalize timed out; using text so far") }
            deliver()
        }
        lock.lock(); completed = true; lock.unlock()
    }

    func cancel() {
        lock.lock(); completed = true; input.finish(); lock.unlock()
        resultsTask?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }
}

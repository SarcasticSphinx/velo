import Foundation
import AVFoundation
import Speech

@main struct EngineTests {
    static func main() {
        var gesture = FnGesture()
        precondition(gesture.press(at: 0, interval: 0.5) == .start)
        precondition(gesture.wantsRecording)
        precondition(gesture.press(at: 10, interval: 0.5) == .none)
        precondition(gesture.expireRelease() == .none) // Silence cannot stop a held key.
        precondition(gesture.release(at: 11) == .awaitSecondTap)
        precondition(gesture.wantsRecording) // Startup completion between taps must not stop.
        precondition(gesture.press(at: 11.4, interval: 0.5) == .lock)
        precondition(gesture.release(at: 11.45) == .none)
        precondition(gesture.expireRelease() == .none)
        precondition(gesture.wantsRecording && gesture.locked)
        precondition(gesture.press(at: 100, interval: 0.5) == .stop)
        precondition(!gesture.wantsRecording)
        _ = gesture.release(at: 101)
        precondition(gesture.press(at: 102, interval: 0.5) == .start)
        _ = gesture.release(at: 103)
        precondition(gesture.expireRelease() == .stop)
        precondition(!gesture.wantsRecording)
        let request = DictationEngine.makeRequest(vocabulary: (0..<150).map { "term\($0)" })
        precondition(request.requiresOnDeviceRecognition, "Cloud recognition must remain disabled")
        precondition(request.shouldReportPartialResults)
        precondition(request.contextualStrings.count == 100)
        var transcript = TranscriptSegments()
        transcript.update("First")
        transcript.update("First sentence.")
        transcript.commit()
        transcript.commit() // A silence-only segment must not clear previous words.
        precondition(transcript.text == "First sentence.")
        transcript.update("After a long pause.")
        precondition(transcript.text == "First sentence. After a long pause.")
        transcript.commit()
        transcript.update("Last words")
        precondition(transcript.text == "First sentence. After a long pause. Last words")
        // A pause inside one recognition task restarts its partials; earlier words must stay.
        var paused = TranscriptSegments()
        paused.update("Hello there this is the first part")
        paused.update("And then")
        precondition(paused.text == "Hello there this is the first part And then")
        paused.update("And then more words")
        precondition(paused.text == "Hello there this is the first part And then more words")
        // If the recognizer reports the whole text again, it must not be duplicated.
        paused.update("Hello there, this is the first part. And then more words.")
        precondition(paused.text == "Hello there, this is the first part. And then more words.")
        paused.commit()
        precondition(paused.text == "Hello there, this is the first part. And then more words.")
        // Ordinary revisions are not restarts.
        precondition(!TranscriptSegments.isRestart(from: "I want to go", to: "I want to"))
        precondition(!TranscriptSegments.isRestart(from: "Eye want", to: "I want to go"))
        precondition(DictationEngine.isSilenceError(NSError(domain: "kAFAssistantErrorDomain", code: 1110)))
        precondition(!DictationEngine.isSilenceError(NSError(domain: "Other", code: 1110)))
        precondition(!DictationEngine.isSilenceError(NSError(domain: "kAFAssistantErrorDomain", code: 1101)))
        let engine = DictationEngine()
        var callbacks = 0
        engine.onFinished = { _ in callbacks += 1 }
        engine.onFailure = { _ in callbacks += 1 }
        engine.stop()
        engine.stop()
        precondition(!engine.isRecording && callbacks == 0, "Idle stop must be harmless")
        if SFSpeechRecognizer.authorizationStatus() != .authorized || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            engine.start(vocabulary: [])
            precondition(!engine.isRecording && callbacks == 1, "Missing permission must fail once without recording")
        }
        print("Engine policy and idle-state tests passed")
    }
}

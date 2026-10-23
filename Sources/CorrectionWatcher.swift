import AppKit
import ApplicationServices

/// After a paste, briefly watches the same text field and reports words the user corrected.
/// Field contents are read locally and never stored; only learned word pairs are saved.
final class CorrectionWatcher {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "BreezeLearnCorrections") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "BreezeLearnCorrections") }
    }

    private static let watchFor: TimeInterval = 30
    private static let maximumLength = 100_000

    private var timer: Timer?
    private var element: AXUIElement?
    private var app: NSRunningApplication?
    private var afterPaste: String?
    private var span: Range<Int>?
    private var latest: String?
    private var deadline = Date.distantPast
    private var generation = 0
    private var onLearned: (([CorrectionLearner.Correction]) -> Void)?

    func watch(_ element: AXUIElement, in app: NSRunningApplication?, before: String, pasted: String,
               onLearned: @escaping ([CorrectionLearner.Correction]) -> Void) {
        finish()
        guard Self.enabled, before.count < Self.maximumLength else { return }
        generation += 1
        let current = generation
        // Give the target app a moment to apply the paste before taking the baseline.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.generation == current,
                  let after = TextInsertion.value(of: element), after.count < Self.maximumLength,
                  let span = Self.insertedSpan(before: before, after: after),
                  TextProcessor.words(String(Array(after)[span])) == TextProcessor.words(pasted) else { return }
            self.element = element
            self.app = app
            self.afterPaste = after
            self.latest = after
            self.span = span
            self.onLearned = onLearned
            self.deadline = Date().addingTimeInterval(Self.watchFor)
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// Where the paste landed: the stretch that differs between the field before and after.
    static func insertedSpan(before: String, after: String) -> Range<Int>? {
        let b = Array(before), a = Array(after)
        var prefix = 0
        while prefix < min(a.count, b.count) && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let end = a.count - suffix
        return end > prefix ? prefix..<end : nil
    }

    private func tick() {
        guard let element, Date() < deadline,
              let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let focused = TextInsertion.focusedElement(in: app), CFEqual(focused, element),
              let value = TextInsertion.value(of: element), value.count < Self.maximumLength else {
            finish()
            return
        }
        latest = value
    }

    /// Stops watching and reports what was learned. Also called when a new dictation starts.
    func finish() {
        generation += 1
        timer?.invalidate()
        timer = nil
        if let afterPaste, let span, let latest, latest != afterPaste {
            let learned = CorrectionLearner.corrections(after: afterPaste, span: span, later: latest)
            if !learned.isEmpty { onLearned?(learned) }
        }
        element = nil; app = nil; afterPaste = nil; span = nil; latest = nil; onLearned = nil
    }
}

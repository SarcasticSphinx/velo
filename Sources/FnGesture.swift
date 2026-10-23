import Foundation

/// Recording intent survives permission prompts and recognizer restarts.
struct FnGesture {
    enum Action { case none, start, lock, stop, awaitSecondTap }
    private(set) var down = false
    private(set) var wantsRecording = false
    private(set) var locked = false
    private var releasedAt: TimeInterval?

    mutating func press(at time: TimeInterval, interval: TimeInterval) -> Action {
        guard !down else { return .none }
        down = true
        if locked {
            locked = false; wantsRecording = false; releasedAt = nil
            return .stop
        }
        if wantsRecording, let releasedAt, time - releasedAt <= interval {
            locked = true; self.releasedAt = nil
            return .lock
        }
        releasedAt = nil
        if wantsRecording { return .none }
        wantsRecording = true
        return .start
    }
    mutating func release(at time: TimeInterval) -> Action {
        guard down else { return .none }
        down = false
        guard wantsRecording, !locked else { return .none }
        releasedAt = time
        return .awaitSecondTap
    }
    mutating func expireRelease() -> Action {
        guard wantsRecording, !down, !locked, releasedAt != nil else { return .none }
        wantsRecording = false; releasedAt = nil
        return .stop
    }
    mutating func reset() { wantsRecording = false; locked = false; releasedAt = nil }
}

/// The modifier key held to dictate. Fn is optional because macOS often uses it to switch input languages.
enum DictationKey: Int, CaseIterable {
    case rightOption, rightCommand, fn

    static var current: DictationKey {
        get { DictationKey(rawValue: UserDefaults.standard.integer(forKey: "BreezeDictationKey")) ?? .rightOption }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "BreezeDictationKey") }
    }
    var keyCode: UInt16 {
        switch self { case .rightOption: return 61; case .rightCommand: return 54; case .fn: return 63 }
    }
    var title: String {
        switch self { case .rightOption: return "Right Option ⌥"; case .rightCommand: return "Right Command ⌘"; case .fn: return "Fn / Globe 🌐" }
    }
    /// Device-specific bits, so the left-hand key of the same kind is ignored.
    func isDown(flags: UInt) -> Bool {
        switch self {
        case .rightOption: return flags & 0x40 != 0      // NX_DEVICERALTKEYMASK
        case .rightCommand: return flags & 0x10 != 0     // NX_DEVICERCMDKEYMASK
        case .fn: return flags & (1 << 23) != 0          // NSEvent.ModifierFlags.function
        }
    }
}

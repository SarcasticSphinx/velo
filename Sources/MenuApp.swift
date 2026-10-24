import AppKit
import ApplicationServices
import Carbon
import QuartzCore

/// Pastes into the focused text field; with no text field, leaves the text on the clipboard.
enum TextInsertion {
    enum Outcome { case pasted, copied }
    private static var manualAccessibilityRequested = Set<pid_t>()

    private static func capturePasteboard(_ board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map { original in
            let snapshot = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { snapshot.setData(data, forType: type) }
            }
            return snapshot
        }
    }

    static func focusedElement(in app: NSRunningApplication?) -> AXUIElement? {
        guard AXIsProcessTrusted(), let app else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Electron apps (Slack, VS Code, Notion…) only expose their text fields when asked.
        if manualAccessibilityRequested.insert(app.processIdentifier).inserted {
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func acceptsText(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"] as [String]
        if let role = role as? String, textRoles.contains(role) { return true }
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
           (editable as? Bool) == true { return true }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Targets whatever app is frontmost now, like typing would.
    static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == kAXSecureTextFieldSubrole
    }

    /// `onPasted` receives the field and its text from just before the paste, for learning corrections.
    static func insert(_ text: String, fallbackApp: NSRunningApplication?,
                       onPasted: ((AXUIElement, String) -> Void)? = nil,
                       completion: @escaping (Outcome) -> Void) {
        guard !text.isEmpty else { return }
        func clipboardOnly(_ reason: String) {
            Diagnostics.event("Copied to clipboard: " + reason)
            copy(text)
            completion(.copied)
        }
        guard AXIsProcessTrusted() else { clipboardOnly("Accessibility not authorized"); return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var target = NSWorkspace.shared.frontmostApplication
        if target == nil || target?.processIdentifier == ownPID { target = fallbackApp }
        guard let target, !target.isTerminated, target.processIdentifier != ownPID else {
            clipboardOnly("no application to paste into"); return
        }
        if !target.isActive {
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: target)
                _ = target.activate(from: .current, options: [])
            } else {
                _ = target.activate(options: [])
            }
        }

        // Activation is asynchronous. Never send a global paste to an unverified app.
        func waitForFocus(_ attempts: Int) {
            guard !target.isTerminated else { clipboardOnly("target exited"); return }
            guard target.isActive,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                guard attempts > 0 else { clipboardOnly("activation timed out"); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { waitForFocus(attempts - 1) }
                return
            }
            guard let focused = focusedElement(in: target), acceptsText(focused) else {
                clipboardOnly("no text field focused"); return
            }
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
                clipboardOnly("keyboard events unavailable"); return
            }
            let fieldBefore = isSecure(focused) ? nil : value(of: focused)
            let clipboard = NSPasteboard.general
            let original = capturePasteboard(clipboard)
            clipboard.clearContents()
            guard clipboard.setString(text, forType: .string) else { completion(.copied); return }
            let injectedClipboardChange = clipboard.changeCount
            down.flags = .maskCommand
            up.flags = .maskCommand
            // PID-targeted events provide another guard against a focus change during delivery.
            down.postToPid(target.processIdentifier)
            up.postToPid(target.processIdentifier)
            Diagnostics.event("Paste events delivered to focused text field")
            completion(.pasted)
            if let fieldBefore { onPasted?(focused, fieldBefore) }
            // Event posting has no receipt; clipboard restoration is best effort.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if clipboard.changeCount == injectedClipboardChange {
                    clipboard.clearContents()
                    if !original.isEmpty { _ = clipboard.writeObjects(original) }
                }
            }
        }
        waitForFocus(30)
    }
}

/// Short start/stop cues, like Wispr Flow's.
enum SoundCue {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "BreezeSounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "BreezeSounds") }
    }
    static func play(_ name: String) {
        guard enabled, let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 0.25
        sound.play()
    }
}

final class DictationApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private lazy var brandMenuIcon: NSImage? = {
        guard let image = NSImage(named: "MenuBarTemplate") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var smartItem: NSMenuItem!
    private var lastItem: NSMenuItem!
    private let engine = DictationEngine()
    private let vocabulary = VocabularyStore()
    private lazy var hud = DictationHUD()
    private let correctionWatcher = CorrectionWatcher()
    private let dictionaryMenu = NSMenu()
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var history: [String] = [] // Newest first; memory only.
    private var historyMenu = NSMenu()
    private var soundItem: NSMenuItem!
    private var pending = false
    private var hotKey: EventHotKeyRef?
    private var pasteLastHotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var fnMonitor: Any?
    private var localFnMonitor: Any?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var holdStartedAt: TimeInterval = 0
    private var processingCue: DispatchWorkItem?
    private var keyItems: [NSMenuItem] = []
    private var fnGesture = FnGesture()
    private var fnLocked: Bool { fnGesture.locked }
    private var releaseTask: DispatchWorkItem?
    private var fnSession = false
    private var providerItems: [NSMenuItem] = []
    private var modelItems: [NSMenuItem] = []

    private var smartRewrite: Bool {
        get { UserDefaults.standard.bool(forKey: "BreezeSmartRewrite") }
        set { UserDefaults.standard.set(newValue, forKey: "BreezeSmartRewrite") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        lastExternalApplication = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.lastExternalApplication = app
        }
        configureMenu()
        configureRecognition()
        DictationEngine.prepareModernEngine()
        configureGlobalShortcut()
        fnMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in self?.handleFn(event) }
        localFnMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in self?.handleFn(event); return event }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.handleKeyDown(event) }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.handleKeyDown(event); return event }
        if !AXIsProcessTrusted() {
            // Auto-paste needs Accessibility; ask up front instead of silently falling back to the clipboard.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        Diagnostics.event("Launched; Accessibility authorized=\(AXIsProcessTrusted()); rewrite enabled=\(smartRewrite)")
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = brandMenuIcon ?? NSImage(systemSymbolName: "mic", accessibilityDescription: "Velo")
        let menu = NSMenu()
        menu.autoenablesItems = false
        toggleItem = NSMenuItem(title: "Start Dictation   ⌥⇧Space", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        lastItem = NSMenuItem(title: "Paste Last Transcript   ⌥⇧V", action: #selector(pasteLast), keyEquivalent: "")
        lastItem.target = self
        lastItem.isEnabled = false
        menu.addItem(lastItem)
        let recent = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        recent.submenu = historyMenu
        menu.addItem(recent)
        rebuildHistoryMenu()
        menu.addItem(.separator())

        let dictionary = NSMenuItem(title: "Personal Dictionary", action: nil, keyEquivalent: "")
        dictionaryMenu.delegate = self // Rebuilt each time it opens, so learned words appear.
        dictionaryMenu.autoenablesItems = false
        dictionary.submenu = dictionaryMenu
        menu.addItem(dictionary)
        for (index, title) in ["Rewrite: Off", "Rewrite: Local Ollama", "Rewrite: OpenRouter"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(selectProvider(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = RewriteProvider.mode == index ? .on : .off
            providerItems.append(item); menu.addItem(item)
        }
        let keyMenu = NSMenu()
        for key in DictationKey.allCases {
            let item = NSMenuItem(title: key.title, action: #selector(selectDictationKey(_:)), keyEquivalent: "")
            item.target = self; item.tag = key.rawValue; item.state = key == DictationKey.current ? .on : .off
            keyItems.append(item); keyMenu.addItem(item)
        }
        let keyItem = NSMenuItem(title: "Dictation Key", action: nil, keyEquivalent: "")
        keyItem.submenu = keyMenu
        menu.addItem(keyItem)
        let modelMenu = NSMenu()
        for (index, model) in RewriteProvider.models.enumerated() {
            let item = NSMenuItem(title: model.title, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = model.id == RewriteProvider.model ? .on : .off
            modelItems.append(item); modelMenu.addItem(item)
        }
        let modelItem = NSMenuItem(title: "OpenRouter Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)
        soundItem = NSMenuItem(title: "Sound Effects", action: #selector(toggleSounds), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = SoundCue.enabled ? .on : .off
        menu.addItem(soundItem)
        let configure = NSMenuItem(title: "Configure OpenRouter API Key…", action: #selector(configureKey), keyEquivalent: "")
        configure.target = self; menu.addItem(configure)
        let accessibility = NSMenuItem(title: "Request Accessibility Permission…", action: #selector(requestAccessibility), keyEquivalent: "")
        accessibility.target = self
        menu.addItem(accessibility)
        let diagnostics = NSMenuItem(title: "Permission & Recognition Status…", action: #selector(showDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Velo", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func configureRecognition() {
        engine.onPartial = { [weak self] partial in
            guard let self, self.engine.isRecording else { return }
            self.hud.setCaption(String(partial.suffix(90)))
        }
        engine.onLevel = { [weak self] level in self?.hud.setLevel(level) }
        engine.onStatus = { message in Diagnostics.event("Engine status: " + message) }
        engine.onStopped = { [weak self] in
            guard let self else { return }
            self.pending = true
            SoundCue.play("Pop")
            self.hud.setLevel(0)
            // Most dictations finish almost instantly; only show the dots if finishing takes a moment.
            let cue = DispatchWorkItem { [weak self] in
                guard let self, !self.engine.isRecording else { return }
                self.hud.show(.processing)
            }
            self.processingCue = cue
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: cue)
            self.updateUI()
        }
        engine.onFinished = { [weak self] rawText in self?.finished(rawText) }
        engine.onFailure = { [weak self] message in
            guard let self else { return }
            self.pending = false
            self.fnSession = false
            self.fnGesture.reset()
            self.updateUI()
            self.hud.show(.hidden)
            self.alert("Dictation failed", message)
        }
    }

    private func configureGlobalShortcut() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, data -> OSStatus in
            guard let data, let event else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<DictationApp>.fromOpaque(data).takeUnretainedValue()
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            DispatchQueue.main.async { identifier.id == 2 ? app.pasteLast() : app.toggle() }
            return noErr
        }, 1, &spec, context, &handler)
        guard status == noErr else {
            Diagnostics.event("Hotkey handler installation failed: \(status)")
            alert("Shortcut unavailable", "Could not install the shortcut handler (OSStatus \(status)). Use Start Dictation in the menu.")
            return
        }
        let identifier = EventHotKeyID(signature: 0x42726565, id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | shiftKey),
                                           identifier, GetApplicationEventTarget(), 0, &hotKey)
        Diagnostics.event("Option+Shift+Space registration OSStatus=\(registered)")
        let pasteIdentifier = EventHotKeyID(signature: 0x42726565, id: 2)
        let pasteRegistered = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(optionKey | shiftKey),
                                                  pasteIdentifier, GetApplicationEventTarget(), 0, &pasteLastHotKey)
        Diagnostics.event("Option+Shift+V registration OSStatus=\(pasteRegistered)")
        if registered != noErr {
            alert("Shortcut unavailable", "Could not register ⌥⇧Space (OSStatus \(registered)). Another app may be using it. Use Start Dictation in the menu, or free the shortcut and relaunch.")
        }
    }

    @objc private func toggle() {
        if engine.isRecording {
            Diagnostics.event("Menu or toggle shortcut requested stop")
            engine.stop()
            return
        }
        guard !pending else { return }
        correctionWatcher.finish() // Learn from the previous paste before the next one.
        vocabulary.reload()
        pending = true
        updateUI()
        DictationEngine.requestPermissions { [weak self] failure in
            guard let self else { return }
            if let failure {
                self.pending = false
                self.alert("Permissions needed", failure)
                self.updateUI()
                return
            }
            self.pending = false
            if self.fnSession && !self.fnGesture.wantsRecording {
                self.fnSession = false
                self.updateUI()
                return
            }
            self.engine.start(vocabulary: self.vocabulary.contextualStrings)
            RewriteProvider.warmUp()
            if self.engine.isRecording {
                SoundCue.play("Tink")
                // Only a held dictation key ends on release; everything else is hands-free until stopped.
                self.hud.show(self.fnSession && !self.fnLocked ? .listening : .locked)
            }
            self.updateUI()
        }
    }

    /// The engine is free again here, so a new recording may start while this one is delivered.
    private func finished(_ raw: String) {
        fnSession = false
        fnGesture.reset()
        pending = false
        updateUI()
        let cleaned = TextProcessor.polish(raw, replacements: vocabulary.allReplacements)
        guard !cleaned.isEmpty else {
            if !engine.isRecording { processingCue?.cancel(); hud.show(.hidden) }
            return
        }
        remember(cleaned) // Saved before any rewrite or paste can fail.
        let context = RewritePrompt.context(for: NSWorkspace.shared.frontmostApplication)
        // Keep the transcript unless the model made only light edits.
        func faithful(_ text: String) -> String {
            if RewritePrompt.isFaithful(original: cleaned, edited: text) { return text }
            Diagnostics.event("Rewrite changed too much; using cleaned transcript")
            return cleaned
        }
        if RewriteProvider.mode == 2 && RewritePrompt.worthRewriting(cleaned) {
            RewriteProvider.rewrite(cleaned, context: context, vocabulary: vocabulary.contextualStrings) { [weak self] text, failure in
                guard let self else { return }
                if failure != nil { Diagnostics.event("OpenRouter rewrite failed; using cleaned transcript") }
                self.deliver(faithful(text), replacing: cleaned)
            }
        } else if RewriteProvider.mode == 1 && RewritePrompt.worthRewriting(cleaned) {
            LocalRewriter.rewrite(cleaned, vocabulary: vocabulary.contextualStrings, context: context) { [weak self] text in
                self?.deliver(faithful(text), replacing: cleaned)
            }
        } else {
            deliver(cleaned, replacing: cleaned)
        }
    }

    private func deliver(_ text: String, replacing original: String) {
        if text != original, let index = history.firstIndex(of: original) {
            history[index] = text
            rebuildHistoryMenu()
        }
        let onPasted: (AXUIElement, String) -> Void = { [weak self] field, before in
            guard let self else { return }
            self.correctionWatcher.watch(field, in: NSWorkspace.shared.frontmostApplication, before: before, pasted: text) {
                [weak self] learned in self?.learn(learned)
            }
        }
        TextInsertion.insert(text, fallbackApp: lastExternalApplication, onPasted: onPasted) { [weak self] outcome in
            guard let self, !self.engine.isRecording, !self.pending else { return }
            self.showOutcome(outcome)
        }
    }

    private func learn(_ corrections: [CorrectionLearner.Correction]) {
        let new = corrections.filter { vocabulary.replacements[$0.heard] != $0.meant }
        guard !new.isEmpty else { return }
        for correction in new { vocabulary.addWord(heard: correction.heard, preferred: correction.meant) }
        Diagnostics.event("Learned \(new.count) correction(s) into the personal dictionary")
        if !engine.isRecording && !pending {
            let names = new.map { "“\($0.meant)”" }.joined(separator: ", ")
            hud.show(.done("Learned \(names)"))
        }
    }

    private func showOutcome(_ outcome: TextInsertion.Outcome) {
        processingCue?.cancel()
        // A paste speaks for itself; only explain when the text went to the clipboard instead.
        if outcome == .pasted { hud.show(.hidden) }
        else if !AXIsProcessTrusted() { hud.show(.notice("Copied to clipboard · allow Accessibility to auto-paste")) }
        else { hud.show(.notice("No text field selected · Copied to clipboard")) }
    }

    private func remember(_ text: String) {
        history.insert(text, at: 0)
        if history.count > 15 { history.removeLast(history.count - 15) }
        rebuildHistoryMenu()
    }

    private func rebuildHistoryMenu() {
        historyMenu.removeAllItems()
        lastItem?.isEnabled = !history.isEmpty
        guard !history.isEmpty else {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
            return
        }
        for (index, text) in history.enumerated() {
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            let item = NSMenuItem(title: String(flat.prefix(60)) + (flat.count > 60 ? "…" : ""),
                                  action: #selector(copyHistory(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.toolTip = "Click to copy"
            historyMenu.addItem(item)
        }
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard history.indices.contains(sender.tag) else { return }
        TextInsertion.copy(history[sender.tag])
        hud.show(.done("Copied"))
    }

    @objc func pasteLast() {
        guard let text = history.first, !engine.isRecording else { return }
        TextInsertion.insert(text, fallbackApp: lastExternalApplication) { [weak self] outcome in
            self?.showOutcome(outcome)
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        RewriteProvider.model = RewriteProvider.models[sender.tag].id
        for item in modelItems { item.state = item.tag == sender.tag ? .on : .off }
    }

    @objc private func toggleSounds() {
        SoundCue.enabled.toggle()
        soundItem.state = SoundCue.enabled ? .on : .off
    }

    private func updateUI() {
        // Let AppKit choose contrasting template colors in every recording state.
        statusItem.button?.contentTintColor = nil
        if engine.isRecording {
            statusItem.button?.image = brandMenuIcon ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
            toggleItem.title = "Stop Dictation   ⌥⇧Space"
        } else {
            statusItem.button?.image = brandMenuIcon ?? NSImage(systemSymbolName: "mic", accessibilityDescription: "Velo")
            toggleItem.title = pending ? "Processing…" : "Start Dictation   ⌥⇧Space"
        }
        toggleItem.isEnabled = !pending || engine.isRecording
        statusItem.button?.toolTip = engine.isRecording ? "Recording — ⌥⇧Space to stop" : (pending ? "Processing dictation…" : "Velo — ⌥⇧Space to dictate")
    }

    // MARK: Personal dictionary

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === dictionaryMenu else { return }
        vocabulary.reload()
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, state: Bool? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = action != nil
            if let state { item.state = state ? .on : .off }
            menu.addItem(item)
            return item
        }
        _ = add("Add Word…", #selector(addWord))
        _ = add("Add Snippet…", #selector(addSnippet))
        let words = vocabulary.replacements.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        if !words.isEmpty {
            menu.addItem(.separator())
            _ = add("Words — click to remove", nil)
            for (heard, preferred) in words {
                let title = heard == preferred.lowercased() ? preferred : "\(heard) → \(preferred)"
                add(title, #selector(removeEntry(_:))).representedObject = ["word", heard]
            }
        }
        if !vocabulary.snippets.isEmpty {
            menu.addItem(.separator())
            _ = add("Snippets — click to remove", nil)
            for (trigger, expansion) in vocabulary.snippets.sorted(by: { $0.key < $1.key }) {
                let preview = expansion.replacingOccurrences(of: "\n", with: " ")
                add("“\(trigger)” → \(preview.prefix(36))\(preview.count > 36 ? "…" : "")", #selector(removeEntry(_:)))
                    .representedObject = ["snippet", trigger]
            }
        }
        menu.addItem(.separator())
        _ = add("Learn From My Corrections", #selector(toggleLearning), state: CorrectionWatcher.enabled)
        _ = add("Open Dictionary Folder…", #selector(openDictionaryFolder))
    }

    /// Two-field dialog; returns nil on cancel.
    private func ask(_ title: String, _ info: String, _ first: String, _ second: String,
                     multilineSecond: Bool = false) -> (String, String)? {
        let dialog = NSAlert()
        dialog.messageText = title
        dialog.informativeText = info
        let top = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        top.placeholderString = first
        let bottomHeight: CGFloat = multilineSecond ? 72 : 24
        let bottom: NSView
        let readBottom: () -> String
        if multilineSecond {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: bottomHeight))
            let text = NSTextView(frame: scroll.bounds)
            text.font = .systemFont(ofSize: 13)
            text.isRichText = false
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            bottom = scroll
            readBottom = { text.string }
        } else {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.placeholderString = second
            bottom = field
            readBottom = { field.stringValue }
        }
        let caption = NSTextField(labelWithString: multilineSecond ? second : "")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        let stack = NSStackView(views: multilineSecond ? [top, caption, bottom] : [top, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 24 + bottomHeight + (multilineSecond ? 26 : 6))
        dialog.accessoryView = stack
        dialog.addButton(withTitle: "Add")
        dialog.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        dialog.window.initialFirstResponder = top
        guard dialog.runModal() == .alertFirstButtonReturn else { return nil }
        return (top.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), readBottom())
    }

    @objc private func addWord() {
        guard let (preferred, heardAs) = ask(
            "Add a word", "How it should be written, e.g. a name or product. Optionally, what dictation tends to hear instead.",
            "Correct spelling, e.g. Wispr Flow", "Often heard as, comma-separated (optional), e.g. whisper flow"),
            !preferred.isEmpty else { return }
        vocabulary.addWord(heard: preferred, preferred: preferred) // Also fixes capitalization and hints the recognizer.
        for variant in heardAs.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !variant.isEmpty {
            vocabulary.addWord(heard: variant, preferred: preferred)
        }
        hud.show(.done("Added “\(preferred)”"))
    }

    @objc private func addSnippet() {
        guard let (trigger, expansion) = ask(
            "Add a snippet", "Say the trigger phrase and the snippet is inserted instead. Use a phrase you wouldn't say otherwise, like “insert my email”.",
            "Trigger phrase, e.g. insert my email", "Text to insert:", multilineSecond: true),
            !trigger.isEmpty, !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        vocabulary.addSnippet(trigger: trigger, expansion: expansion.trimmingCharacters(in: .whitespacesAndNewlines))
        hud.show(.done("Added snippet “\(trigger)”"))
    }

    @objc private func removeEntry(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? [String], entry.count == 2 else { return }
        let confirm = NSAlert()
        confirm.messageText = "Remove “\(sender.title)”?"
        confirm.addButton(withTitle: "Remove")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        if entry[0] == "word" { vocabulary.removeWord(entry[1]) } else { vocabulary.removeSnippet(entry[1]) }
    }

    @objc private func toggleLearning() {
        CorrectionWatcher.enabled.toggle()
        if !CorrectionWatcher.enabled { correctionWatcher.finish() }
    }

    @objc private func openDictionaryFolder() {
        NSWorkspace.shared.open(vocabulary.directory)
    }

    @objc private func selectDictationKey(_ sender: NSMenuItem) {
        guard let key = DictationKey(rawValue: sender.tag) else { return }
        DictationKey.current = key
        fnGesture.reset()
        for item in keyItems { item.state = item.tag == key.rawValue ? .on : .off }
        if key == .fn && UserDefaults(suiteName: "com.apple.HIToolbox")?.integer(forKey: "AppleFnUsageType") != 0 {
            alert("Fn also switches input language", "Set System Settings → Keyboard → \"Press 🌐 key to\" → Do Nothing, or Fn will change your input language while you dictate.")
        }
    }

    /// Pressing another key while holding the dictation key means the user is typing a shortcut.
    private func handleKeyDown(_ event: NSEvent) {
        guard fnGesture.down, !fnGesture.locked, event.timestamp - holdStartedAt < 1.0 else { return }
        Diagnostics.event("Key pressed during dictation-key hold; treating as shortcut")
        releaseTask?.cancel()
        fnGesture.reset()
        if engine.isRecording {
            engine.cancel()
            fnSession = false
        }
        hud.show(.hidden)
        updateUI()
    }

    private func handleFn(_ event: NSEvent) {
        let key = DictationKey.current
        guard event.keyCode == key.keyCode else { return }
        let down = key.isDown(flags: event.modifierFlags.rawValue)
        // Ignore an incidental flags event that contradicts the hardware key state.
        if !down && CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key.keyCode)) {
            Diagnostics.event("Ignored dictation-key release while hardware key remains down")
            return
        }
        if down && !fnGesture.down { holdStartedAt = event.timestamp }
        // Short enough that releasing the key feels instant, long enough for a deliberate double tap.
        let interval = 0.3
        let action = down ? fnGesture.press(at: event.timestamp, interval: interval)
                          : fnGesture.release(at: event.timestamp)
        switch action {
        case .start:
            releaseTask?.cancel()
            guard !pending, !engine.isRecording else { fnGesture.reset(); return }
            fnSession = true
            Diagnostics.event("Fn hold requested recording")
            toggle()
        case .lock:
            releaseTask?.cancel()
            Diagnostics.event("Fn double tap locked recording")
            if engine.isRecording { hud.show(.locked) }
        case .stop:
            releaseTask?.cancel()
            Diagnostics.event("Fn tap explicitly ended locked recording")
            engine.stop()
        case .awaitSecondTap:
            releaseTask?.cancel()
            let task = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key.keyCode)) { return }
                if self.fnGesture.expireRelease() == .stop {
                    Diagnostics.event("Fn release explicitly ended held recording")
                    self.engine.stop()
                }
            }
            releaseTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: task)
        case .none: break
        }
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        RewriteProvider.mode = sender.tag
        for item in providerItems { item.state = item.tag == sender.tag ? .on : .off }
        if sender.tag == 2 { alert("OpenRouter selected", "Finished transcripts will be sent to OpenRouter and its model provider for rewriting with \(RewriteProvider.modelTitle) (change it under OpenRouter Model). Speech recognition itself stays on-device. API usage may incur charges.") }
    }

    @objc private func configureKey() {
        let dialog = NSAlert()
        dialog.messageText = "OpenRouter API key"
        dialog.informativeText = "Stored in macOS Keychain. Model: \(RewriteProvider.modelTitle)."
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        dialog.accessoryView = input
        dialog.addButton(withTitle: "Save"); dialog.addButton(withTitle: "Cancel")
        if dialog.runModal() == .alertFirstButtonReturn {
            let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty || !RewriteProvider.save(key) { alert("Key not saved", "Enter a valid key and allow Keychain access, then try again.") }
        }
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Diagnostics.event("Accessibility authorized=\(trusted)")
        if !trusted {
            alert("Enable automatic insertion", "Open System Settings → Privacy & Security → Accessibility and enable Velo. After a rebuild, remove the old entry and add this app again if needed. Dictation still works with manual paste.")
        }
    }

    @objc private func showDiagnostics() {
        alert("Velo status", DictationEngine.diagnosticSummary() + "\nAccessibility: " + (AXIsProcessTrusted() ? "authorized" : "not authorized — enable in Privacy & Security → Accessibility") + "\nGlobal shortcut: " + (hotKey == nil ? "unavailable — use Start Dictation in this menu" : "⌥⇧Space registered") + "\nPaste last: " + (pasteLastHotKey == nil ? "unavailable — use the menu" : "⌥⇧V registered") + "\nSmart Rewrite: " + (["off", "local Ollama", "OpenRouter · " + RewriteProvider.modelTitle][min(2, max(0, RewriteProvider.mode))]))
    }

    @objc private func quitApp() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let pasteLastHotKey { UnregisterEventHotKey(pasteLastHotKey) }
        for monitor in [fnMonitor, localFnMonitor, keyMonitor, localKeyMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        if let handler { RemoveEventHandler(handler) }
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.runModal()
    }
}

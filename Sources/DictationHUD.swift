import AppKit
import QuartzCore

/// Minimal floating pill near the bottom of the screen. It never takes focus,
/// so it can't become the paste target.
final class DictationHUD {
    enum Mode: Equatable { case hidden, listening, locked, processing, done(String), notice(String) }

    private static let size = NSSize(width: 520, height: 120)
    private static let pillHeight: CGFloat = 36
    private static let barCount = 11

    private let panel: NSPanel
    private let pill = NSView()
    private let content = CALayer()
    private let bars: [CALayer]
    private let dots: [CALayer]
    private let lockDot = CALayer()
    private let check = CAShapeLayer()
    private let warning = CALayer()
    private let label = NSTextField(labelWithString: "")
    private let captionBox = NSView()
    private let caption = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var level: CGFloat = 0
    private var targetLevel: CGFloat = 0
    private var phase: CGFloat = 0
    private var hideWork: DispatchWorkItem?
    private(set) var mode: Mode = .hidden

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true

        let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
        root.wantsLayer = true
        panel.contentView = root

        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.94).cgColor
        pill.layer?.cornerRadius = Self.pillHeight / 2
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        pill.layer?.shadowColor = NSColor.black.cgColor
        pill.layer?.shadowOpacity = 0.35
        pill.layer?.shadowRadius = 10
        pill.layer?.shadowOffset = CGSize(width: 0, height: -3)
        root.addSubview(pill)

        // AppKit orders view layers itself, so the animated layers live in a view above the pill.
        let stage = NSView(frame: root.bounds)
        stage.wantsLayer = true
        root.addSubview(stage)
        content.frame = stage.bounds
        stage.layer?.addSublayer(content)

        bars = (0..<Self.barCount).map { _ in
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = 1.5
            return bar
        }
        bars.forEach(content.addSublayer)
        dots = (0..<3).map { _ in
            let dot = CALayer()
            dot.backgroundColor = NSColor(white: 1, alpha: 0.9).cgColor
            dot.cornerRadius = 3
            dot.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
            return dot
        }
        dots.forEach(content.addSublayer)

        lockDot.backgroundColor = NSColor.systemRed.cgColor
        lockDot.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        lockDot.cornerRadius = 4
        content.addSublayer(lockDot)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 3, y: 9))
        path.addLine(to: CGPoint(x: 7, y: 5))
        path.addLine(to: CGPoint(x: 15, y: 13))
        check.path = path
        check.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        check.fillColor = nil
        check.strokeColor = NSColor.systemGreen.cgColor
        check.lineWidth = 2.4
        check.lineCap = .round
        check.lineJoin = .round
        content.addSublayer(check)

        warning.backgroundColor = NSColor.systemOrange.cgColor
        warning.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        warning.cornerRadius = 4
        content.addSublayer(warning)

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alphaValue = 0
        root.addSubview(label)

        captionBox.wantsLayer = true
        captionBox.layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.82).cgColor
        captionBox.layer?.cornerRadius = 10
        captionBox.alphaValue = 0
        caption.font = .systemFont(ofSize: 12, weight: .regular)
        caption.textColor = NSColor(white: 1, alpha: 0.85)
        caption.lineBreakMode = .byTruncatingHead
        caption.maximumNumberOfLines = 1
        captionBox.addSubview(caption)
        root.addSubview(captionBox)

        apply(.hidden, animated: false)
    }

    func setLevel(_ value: Float) { targetLevel = CGFloat(value) }

    /// Shows the end of the live transcript above the pill.
    func setCaption(_ text: String) {
        guard mode == .listening || mode == .locked else { return }
        let tail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return }
        caption.stringValue = tail
        let width = min(Self.size.width - 40, caption.fittingSize.width + 24)
        let box = NSRect(x: (Self.size.width - width) / 2, y: Self.pillHeight + 22, width: width, height: 26)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            captionBox.animator().frame = box
            captionBox.animator().alphaValue = 1
        }
        caption.frame = NSRect(x: 12, y: 5, width: width - 24, height: 16)
    }

    func show(_ next: Mode) {
        hideWork?.cancel()
        guard next != mode else { return }
        apply(next, animated: true)
        switch next {
        case .done, .notice:
            let work = DispatchWorkItem { [weak self] in self?.show(.hidden) }
            hideWork = work
            let delay: Double = { if case .done = next { return 1.1 } else { return 2.2 } }()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        default: break
        }
    }

    private func apply(_ next: Mode, animated: Bool) {
        let previous = mode
        mode = next
        if next == .hidden {
            stopTicking()
            guard animated, panel.isVisible else { panel.orderOut(nil); return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.mode == .hidden else { return }
                self.panel.orderOut(nil)
            })
            slide(from: 0, to: -12)
            return
        }

        let appearing = previous == .hidden || !panel.isVisible
        if appearing {
            position()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
            layoutPill(width(for: next), animated: false)
            slide(from: -16, to: 0)
        } else {
            layoutPill(width(for: next), animated: true)
        }

        let listening = next == .listening || next == .locked
        let center = CGPoint(x: Self.size.width / 2, y: Self.pillHeight / 2 + 8)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.3 : 0)
        let barsOffset: CGFloat = next == .locked ? -8 : 0
        for (index, bar) in bars.enumerated() {
            let x = center.x + barsOffset + CGFloat(index - Self.barCount / 2) * 6
            bar.position = CGPoint(x: x, y: center.y)
            bar.opacity = listening ? 1 : 0
        }
        lockDot.position = CGPoint(x: center.x + 34, y: center.y)
        lockDot.opacity = next == .locked ? 1 : 0
        for (index, dot) in dots.enumerated() {
            dot.position = CGPoint(x: center.x + CGFloat(index - 1) * 12, y: center.y)
            dot.opacity = next == .processing ? 1 : 0
        }
        CATransaction.commit()

        if next == .locked { pulse(lockDot) } else { lockDot.removeAllAnimations() }
        if next == .processing { bounce() } else { dots.forEach { $0.removeAllAnimations() } }
        if listening { startTicking() } else { stopTicking() }
        if !listening { NSAnimationContext.runAnimationGroup { $0.duration = 0.2; captionBox.animator().alphaValue = 0 } }
        if appearing && listening { caption.stringValue = ""; captionBox.alphaValue = 0 }

        var message: String?
        var iconWidth: CGFloat = 0
        switch next {
        case .done(let text): message = text; iconWidth = 18
        case .notice(let text): message = text; iconWidth = 8
        default: break
        }
        check.opacity = 0
        warning.opacity = 0
        if let message {
            label.stringValue = message
            let textWidth = label.fittingSize.width
            let total = iconWidth + 8 + textWidth
            let startX = center.x - total / 2
            let icon: CALayer = { if case .done = next { return check } else { return warning } }()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            icon.position = CGPoint(x: startX + iconWidth / 2, y: center.y)
            icon.opacity = 1
            CATransaction.commit()
            if icon === check { drawCheck() } else { pulse(warning) }
            label.frame = NSRect(x: startX + iconWidth + 8, y: center.y - 9, width: textWidth + 2, height: 18)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                label.animator().alphaValue = 1
            }
        } else {
            label.alphaValue = 0
        }
    }

    private func width(for mode: Mode) -> CGFloat {
        switch mode {
        case .hidden: return 60
        case .listening: return 100
        case .locked: return 116
        case .processing: return 70
        case .done(let text), .notice(let text):
            label.stringValue = text
            return label.fittingSize.width + (mode == .done(text) ? 18 : 8) + 8 + 36
        }
    }

    private func layoutPill(_ width: CGFloat, animated: Bool) {
        let frame = NSRect(x: (Self.size.width - width) / 2, y: 8, width: width, height: Self.pillHeight)
        guard animated else { pill.frame = frame; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.25, 0.35, 1)
            context.allowsImplicitAnimation = true
            pill.animator().frame = frame
        }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 18))
    }

    private func slide(from offset: CGFloat, to target: CGFloat) {
        guard let layer = panel.contentView?.layer else { return }
        let animation = CASpringAnimation(keyPath: "transform.translation.y")
        animation.fromValue = offset
        animation.toValue = target
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = target == 0
        animation.damping = 14
        animation.stiffness = 260
        animation.mass = 0.8
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: "pop")
    }

    private func pulse(_ layer: CALayer) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.3
        animation.duration = 0.7
        animation.autoreverses = true
        animation.repeatCount = .infinity
        layer.add(animation, forKey: "pulse")
    }

    private func bounce() {
        for (index, dot) in dots.enumerated() {
            let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
            animation.values = [0, 5, 0, 0]
            animation.keyTimes = [0, 0.25, 0.5, 1]
            animation.duration = 0.9
            animation.repeatCount = .infinity
            animation.beginTime = CACurrentMediaTime() + Double(index) * 0.13
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(animation, forKey: "bounce")
        }
    }

    private func drawCheck() {
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 0.32
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        check.add(animation, forKey: "draw")
    }

    private func startTicking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
        targetLevel = 0
    }

    /// Bars follow the microphone level, tallest in the middle, with a gentle idle ripple.
    private func tick() {
        level += (targetLevel - level) * (targetLevel > level ? 0.35 : 0.12)
        phase += 0.16
        let middle = CGFloat(Self.barCount / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let distance = abs(CGFloat(index) - middle) / (middle + 1)
            let weight = 1 - distance * 0.65
            let ripple = (sin(phase + CGFloat(index) * 0.8) + 1) / 2
            let height = 3 + level * 20 * weight * (0.55 + 0.45 * ripple) + ripple * 2
            bar.bounds = CGRect(x: 0, y: 0, width: 3, height: min(22, height))
        }
        CATransaction.commit()
    }
}

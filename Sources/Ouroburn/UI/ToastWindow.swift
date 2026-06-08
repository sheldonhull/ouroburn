import AppKit
import CoreGraphics

/// In-app toast surfaced when the live USD/hr breaches the user's threshold or hits a new daily
/// peak. Implemented as a non-activating floating panel pinned to the top-right of the active
/// screen — chosen over `UNUserNotification` because the user explicitly wanted an on-screen
/// signal that doesn't depend on Notification Center being visible.
///
/// Behavior: idle-aware auto-dismiss. If the user is at the machine (low input-idle time) they've
/// already seen the toast, so it self-closes after `activeDismissSeconds`. If the machine is idle
/// (user away) the toast stays pinned and the dismiss check reschedules — so it survives until the
/// user returns, becomes active, and the next check fires. A click always dismisses immediately.
@MainActor
final class ToastWindow {
    private let panel: NSPanel
    private var dismissWork: DispatchWorkItem?

    /// Input-idle threshold separating "user present" from "user away". Below this the user is
    /// treated as active (saw the toast); at/above it the toast persists.
    private static let idleThresholdSeconds: TimeInterval = 60
    /// While the user stays idle, re-check at this cadence so the toast closes shortly after they
    /// return and become active again.
    private static let idleRecheckSeconds: TimeInterval = 5

    /// Active toast singleton — when a new toast arrives we replace the old one rather than
    /// stacking. Keeps the alert footprint to a single chip in the corner.
    private static var current: ToastWindow?

    static func show(
        title: String,
        message: String,
        accent: NSColor = Theme.accentPeach,
        activeDismissSeconds: TimeInterval = 6
    ) {
        current?.close()
        let toast = ToastWindow(title: title, message: message, accent: accent)
        toast.present()
        toast.scheduleAutoDismiss(after: activeDismissSeconds)
        current = toast
    }

    static func dismissAll() {
        current?.close()
        current = nil
    }

    /// Seconds since the last keyboard/mouse input across the whole session. Wide-event idle clock
    /// (`~0` = any input type). No entitlement required.
    private static func userIdleSeconds() -> TimeInterval {
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    /// Close once the user is active (has seen it). While idle, reschedule rather than close.
    private func scheduleAutoDismiss(after seconds: TimeInterval) {
        guard seconds > 0 else { return }
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if Self.userIdleSeconds() < Self.idleThresholdSeconds {
                close()
            } else {
                scheduleAutoDismiss(after: Self.idleRecheckSeconds)
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private init(title: String, message: String, accent: NSColor) {
        let width: CGFloat = 640
        let height: CGFloat = 88
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        let content = ToastContentView(title: title, message: message, accent: accent)
        panel.contentView = content
        content.onDismiss = { [weak self] in self?.close() }
    }

    private func present() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let panelSize = panel.frame.size
        let margin: CGFloat = 16
        let origin = NSPoint(
            x: visible.maxX - panelSize.width - margin,
            y: visible.maxY - panelSize.height - margin
        )
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func close() {
        dismissWork?.cancel()
        dismissWork = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            Task { @MainActor in panel.orderOut(nil) }
        }
        if Self.current === self { Self.current = nil }
    }
}

@MainActor
private final class ToastContentView: NSView {
    var onDismiss: (() -> Void)?

    private let icon = NSImageView()
    private let accent: NSColor
    private static let pulseKey = "ouroburn.toast.ekg"

    init(title: String, message: String, accent: NSColor) {
        self.accent = accent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = Theme.surface.withAlphaComponent(0.96).cgColor
        layer?.borderColor = Theme.divider.cgColor
        layer?.borderWidth = 1
        Theme.applyGhostRim(layer!, color: accent, rimAlpha: 0.55, glowRadius: 14, glowAlpha: 0.42)

        icon.wantsLayer = true
        icon.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
        icon.contentTintColor = accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithAttributedString:
            Theme.glowAttributedTitle(title, color: accent, font: Theme.titleFont(size: 13)))
        titleField.translatesAutoresizingMaskIntoConstraints = false

        let messageField = NSTextField(labelWithString: message)
        messageField.font = Theme.bodyFont(size: 11)
        messageField.textColor = Theme.textPrimary
        messageField.maximumNumberOfLines = 1
        messageField.lineBreakMode = .byTruncatingTail
        messageField.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton()
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        closeButton.contentTintColor = Theme.textTertiary
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        closeButton.toolTip = "Dismiss"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let dismissField = NSTextField(labelWithString: "Click to dismiss")
        dismissField.font = Theme.bodyFont(size: 9)
        dismissField.textColor = Theme.textTertiary
        dismissField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(titleField)
        addSubview(messageField)
        addSubview(closeButton)
        addSubview(dismissField)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),

            messageField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),
            messageField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            messageField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            dismissField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            dismissField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            dismissField.topAnchor.constraint(greaterThanOrEqualTo: messageField.bottomAnchor, constant: 2)
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleClose)))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    @objc private func handleClose() {
        onDismiss?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // EKG-style pulse on the alert icon, only while on screen. CAAnimations added off-window
        // get dropped, so (re)install on attach and remove on detach.
        if window != nil { startEKGPulse() } else { icon.layer?.removeAnimation(forKey: Self.pulseKey) }
    }

    /// "lub-dub" double-beat scale + glow — the heartbeat pulse, reserved for this top-corner alert
    /// rather than running on the always-visible panel.
    private func startEKGPulse() {
        guard let layer = icon.layer, layer.animation(forKey: Self.pulseKey) == nil else { return }
        layer.shadowColor = accent.cgColor
        layer.shadowRadius = 5
        layer.shadowOffset = .zero

        let beat = CAKeyframeAnimation(keyPath: "transform.scale")
        beat.values = [1.0, 1.24, 1.0, 1.16, 1.0, 1.0]
        beat.keyTimes = [0.0, 0.10, 0.20, 0.30, 0.42, 1.0]
        beat.duration = 1.4
        beat.repeatCount = .infinity
        beat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(beat, forKey: Self.pulseKey)

        let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        glow.values = [0.0, 0.6, 0.1, 0.45, 0.0, 0.0]
        glow.keyTimes = [0.0, 0.10, 0.20, 0.30, 0.42, 1.0]
        glow.duration = 1.4
        glow.repeatCount = .infinity
        glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(glow, forKey: Self.pulseKey + ".glow")
    }
}

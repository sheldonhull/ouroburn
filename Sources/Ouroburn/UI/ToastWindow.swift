import AppKit

/// In-app toast surfaced when the live USD/hr breaches the user's threshold or hits a new daily
/// peak. Implemented as a non-activating floating panel pinned to the top-right of the active
/// screen — chosen over `UNUserNotification` because the user explicitly wanted an on-screen
/// signal that doesn't depend on Notification Center being visible.
///
/// Behavior: toast stays pinned until the user clicks the X / Dismiss button (or anywhere on the
/// body). Caller-provided duration values are accepted but ignored — earlier auto-dismiss was
/// removed at the user's request so a brief glance away doesn't lose the alert.
@MainActor
final class ToastWindow {
    private let panel: NSPanel

    /// Active toast singleton — when a new toast arrives we replace the old one rather than
    /// stacking. Keeps the alert footprint to a single chip in the corner.
    private static var current: ToastWindow?

    static func show(title: String, message: String, accent: NSColor = Theme.accentPeach) {
        current?.close()
        let toast = ToastWindow(title: title, message: message, accent: accent)
        toast.present()
        current = toast
    }

    static func dismissAll() {
        current?.close()
        current = nil
    }

    private init(title: String, message: String, accent: NSColor) {
        let width: CGFloat = 340
        let height: CGFloat = 94
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

    init(title: String, message: String, accent: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = Theme.surface.withAlphaComponent(0.96).cgColor
        layer?.borderColor = Theme.divider.cgColor
        layer?.borderWidth = 1
        Theme.applyGhostRim(layer!, color: accent, rimAlpha: 0.55, glowRadius: 14, glowAlpha: 0.42)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)
        icon.contentTintColor = accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithAttributedString:
            Theme.glowAttributedTitle(title, color: accent, font: Theme.titleFont(size: 13)))
        titleField.translatesAutoresizingMaskIntoConstraints = false

        let messageField = NSTextField(wrappingLabelWithString: message)
        messageField.font = Theme.bodyFont(size: 11)
        messageField.textColor = Theme.textPrimary
        messageField.maximumNumberOfLines = 3
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
}

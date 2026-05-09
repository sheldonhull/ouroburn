import AppKit

/// In-app toast surfaced when the live USD/hr breaches the user's threshold for a sustained
/// window. Implemented as a non-activating floating panel pinned to the top-right of the active
/// screen — chosen over `UNUserNotification` because the user explicitly wanted an on-screen
/// signal that doesn't depend on Notification Center being visible.
@MainActor
final class ToastWindow {
    private let panel: NSPanel
    private var dismissWorkItem: DispatchWorkItem?

    /// Active toast singleton — when a new toast arrives we replace the old one rather than
    /// stacking. Keeps the alert footprint to a single chip in the corner.
    private static var current: ToastWindow?

    static func show(title: String, message: String, durationSeconds: Double) {
        current?.close()
        let toast = ToastWindow(title: title, message: message)
        toast.present(durationSeconds: durationSeconds)
        current = toast
    }

    static func dismissAll() {
        current?.close()
        current = nil
    }

    private init(title: String, message: String) {
        let width: CGFloat = 320
        let height: CGFloat = 78
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

        let content = ToastContentView(title: title, message: message)
        panel.contentView = content
        content.onClick = { [weak self] in self?.close() }
    }

    private func present(durationSeconds: Double) {
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

        let work = DispatchWorkItem { [weak self] in self?.close() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + durationSeconds, execute: work)
    }

    private func close() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
        })
        if Self.current === self { Self.current = nil }
    }
}

@MainActor
private final class ToastContentView: NSView {
    var onClick: (() -> Void)?

    init(title: String, message: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = Theme.surface.withAlphaComponent(0.92).cgColor
        Theme.applyGhostRim(layer!, color: Theme.accentPeach, rimAlpha: 0.55, glowRadius: 14, glowAlpha: 0.42)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)
        icon.contentTintColor = Theme.accentPeach
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithAttributedString:
            Theme.glowAttributedTitle(title, color: Theme.accentPeach, font: Theme.titleFont(size: 13)))
        titleField.translatesAutoresizingMaskIntoConstraints = false

        let messageField = NSTextField(wrappingLabelWithString: message)
        messageField.font = Theme.bodyFont(size: 11)
        messageField.textColor = Theme.textPrimary
        messageField.maximumNumberOfLines = 2
        messageField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(titleField)
        addSubview(messageField)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),

            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            messageField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),
            messageField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            messageField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            messageField.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleClick)))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    @objc private func handleClick() { onClick?() }
}

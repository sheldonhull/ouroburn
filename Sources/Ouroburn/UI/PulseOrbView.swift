import AppKit

/// A small glowing orb that emits a one-shot radial pulse on demand. Two intensities:
/// `.soft` for an OAuth upstream fetch, `.strong` (brighter, wider neon ring) for a local live
/// refresh. Idle it sits as a dim dot; each pulse expands a ring outward from the core and fades.
@MainActor
final class PulseOrbView: NSView {
    enum Intensity {
        case soft, strong
    }

    private let core = CALayer()
    private let ring = CALayer()
    private var accent: NSColor = Theme.accentMint

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        configureLayers()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 14, height: 14)
    }

    private func configureLayers() {
        ring.masksToBounds = false
        ring.opacity = 0
        layer?.addSublayer(ring)

        core.masksToBounds = false
        layer?.addSublayer(core)
        applyAccent()
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        let coreSide = side * 0.5
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        core.frame = CGRect(x: center.x - coreSide / 2, y: center.y - coreSide / 2, width: coreSide, height: coreSide)
        core.cornerRadius = coreSide / 2
        ring.frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        ring.cornerRadius = side / 2
    }

    /// Recolor the orb (e.g. to track burn tier). Idle core stays dim; pulses use full accent.
    func setAccent(_ color: NSColor) {
        guard color != accent else { return }
        accent = color
        applyAccent()
    }

    private func applyAccent() {
        core.backgroundColor = accent.withAlphaComponent(0.85).cgColor
        core.shadowColor = accent.cgColor
        core.shadowOpacity = 0.7
        core.shadowRadius = 3
        core.shadowOffset = .zero
        ring.backgroundColor = accent.withAlphaComponent(0.0).cgColor
        ring.borderColor = accent.cgColor
    }

    /// Fire a single pulse. `.strong` expands wider, glows brighter, and lasts a touch longer —
    /// used for the more-frequent local refresh so it reads as the livelier signal.
    func pulse(_ intensity: Intensity) {
        let toScale: CGFloat = intensity == .strong ? 2.6 : 1.9
        let duration: CFTimeInterval = intensity == .strong ? 0.75 : 0.55
        let borderWidth: CGFloat = intensity == .strong ? 2.5 : 1.5
        let startOpacity: Float = intensity == .strong ? 0.9 : 0.6

        ring.borderWidth = borderWidth

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6
        scale.toValue = toScale
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = startOpacity
        fade.toValue = 0.0
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = duration
        group.isRemovedOnCompletion = true
        ring.add(group, forKey: "ouroburn.orb.pulse")

        // Core blip so the center also reacts.
        let blip = CABasicAnimation(keyPath: "transform.scale")
        blip.fromValue = 1.0
        blip.toValue = intensity == .strong ? 1.5 : 1.25
        blip.duration = 0.18
        blip.autoreverses = true
        blip.timingFunction = CAMediaTimingFunction(name: .easeOut)
        core.add(blip, forKey: "ouroburn.orb.core")
    }
}

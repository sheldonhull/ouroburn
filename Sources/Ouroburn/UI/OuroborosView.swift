import AppKit
import QuartzCore

/// Animated ouroboros for the menu bar.
///
/// Renders a coiled snake biting its tail using a tapered body (head fat, tail thin), an open
/// mouth wedge, an eye, and a tail tip clamped in the mouth. A bold tier number (1-10) sits in
/// the center to communicate burn intensity at a glance.
///
/// Architecture: snake is rasterized to a `CGImage` once per tier (color + size unchanged
/// between ticks), then a single `CABasicAnimation` on `transform.rotation.z` spins the image
/// layer — the GPU composites the rotation, so per-frame CPU is zero. Tier number sits in a
/// sibling layer that does NOT inherit the rotation transform.
@MainActor
final class OuroborosView: NSView {
    private let snakeLayer = CALayer()
    private let numberLayer = CATextLayer()
    private var currentTier: Int = -1
    private var currentImageSize: CGSize = .zero

    /// Number of tiers mapped onto `liveRate / medianRate`. Tier 1 = baseline (idle slow spin),
    /// tier 10 = max RPS (max color). Each tier picks a distinct rotation speed AND a distinct
    /// interpolated color along the idle → warm → hot ramp.
    static let tierCount = 10
    static let idleColor = Theme.accentBlue
    static let warmColor = Theme.accentMint
    static let hotColor = Theme.accentRed
    static let baseRPS: CGFloat = 0.10
    static let maxRPS: CGFloat = 1.50

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.frame = bounds
        layer?.shadowRadius = 4
        layer?.shadowOpacity = 0.45
        layer?.shadowOffset = .zero

        snakeLayer.frame = bounds
        snakeLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        snakeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        snakeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(snakeLayer)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        numberLayer.contentsScale = scale
        numberLayer.alignmentMode = .center
        numberLayer.font = NSFont.boldSystemFont(ofSize: 10) as CTFont
        numberLayer.fontSize = 10
        numberLayer.foregroundColor = NSColor.white.cgColor
        // Subtle dark shadow so the number stays legible against any tier color.
        numberLayer.shadowColor = NSColor.black.cgColor
        numberLayer.shadowOpacity = 0.85
        numberLayer.shadowRadius = 1.5
        numberLayer.shadowOffset = .zero
        layoutNumberLayer()
        layer?.addSublayer(numberLayer)

        applyTier(1)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
        snakeLayer.frame = bounds
        snakeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layoutNumberLayer()
        if bounds.size != currentImageSize {
            // Force a re-rasterize at the new size.
            currentTier = -1
            applyTier(max(1, currentTier))
        }
    }

    private func layoutNumberLayer() {
        let font = NSFont.boldSystemFont(ofSize: 10)
        let lineHeight = font.ascender - font.descender
        numberLayer.frame = CGRect(
            x: 0,
            y: (bounds.height - lineHeight) / 2,
            width: bounds.width,
            height: lineHeight
        )
    }

    /// Map `liveRate / medianRate` onto tiers 1...10. `liveRate <= medianRate` → tier 1.
    /// `liveRate >= medianRate * 3` → tier 10. Linear in between.
    func update(liveRate: Double, medianRate: Double) {
        let safeMedian = max(medianRate, 1)
        let ratio = max(0, liveRate / safeMedian)
        let normalized = min(1.0, max(0.0, (ratio - 1.0) / 2.0))
        let tier = max(1, min(Self.tierCount, 1 + Int(normalized * Double(Self.tierCount - 1) + 0.5)))
        applyTier(tier)
    }

    private func applyTier(_ tier: Int) {
        guard tier != currentTier || bounds.size != currentImageSize else { return }
        currentTier = tier
        currentImageSize = bounds.size

        let t = CGFloat(tier - 1) / CGFloat(max(1, Self.tierCount - 1))
        let rps = Self.baseRPS + (Self.maxRPS - Self.baseRPS) * t
        let color = Self.colorFor(tier: tier)

        // Render once at the current size + color. Result is cached in the layer's `contents`
        // until the tier or size changes again.
        let image = renderSnakeImage(color: color, size: bounds.size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snakeLayer.contents = image
        layer?.shadowColor = color.cgColor
        layer?.shadowRadius = 3 + 5 * t
        numberLayer.string = "\(tier)"
        numberLayer.foregroundColor = contrastTextColor(forBackground: color).cgColor
        CATransaction.commit()

        installRotation(rps: rps)
    }

    private func installRotation(rps: CGFloat) {
        snakeLayer.removeAnimation(forKey: "spin")
        let rot = CABasicAnimation(keyPath: "transform.rotation.z")
        rot.fromValue = 0
        rot.toValue = -2 * Double.pi
        rot.duration = 1.0 / Double(rps)
        rot.repeatCount = .infinity
        rot.isRemovedOnCompletion = false
        snakeLayer.add(rot, forKey: "spin")
    }

    private static func colorFor(tier: Int) -> NSColor {
        let t = CGFloat(tier - 1) / CGFloat(max(1, tierCount - 1))
        if t < 0.5 {
            return lerp(idleColor, warmColor, t * 2)
        }
        return lerp(warmColor, hotColor, (t - 0.5) * 2)
    }

    private func contrastTextColor(forBackground color: NSColor) -> NSColor {
        // Compute relative luminance (sRGB) and pick black on light backgrounds, white on dark.
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = rgb.redComponent
        let g = rgb.greenComponent
        let b = rgb.blueComponent
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return lum > 0.6 ? .black : .white
    }

    private func renderSnakeImage(color: NSColor, size: CGSize) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let nsImage = NSImage(size: size, flipped: false) { [color] _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2 - 1
            Self.drawSnake(in: ctx, center: center, radius: radius, color: color)
            return true
        }
        var rect = CGRect(origin: .zero, size: size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: - Drawing (pure, called once per tier transition)

    private static func drawSnake(in ctx: CGContext, center: CGPoint, radius: CGFloat, color: NSColor) {
        let mainColor = color
        let highlightColor = color.blended(withFraction: 0.45, of: .white) ?? color
        let darkColor = color.blended(withFraction: 0.45, of: .black) ?? color
        let glowColor = color.withAlphaComponent(0.55)

        let mouthGap: CGFloat = 0.34
        let bodyStart: CGFloat = mouthGap
        let bodyEnd: CGFloat = 2 * .pi - mouthGap * 0.55

        let outerHead: CGFloat = radius * 0.78
        let outerTail: CGFloat = radius * 0.96
        let innerHead: CGFloat = radius * 0.42
        let innerTail: CGFloat = radius * 0.78

        // Outer glow halo
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 6, color: glowColor.cgColor)
        let haloPath = CGMutablePath()
        haloPath.addArc(
            center: center,
            radius: (outerHead + outerTail) / 2,
            startAngle: bodyStart,
            endAngle: bodyEnd,
            clockwise: false
        )
        ctx.addPath(haloPath)
        ctx.setStrokeColor(mainColor.withAlphaComponent(0.0).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()

        // Body
        let bodyPath = CGMutablePath()
        let steps = 56
        for i in 0 ... steps {
            let t = CGFloat(i) / CGFloat(steps)
            let angle = bodyStart + t * (bodyEnd - bodyStart)
            let radial = lerp(outerTail, outerHead, t)
            let p = CGPoint(x: center.x + radial * cos(angle), y: center.y + radial * sin(angle))
            i == 0 ? bodyPath.move(to: p) : bodyPath.addLine(to: p)
        }
        for i in 0 ... steps {
            let t = CGFloat(i) / CGFloat(steps)
            let angle = bodyEnd - t * (bodyEnd - bodyStart)
            let radial = lerp(innerHead, innerTail, t)
            let p = CGPoint(x: center.x + radial * cos(angle), y: center.y + radial * sin(angle))
            bodyPath.addLine(to: p)
        }
        bodyPath.closeSubpath()

        ctx.addPath(bodyPath)
        ctx.setFillColor(mainColor.cgColor)
        ctx.fillPath()

        // Inner highlight rim
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        let highlightPath = CGMutablePath()
        for i in 0 ... steps {
            let t = CGFloat(i) / CGFloat(steps)
            let angle = bodyStart + t * (bodyEnd - bodyStart)
            let radial = lerp(outerTail, outerHead, t) - 1.2
            let p = CGPoint(x: center.x + radial * cos(angle), y: center.y + radial * sin(angle))
            i == 0 ? highlightPath.move(to: p) : highlightPath.addLine(to: p)
        }
        ctx.addPath(highlightPath)
        ctx.setStrokeColor(highlightColor.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1.2)
        ctx.strokePath()
        ctx.restoreGState()

        // Scale ridges
        ctx.setLineWidth(0.4)
        ctx.setStrokeColor(darkColor.withAlphaComponent(0.55).cgColor)
        let scaleCount = 16
        for i in 0 ..< scaleCount {
            let t = CGFloat(i) / CGFloat(scaleCount - 1)
            let angle = bodyStart + t * (bodyEnd - bodyStart)
            let inner = lerp(innerHead, innerTail, 1 - t)
            let outer = lerp(outerHead, outerTail, 1 - t)
            ctx.move(to: CGPoint(x: center.x + (inner + 0.5) * cos(angle), y: center.y + (inner + 0.5) * sin(angle)))
            ctx.addLine(to: CGPoint(x: center.x + (outer - 0.5) * cos(angle), y: center.y + (outer - 0.5) * sin(angle)))
            ctx.strokePath()
        }

        // Body outline
        ctx.addPath(bodyPath)
        ctx.setLineWidth(0.6)
        ctx.setStrokeColor(darkColor.withAlphaComponent(0.7).cgColor)
        ctx.strokePath()

        // Head
        let headAngle = bodyEnd
        let headRadial = (outerHead + innerHead) / 2
        let headCenter = CGPoint(x: center.x + headRadial * cos(headAngle), y: center.y + headRadial * sin(headAngle))
        let headSize: CGFloat = (outerHead - innerHead) * 0.62

        ctx.setFillColor(mainColor.cgColor)
        ctx.beginPath()
        ctx.addEllipse(in: CGRect(
            x: headCenter.x - headSize, y: headCenter.y - headSize,
            width: headSize * 2, height: headSize * 2
        ))
        ctx.fillPath()

        ctx.setLineWidth(0.5)
        ctx.setStrokeColor(darkColor.cgColor)
        ctx.beginPath()
        ctx.addEllipse(in: CGRect(
            x: headCenter.x - headSize, y: headCenter.y - headSize,
            width: headSize * 2, height: headSize * 2
        ))
        ctx.strokePath()

        // Tail + mouth
        let tailAngle = bodyStart
        let tailRadial = (outerTail + innerTail) / 2
        let tailCenter = CGPoint(x: center.x + tailRadial * cos(tailAngle), y: center.y + tailRadial * sin(tailAngle))

        let toTail = CGPoint(x: tailCenter.x - headCenter.x, y: tailCenter.y - headCenter.y)
        let toTailLen = max(hypot(toTail.x, toTail.y), 0.001)
        let toTailNorm = CGPoint(x: toTail.x / toTailLen, y: toTail.y / toTailLen)
        let perp = CGPoint(x: -toTailNorm.y, y: toTailNorm.x)
        let biteDepth = headSize * 1.05
        let biteWidth = headSize * 0.55

        let mouthPath = CGMutablePath()
        mouthPath.move(to: headCenter)
        mouthPath.addLine(to: CGPoint(
            x: headCenter.x + toTailNorm.x * biteDepth + perp.x * biteWidth,
            y: headCenter.y + toTailNorm.y * biteDepth + perp.y * biteWidth
        ))
        mouthPath.addLine(to: CGPoint(
            x: headCenter.x + toTailNorm.x * biteDepth - perp.x * biteWidth,
            y: headCenter.y + toTailNorm.y * biteDepth - perp.y * biteWidth
        ))
        mouthPath.closeSubpath()
        ctx.addPath(mouthPath)
        ctx.setFillColor(NSColor(calibratedWhite: 0.05, alpha: 0.9).cgColor)
        ctx.fillPath()

        // Eye
        let eyeCenter = CGPoint(
            x: headCenter.x - toTailNorm.x * headSize * 0.08 + perp.x * headSize * 0.45,
            y: headCenter.y - toTailNorm.y * headSize * 0.08 + perp.y * headSize * 0.45
        )
        let eyeSize: CGFloat = max(0.6, headSize * 0.32)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.beginPath()
        ctx.addEllipse(in: CGRect(
            x: eyeCenter.x - eyeSize,
            y: eyeCenter.y - eyeSize,
            width: eyeSize * 2,
            height: eyeSize * 2
        ))
        ctx.fillPath()
        let pupilSize = eyeSize * 0.55
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.beginPath()
        ctx.addEllipse(in: CGRect(
            x: eyeCenter.x - pupilSize, y: eyeCenter.y - pupilSize,
            width: pupilSize * 2, height: pupilSize * 2
        ))
        ctx.fillPath()

        // Tail wedge
        let tailTip = CGPoint(
            x: tailCenter.x - cos(tailAngle) * (outerTail - innerTail) * 0.45,
            y: tailCenter.y - sin(tailAngle) * (outerTail - innerTail) * 0.45
        )
        let tailFlare = CGPoint(x: -sin(tailAngle), y: cos(tailAngle))
        let tailWidth: CGFloat = (outerTail - innerTail) * 0.22
        let tailPath = CGMutablePath()
        tailPath.move(to: tailTip)
        tailPath.addLine(to: CGPoint(
            x: tailCenter.x + tailFlare.x * tailWidth,
            y: tailCenter.y + tailFlare.y * tailWidth
        ))
        tailPath.addLine(to: CGPoint(
            x: tailCenter.x - tailFlare.x * tailWidth,
            y: tailCenter.y - tailFlare.y * tailWidth
        ))
        tailPath.closeSubpath()
        ctx.addPath(tailPath)
        ctx.setFillColor(darkColor.cgColor)
        ctx.fillPath()
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    private static func lerp(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let clamped = max(0, min(1, t))
        return a.blended(withFraction: clamped, of: b) ?? b
    }
}

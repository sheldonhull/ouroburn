import AppKit
import QuartzCore

/// Animated ouroboros for the menu bar.
///
/// Renders a coiled snake biting its tail using a tapered body of varying thickness (head fat,
/// tail thin), an open mouth wedge, an eye, and a tail tip clamped in the mouth. Idle color is
/// a bright neon cyan with a subtle glow so the icon stays legible against any menu bar wallpaper;
/// it heats toward amber and then rose as the burn rate climbs.
@MainActor
final class OuroborosView: NSView {
    private var displayLink: CVDisplayLink?
    private var phase: CGFloat = 0
    private var rotationsPerSecond: CGFloat = 0.10
    private var bodyColor: NSColor = OuroborosView.idleColor
    private var glowColor: NSColor = OuroborosView.idleColor.withAlphaComponent(0.55)
    private var lastTickTime: CFTimeInterval = CACurrentMediaTime()
    private var lastDrawTime: CFTimeInterval = 0
    /// Cap redraws to ~30 fps. Doubling the budget over the displayLink rate is invisible to the
    /// user but halves the main-thread cost of geometric ouroboros drawing.
    private let frameInterval: CFTimeInterval = 1.0 / 30.0

    static let idleColor = Theme.accentBlue
    static let warmColor = Theme.accentMint
    static let hotColor = Theme.accentRed
    static let baseRPS: CGFloat = 0.10
    static let maxRPS: CGFloat = 1.50
    static let spikeMultiplier: CGFloat = 1.30  // live > median * spikeMultiplier kicks the ramp

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = bodyColor.cgColor
        layer?.shadowRadius = 4
        layer?.shadowOpacity = 0.45
        layer?.shadowOffset = .zero
        startAnimating()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    /// Drive the rotation + color from the live vs. median rate.
    ///
    /// Below the spike multiplier (live ≤ median × 1.30) the snake holds a slow base spin so
    /// it always reads as "running". Above that, rotation and color ramp up linearly until
    /// the live rate is twice the spike threshold, where it pegs at hot red.
    func update(liveRate: Double, medianRate: Double) {
        let safeMedian = max(medianRate, 1)
        let ratio = max(0, liveRate / safeMedian)
        if ratio <= Double(Self.spikeMultiplier) {
            rotationsPerSecond = Self.baseRPS
            bodyColor = Self.idleColor
        } else {
            let t = min(1, (ratio - Double(Self.spikeMultiplier)) / Double(Self.spikeMultiplier))
            rotationsPerSecond = Self.baseRPS + (Self.maxRPS - Self.baseRPS) * CGFloat(t)
            bodyColor = t < 0.5
                ? Self.lerp(Self.idleColor, Self.warmColor, CGFloat(t * 2))
                : Self.lerp(Self.warmColor, Self.hotColor, CGFloat((t - 0.5) * 2))
        }
        glowColor = bodyColor.withAlphaComponent(0.55)
        layer?.shadowColor = bodyColor.cgColor
        layer?.shadowRadius = 3 + 5 * CGFloat(min(1, max(0, (ratio - Double(Self.spikeMultiplier)) / Double(Self.spikeMultiplier))))
        needsDisplay = true
    }

    func stopAnimating() {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
            self.displayLink = nil
        }
    }

    private func startAnimating() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        displayLink = link
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let view = Unmanaged<OuroborosView>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { view.tick() }
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = max(0, now - lastTickTime)
        lastTickTime = now
        phase += rotationsPerSecond * CGFloat(dt) * (2 * .pi)
        if phase > 2 * .pi { phase -= 2 * .pi }
        // Throttle invalidation: at 60Hz CVDisplayLink, only mark dirty every other frame.
        if now - lastDrawTime >= frameInterval {
            lastDrawTime = now
            needsDisplay = true
        }
    }

    override func draw(_: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 1

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: phase)
        ctx.translateBy(x: -center.x, y: -center.y)
        drawSnake(in: ctx, center: center, radius: radius)
        ctx.restoreGState()
    }

    private func drawSnake(in ctx: CGContext, center: CGPoint, radius: CGFloat) {
        let mainColor = bodyColor
        let highlightColor = bodyColor.blended(withFraction: 0.45, of: .white) ?? bodyColor
        let darkColor = bodyColor.blended(withFraction: 0.45, of: .black) ?? bodyColor

        let mouthGap: CGFloat = 0.34
        let bodyStart: CGFloat = mouthGap
        let bodyEnd: CGFloat = 2 * .pi - mouthGap * 0.55

        let outerHead: CGFloat = radius * 0.78
        let outerTail: CGFloat = radius * 0.96
        let innerHead: CGFloat = radius * 0.42
        let innerTail: CGFloat = radius * 0.78

        // Outer glow halo — soft larger pass, drawn first.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 6, color: glowColor.cgColor)
        let haloPath = CGMutablePath()
        haloPath.addArc(center: center, radius: (outerHead + outerTail) / 2, startAngle: bodyStart,
                        endAngle: bodyEnd, clockwise: false)
        ctx.addPath(haloPath)
        ctx.setStrokeColor(mainColor.withAlphaComponent(0.0).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()

        // Body path
        let bodyPath = CGMutablePath()
        let steps = 56
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let angle = bodyStart + t * (bodyEnd - bodyStart)
            let radial = lerp(outerTail, outerHead, t)
            let p = CGPoint(x: center.x + radial * cos(angle), y: center.y + radial * sin(angle))
            i == 0 ? bodyPath.move(to: p) : bodyPath.addLine(to: p)
        }
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let angle = bodyEnd - t * (bodyEnd - bodyStart)
            let radial = lerp(innerHead, innerTail, t)
            let p = CGPoint(x: center.x + radial * cos(angle), y: center.y + radial * sin(angle))
            bodyPath.addLine(to: p)
        }
        bodyPath.closeSubpath()

        // Body fill with vertical sheen via two-pass (fill, then alpha-blended highlight)
        ctx.addPath(bodyPath)
        ctx.setFillColor(mainColor.cgColor)
        ctx.fillPath()

        // Inner highlight rim along the outside edge for a glassy neon feel.
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        let highlightPath = CGMutablePath()
        for i in 0...steps {
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

        // Scale ridges along the spine
        ctx.setLineWidth(0.4)
        ctx.setStrokeColor(darkColor.withAlphaComponent(0.55).cgColor)
        let scaleCount = 16
        for i in 0..<scaleCount {
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

        // Tail tip + mouth
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

        // Eye on the head
        let eyeCenter = CGPoint(
            x: headCenter.x - toTailNorm.x * headSize * 0.08 + perp.x * headSize * 0.45,
            y: headCenter.y - toTailNorm.y * headSize * 0.08 + perp.y * headSize * 0.45
        )
        let eyeSize: CGFloat = max(0.6, headSize * 0.32)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.beginPath()
        ctx.addEllipse(in: CGRect(x: eyeCenter.x - eyeSize, y: eyeCenter.y - eyeSize, width: eyeSize * 2, height: eyeSize * 2))
        ctx.fillPath()
        let pupilSize = eyeSize * 0.55
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.beginPath()
        ctx.addEllipse(in: CGRect(
            x: eyeCenter.x - pupilSize, y: eyeCenter.y - pupilSize,
            width: pupilSize * 2, height: pupilSize * 2
        ))
        ctx.fillPath()

        // Tail wedge held in the mouth
        let tailTip = CGPoint(
            x: tailCenter.x - cos(tailAngle) * (outerTail - innerTail) * 0.45,
            y: tailCenter.y - sin(tailAngle) * (outerTail - innerTail) * 0.45
        )
        let tailFlare = CGPoint(x: -sin(tailAngle), y: cos(tailAngle))
        let tailWidth: CGFloat = (outerTail - innerTail) * 0.22
        let tailPath = CGMutablePath()
        tailPath.move(to: tailTip)
        tailPath.addLine(to: CGPoint(x: tailCenter.x + tailFlare.x * tailWidth, y: tailCenter.y + tailFlare.y * tailWidth))
        tailPath.addLine(to: CGPoint(x: tailCenter.x - tailFlare.x * tailWidth, y: tailCenter.y - tailFlare.y * tailWidth))
        tailPath.closeSubpath()
        ctx.addPath(tailPath)
        ctx.setFillColor(darkColor.cgColor)
        ctx.fillPath()
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    private static func lerp(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let clamped = max(0, min(1, t))
        return a.blended(withFraction: clamped, of: b) ?? b
    }
}

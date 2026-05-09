import AppKit

/// Sparkline of today's OAuth billing deltas. Filters samples to the local day, smooths
/// neighbours, and renders a Catmull-Rom curve with a hover tooltip.
@MainActor
final class OAuthHeartbeatView: NSView {
    fileprivate struct Beat {
        let timestamp: Date
        let dollars: Double
        let smoothed: Double
        let mtd: Double
    }

    private var samples: [BillingSample] = []
    private var beats: [Beat] = []

    private let titleLabel = NSTextField(labelWithString: "")
    private let canvas = HeartbeatCanvas()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.cornerRadius = 12
        layer?.borderColor = Theme.divider.cgColor
        layer?.borderWidth = 1
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func update(samples raw: [BillingSample]) {
        let sorted = raw.sorted { $0.timestamp < $1.timestamp }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        // Keep one pre-midnight anchor so the first today-delta has a real baseline.
        let firstTodayIdx = sorted.firstIndex { $0.timestamp >= dayStart }
        let scoped: [BillingSample]
        if let firstTodayIdx, firstTodayIdx > 0 {
            scoped = Array(sorted[(firstTodayIdx - 1)...])
        } else if let firstTodayIdx {
            scoped = Array(sorted[firstTodayIdx...])
        } else {
            scoped = []
        }
        samples = scoped
        beats = Self.computeBeats(samples: samples, todayStart: dayStart)
        canvas.update(beats: beats)
        renderHeader()
    }

    private static func computeBeats(samples: [BillingSample], todayStart: Date) -> [Beat] {
        guard samples.count >= 2 else { return [] }
        var raw: [(Date, Double, Double)] = []
        raw.reserveCapacity(samples.count - 1)
        for i in 1 ..< samples.count {
            let prev = samples[i - 1]
            let curr = samples[i]
            guard curr.timestamp >= todayStart else { continue }
            raw.append((curr.timestamp, curr.totalUSD - prev.totalUSD, curr.totalUSD))
        }
        // Centred 3-tap moving average; endpoints unmodified so the latest beat stays sharp.
        var beats: [Beat] = []
        beats.reserveCapacity(raw.count)
        for (i, point) in raw.enumerated() {
            let smoothed: Double
            if i == 0 || i == raw.count - 1 {
                smoothed = point.1
            } else {
                smoothed = (raw[i - 1].1 + point.1 + raw[i + 1].1) / 3
            }
            beats.append(Beat(timestamp: point.0, dollars: point.1, smoothed: smoothed, mtd: point.2))
        }
        return beats
    }

    private func renderHeader() {
        titleLabel.attributedStringValue = Theme.glowAttributedTitle(
            "OAuth billing",
            color: Theme.accentMint,
            font: Theme.titleFont(size: 12)
        )
    }

    private func configureSubviews() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(canvas)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            canvas.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }
}

@MainActor
private final class HeartbeatCanvas: NSView {
    private var beats: [OAuthHeartbeatView.Beat] = []
    private var positions: [CGPoint] = []
    private var hoveredIndex: Int?
    private var trackingArea: NSTrackingArea?

    private let tooltip = HeartbeatTooltip()
    private var tooltipTopConstraint: NSLayoutConstraint?
    private var tooltipLeadingConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        tooltip.translatesAutoresizingMaskIntoConstraints = false
        tooltip.isHidden = true
        addSubview(tooltip)
        let top = tooltip.topAnchor.constraint(equalTo: topAnchor, constant: 4)
        let leading = tooltip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        tooltipTopConstraint = top
        tooltipLeadingConstraint = leading
        NSLayoutConstraint.activate([top, leading])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func update(beats next: [OAuthHeartbeatView.Beat]) {
        beats = next
        hoveredIndex = nil
        tooltip.isHidden = true
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseExited(with _: NSEvent) {
        hoveredIndex = nil
        tooltip.isHidden = true
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard !beats.isEmpty else { return }
        let position = convert(event.locationInWindow, from: nil)
        let plot = plotRect()
        guard plot.contains(position) else {
            hoveredIndex = nil
            tooltip.isHidden = true
            needsDisplay = true
            return
        }
        let stride = plot.width / CGFloat(max(beats.count - 1, 1))
        let idx = Int(round((position.x - plot.minX) / stride))
        let clamped = min(max(idx, 0), beats.count - 1)
        hoveredIndex = clamped
        tooltip.update(beat: beats[clamped], accent: accentColor())
        tooltip.isHidden = false
        positionTooltipNear(plotPoint: positions[safe: clamped] ?? .zero)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let plot = plotRect()
        positions = []

        drawZeroLine(in: ctx, rect: plot)
        guard beats.count >= 2 else {
            drawEmptyState(in: ctx, rect: plot)
            return
        }
        positions = computePositions(rect: plot)
        drawSparkline(in: ctx, rect: plot)
        if let hoveredIndex {
            drawHoverIndicator(in: ctx, rect: plot, index: hoveredIndex)
        }
    }

    private func plotRect() -> NSRect {
        bounds.insetBy(dx: 0, dy: 4)
    }

    private func drawZeroLine(in ctx: CGContext, rect: NSRect) {
        ctx.saveGState()
        ctx.setStrokeColor(Theme.divider.cgColor)
        ctx.setLineWidth(0.5)
        ctx.setLineDash(phase: 0, lengths: [2, 3])
        let y = rect.minY + 2
        ctx.move(to: CGPoint(x: rect.minX, y: y))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawEmptyState(in _: CGContext, rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.bodyFont(size: 10),
            .foregroundColor: Theme.textTertiary
        ]
        let label = "Waiting for samples…"
        let attributed = NSAttributedString(string: label, attributes: attrs)
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func computePositions(rect: NSRect) -> [CGPoint] {
        // $1 floor keeps placid periods from amplifying noise.
        let peak = max(beats.map { abs($0.smoothed) }.max() ?? 0, 1)
        let stride = rect.width / CGFloat(max(beats.count - 1, 1))
        return beats.enumerated().map { index, beat in
            let x = rect.minX + stride * CGFloat(index)
            let normalized = CGFloat(beat.smoothed / peak)
            let y = rect.minY + 2 + (rect.height - 4) * max(0, normalized)
            return CGPoint(x: x, y: y)
        }
    }

    private func drawSparkline(in ctx: CGContext, rect: NSRect) {
        let path = smoothPath(through: positions)
        let accent = accentColor()

        ctx.saveGState()
        let fill = path.mutableCopy() ?? CGMutablePath()
        fill.addLine(to: CGPoint(x: positions.last!.x, y: rect.minY))
        fill.addLine(to: CGPoint(x: positions.first!.x, y: rect.minY))
        fill.closeSubpath()
        ctx.addPath(fill)
        ctx.clip()
        let colors = [
            accent.withAlphaComponent(0.35).cgColor,
            accent.withAlphaComponent(0.04).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: rect.maxY),
                end: CGPoint(x: 0, y: rect.minY),
                options: []
            )
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 4, color: accent.withAlphaComponent(0.45).cgColor)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        if let tip = positions.last {
            ctx.setFillColor(accent.cgColor)
            ctx.fillEllipse(in: CGRect(x: tip.x - 2.5, y: tip.y - 2.5, width: 5, height: 5))
        }
    }

    /// Catmull-Rom curve through the points (tension 0.5).
    private func smoothPath(through points: [CGPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count < 3 {
            for p in points.dropFirst() { path.addLine(to: p) }
            return path
        }
        for i in 0 ..< points.count - 1 {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    private func drawHoverIndicator(in ctx: CGContext, rect: NSRect, index: Int) {
        guard index < positions.count else { return }
        let position = positions[index]
        let accent = accentColor()
        ctx.saveGState()
        ctx.setStrokeColor(Theme.textPrimary.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [2, 2])
        ctx.move(to: CGPoint(x: position.x, y: rect.minY))
        ctx.addLine(to: CGPoint(x: position.x, y: rect.maxY))
        ctx.strokePath()
        ctx.restoreGState()

        ctx.setFillColor(Theme.background.cgColor)
        ctx.fillEllipse(in: CGRect(x: position.x - 4, y: position.y - 4, width: 8, height: 8))
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.6)
        ctx.strokeEllipse(in: CGRect(x: position.x - 4, y: position.y - 4, width: 8, height: 8))
    }

    private func positionTooltipNear(plotPoint: CGPoint) {
        let size = tooltip.fittingSize
        let preferredX = min(max(plotPoint.x - size.width / 2, 4), bounds.width - size.width - 4)
        let preferredY: CGFloat = if plotPoint.y > bounds.height - size.height - 12 {
            plotPoint.y - size.height - 8
        } else {
            max(plotPoint.y + 8, 4)
        }
        tooltipTopConstraint?.constant = bounds.height - preferredY - size.height
        tooltipLeadingConstraint?.constant = preferredX
    }

    fileprivate func accentColor() -> NSColor {
        guard let last = beats.last else { return Theme.accentMint }
        let value = abs(last.dollars)
        if value > 5 { return Theme.accentRed }
        if value > 1 { return Theme.accentPeach }
        if value > 0.05 { return Theme.accentMint }
        return Theme.accentBlue
    }
}

@MainActor
private final class HeartbeatTooltip: NSView {
    private let timeLabel = NSTextField(labelWithString: "")
    private let deltaLabel = NSTextField(labelWithString: "")
    private let mtdLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = Theme.backgroundDeep.cgColor
        layer?.borderColor = Theme.divider.cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 8
        layer?.shadowOffset = .zero

        timeLabel.font = Theme.numericFont(size: 11)
        timeLabel.textColor = Theme.textPrimary
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        deltaLabel.font = Theme.numericFont(size: 11)
        deltaLabel.textColor = Theme.accentPeach
        deltaLabel.translatesAutoresizingMaskIntoConstraints = false

        mtdLabel.font = Theme.bodyFont(size: 10)
        mtdLabel.textColor = Theme.textSecondary
        mtdLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [timeLabel, deltaLabel, mtdLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220)
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func update(beat: OAuthHeartbeatView.Beat, accent: NSColor) {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d · HH:mm:ss"
        timeLabel.stringValue = formatter.string(from: beat.timestamp)
        deltaLabel.stringValue = String(format: "Δ $%.2f", beat.dollars)
        deltaLabel.textColor = accent
        mtdLabel.stringValue = String(format: "MTD $%.2f", beat.mtd)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

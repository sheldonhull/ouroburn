import AppKit

/// Sparkline of OAuth billing spend over a selectable range. Buckets the month-to-date sample
/// series into hourly (today), weekly (this month), or daily (this month) reset-aware spend, then
/// renders a Catmull-Rom curve with a hover tooltip. The active range follows whichever hero tile
/// the cursor is over; it defaults to the month.
@MainActor
final class OAuthHeartbeatView: NSView {
    enum Range {
        case today, week, month

        var title: String {
            switch self {
            case .today: "Today"
            case .week: "This week"
            case .month: "This month"
            }
        }
    }

    fileprivate struct Beat {
        let timestamp: Date
        let dollars: Double
        let smoothed: Double
        let mtd: Double
        /// Pre-formatted bucket span for the tooltip (e.g. "14:00–15:00", "Jun 3").
        let label: String
    }

    private var allSamples: [BillingSample] = []
    private var range: Range = .month
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
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    func update(samples raw: [BillingSample]) {
        allSamples = raw.sorted { $0.timestamp < $1.timestamp }
        rebuild()
    }

    /// Switch the displayed range (driven by hero-tile hover). No-op when unchanged.
    func setRange(_ next: Range) {
        guard next != range else { return }
        range = next
        rebuild()
    }

    private func rebuild() {
        beats = Self.buildBeats(samples: allSamples, range: range, now: Date(), calendar: .current)
        canvas.update(beats: beats)
        renderHeader()
    }

    /// One beat per time bucket, each carrying that bucket's reset-aware OAuth spend. Bucketing:
    /// hourly across today, weekly across the current month, or one bar per day of the month.
    private static func buildBeats(
        samples: [BillingSample],
        range: Range,
        now: Date,
        calendar: Calendar
    ) -> [Beat] {
        let buckets = Self.buckets(for: range, now: now, calendar: calendar)
        var raw: [(date: Date, spend: Double, label: String)] = []
        raw.reserveCapacity(buckets.count)
        for bucket in buckets {
            guard bucket.start <= now else { break } // skip future buckets
            // `oauthSpend` is reset-aware (skips the negative step a billing-cycle rollover or a
            // transient trough produces), so per-bucket spend never goes negative.
            let spend = BurnTracker.oauthSpend(
                samples: samples,
                since: bucket.start,
                now: min(bucket.end, now)
            ) ?? 0
            raw.append((bucket.start, spend, bucket.label))
        }
        // Centred 3-tap moving average for a smooth curve; endpoints unmodified. `mtd` carries the
        // running cumulative across the range so the tooltip can show spend-to-here.
        var beats: [Beat] = []
        beats.reserveCapacity(raw.count)
        var cumulative = 0.0
        for (i, point) in raw.enumerated() {
            cumulative += point.spend
            let smoothed: Double = if i == 0 || i == raw.count - 1 {
                point.spend
            } else {
                (raw[i - 1].spend + point.spend + raw[i + 1].spend) / 3
            }
            beats.append(Beat(
                timestamp: point.date,
                dollars: point.spend,
                smoothed: smoothed,
                mtd: cumulative,
                label: point.label
            ))
        }
        return beats
    }

    /// `(start, end, label)` buckets for the range. Today → 24 hourly; month → one per day of the
    /// current month; week → one bar per week overlapping the current month (Sunday-aligned).
    private static func buckets(
        for range: Range,
        now: Date,
        calendar: Calendar
    ) -> [(start: Date, end: Date, label: String)] {
        var cal = calendar
        cal.firstWeekday = 1
        let fmt = DateFormatter()
        switch range {
        case .today:
            let dayStart = cal.startOfDay(for: now)
            fmt.dateFormat = "HH:mm"
            return (0 ..< 24).compactMap { hour in
                guard let start = cal.date(byAdding: .hour, value: hour, to: dayStart),
                      let end = cal.date(byAdding: .hour, value: 1, to: start) else { return nil }
                return (start, end, "\(fmt.string(from: start))–\(fmt.string(from: end))")
            }
        case .month:
            guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)),
                  let range = cal.range(of: .day, in: .month, for: now) else { return [] }
            fmt.dateFormat = "MMM d"
            return range.compactMap { day in
                guard let start = cal.date(byAdding: .day, value: day - 1, to: monthStart),
                      let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
                return (start, end, fmt.string(from: start))
            }
        case .week:
            guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)),
                  let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) else { return [] }
            fmt.dateFormat = "MMM d"
            // Start on the Sunday on/before the 1st so the first week's partial days are included.
            let firstWeekStart = cal.date(
                byAdding: .day,
                value: -((cal.component(.weekday, from: monthStart) - cal.firstWeekday + 7) % 7),
                to: monthStart
            ) ?? monthStart
            var out: [(start: Date, end: Date, label: String)] = []
            var weekStart = firstWeekStart
            while weekStart < monthEnd {
                guard let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart) else { break }
                // Clamp to the month so the first/last bars only count in-month spend.
                let start = max(weekStart, monthStart)
                let end = min(weekEnd, monthEnd)
                out.append((start, end, "wk \(fmt.string(from: start))"))
                weekStart = weekEnd
            }
            return out
        }
    }

    private func renderHeader() {
        titleLabel.attributedStringValue = Theme.glowAttributedTitle(
            "OAuth billing · \(range.title)",
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
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

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
            for p in points.dropFirst() {
                path.addLine(to: p)
            }
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
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    func update(beat: OAuthHeartbeatView.Beat, accent: NSColor) {
        timeLabel.stringValue = beat.label
        deltaLabel.stringValue = NumberFormatting.compactDollars(beat.dollars)
        deltaLabel.textColor = accent
        mtdLabel.stringValue = "Σ \(NumberFormatting.compactDollars(beat.mtd))"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

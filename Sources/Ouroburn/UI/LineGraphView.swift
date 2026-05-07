import AppKit

/// Activity-over-time line graph for the popover. Hover snaps to the nearest data point and
/// shows a tooltip overlay with the bucket label, token count, cost, and the dominant session.
@MainActor
final class LineGraphView: NSView {
    private var points: [TimelinePoint] = []
    private var accentColor: NSColor = Theme.accentBlue
    private var trackingArea: NSTrackingArea?
    private var hoveredIndex: Int?
    private let tooltip = TooltipView()
    private var tooltipTopConstraint: NSLayoutConstraint?
    private var tooltipLeadingConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.cornerRadius = 12
        layer?.borderColor = Theme.divider.cgColor
        layer?.borderWidth = 1

        tooltip.translatesAutoresizingMaskIntoConstraints = false
        tooltip.isHidden = true
        addSubview(tooltip)
        let top = tooltip.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        let leading = tooltip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        tooltipTopConstraint = top
        tooltipLeadingConstraint = leading
        NSLayoutConstraint.activate([top, leading])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func update(points: [TimelinePoint], accent: NSColor) {
        self.points = points
        self.accentColor = accent
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
        guard !points.isEmpty else { return }
        let position = convert(event.locationInWindow, from: nil)
        let plotRect = plotArea()
        guard plotRect.contains(position) else {
            hoveredIndex = nil
            tooltip.isHidden = true
            needsDisplay = true
            return
        }
        let stride = plotRect.width / CGFloat(max(points.count - 1, 1))
        let idx = Int(round((position.x - plotRect.minX) / stride))
        let clamped = min(max(idx, 0), points.count - 1)
        hoveredIndex = clamped
        let point = points[clamped]
        tooltip.update(point: point, accent: accentColor)
        tooltip.isHidden = false
        positionTooltipNear(plotPoint: pointPosition(at: clamped))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let plotRect = plotArea()

        drawGrid(in: ctx, rect: plotRect)
        if points.isEmpty {
            drawEmptyMessage(in: ctx, rect: plotRect)
            return
        }
        drawAxisLabels(in: ctx, rect: plotRect)
        drawLine(in: ctx, rect: plotRect)
        if let hoveredIndex {
            drawHoverIndicator(in: ctx, rect: plotRect, index: hoveredIndex)
        }
    }

    private func plotArea() -> NSRect {
        bounds.insetBy(dx: 12, dy: 16)
    }

    private func pointPosition(at index: Int) -> CGPoint {
        let plotRect = plotArea()
        let max = maxTokens()
        let normalized = max > 0 ? CGFloat(points[index].tokens) / CGFloat(max) : 0
        let stride = plotRect.width / CGFloat(Swift.max(points.count - 1, 1))
        let x = plotRect.minX + stride * CGFloat(index)
        let y = plotRect.minY + (plotRect.height - 18) * normalized + 4
        return CGPoint(x: x, y: y)
    }

    private func maxTokens() -> Int {
        points.map(\.tokens).max() ?? 0
    }

    private func drawGrid(in ctx: CGContext, rect: NSRect) {
        ctx.saveGState()
        ctx.setStrokeColor(Theme.divider.cgColor)
        ctx.setLineWidth(0.5)
        ctx.setLineDash(phase: 0, lengths: [2, 3])
        let rows = 3
        for i in 0...rows {
            let y = rect.minY + CGFloat(i) * (rect.height - 12) / CGFloat(rows) + 4
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawEmptyMessage(in ctx: CGContext, rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.bodyFont(size: 11),
            .foregroundColor: Theme.textTertiary,
        ]
        let label: String
        if points.isEmpty {
            label = "No timeline data for this view."
        } else {
            label = "Empty timeline."
        }
        let attributed = NSAttributedString(string: label, attributes: attrs)
        let size = attributed.size()
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        attributed.draw(at: origin)
        _ = ctx
    }

    private func drawAxisLabels(in _: CGContext, rect: NSRect) {
        guard points.count > 1 else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.bodyFont(size: 9),
            .foregroundColor: Theme.textTertiary,
        ]
        let max = maxTokens()
        let maxLabel = "\(BurnFormatting.compactTokens(max)) TK"
        NSAttributedString(string: maxLabel, attributes: attrs).draw(at: CGPoint(x: rect.minX, y: rect.maxY - 2))

        let firstStr = NSAttributedString(string: points.first?.label ?? "", attributes: attrs)
        firstStr.draw(at: CGPoint(x: rect.minX, y: rect.minY - 14))
        let lastStr = NSAttributedString(string: points.last?.label ?? "", attributes: attrs)
        let lastSize = lastStr.size()
        lastStr.draw(at: CGPoint(x: rect.maxX - lastSize.width, y: rect.minY - 14))
    }

    private func drawLine(in ctx: CGContext, rect: NSRect) {
        guard points.count > 1 else { return }
        let positions = (0..<points.count).map { pointPosition(at: $0) }

        // Filled gradient under the line
        let fillPath = CGMutablePath()
        fillPath.move(to: CGPoint(x: positions.first!.x, y: rect.minY))
        for p in positions { fillPath.addLine(to: p) }
        fillPath.addLine(to: CGPoint(x: positions.last!.x, y: rect.minY))
        fillPath.closeSubpath()
        ctx.saveGState()
        ctx.addPath(fillPath)
        ctx.clip()
        let colors = [
            accentColor.withAlphaComponent(0.45).cgColor,
            accentColor.withAlphaComponent(0.05).cgColor,
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

        // Line stroke
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 4, color: accentColor.withAlphaComponent(0.45).cgColor)
        ctx.setStrokeColor(accentColor.cgColor)
        ctx.setLineWidth(1.6)
        ctx.beginPath()
        ctx.move(to: positions[0])
        for p in positions.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
        ctx.restoreGState()

        // Data dots
        ctx.setFillColor(accentColor.cgColor)
        for p in positions {
            ctx.fillEllipse(in: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2))
        }
    }

    private func drawHoverIndicator(in ctx: CGContext, rect: NSRect, index: Int) {
        let position = pointPosition(at: index)
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
        ctx.setStrokeColor(accentColor.cgColor)
        ctx.setLineWidth(1.6)
        ctx.strokeEllipse(in: CGRect(x: position.x - 4, y: position.y - 4, width: 8, height: 8))
    }

    private func positionTooltipNear(plotPoint: CGPoint) {
        let preferredX = min(max(plotPoint.x - 60, 8), bounds.width - tooltip.fittingSize.width - 8)
        let preferredY: CGFloat
        if plotPoint.y > bounds.height - 60 {
            preferredY = plotPoint.y - tooltip.fittingSize.height - 12
        } else {
            preferredY = max(plotPoint.y + 8, 8)
        }
        // Anchor tooltip from top-left of view because subview frames flow that way.
        tooltipTopConstraint?.constant = bounds.height - preferredY - tooltip.fittingSize.height
        tooltipLeadingConstraint?.constant = preferredX
    }
}

@MainActor
private final class TooltipView: NSView {
    private let labelTitle = NSTextField(labelWithString: "")
    private let labelTokens = NSTextField(labelWithString: "")
    private let labelCost = NSTextField(labelWithString: "")
    private let labelSession = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = Theme.backgroundDeep.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.divider.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 8
        layer?.shadowOffset = .zero

        labelTitle.font = Theme.titleFont(size: 11)
        labelTitle.textColor = Theme.textPrimary
        labelTitle.translatesAutoresizingMaskIntoConstraints = false

        labelTokens.font = Theme.numericFont(size: 11)
        labelTokens.textColor = Theme.accentBlue
        labelTokens.translatesAutoresizingMaskIntoConstraints = false

        labelCost.font = Theme.numericFont(size: 11)
        labelCost.textColor = Theme.accentMint
        labelCost.translatesAutoresizingMaskIntoConstraints = false

        labelSession.font = Theme.bodyFont(size: 10)
        labelSession.textColor = Theme.textSecondary
        labelSession.translatesAutoresizingMaskIntoConstraints = false
        labelSession.lineBreakMode = .byTruncatingMiddle
        labelSession.maximumNumberOfLines = 1

        let stack = NSStackView(views: [labelTitle, labelTokens, labelCost, labelSession])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func update(point: TimelinePoint, accent: NSColor) {
        labelTitle.stringValue = point.label
        labelTokens.stringValue = "\(BurnFormatting.compactTokens(point.tokens)) TK"
        labelTokens.textColor = accent
        labelCost.stringValue = String(format: "$%.2f", point.costUSD)
        if let session = point.topSession, point.topSessionTokens > 0 {
            labelSession.stringValue = "Top: \(prettify(session)) (\(BurnFormatting.compactTokens(point.topSessionTokens)) TK)"
            labelSession.isHidden = false
        } else {
            labelSession.stringValue = ""
            labelSession.isHidden = true
        }
    }

    private func prettify(_ session: String) -> String {
        // Sessions look like "<sanitized-project>/<sessionUUID>". The UUID alone is noise; show
        // the project segment plus a short suffix so it's identifiable but not overwhelming.
        let parts = session.split(separator: "/").map(String.init)
        guard let project = parts.first else { return session }
        let cleaned = project.replacingOccurrences(of: "-Users-", with: "~/")
        if let last = parts.last, last != project {
            return "\(cleaned) · \(last.prefix(8))"
        }
        return cleaned
    }
}

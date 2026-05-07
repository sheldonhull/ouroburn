import AppKit

/// Popover content. Hero panel, line graph, segmented mode selector, drill-down rows. Mode
/// switching uses the snapshot's pre-aggregated bucket map, so it never blocks the main thread
/// or shows a spinner past the cold first poll.
@MainActor
final class MetricsViewController: NSViewController {
    var onModeChange: ((ViewMode) -> Void)?

    private let headlineRate = NSTextField(labelWithString: "—")
    private let headlineSubrate = NSTextField(labelWithString: "")
    private let headlineCost = NSTextField(labelWithString: "—")
    private let medianBar = ProgressBar()
    private let todayTile = StatTile(title: "Today", symbol: "sun.max")
    private let weekTile = StatTile(title: "This week", symbol: "calendar")
    private let monthTile = StatTile(title: "This month", symbol: "creditcard")

    private let segmented = NSSegmentedControl()
    private let graphView = LineGraphView()
    private let graphSpinner = PaneSpinner(message: "Building timeline…")
    private let listSpinner = PaneSpinner(message: "Parsing transcripts…")
    private let refreshBanner = RefreshBanner()
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let billedTotalLabel = NSTextField(labelWithString: "")

    private var snapshot: TrackerSnapshot?
    private var lastRenderedMode: ViewMode = .day
    private var lastRenderedRowIDs: [String] = []
    private var expandedRowIDs = Set<String>()
    private var displayedMode: ViewMode = .day

    /// Hard cap on rows rendered into the popover. Session view alone can produce 1k+ rows;
    /// rebuilding that many NSViews on every snapshot pegs the main thread. Rows beyond this
    /// limit collapse into a single "+N more" footer row.
    private let rowRenderCap = 80

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 640))
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.background.cgColor
        view = root

        configureHero()
        configureSegmented()
        configureGraph()
        configureBody()
        configureFooter()
        configureRefreshBanner()

        renderEmptyState()
    }

    func setRefreshState(_ state: RefreshState) {
        refreshBanner.setState(state)
    }

    private func configureRefreshBanner() {
        refreshBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(refreshBanner)
        NSLayoutConstraint.activate([
            refreshBanner.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            refreshBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            refreshBanner.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -36),
        ])
    }

    func update(snapshot: TrackerSnapshot) {
        self.snapshot = snapshot
        if displayedMode == lastRenderedMode {
            // First render uses the snapshot's own mode; afterwards the user's selection wins.
            displayedMode = snapshot.mode
        }
        if let index = ViewMode.allCases.firstIndex(of: displayedMode) {
            segmented.selectedSegment = index
        }

        renderHero(snapshot: snapshot)
        renderGraph(snapshot: snapshot)
        renderListIfChanged(snapshot: snapshot)
        renderFooter(snapshot: snapshot)
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        let mode = ViewMode.allCases[sender.selectedSegment]
        guard mode != displayedMode else { return }
        displayedMode = mode
        onModeChange?(mode)
        // Local re-render off the snapshot we already have. Avoids a round-trip through the
        // tracker that would otherwise rebuild the entire main-thread view tree twice in a row.
        if let snapshot {
            renderGraph(snapshot: snapshot)
            renderListIfChanged(snapshot: snapshot, force: true)
        }
    }

    private func renderHero(snapshot: TrackerSnapshot) {
        let stale = snapshot.stale ? "  ·  loading…" : ""
        let median = snapshot.medianTokensPerMinute
        let live = snapshot.tokensPerMinute

        headlineRate.attributedStringValue = Theme.glowAttributedTitle(
            "\(BurnFormatting.compactTokens(Int(median))) TK/min",
            color: rateColor(rate: median),
            font: Theme.titleFont(size: 28)
        )
        headlineSubrate.stringValue = String(
            format: "median (rolling 30m) · live %@ TK/min%@",
            BurnFormatting.compactTokens(Int(live)), stale
        )
        headlineSubrate.font = Theme.bodyFont(size: 11)
        headlineSubrate.textColor = Theme.textTertiary

        headlineCost.attributedStringValue = Theme.glowAttributedTitle(
            String(format: "~$%.2f / hr", snapshot.costPerHour),
            color: Theme.accentMint,
            font: Theme.titleFont(size: 18)
        )

        medianBar.setProgress(
            value: min(median, 5000) / 5000,
            tint: rateColor(rate: median)
        )

        todayTile.update(
            tokens: snapshot.todayTokens,
            costUSD: snapshot.todayCostUSD,
            accent: Theme.accentBlue,
            placeholder: snapshot.stale && snapshot.todayTokens == 0
        )
        weekTile.update(
            tokens: snapshot.weekTokens,
            costUSD: snapshot.weekCostUSD,
            accent: Theme.accentMint,
            placeholder: snapshot.stale && snapshot.weekTokens == 0
        )
        monthTile.update(
            tokens: snapshot.monthTokens,
            costUSD: snapshot.monthCostUSD,
            accent: Theme.accentPeach,
            placeholder: snapshot.stale && snapshot.monthTokens == 0
        )

        if let billed = snapshot.billedMonthUSD {
            billedTotalLabel.isHidden = false
            billedTotalLabel.attributedStringValue = Theme.glowAttributedTitle(
                String(format: "Anthropic billed MTD: $%.2f", billed),
                color: Theme.accentLime,
                font: Theme.titleFont(size: 11)
            )
        } else {
            billedTotalLabel.stringValue = "Set CLAUDE_OAUTH_TOKEN (Enterprise) or ANTHROPIC_ADMIN_API_KEY for billed MTD"
            billedTotalLabel.font = Theme.bodyFont(size: 10)
            billedTotalLabel.textColor = Theme.textTertiary
            billedTotalLabel.isHidden = false
        }
    }

    private func renderGraph(snapshot: TrackerSnapshot) {
        let timeline = snapshot.timelinesByMode[displayedMode] ?? []
        graphView.update(points: timeline, accent: rateColor(rate: snapshot.medianTokensPerMinute))
        graphSpinner.setLoading(snapshot.stale && timeline.isEmpty)
    }

    private func renderFooter(snapshot: TrackerSnapshot) {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        footerLabel.stringValue = "Updated \(formatter.string(from: snapshot.updatedAt))   ·   60s poll · click row to expand"
    }

    private func renderListIfChanged(snapshot: TrackerSnapshot, force: Bool = false) {
        let buckets = snapshot.bucketsByMode[displayedMode] ?? []
        let ids = buckets.prefix(rowRenderCap).map(\.id)
        let same = ids == lastRenderedRowIDs && lastRenderedMode == displayedMode
        listSpinner.setLoading(snapshot.stale && buckets.isEmpty)
        if same && !force {
            updateRowsInPlace(buckets: buckets)
            return
        }
        lastRenderedMode = displayedMode
        lastRenderedRowIDs = ids
        renderRows(buckets)
    }

    private func configureHero() {
        headlineRate.translatesAutoresizingMaskIntoConstraints = false
        headlineSubrate.translatesAutoresizingMaskIntoConstraints = false
        headlineCost.translatesAutoresizingMaskIntoConstraints = false
        medianBar.translatesAutoresizingMaskIntoConstraints = false
        todayTile.translatesAutoresizingMaskIntoConstraints = false
        weekTile.translatesAutoresizingMaskIntoConstraints = false
        monthTile.translatesAutoresizingMaskIntoConstraints = false

        let rateStack = NSStackView(views: [headlineRate, headlineSubrate])
        rateStack.orientation = .vertical
        rateStack.alignment = .leading
        rateStack.spacing = 0
        rateStack.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [rateStack, NSView(), headlineCost])
        topRow.orientation = .horizontal
        topRow.alignment = .firstBaseline
        topRow.distribution = .fill
        topRow.spacing = 12
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let tileRow = NSStackView(views: [todayTile, weekTile, monthTile])
        tileRow.orientation = .horizontal
        tileRow.alignment = .top
        tileRow.distribution = .fillEqually
        tileRow.spacing = 10
        tileRow.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(topRow)
        view.addSubview(medianBar)
        view.addSubview(tileRow)

        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            topRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            topRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

            medianBar.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 10),
            medianBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            medianBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            medianBar.heightAnchor.constraint(equalToConstant: 6),

            tileRow.topAnchor.constraint(equalTo: medianBar.bottomAnchor, constant: 14),
            tileRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            tileRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            tileRow.heightAnchor.constraint(equalToConstant: 86),
        ])
    }

    private func configureSegmented() {
        segmented.segmentStyle = .texturedRounded
        segmented.trackingMode = .selectOne
        segmented.target = self
        segmented.action = #selector(segmentChanged(_:))
        segmented.translatesAutoresizingMaskIntoConstraints = false

        segmented.segmentCount = ViewMode.allCases.count
        for (index, mode) in ViewMode.allCases.enumerated() {
            segmented.setLabel(mode.title, forSegment: index)
            if let symbol = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: mode.title) {
                segmented.setImage(symbol, forSegment: index)
                segmented.setImageScaling(.scaleProportionallyDown, forSegment: index)
            }
        }
        segmented.selectedSegment = 0
        view.addSubview(segmented)

        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: monthTile.bottomAnchor, constant: 18),
            segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            segmented.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
        ])
    }

    private func configureGraph() {
        graphView.translatesAutoresizingMaskIntoConstraints = false
        graphSpinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(graphView)
        view.addSubview(graphSpinner)
        NSLayoutConstraint.activate([
            graphView.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 12),
            graphView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            graphView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            graphView.heightAnchor.constraint(equalToConstant: 130),

            graphSpinner.centerXAnchor.constraint(equalTo: graphView.centerXAnchor),
            graphSpinner.centerYAnchor.constraint(equalTo: graphView.centerYAnchor),
        ])
    }

    private func configureBody() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 12, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false

        document.addSubview(stack)
        view.addSubview(scrollView)
        listSpinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(listSpinner)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            scrollView.topAnchor.constraint(equalTo: graphView.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),

            listSpinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            listSpinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    private func configureFooter() {
        footerLabel.font = Theme.bodyFont(size: 10)
        footerLabel.textColor = Theme.textTertiary
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        billedTotalLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footerLabel)
        view.addSubview(billedTotalLabel)

        NSLayoutConstraint.activate([
            footerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            footerLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),

            billedTotalLabel.leadingAnchor.constraint(greaterThanOrEqualTo: footerLabel.trailingAnchor, constant: 12),
            billedTotalLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            billedTotalLabel.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor),

            scrollView.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -8),
        ])
    }

    private func renderRows(_ buckets: [AggregateBucket]) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        if buckets.isEmpty { renderEmptyState(); return }
        let visible = Array(buckets.prefix(rowRenderCap))
        for bucket in visible {
            let row = BucketRowView(bucket: bucket, expanded: expandedRowIDs.contains(bucket.id))
            row.onToggle = { [weak self] id in
                guard let self else { return }
                if expandedRowIDs.contains(id) { expandedRowIDs.remove(id) }
                else { expandedRowIDs.insert(id) }
                if let snapshot = self.snapshot { renderListIfChanged(snapshot: snapshot, force: true) }
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        }
        if buckets.count > rowRenderCap {
            let overflow = makeOverflowRow(hidden: buckets.count - rowRenderCap)
            stack.addArrangedSubview(overflow)
            overflow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        }
    }

    private func updateRowsInPlace(buckets: [AggregateBucket]) {
        // Same id list, same mode — only the underlying tokens/cost numbers may have moved.
        // We rebuild rather than mutate-in-place because BucketRowView is single-shot today,
        // but cap the work to the visible window so it stays cheap.
        renderRows(buckets)
    }

    private func makeOverflowRow(hidden: Int) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        row.layer?.backgroundColor = Theme.surface.cgColor
        row.layer?.borderColor = Theme.divider.cgColor
        row.layer?.borderWidth = 1
        let label = NSTextField(labelWithString: "+ \(hidden) more rows hidden — narrow the view by switching modes.")
        label.font = Theme.bodyFont(size: 11)
        label.textColor = Theme.textTertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
        ])
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func renderEmptyState() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.surface.cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderColor = Theme.divider.cgColor
        container.layer?.borderWidth = 1
        container.translatesAutoresizingMaskIntoConstraints = false

        let symbol = NSImageView()
        if let image = NSImage(systemSymbolName: "flame", accessibilityDescription: nil) {
            symbol.image = image
            symbol.contentTintColor = Theme.accentBlue
            symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .light)
        }
        symbol.translatesAutoresizingMaskIntoConstraints = false

        let empty = NSTextField(wrappingLabelWithString:
            "No usage in this view yet. Once Claude Code writes a transcript line under " +
            "~/.claude/projects/, it will appear here.")
        empty.font = Theme.bodyFont(size: 12)
        empty.textColor = Theme.textSecondary
        empty.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(symbol)
        container.addSubview(empty)
        NSLayoutConstraint.activate([
            symbol.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            symbol.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            empty.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            empty.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 12),
            empty.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            empty.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        stack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
    }

    private func rateColor(rate: Double) -> NSColor {
        switch rate {
        case 0..<800: Theme.accentBlue
        case 800..<2_000: Theme.accentMint
        case 2_000..<3_500: Theme.accentPeach
        default: Theme.accentRed
        }
    }
}

extension ViewMode {
    var symbolName: String {
        switch self {
        case .day: "calendar"
        case .week: "calendar.badge.clock"
        case .month: "square.grid.3x3.fill"
        case .sessionBlock: "clock.arrow.circlepath"
        case .session: "person.crop.circle.badge.clock"
        }
    }
}

@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class StatTile: NSView {
    private let title: NSTextField
    private let cost = NSTextField(labelWithString: "—")
    private let tokens = NSTextField(labelWithString: "—")
    private let symbolView = NSImageView()
    private let symbolName: String

    init(title: String, symbol: String) {
        self.title = NSTextField(labelWithString: title.uppercased())
        self.symbolName = symbol
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.divider.cgColor
        layer?.borderWidth = 1
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func update(tokens tokenCount: Int, costUSD: Double, accent: NSColor, placeholder: Bool = false) {
        if placeholder {
            cost.attributedStringValue = Theme.glowAttributedTitle(
                "—",
                color: Theme.textTertiary,
                font: Theme.titleFont(size: 18)
            )
            tokens.stringValue = "loading…"
            tokens.font = Theme.bodyFont(size: 11)
            tokens.textColor = Theme.textTertiary
        } else {
            cost.attributedStringValue = Theme.glowAttributedTitle(
                String(format: "$%.2f", costUSD),
                color: accent,
                font: Theme.titleFont(size: 18)
            )
            tokens.stringValue = "\(BurnFormatting.compactTokens(tokenCount)) TK"
            tokens.font = Theme.numericFont(size: 11)
            tokens.textColor = Theme.textSecondary
        }
        symbolView.contentTintColor = accent
        layer?.shadowColor = accent.cgColor
        layer?.shadowRadius = 6
        layer?.shadowOpacity = placeholder ? 0.05 : 0.18
        layer?.shadowOffset = .zero
    }

    private func configureSubviews() {
        title.font = Theme.bodyFont(size: 10)
        title.textColor = Theme.textTertiary
        title.translatesAutoresizingMaskIntoConstraints = false

        cost.translatesAutoresizingMaskIntoConstraints = false
        tokens.translatesAutoresizingMaskIntoConstraints = false

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            symbolView.image = image
            symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        }
        symbolView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(title)
        addSubview(symbolView)
        addSubview(cost)
        addSubview(tokens)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            symbolView.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            symbolView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            symbolView.widthAnchor.constraint(equalToConstant: 18),
            symbolView.heightAnchor.constraint(equalToConstant: 18),

            cost.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            cost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            tokens.topAnchor.constraint(equalTo: cost.bottomAnchor, constant: 2),
            tokens.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tokens.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ])
    }
}

@MainActor
private final class ProgressBar: NSView {
    private let track = NSView()
    private let fill = NSView()
    private var fillWidthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.wantsLayer = true
        track.layer?.backgroundColor = Theme.surface.cgColor
        track.layer?.cornerRadius = 3
        track.translatesAutoresizingMaskIntoConstraints = false
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 3
        fill.layer?.backgroundColor = Theme.accentBlue.cgColor
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(track)
        track.addSubview(fill)
        let widthC = fill.widthAnchor.constraint(equalToConstant: 0)
        fillWidthConstraint = widthC
        NSLayoutConstraint.activate([
            track.topAnchor.constraint(equalTo: topAnchor),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            widthC,
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func setProgress(value: Double, tint: NSColor) {
        let trackWidth = max(track.bounds.width, bounds.width)
        fillWidthConstraint?.constant = trackWidth * CGFloat(min(max(value, 0), 1))
        fill.layer?.backgroundColor = tint.cgColor
        fill.layer?.shadowColor = tint.cgColor
        fill.layer?.shadowRadius = 4
        fill.layer?.shadowOpacity = 0.6
        fill.layer?.shadowOffset = .zero
    }
}

@MainActor
private final class BucketRowView: NSView {
    var onToggle: ((String) -> Void)?

    private let bucket: AggregateBucket
    private let expanded: Bool

    init(bucket: AggregateBucket, expanded: Bool) {
        self.bucket = bucket
        self.expanded = expanded
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = Theme.divider.cgColor
        layer?.backgroundColor = (bucket.isActive ? Theme.surfaceMuted : Theme.surface).cgColor
        configure()

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    @objc private func handleClick() {
        onToggle?(bucket.id)
    }

    private func configure() {
        let primaryColor: NSColor = bucket.isGap ? Theme.textTertiary
            : (bucket.isActive ? Theme.accentMint : Theme.textPrimary)

        let titleString = bucket.isGap ? "— gap —"
            : (bucket.isActive ? "● \(bucket.key)" : bucket.key)
        let title = NSTextField(labelWithString: titleString)
        title.font = Theme.titleFont(size: 13)
        title.textColor = primaryColor
        title.lineBreakMode = .byTruncatingMiddle
        if !bucket.isGap, bucket.isActive {
            title.attributedStringValue = Theme.glowAttributedTitle(titleString, color: primaryColor, font: Theme.titleFont(size: 13))
        }
        title.translatesAutoresizingMaskIntoConstraints = false

        let tokens = NSTextField(labelWithString: "\(BurnFormatting.compactTokens(bucket.totalTokens)) TK")
        tokens.font = Theme.numericFont(size: 12)
        tokens.textColor = Theme.textSecondary
        tokens.translatesAutoresizingMaskIntoConstraints = false

        let cost = NSTextField(labelWithString: String(format: "$%.2f", bucket.costUSD))
        cost.font = Theme.numericFont(size: 12)
        cost.textColor = Theme.accentMint
        cost.translatesAutoresizingMaskIntoConstraints = false

        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                                accessibilityDescription: nil)
        chevron.contentTintColor = Theme.textTertiary
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let summary = NSStackView(views: [tokens, cost, chevron])
        summary.orientation = .horizontal
        summary.spacing = 12
        summary.alignment = .centerY
        summary.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [title, NSView(), summary])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        if expanded {
            let expansion = makeExpansionView()
            expansion.translatesAutoresizingMaskIntoConstraints = false
            addSubview(expansion)
            NSLayoutConstraint.activate([
                expansion.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 8),
                expansion.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                expansion.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                expansion.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            ])
        } else {
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10).isActive = true
        }
    }

    private func makeExpansionView() -> NSView {
        let container = NSView()
        let header = NSTextField(labelWithString: "Models")
        header.font = Theme.bodyFont(size: 10)
        header.textColor = Theme.textTertiary
        header.translatesAutoresizingMaskIntoConstraints = false

        let modelStack = NSStackView()
        modelStack.orientation = .vertical
        modelStack.alignment = .leading
        modelStack.spacing = 4
        modelStack.translatesAutoresizingMaskIntoConstraints = false

        if bucket.models.isEmpty {
            let empty = NSTextField(labelWithString: "No model details for this bucket.")
            empty.font = Theme.bodyFont(size: 11)
            empty.textColor = Theme.textTertiary
            modelStack.addArrangedSubview(empty)
        } else {
            for (index, model) in bucket.models.enumerated() {
                modelStack.addArrangedSubview(makeModelRow(model: model, index: index))
            }
        }

        container.addSubview(header)
        container.addSubview(modelStack)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            modelStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            modelStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            modelStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            modelStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func makeModelRow(model: ModelBreakdown, index: Int) -> NSView {
        let palette = [Theme.accentBlue, Theme.accentMint, Theme.accentPeach, Theme.accentLime]
        let color = palette[index % palette.count]

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: BurnFormatting.shortModel(model.model))
        label.font = Theme.titleFont(size: 11)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(labelWithString: String(
            format: "in %@ · out %@ · cache %@/%@",
            BurnFormatting.compactTokens(model.inputTokens),
            BurnFormatting.compactTokens(model.outputTokens),
            BurnFormatting.compactTokens(model.cacheCreationTokens),
            BurnFormatting.compactTokens(model.cacheReadTokens)
        ))
        detail.font = Theme.bodyFont(size: 10)
        detail.textColor = Theme.textTertiary
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.lineBreakMode = .byTruncatingMiddle

        let amount = NSTextField(labelWithString: "\(BurnFormatting.compactTokens(model.totalTokens)) TK · $\(String(format: "%.2f", model.costUSD))")
        amount.font = Theme.numericFont(size: 11)
        amount.textColor = Theme.textSecondary
        amount.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(dot)
        row.addSubview(label)
        row.addSubview(detail)
        row.addSubview(amount)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),

            label.topAnchor.constraint(equalTo: row.topAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),

            amount.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            amount.trailingAnchor.constraint(equalTo: row.trailingAnchor),

            detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }
}

enum BurnFormatting {
    static func compactTokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: "\(count)"
        case ..<1_000_000: String(format: "%.1fk", Double(count) / 1_000)
        default: String(format: "%.2fM", Double(count) / 1_000_000)
        }
    }

    static func shortModel(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "anthropic/", with: "")
        return stripped
            .replacingOccurrences(of: "-20", with: " 20")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

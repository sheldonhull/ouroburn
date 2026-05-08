import AppKit

/// Popover content. Hero panel, line graph, segmented mode selector, drill-down rows. Mode
/// switching uses the snapshot's pre-aggregated bucket map, so it never blocks the main thread
/// or shows a spinner past the cold first poll.
@MainActor
final class MetricsViewController: NSViewController {
    var onModeChange: ((ViewMode) -> Void)?
    var onLoginClick: (() -> Void)?
    var onMonthlyTileClick: (() -> Void)?

    private let headlineRate = NSTextField(labelWithString: "—")
    private let headlineSubrate = NSTextField(labelWithString: "")
    private let headlineCost = NSTextField(labelWithString: "—")
    private let medianBar = ProgressBar()
    private let todayTile = StatTile(title: "Today", symbol: "sun.max")
    private let weekTile = StatTile(title: "This week", symbol: "calendar")
    private let monthTile = StatTile(title: "This month", symbol: "creditcard")

    private let segmented = NSSegmentedControl()
    private let heartbeatView = OAuthHeartbeatView()
    private let heartbeatStore = BillingSampleStore()
    private let graphView = LineGraphView()
    private let graphSpinner = PaneSpinner(message: "Building timeline…")
    private let listSpinner = PaneSpinner(message: "Parsing transcripts…")
    private let refreshBanner = RefreshBanner()
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let billedTotalLabel = NSTextField(labelWithString: "")
    private let connectionButton = NSButton(title: "Disconnected", target: nil, action: nil)

    private var snapshot: TrackerSnapshot?
    private var lastRenderedMode: ViewMode = .day
    private var lastRenderedRowIDs: [String] = []
    private var expandedRowIDs = Set<String>()
    private var displayedMode: ViewMode = .day

    /// Hard cap on rows rendered into the popover. Session view alone can produce 1k+ rows;
    /// rebuilding that many NSViews on every snapshot pegs the main thread. Rows beyond this
    /// limit collapse into a single "+N more" footer row.
    private let rowRenderCap = 80

    /// Popover content size is pinned so that switching into Session view (whose long encoded
    /// project paths previously stretched the row labels) no longer reflows the popover frame.
    private static let contentSize = NSSize(width: 560, height: 640)

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.background.cgColor
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.contentSize.width),
            root.heightAnchor.constraint(equalToConstant: Self.contentSize.height)
        ])
        preferredContentSize = Self.contentSize

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

    enum ConnectionState: Equatable {
        case disconnected
        case authorizing
        case connected(spendUSD: Double?)
    }

    private var connectionState: ConnectionState = .disconnected

    func setConnectionState(_ state: ConnectionState) {
        connectionState = state
        applyConnectionStyle()
    }

    private func applyConnectionStyle() {
        let symbolName: String
        let color: NSColor
        let enabled: Bool
        let tooltip: String
        switch connectionState {
        case .disconnected:
            symbolName = "xmark.circle.fill"
            color = Theme.accentRed
            enabled = true
            tooltip = "Disconnected — click to sign in"
        case .authorizing:
            symbolName = "ellipsis.circle.fill"
            color = Theme.accentPeach
            enabled = false
            tooltip = "Authorizing…"
        case let .connected(spendUSD):
            symbolName = "checkmark.circle.fill"
            color = Theme.accentMint
            enabled = true
            tooltip = spendUSD.map { String(format: "Connected · $%.2f MTD — click to sign out", $0) }
                ?? "Connected · fetching MTD"
        }
        connectionButton.title = ""
        connectionButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: tooltip
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        connectionButton.contentTintColor = color
        connectionButton.isEnabled = enabled
        connectionButton.toolTip = tooltip
        if let layer = connectionButton.layer {
            Theme.applyGhostRim(layer, color: color, rimAlpha: 0.32, glowRadius: 10, glowAlpha: 0.45)
        }
    }

    @objc private func connectionButtonClicked(_: Any?) {
        onLoginClick?()
    }

    private func configureRefreshBanner() {
        refreshBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(refreshBanner)
        // Pin the spinner inline at the bottom-left footer so it stops covering the segmented
        // control / hero numbers while a poll is in flight.
        NSLayoutConstraint.activate([
            refreshBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            refreshBanner.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
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
        renderHeartbeat()
        renderGraph(snapshot: snapshot)
        renderListIfChanged(snapshot: snapshot)
        renderFooter(snapshot: snapshot)
    }

    private func renderHeartbeat() {
        heartbeatView.update(samples: heartbeatStore.load())
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
        // Monthly tile prefers the upstream Anthropic OAuth spend when available — that's the
        // billed truth. Falls back to local-aggregate sum so the tile still has a number when
        // the user hasn't signed in yet.
        if let billed = snapshot.billedMonthUSD {
            monthTile.update(
                tokens: snapshot.monthTokens,
                costUSD: billed,
                accent: Theme.accentPeach,
                placeholder: false
            )
        } else {
            monthTile.update(
                tokens: snapshot.monthTokens,
                costUSD: snapshot.monthCostUSD,
                accent: Theme.accentPeach,
                placeholder: snapshot.stale && snapshot.monthTokens == 0
            )
        }

        // Connection button doubles as the spend label. Stays red when disconnected, flips to
        // mint with the dollar value once OAuth produces a number.
        let isStoredCredentialPresent = OAuthCredentialStore.load() != nil
        if !isStoredCredentialPresent, connectionState != .authorizing {
            setConnectionState(.disconnected)
        } else if isStoredCredentialPresent, connectionState != .authorizing {
            setConnectionState(.connected(spendUSD: snapshot.billedMonthUSD))
        }
    }

    private func renderGraph(snapshot: TrackerSnapshot) {
        let timeline = snapshot.timelinesByMode[displayedMode] ?? []
        let metric: LineGraphMetric = displayedMode == .session ? .cost : .tokens
        let accent = displayedMode == .session
            ? Theme.accentMint
            : rateColor(rate: snapshot.medianTokensPerMinute)
        graphView.update(points: timeline, accent: accent, metric: metric)
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
        if same, !force {
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
        monthTile.onClick = { [weak self] in self?.onMonthlyTileClick?() }
        monthTile.toolTip = "Click for sample-by-sample Anthropic spend history"

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
            tileRow.heightAnchor.constraint(equalToConstant: 86)
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
            segmented.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18)
        ])
    }

    private func configureGraph() {
        heartbeatView.translatesAutoresizingMaskIntoConstraints = false
        graphView.translatesAutoresizingMaskIntoConstraints = false
        graphSpinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(heartbeatView)
        view.addSubview(graphView)
        view.addSubview(graphSpinner)
        NSLayoutConstraint.activate([
            heartbeatView.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 10),
            heartbeatView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            heartbeatView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            heartbeatView.heightAnchor.constraint(equalToConstant: 170),

            graphView.topAnchor.constraint(equalTo: heartbeatView.bottomAnchor, constant: 8),
            graphView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            graphView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            graphView.heightAnchor.constraint(equalToConstant: 90),

            graphSpinner.centerXAnchor.constraint(equalTo: graphView.centerXAnchor),
            graphSpinner.centerYAnchor.constraint(equalTo: graphView.centerYAnchor)
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
            listSpinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
    }

    private func configureFooter() {
        footerLabel.isHidden = true
        billedTotalLabel.isHidden = true
        connectionButton.translatesAutoresizingMaskIntoConstraints = false
        connectionButton.isBordered = false
        connectionButton.bezelStyle = .smallSquare
        connectionButton.imagePosition = .imageOnly
        connectionButton.target = self
        connectionButton.action = #selector(connectionButtonClicked(_:))
        connectionButton.wantsLayer = true
        connectionButton.layer?.cornerRadius = 12
        connectionButton.layer?.backgroundColor = Theme.surface.withAlphaComponent(0.55).cgColor
        view.addSubview(connectionButton)

        NSLayoutConstraint.activate([
            connectionButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            connectionButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            connectionButton.widthAnchor.constraint(equalToConstant: 24),
            connectionButton.heightAnchor.constraint(equalToConstant: 24),

            scrollView.bottomAnchor.constraint(equalTo: connectionButton.topAnchor, constant: -8)
        ])
    }

    private func renderRows(_ buckets: [AggregateBucket]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view); view.removeFromSuperview()
        }
        if buckets.isEmpty { renderEmptyState(); return }
        if displayedMode == .session {
            renderSessionTree(buckets)
            return
        }
        let visible = Array(buckets.prefix(rowRenderCap))
        for bucket in visible {
            appendBucketRow(bucket: bucket)
        }
        if buckets.count > rowRenderCap {
            appendOverflowRow(hidden: buckets.count - rowRenderCap)
        }
    }

    /// Session view: collapse the shared path segments into a single dim header and group
    /// buckets by project so each repo appears once with its sessions indented underneath.
    private func renderSessionTree(_ buckets: [AggregateBucket]) {
        struct Item { let bucket: AggregateBucket; let segments: [String]; let session: String }

        let items: [Item] = buckets.compactMap { bucket in
            guard let split = ProjectPath.splitSessionBucketID(bucket.id) else { return nil }
            return Item(
                bucket: bucket,
                segments: ProjectPath.segments(split.project),
                session: split.session
            )
        }
        guard !items.isEmpty else {
            for bucket in buckets.prefix(rowRenderCap) {
                appendBucketRow(bucket: bucket)
            }
            return
        }

        let prefix = ProjectPath.commonPrefixLeavingTail(items.map(\.segments))
        if !prefix.isEmpty {
            appendPrefixHeader(prefix: prefix)
        }

        var groupTails: [String: [String]] = [:]
        var groupItems: [String: [Item]] = [:]
        var groupLatest: [String: Date] = [:]
        for item in items {
            let tail = Array(item.segments.dropFirst(prefix.count))
            let key = tail.joined(separator: "/")
            groupTails[key] = tail
            groupItems[key, default: []].append(item)
            // Items already arrive sorted by latest end first (Aggregator.groupBySession),
            // so the first bucket per group also carries the group's most recent activity.
            if groupLatest[key] == nil {
                groupLatest[key] = item.bucket.end ?? item.bucket.start ?? .distantPast
            }
        }
        // Order projects by most-recent activity desc so the active repo always floats to top
        // on every refresh.
        let sortedKeys = groupItems.keys.sorted { lhs, rhs in
            (groupLatest[lhs] ?? .distantPast) > (groupLatest[rhs] ?? .distantPast)
        }

        var rendered = 0
        for key in sortedKeys {
            guard let tail = groupTails[key] else { continue }
            let group = groupItems[key] ?? []
            appendProjectHeader(tail: tail, sessionCount: group.count)
            for item in group {
                if rendered >= rowRenderCap { break }
                appendBucketRow(bucket: item.bucket, displayKey: shortSession(item.session), indent: 18)
                rendered += 1
            }
            if rendered >= rowRenderCap { break }
        }
        if items.count > rendered {
            appendOverflowRow(hidden: items.count - rendered)
        }
    }

    private func appendBucketRow(bucket: AggregateBucket, displayKey: String? = nil, indent: CGFloat = 0) {
        let row = BucketRowView(
            bucket: bucket,
            expanded: expandedRowIDs.contains(bucket.id),
            displayKey: displayKey
        )
        row.onToggle = { [weak self] id in
            guard let self else { return }
            if expandedRowIDs.contains(id) { expandedRowIDs.remove(id) }
            else { expandedRowIDs.insert(id) }
            if let snapshot { renderListIfChanged(snapshot: snapshot, force: true) }
        }
        if indent > 0 {
            let wrapper = IndentedContainer(child: row, leading: indent)
            stack.addArrangedSubview(wrapper)
            wrapper.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        } else {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        }
    }

    private func appendPrefixHeader(prefix: [String]) {
        let label = NSTextField(labelWithString: ProjectPath.displayPath(prefix) + "/…")
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = Theme.textTertiary
        label.lineBreakMode = .byTruncatingHead
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -6),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -2)
        ])
        stack.addArrangedSubview(wrapper)
        wrapper.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
    }

    private func appendProjectHeader(tail: [String], sessionCount: Int) {
        let title = NSTextField(labelWithString: tail.joined(separator: "/"))
        title.font = Theme.titleFont(size: 12)
        title.textColor = Theme.textSecondary
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false

        let count = NSTextField(labelWithString: "\(sessionCount)")
        count.font = Theme.numericFont(size: 10)
        count.textColor = Theme.textTertiary
        count.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [title, NSView(), count])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 6),
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -6),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -2)
        ])
        stack.addArrangedSubview(wrapper)
        wrapper.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
    }

    private func appendOverflowRow(hidden: Int) {
        let overflow = makeOverflowRow(hidden: hidden)
        stack.addArrangedSubview(overflow)
        overflow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
    }

    private func shortSession(_ id: String) -> String {
        guard id.count > 12 else { return id }
        let head = id.prefix(8)
        let tail = id.suffix(4)
        return "\(head)…\(tail)"
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
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10)
        ])
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func renderEmptyState() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view); view.removeFromSuperview()
        }
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
            empty.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        stack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
    }

    private func rateColor(rate: Double) -> NSColor {
        switch rate {
        case 0 ..< 800: Theme.accentBlue
        case 800 ..< 2000: Theme.accentMint
        case 2000 ..< 3500: Theme.accentPeach
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
    override var isFlipped: Bool {
        true
    }
}

@MainActor
private final class IndentedContainer: NSView {
    init(child: NSView, leading: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: topAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            child.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }
}

@MainActor
final class StatTile: NSView {
    var onClick: (() -> Void)?

    private let title: NSTextField
    private let cost = NSTextField(labelWithString: "—")
    private let tokens = NSTextField(labelWithString: "—")
    private let symbolView = NSImageView()
    private let symbolName: String

    init(title: String, symbol: String) {
        self.title = NSTextField(labelWithString: title.uppercased())
        symbolName = symbol
        super.init(frame: .zero)
        wantsLayer = true
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
        layer?.cornerRadius = 12
        layer?.backgroundColor = Theme.surface.withAlphaComponent(0.65).cgColor
        // Ghost rim — tinted outline + soft outer halo. Accent color is overridden in
        // `update(...)` so the tile glows with whatever the snapshot just set.
        Theme.applyGhostRim(layer!, color: Theme.accentBlue, rimAlpha: 0.22, glowRadius: 10, glowAlpha: 0.20)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    @objc private func handleClick() { onClick?() }

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
        if let layer {
            // Re-tint the ghost rim every update so today/week/month each glow in their own
            // accent without losing the soft halo treatment.
            Theme.applyGhostRim(
                layer,
                color: accent,
                rimAlpha: placeholder ? 0.10 : 0.32,
                glowRadius: 12,
                glowAlpha: placeholder ? 0.08 : 0.30
            )
        }
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
            tokens.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
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
            widthC
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

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
    private let displayKey: String?

    init(bucket: AggregateBucket, expanded: Bool, displayKey: String? = nil) {
        self.bucket = bucket
        self.expanded = expanded
        self.displayKey = displayKey
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = (bucket.isActive ? Theme.surfaceMuted : Theme.surface)
            .withAlphaComponent(0.55).cgColor
        // Active rows glow brighter in mint (matches the active dot); inactive rows still get
        // a faint ghost rim so the row reads as a chip rather than a flat block.
        let rimColor: NSColor = bucket.isActive ? Theme.accentMint : Theme.accentBlue
        Theme.applyGhostRim(
            layer!,
            color: rimColor,
            rimAlpha: bucket.isActive ? 0.32 : 0.14,
            glowRadius: bucket.isActive ? 10 : 6,
            glowAlpha: bucket.isActive ? 0.28 : 0.10
        )
        configure()

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    @objc private func handleClick() {
        onToggle?(bucket.id)
    }

    private func configure() {
        let primaryColor: NSColor = bucket.isGap ? Theme.textTertiary
            : (bucket.isActive ? Theme.accentMint : Theme.textPrimary)

        let baseKey = displayKey ?? bucket.key
        let titleString = bucket.isGap ? "— gap —"
            : (bucket.isActive ? "● \(baseKey)" : baseKey)
        let title = NSTextField(labelWithString: titleString)
        title.font = Theme.titleFont(size: 13)
        title.textColor = primaryColor
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if !bucket.isGap, bucket.isActive {
            title.attributedStringValue = Theme.glowAttributedTitle(
                titleString,
                color: primaryColor,
                font: Theme.titleFont(size: 13)
            )
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
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
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
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])

        if expanded {
            let expansion = makeExpansionView()
            expansion.translatesAutoresizingMaskIntoConstraints = false
            addSubview(expansion)
            NSLayoutConstraint.activate([
                expansion.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 8),
                expansion.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                expansion.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                expansion.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
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
            modelStack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
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

        let amount =
            NSTextField(
                labelWithString: "\(BurnFormatting.compactTokens(model.totalTokens)) TK · $\(String(format: "%.2f", model.costUSD))"
            )
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
            detail.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }
}

enum BurnFormatting {
    static func compactTokens(_ count: Int) -> String {
        switch count {
        case ..<1000: "\(count)"
        case ..<1_000_000: String(format: "%.1fk", Double(count) / 1000)
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

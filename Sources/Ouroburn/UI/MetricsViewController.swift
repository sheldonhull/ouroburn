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
    private let topSessionsView = TopSessionsView()
    private let sectionDivider = SectionDivider()
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
    private var expandedProjectIDs = Set<String>()
    private var didAutoExpandTodayForMode: [ViewMode: Bool] = [:]
    private var displayedMode: ViewMode = .day
    private let pulseOrb = PulseOrb()

    /// Hard cap on rows rendered into the popover. Session view alone can produce 1k+ rows;
    /// rebuilding that many NSViews on every snapshot pegs the main thread. Rows beyond this
    /// limit collapse into a single "+N more" footer row.
    private let rowRenderCap = 80

    /// Popover content size is pinned so that switching into Session view (whose long encoded
    /// project paths previously stretched the row labels) no longer reflows the popover frame.
    private static let contentSize = NSSize(width: 580, height: 840)

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
        configurePriorityPanel()
        configureSegmented()
        configureGraph()
        configureBody()
        configureFooter()
        configureRefreshBanner()

        renderEmptyState()
    }

    func setRefreshState(_ state: RefreshState) {
        refreshBanner.setState(state)
        // Visual heartbeat: every poll cycle the tracker flips isRefreshing true → false.
        // Pulse on the rising edge so the user gets a single satisfying blip per cycle, not a
        // continuous animation.
        if state.isRefreshing { pulseOrb.pulse() }
    }

    enum ConnectionState: Equatable {
        /// No usable token anywhere (PKCE store, keychain, env). Click to sign in.
        case disconnected
        /// PKCE login flow in progress.
        case authorizing
        /// Token present, last fetch succeeded — optionally carries MTD spend.
        case connected(spendUSD: Double?)
        /// Token present but last fetch failed transiently (network, 5xx, rate-limit). Solid red,
        /// no blink — caller can still click to trigger sign-in if they want to swap accounts.
        case failingTransient(reason: String)
        /// Token present but rejected (401/403/404). Blinks red so the user notices the token is
        /// invalid and needs to be replaced.
        case authInvalid(reason: String)
    }

    private var connectionState: ConnectionState = .disconnected
    private static let blinkAnimationKey = "ouroburn.connection.blink"

    func setConnectionState(_ state: ConnectionState) {
        connectionState = state
        applyConnectionStyle()
    }

    private func applyConnectionStyle() {
        let symbolName: String
        let color: NSColor
        let enabled: Bool
        let tooltip: String
        var blink = false
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
            tooltip = spendUSD.map { "Connected · \(NumberFormatting.compactDollars($0)) MTD — click to sign out" }
                ?? "Connected · fetching MTD"
        case let .failingTransient(reason):
            symbolName = "exclamationmark.circle.fill"
            color = Theme.accentRed
            enabled = true
            tooltip = "Fetch failing: \(reason)"
        case let .authInvalid(reason):
            symbolName = "exclamationmark.octagon.fill"
            color = Theme.accentRed
            enabled = true
            tooltip = "Token rejected: \(reason) — click to sign in again"
            blink = true
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
        applyBlinkAnimation(enabled: blink)
    }

    private func applyBlinkAnimation(enabled: Bool) {
        guard let layer = connectionButton.layer else { return }
        if enabled {
            guard layer.animation(forKey: Self.blinkAnimationKey) == nil else { return }
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1.0
            blink.toValue = 0.25
            blink.duration = 0.55
            blink.autoreverses = true
            blink.repeatCount = .infinity
            blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(blink, forKey: Self.blinkAnimationKey)
        } else {
            layer.removeAnimation(forKey: Self.blinkAnimationKey)
            layer.opacity = 1.0
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
        renderTopSessions(snapshot: snapshot)
        renderGraph(snapshot: snapshot)
        renderListIfChanged(snapshot: snapshot)
        renderFooter(snapshot: snapshot)
    }

    /// Called when the popover transitions from hidden to shown. Re-renders the live priority
    /// panel from the snapshot we already hold so the user sees fresh data on every open without
    /// waiting for the next 60s tick.
    func popoverWillShow() {
        guard let snapshot else { return }
        renderHero(snapshot: snapshot)
        renderHeartbeat()
        renderTopSessions(snapshot: snapshot)
    }

    /// Live tick (~2s while popover open). Overlays the hero USD/hr with the rolling-60s value
    /// and re-ranks the top-5 sessions by current tokens/min. Replaces nothing in the buckets/
    /// timeline data — those still come from the 60s snapshot.
    func applyLive(snapshot live: LiveSnapshot) {
        // Hero USD/hr — only override when there's actual live activity, otherwise keep the 5-min
        // projected number from the latest snapshot.
        if live.tokensPerMinute > 0 {
            headlineCost.attributedStringValue = Theme.glowAttributedTitle(
                "\(NumberFormatting.compactRate(dollarsPerHour: live.costPerHour)) · live",
                color: Theme.accentMint,
                font: Theme.titleFont(size: 18)
            )
        }
        topSessionsView.applyLive(velocities: live.perSession)
    }

    private func renderHeartbeat() {
        heartbeatView.update(samples: heartbeatStore.load())
    }

    private func renderTopSessions(snapshot: TrackerSnapshot) {
        let buckets = snapshot.bucketsByMode[.session] ?? []
        topSessionsView.update(buckets: buckets)
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
            "\(NumberFormatting.compactTokens(Int(median))) tk/m",
            color: rateColor(rate: median),
            font: Theme.titleFont(size: 28)
        )
        headlineSubrate.stringValue = String(
            format: "median (rolling 30m) · live %@ tk/m%@",
            NumberFormatting.compactTokens(Int(live)), stale
        )
        headlineSubrate.font = Theme.bodyFont(size: 11)
        headlineSubrate.textColor = Theme.textTertiary

        headlineCost.attributedStringValue = Theme.glowAttributedTitle(
            NumberFormatting.compactRate(dollarsPerHour: snapshot.costPerHour),
            color: Theme.accentMint,
            font: Theme.titleFont(size: 18)
        )

        medianBar.setProgress(
            value: min(median, 5000) / 5000,
            tint: rateColor(rate: median)
        )

        // Cost prefers OAuth midnight-delta (billed truth); tokens stay JSONL since OAuth exposes
        // no token count.
        todayTile.update(
            tokens: snapshot.todayTokens,
            costUSD: snapshot.displayTodayCostUSD,
            accent: Theme.accentBlue,
            placeholder: snapshot.stale && snapshot.todayTokens == 0
        )
        // Cost prefers OAuth week delta (billed truth); tokens stay JSONL.
        weekTile.update(
            tokens: snapshot.weekTokens,
            costUSD: snapshot.displayWeekCostUSD,
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

        // Connection state derivation order:
        // 1. Mid-PKCE-flow always wins — never overwrite the spinner.
        // 2. If the last billing fetch produced a structured health, that's authoritative.
        // 3. Otherwise fall back to "do we have any token at all" (PKCE store, keychain, or env).
        guard connectionState != .authorizing else { return }
        let hasAnyToken = anyBillingTokenAvailable()
        if let health = lastBillingHealth {
            setConnectionState(connectionState(for: health, spendUSD: snapshot.billedMonthUSD))
        } else if hasAnyToken {
            setConnectionState(.connected(spendUSD: snapshot.billedMonthUSD))
        } else {
            setConnectionState(.disconnected)
        }
    }

    /// True when any of the billing backends has a usable token: PKCE store, keychain entry, or
    /// environment variable. The previous logic only looked at the PKCE store, so a manually
    /// pasted CLAUDE_OAUTH_TOKEN never lit the indicator green.
    private func anyBillingTokenAvailable() -> Bool {
        if OAuthCredentialStore.load() != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["CLAUDE_OAUTH_TOKEN"]?.isEmpty == false { return true }
        if env["ANTHROPIC_ADMIN_API_KEY"]?.isEmpty == false { return true }
        if let v = Keychain.read(account: SecretsAccount.claudeOAuth), !v.isEmpty { return true }
        if let v = Keychain.read(account: SecretsAccount.anthropicAdmin), !v.isEmpty { return true }
        return false
    }

    private var lastBillingHealth: BillingHealth?

    /// Latest structured health from the billing service. Called on the main thread (forwarded
    /// from `StatusBarController.applyBillingHealth`).
    func applyBillingHealth(_ health: BillingHealth) {
        lastBillingHealth = health
        guard connectionState != .authorizing else { return }
        let spend = snapshot?.billedMonthUSD
        setConnectionState(connectionState(for: health, spendUSD: spend))
    }

    private func connectionState(for health: BillingHealth, spendUSD: Double?) -> ConnectionState {
        switch health {
        case .unknown:
            return anyBillingTokenAvailable() ? .connected(spendUSD: spendUSD) : .disconnected
        case .tokenMissing:
            return .disconnected
        case .ok:
            return .connected(spendUSD: spendUSD)
        case let .authInvalid(code):
            return .authInvalid(reason: "HTTP \(code)")
        case let .rateLimited(retryAfterSeconds):
            let mins = Int(max(retryAfterSeconds / 60, 1))
            return .failingTransient(reason: "rate-limited (\(mins)m)")
        case let .transient(reason):
            return .failingTransient(reason: reason)
        }
    }

    private func renderGraph(snapshot: TrackerSnapshot) {
        let timeline = snapshot.timelinesByMode[displayedMode] ?? []
        let metric: LineGraphMetric = displayedMode == .session ? .cost : .tokens
        let accent = displayedMode == .session
            ? Theme.accentMint
            : rateColor(rate: snapshot.medianTokensPerMinute)
        graphView.update(points: timeline, accent: accent, metric: metric)
        // Pulse orb in the hero already signals "we're working" on every tick. The pane spinners
        // were redundant noise that camped on the popover whenever a mode had no data.
        graphSpinner.setLoading(false)
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
        // Spinner suppressed: pulse orb handles the "still working" signal, and the empty-state
        // card surfaces the "no data yet" message when buckets are genuinely empty.
        listSpinner.setLoading(false)
        autoExpandTodayIfNeeded(mode: displayedMode, buckets: buckets)
        if same, !force {
            updateRowsInPlace(buckets: buckets)
            return
        }
        lastRenderedMode = displayedMode
        lastRenderedRowIDs = ids
        renderRows(buckets)
    }

    /// First time we render a non-empty list for a given mode, expand the bucket that represents
    /// "today" (or the most-recent bucket as a proxy when no `start` date is on the bucket). This
    /// lines up with how the user actually reads the popover — they almost always want to drill
    /// into the current day on open without an extra click.
    private func autoExpandTodayIfNeeded(mode: ViewMode, buckets: [AggregateBucket]) {
        guard didAutoExpandTodayForMode[mode] != true, !buckets.isEmpty else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = buckets.first(where: { bucket in
            guard let start = bucket.start else { return false }
            return calendar.isDate(start, inSameDayAs: today)
        }) ?? buckets.first
        if let target {
            expandedRowIDs.insert(target.id)
        }
        didAutoExpandTodayForMode[mode] = true
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

        pulseOrb.translatesAutoresizingMaskIntoConstraints = false
        pulseOrb.toolTip = "Pulses on every refresh tick"

        let topRow = NSStackView(views: [rateStack, pulseOrb, NSView(), headlineCost])
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

        // Pinned below the section divider — drill-down controls live below the priority panel.
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: sectionDivider.bottomAnchor, constant: 10),
            segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            segmented.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18)
        ])
    }

    /// Top section: OAuth heartbeat (the most-watched live signal) + iStat-style top-5 sessions
    /// panel, separated from the drill-down rows by a divider. Both views refresh whenever the
    /// popover opens so the live region feels near-real-time without paying that cost in the
    /// background tick.
    private func configurePriorityPanel() {
        heartbeatView.translatesAutoresizingMaskIntoConstraints = false
        topSessionsView.translatesAutoresizingMaskIntoConstraints = false
        sectionDivider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(heartbeatView)
        view.addSubview(topSessionsView)
        view.addSubview(sectionDivider)

        NSLayoutConstraint.activate([
            heartbeatView.topAnchor.constraint(equalTo: monthTile.bottomAnchor, constant: 14),
            heartbeatView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            heartbeatView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            heartbeatView.heightAnchor.constraint(equalToConstant: 170),

            topSessionsView.topAnchor.constraint(equalTo: heartbeatView.bottomAnchor, constant: 8),
            topSessionsView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            topSessionsView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            topSessionsView.heightAnchor.constraint(equalToConstant: 130),

            sectionDivider.topAnchor.constraint(equalTo: topSessionsView.bottomAnchor, constant: 8),
            sectionDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            sectionDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            sectionDivider.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    private func configureGraph() {
        graphView.translatesAutoresizingMaskIntoConstraints = false
        graphSpinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(graphView)
        view.addSubview(graphSpinner)
        NSLayoutConstraint.activate([
            graphView.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
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
    /// buckets by project. Each project renders as a clickable summary row (chevron + summed
    /// tokens/cost) and stays collapsed by default; sessions only render when the user expands
    /// the project. Mirrors the day/week/month rows so users get one extra grouping layer.
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
            let totals = projectTotals(group.map(\.bucket))
            let isExpanded = expandedProjectIDs.contains(key)
            appendProjectGroupRow(
                key: key,
                tail: tail,
                sessionCount: group.count,
                totalTokens: totals.tokens,
                totalCost: totals.cost,
                anyActive: totals.anyActive,
                expanded: isExpanded
            )
            guard isExpanded else { continue }
            for item in group {
                if rendered >= rowRenderCap { break }
                appendBucketRow(bucket: item.bucket, displayKey: shortSession(item.session), indent: 18)
                rendered += 1
            }
            if rendered >= rowRenderCap { break }
        }
        let visibleSessions = sortedKeys.reduce(0) { acc, key in
            expandedProjectIDs.contains(key) ? acc + (groupItems[key]?.count ?? 0) : acc
        }
        if visibleSessions > rendered {
            appendOverflowRow(hidden: visibleSessions - rendered)
        }
    }

    private func projectTotals(_ buckets: [AggregateBucket]) -> (tokens: Int, cost: Double, anyActive: Bool) {
        var tokens = 0
        var cost = 0.0
        var active = false
        for bucket in buckets {
            tokens += bucket.totalTokens
            cost += bucket.costUSD
            if bucket.isActive { active = true }
        }
        return (tokens, cost, active)
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

    private func appendProjectGroupRow(
        key: String,
        tail: [String],
        sessionCount: Int,
        totalTokens: Int,
        totalCost: Double,
        anyActive: Bool,
        expanded: Bool
    ) {
        let row = ProjectGroupRowView(
            key: key,
            title: tail.joined(separator: "/"),
            sessionCount: sessionCount,
            totalTokens: totalTokens,
            totalCost: totalCost,
            anyActive: anyActive,
            expanded: expanded
        )
        row.onToggle = { [weak self] groupKey in
            guard let self else { return }
            if expandedProjectIDs.contains(groupKey) { expandedProjectIDs.remove(groupKey) }
            else { expandedProjectIDs.insert(groupKey) }
            if let snapshot { renderListIfChanged(snapshot: snapshot, force: true) }
        }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
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

    @objc private func handleClick() {
        onClick?()
    }

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
                NumberFormatting.compactDollars(costUSD),
                color: accent,
                font: Theme.titleFont(size: 18)
            )
            tokens.stringValue = "\(NumberFormatting.compactTokens(tokenCount)) tk"
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
        title.font = Theme.titleFont(size: 14)
        title.textColor = primaryColor
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if !bucket.isGap, bucket.isActive {
            title.attributedStringValue = Theme.glowAttributedTitle(
                titleString,
                color: primaryColor,
                font: Theme.titleFont(size: 14)
            )
        }
        title.translatesAutoresizingMaskIntoConstraints = false

        let tokens = NSTextField(labelWithString: "\(NumberFormatting.compactTokens(bucket.totalTokens)) tk")
        tokens.font = Theme.numericFont(size: 13)
        tokens.textColor = Theme.textSecondary
        tokens.translatesAutoresizingMaskIntoConstraints = false

        let cost = NSTextField(labelWithString: NumberFormatting.compactDollars(bucket.costUSD))
        cost.font = Theme.numericFont(size: 13)
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
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])

        if expanded {
            let expansion = makeExpansionView()
            expansion.translatesAutoresizingMaskIntoConstraints = false
            addSubview(expansion)
            NSLayoutConstraint.activate([
                expansion.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 10),
                expansion.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                expansion.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                expansion.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
            ])
        } else {
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12).isActive = true
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
            NumberFormatting.compactTokens(model.inputTokens),
            NumberFormatting.compactTokens(model.outputTokens),
            NumberFormatting.compactTokens(model.cacheCreationTokens),
            NumberFormatting.compactTokens(model.cacheReadTokens)
        ))
        detail.font = Theme.bodyFont(size: 10)
        detail.textColor = Theme.textTertiary
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.lineBreakMode = .byTruncatingMiddle

        let amount =
            NSTextField(
                labelWithString: "\(NumberFormatting.compactTokens(model.totalTokens)) tk · \(NumberFormatting.compactDollars(model.costUSD))"
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

/// iStat-style top-N panel showing the busiest sessions. Ranks current session-mode buckets by
/// cost descending — when slice 3 lands a tail-read live velocity, ranking swaps to tokens/min
/// in the trailing 60s window without any caller change.
@MainActor
private final class TopSessionsView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Top sessions")
    private let countLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No recent session activity.")

    private static let rowCap = 5
    /// Sessions whose last activity is older than this fall out of the live view. Keeps the panel
    /// from surfacing week-old sessions when the user just opened the popover for a quick glance.
    private static let recentActivityWindow: TimeInterval = 30 * 60

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = Theme.surface.withAlphaComponent(0.55).cgColor
        Theme.applyGhostRim(layer!, color: Theme.accentBlue, rimAlpha: 0.20, glowRadius: 8, glowAlpha: 0.18)
        configure()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    private func configure() {
        titleLabel.font = Theme.titleFont(size: 12)
        titleLabel.textColor = Theme.textSecondary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = Theme.bodyFont(size: 10)
        countLabel.textColor = Theme.textTertiary
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [titleLabel, NSView(), countLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = Theme.bodyFont(size: 11)
        emptyLabel.textColor = Theme.textTertiary
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        addSubview(header)
        addSubview(stack)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// Cached buckets from the last 60s snapshot. Used to re-render the panel when a live tick
    /// arrives without an intervening full snapshot.
    private var lastBuckets: [AggregateBucket] = []

    func update(buckets: [AggregateBucket]) {
        lastBuckets = buckets
        renderRanked(buckets: buckets, liveBySession: nil)
    }

    /// Live-tick override: re-rank by tokens-per-minute from the rolling 60s window. Falls back
    /// to bucket totals when a session has no live activity yet.
    func applyLive(velocities: [SessionVelocity]) {
        var liveBySession: [String: SessionVelocity] = [:]
        for velocity in velocities {
            let split = ProjectPath.splitSessionBucketID("\(velocity.projectPath)/\(velocity.sessionId)")
            let key = split.map { "\($0.project)/\($0.session)" }
                ?? "\(velocity.projectPath)/\(velocity.sessionId)"
            liveBySession[key] = velocity
        }
        renderRanked(buckets: lastBuckets, liveBySession: liveBySession)
    }

    private func renderRanked(
        buckets: [AggregateBucket],
        liveBySession: [String: SessionVelocity]?
    ) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view); view.removeFromSuperview()
        }

        struct Item {
            let bucket: AggregateBucket
            let segments: [String]
            let session: String
            var velocity: SessionVelocity?
        }
        let cutoff = Date().addingTimeInterval(-Self.recentActivityWindow)
        let items: [Item] = buckets.compactMap { bucket in
            guard let split = ProjectPath.splitSessionBucketID(bucket.id) else { return nil }
            let key = "\(split.project)/\(split.session)"
            let velocity = liveBySession?[key]
            // Keep sessions with live activity (any velocity row) OR a bucket that closed inside
            // the recent window. Drops anything older — the panel is a live signal, not a session
            // history view, so a week-old session with no live tail-reads must not surface here.
            let hasLive = (velocity?.tokensPerMinute ?? 0) > 0
            let recent = (bucket.end ?? .distantPast) >= cutoff
            guard hasLive || recent else { return nil }
            return Item(
                bucket: bucket,
                segments: ProjectPath.segments(split.project),
                session: split.session,
                velocity: velocity
            )
        }
        guard !items.isEmpty else {
            emptyLabel.isHidden = false
            countLabel.stringValue = ""
            return
        }
        emptyLabel.isHidden = true

        let prefix = ProjectPath.commonPrefixLeavingTail(items.map(\.segments))
        let ranked: [Item] = if liveBySession != nil {
            // Live mode: tokens/min desc first, then most-recent activity, then cost as final
            // tiebreaker. Sessions with zero live velocity but recent bucket activity still rank
            // by recency so the panel reads as "what's happening now".
            items.sorted { lhs, rhs in
                let l = lhs.velocity?.tokensPerMinute ?? 0
                let r = rhs.velocity?.tokensPerMinute ?? 0
                if l != r { return l > r }
                let le = lhs.bucket.end ?? .distantPast
                let re = rhs.bucket.end ?? .distantPast
                if le != re { return le > re }
                return lhs.bucket.costUSD > rhs.bucket.costUSD
            }
        } else {
            // No live snapshot yet (popover just opened): rank by recency so the top row is the
            // session that most recently wrote a transcript entry.
            items.sorted { lhs, rhs in
                let le = lhs.bucket.end ?? .distantPast
                let re = rhs.bucket.end ?? .distantPast
                if le != re { return le > re }
                return lhs.bucket.costUSD > rhs.bucket.costUSD
            }
        }

        let visible = Array(ranked.prefix(Self.rowCap))
        let isLive = liveBySession != nil
        countLabel.stringValue = isLive
            ? "live · top \(visible.count)"
            : (ranked.count > Self.rowCap
                ? "top \(visible.count) of \(ranked.count)"
                : "\(visible.count) shown")

        for (index, item) in visible.enumerated() {
            let tail = Array(item.segments.dropFirst(prefix.count))
            let projectName = tail.last ?? tail.joined(separator: "/")
            let row = TopSessionsRow(
                rank: index + 1,
                project: projectName,
                session: shortSession(item.session),
                tokens: item.bucket.totalTokens,
                cost: item.bucket.costUSD,
                liveTokensPerMinute: item.velocity?.tokensPerMinute,
                liveCostPerHour: item.velocity?.costPerHour,
                isActive: item.bucket.isActive || (item.velocity?.tokensPerMinute ?? 0) > 0
            )
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func shortSession(_ id: String) -> String {
        guard id.count > 12 else { return id }
        let head = id.prefix(8)
        let tail = id.suffix(4)
        return "\(head)…\(tail)"
    }
}

@MainActor
private final class TopSessionsRow: NSView {
    init(
        rank: Int,
        project: String,
        session: String,
        tokens: Int,
        cost: Double,
        liveTokensPerMinute: Double?,
        liveCostPerHour: Double?,
        isActive: Bool
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let primary: NSColor = isActive ? Theme.accentMint : Theme.textPrimary
        let rankLabel = NSTextField(labelWithString: "\(rank)")
        rankLabel.font = Theme.numericFont(size: 10)
        rankLabel.textColor = Theme.textTertiary
        rankLabel.translatesAutoresizingMaskIntoConstraints = false

        let projectField = NSTextField(labelWithString: isActive ? "● \(project)" : project)
        projectField.font = Theme.titleFont(size: 11)
        projectField.textColor = primary
        projectField.lineBreakMode = .byTruncatingMiddle
        projectField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        projectField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        projectField.translatesAutoresizingMaskIntoConstraints = false

        let sessionField = NSTextField(labelWithString: session)
        sessionField.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        sessionField.textColor = Theme.textTertiary
        sessionField.translatesAutoresizingMaskIntoConstraints = false

        // When a live tokens/min figure is available, prefer it over the static bucket total —
        // that's the whole point of the live tick: surface what's happening right now, not the
        // session's lifetime aggregate.
        let tokensText = if let tpm = liveTokensPerMinute, tpm > 0 {
            NumberFormatting.compactRate(tokensPerMinute: tpm)
        } else {
            "\(NumberFormatting.compactTokens(tokens)) tk"
        }
        let tokensField = NSTextField(labelWithString: tokensText)
        tokensField.font = Theme.numericFont(size: 11)
        tokensField.textColor = Theme.textSecondary
        tokensField.translatesAutoresizingMaskIntoConstraints = false

        let costText = if let cph = liveCostPerHour, cph > 0 {
            NumberFormatting.compactRate(dollarsPerHour: cph)
        } else {
            NumberFormatting.compactDollars(cost)
        }
        let costField = NSTextField(labelWithString: costText)
        costField.font = Theme.numericFont(size: 11)
        costField.textColor = Theme.accentMint
        costField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rankLabel)
        addSubview(projectField)
        addSubview(sessionField)
        addSubview(tokensField)
        addSubview(costField)

        NSLayoutConstraint.activate([
            rankLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            rankLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            rankLabel.widthAnchor.constraint(equalToConstant: 14),

            projectField.leadingAnchor.constraint(equalTo: rankLabel.trailingAnchor, constant: 6),
            projectField.centerYAnchor.constraint(equalTo: centerYAnchor),

            sessionField.leadingAnchor.constraint(equalTo: projectField.trailingAnchor, constant: 8),
            sessionField.centerYAnchor.constraint(equalTo: centerYAnchor),

            costField.trailingAnchor.constraint(equalTo: trailingAnchor),
            costField.centerYAnchor.constraint(equalTo: centerYAnchor),

            tokensField.trailingAnchor.constraint(equalTo: costField.leadingAnchor, constant: -10),
            tokensField.centerYAnchor.constraint(equalTo: centerYAnchor),

            sessionField.trailingAnchor.constraint(lessThanOrEqualTo: tokensField.leadingAnchor, constant: -8),

            heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }
}

/// Single horizontal hairline separating the live priority panel from the drill-down rows.
@MainActor
private final class SectionDivider: NSView {
    private let line = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.divider.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }
}

@MainActor
private final class ProjectGroupRowView: NSView {
    var onToggle: ((String) -> Void)?

    private let key: String
    private let title: String
    private let sessionCount: Int
    private let totalTokens: Int
    private let totalCost: Double
    private let anyActive: Bool
    private let expanded: Bool

    init(
        key: String,
        title: String,
        sessionCount: Int,
        totalTokens: Int,
        totalCost: Double,
        anyActive: Bool,
        expanded: Bool
    ) {
        self.key = key
        self.title = title
        self.sessionCount = sessionCount
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.anyActive = anyActive
        self.expanded = expanded
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = (anyActive ? Theme.surfaceMuted : Theme.surface)
            .withAlphaComponent(0.55).cgColor
        let rim: NSColor = anyActive ? Theme.accentMint : Theme.accentBlue
        Theme.applyGhostRim(
            layer!,
            color: rim,
            rimAlpha: anyActive ? 0.32 : 0.14,
            glowRadius: anyActive ? 10 : 6,
            glowAlpha: anyActive ? 0.28 : 0.10
        )
        configure()
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleClick)))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    @objc private func handleClick() {
        onToggle?(key)
    }

    private func configure() {
        let primary: NSColor = anyActive ? Theme.accentMint : Theme.textPrimary
        let titleString = anyActive ? "● \(title)" : title
        let titleField = NSTextField(labelWithString: titleString)
        titleField.font = Theme.titleFont(size: 13)
        titleField.textColor = primary
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if anyActive {
            titleField.attributedStringValue = Theme.glowAttributedTitle(
                titleString,
                color: primary,
                font: Theme.titleFont(size: 13)
            )
        }
        titleField.translatesAutoresizingMaskIntoConstraints = false

        let countField = NSTextField(labelWithString: "\(sessionCount) sess")
        countField.font = Theme.bodyFont(size: 10)
        countField.textColor = Theme.textTertiary
        countField.translatesAutoresizingMaskIntoConstraints = false

        let tokens = NSTextField(labelWithString: "\(NumberFormatting.compactTokens(totalTokens)) tk")
        tokens.font = Theme.numericFont(size: 12)
        tokens.textColor = Theme.textSecondary
        tokens.translatesAutoresizingMaskIntoConstraints = false

        let cost = NSTextField(labelWithString: NumberFormatting.compactDollars(totalCost))
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

        let summary = NSStackView(views: [countField, tokens, cost, chevron])
        summary.orientation = .horizontal
        summary.spacing = 12
        summary.alignment = .centerY
        summary.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [titleField, NSView(), summary])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }
}

/// Small mint orb that emits one scale+opacity pulse per refresh tick. Sized to slot inline with
/// the hero rate label without competing for visual weight — it's a confirmation signal, not a
/// status badge.
@MainActor
final class PulseOrb: NSView {
    private let orb = NSView()
    private let halo = NSView()
    private static let baseDiameter: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true

        halo.wantsLayer = true
        halo.translatesAutoresizingMaskIntoConstraints = false
        halo.layer?.backgroundColor = Theme.accentMint.withAlphaComponent(0.0).cgColor
        halo.layer?.cornerRadius = Self.baseDiameter
        halo.layer?.shadowColor = Theme.accentMint.cgColor
        halo.layer?.shadowRadius = 6
        halo.layer?.shadowOpacity = 0
        halo.layer?.shadowOffset = .zero

        orb.wantsLayer = true
        orb.translatesAutoresizingMaskIntoConstraints = false
        orb.layer?.backgroundColor = Theme.accentMint.cgColor
        orb.layer?.cornerRadius = Self.baseDiameter / 2

        addSubview(halo)
        addSubview(orb)

        NSLayoutConstraint.activate([
            orb.widthAnchor.constraint(equalToConstant: Self.baseDiameter),
            orb.heightAnchor.constraint(equalToConstant: Self.baseDiameter),
            orb.centerXAnchor.constraint(equalTo: centerXAnchor),
            orb.centerYAnchor.constraint(equalTo: centerYAnchor),

            halo.widthAnchor.constraint(equalToConstant: Self.baseDiameter * 2),
            halo.heightAnchor.constraint(equalToConstant: Self.baseDiameter * 2),
            halo.centerXAnchor.constraint(equalTo: centerXAnchor),
            halo.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    func pulse() {
        guard let orbLayer = orb.layer, let haloLayer = halo.layer else { return }
        // Orb: subtle scale-up to amplify presence.
        let orbScale = CABasicAnimation(keyPath: "transform.scale")
        orbScale.fromValue = 1.0
        orbScale.toValue = 1.35
        orbScale.duration = 0.18
        orbScale.autoreverses = true
        orbScale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        orbLayer.add(orbScale, forKey: "pulseScale")

        // Halo: expanding ring with fading opacity. Re-create the animation each time so back-to-
        // back pulses don't stack on the same animation key.
        let haloScale = CABasicAnimation(keyPath: "transform.scale")
        haloScale.fromValue = 0.6
        haloScale.toValue = 1.4
        haloScale.duration = 0.6

        let haloOpacity = CABasicAnimation(keyPath: "opacity")
        haloOpacity.fromValue = 0.6
        haloOpacity.toValue = 0.0
        haloOpacity.duration = 0.6

        let group = CAAnimationGroup()
        group.animations = [haloScale, haloOpacity]
        group.duration = 0.6
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        haloLayer.shadowOpacity = 0
        haloLayer.add(group, forKey: "pulseHalo")
    }
}

enum BurnFormatting {
    static func shortModel(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "anthropic/", with: "")
        return stripped
            .replacingOccurrences(of: "-20", with: " 20")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

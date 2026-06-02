import Foundation
import os

/// Visible "we're working" signal. Toggled around every poll so the popover can show a
/// progress banner — important on the first cold launch when the parser walks ~7 GB of JSONL.
struct RefreshState: Sendable {
    let isRefreshing: Bool
    let message: String
}

/// Single time-axis sample for the activity line graph. `topSession` is the session id that
/// contributed the most tokens to this bucket — what the hover tooltip surfaces.
struct TimelinePoint: Sendable, Equatable {
    let timestamp: Date
    let label: String
    let tokens: Int
    let costUSD: Double
    let topSession: String?
    let topSessionTokens: Int
}

/// Snapshot delivered to the UI on every poll. Pre-computes buckets for every mode so the
/// segmented control can switch instantly without spawning extra work or showing a spinner
/// past the cold first poll.
struct TrackerSnapshot: Sendable {
    let mode: ViewMode
    let bucketsByMode: [ViewMode: [AggregateBucket]]
    let timelinesByMode: [ViewMode: [TimelinePoint]]
    let tokensPerMinute: Double
    let medianTokensPerMinute: Double
    let previousTokensPerMinute: Double
    let costPerHour: Double

    /// Always-current hero stats (independent of selected view mode).
    let todayTokens: Int
    let todayCostUSD: Double
    let weekTokens: Int
    let weekCostUSD: Double
    let monthTokens: Int
    let monthCostUSD: Double

    let updatedAt: Date
    let spikeDetected: Bool
    let stale: Bool

    /// Optional billed-cost figure from Anthropic admin API. Nil unless the user has set
    /// `ANTHROPIC_ADMIN_API_KEY` and a successful fetch has occurred.
    let billedMonthUSD: Double?

    /// Human-readable status surfaced when the billing fetch can't currently produce a fresh
    /// dollar value (rate-limited, unauthorized, transport error, …).
    let billingStatusMessage: String?

    /// OAuth-billed spend for the local day (reset-aware sum of MTD steps since midnight). Nil
    /// until a usable two-point series exists. Truer than `todayCostUSD` (JSONL list-price
    /// estimate) because it's what Anthropic actually charged past included quota.
    let oauthTodayUSD: Double?

    /// OAuth-billed spend for the current week. Same derivation as `oauthTodayUSD`, windowed from
    /// the start of week. Nil until a usable series exists.
    let oauthWeekUSD: Double?

    /// Headline "today" spend for tiles + alerts. OAuth delta when available, else the local
    /// JSONL estimate so the figure never goes blank before sign-in.
    var displayTodayCostUSD: Double {
        oauthTodayUSD ?? todayCostUSD
    }

    /// Headline "week" spend. OAuth delta when available, else the JSONL estimate.
    var displayWeekCostUSD: Double {
        oauthWeekUSD ?? weekCostUSD
    }

    var buckets: [AggregateBucket] {
        bucketsByMode[mode] ?? []
    }

    var timeline: [TimelinePoint] {
        timelinesByMode[mode] ?? []
    }

    var totalTokens: Int {
        buckets.reduce(0) { $0 + $1.totalTokens }
    }

    var totalCostUSD: Double {
        buckets.reduce(0.0) { $0 + $1.costUSD }
    }

    func with(
        billedMonthUSD: Double?,
        billingStatusMessage: String? = nil,
        oauthTodayUSD: Double?? = nil,
        oauthWeekUSD: Double?? = nil
    ) -> TrackerSnapshot {
        TrackerSnapshot(
            mode: mode,
            bucketsByMode: bucketsByMode,
            timelinesByMode: timelinesByMode,
            tokensPerMinute: tokensPerMinute,
            medianTokensPerMinute: medianTokensPerMinute,
            previousTokensPerMinute: previousTokensPerMinute,
            costPerHour: costPerHour,
            todayTokens: todayTokens,
            todayCostUSD: todayCostUSD,
            weekTokens: weekTokens,
            weekCostUSD: weekCostUSD,
            monthTokens: monthTokens,
            monthCostUSD: monthCostUSD,
            updatedAt: updatedAt,
            spikeDetected: spikeDetected,
            stale: stale,
            billedMonthUSD: billedMonthUSD,
            billingStatusMessage: billingStatusMessage,
            oauthTodayUSD: oauthTodayUSD ?? self.oauthTodayUSD,
            oauthWeekUSD: oauthWeekUSD ?? self.oauthWeekUSD
        )
    }
}

/// Per-session live velocity sample: tokens-per-minute and projected USD/hr derived from the
/// trailing 60s window. Emitted only while the popover is open so we don't pay incremental I/O
/// in the background.
struct SessionVelocity: Sendable, Equatable {
    let projectPath: String
    let sessionId: String
    let tokensPerMinute: Double
    let costPerHour: Double
    let lastSampleAt: Date
}

/// Live snapshot delivered between full 60s ticks. Computed from incremental tail-reads of new
/// JSONL bytes since the popover opened. Active only while the popover is shown.
struct LiveSnapshot: Sendable {
    let updatedAt: Date
    let tokensPerMinute: Double
    let costPerHour: Double
    let perSession: [SessionVelocity]
}

/// Fires when the live USD/hr stays at or above the user's threshold for at least
/// `Preferences.toastSustainedSeconds`. Carries the breach value plus the top session so the UI
/// layer can render a "what's burning" message without re-deriving it.
struct ToastEvent: Sendable {
    enum Kind: Sendable {
        case threshold
        case dailyPeak
    }

    let kind: Kind
    let costPerHour: Double
    let thresholdUSDPerHour: Double
    let topSession: SessionVelocity?
    let firstBreachAt: Date
    /// Today's prior peak delta-derived $/hr — populated only for `dailyPeak` events.
    let previousPeakUSDPerHour: Double?
    /// Today's spend at fire time — OAuth midnight-delta when available, else JSONL estimate.
    /// Stable headline figure that doesn't whipsaw like $/hr.
    let todayCostUSD: Double
}

/// Orchestrator: every 60 seconds, reload all transcripts, recompute aggregates for the active
/// view mode, and emit a snapshot. Burn rate is the trailing 5-minute token sum projected to a
/// per-minute number — independent of the chosen view mode.
final class BurnTracker: @unchecked Sendable {
    var onUpdate: ((TrackerSnapshot) -> Void)?
    var onSpike: ((TrackerSnapshot) -> Void)?
    var onRefreshStateChanged: ((RefreshState) -> Void)?
    /// Fires every `liveTickInterval` while the popover is shown. Replaces nothing — strictly
    /// additive over the 60s `onUpdate` snapshot.
    var onLiveUpdate: ((LiveSnapshot) -> Void)?
    /// Fires once per breach when live USD/hr stays at/above threshold for the sustained window.
    /// Cooldown of `notificationCooldownSeconds` applies between fires.
    var onToast: ((ToastEvent) -> Void)?
    /// Fires after every billing fetch — success or failure — so the popover indicator can
    /// reflect token state without re-polling the billing actor.
    var onBillingHealth: ((BillingHealth) -> Void)?

    static let pollInterval: TimeInterval = 60
    static let burnWindowSeconds: TimeInterval = 5 * 60
    static let billingTickInterval: TimeInterval = 30
    static let spikeMultiplierDefault: Double = 2.0
    static let spikeMinimumRateDefault: Double = 500
    static let liveTickInterval: TimeInterval = 4
    /// Min interval between `entries.plist` writes. Cap to avoid hammering the disk on hot
    /// sessions where every poll updates a couple files. 2 min is plenty — relaunch cost-savings
    /// scale with `(time since last save)`, not write frequency.
    static let entriesPersistInterval: TimeInterval = 120
    static let liveWindowSeconds: TimeInterval = 60

    private let loader: JSONLLoader
    private let pricingService: PricingService
    private let billingService: BillingService?
    private let cache: DiskCache
    private let sampleStore: BillingSampleStore
    private let queue = DispatchQueue(label: "ouroburn.burn-tracker", qos: .utility)
    private let liveQueue = DispatchQueue(label: "ouroburn.burn-tracker.live", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private var timer: DispatchSourceTimer?
    private var billingTimer: DispatchSourceTimer?
    private var liveTimer: DispatchSourceTimer?
    private var fileWatcher: SessionFileWatcher?

    private enum Trigger {
        case timer, watcher, force
    }

    private struct State {
        var pricingTable: [String: ModelPricing] = [:]
        var activeMode: ViewMode = .day
        var previousRate: Double = 0
        var lastSnapshot: TrackerSnapshot?
        /// mtime-keyed cache: avoids reparsing files that haven't changed.
        var fileCache: [URL: CachedFile] = [:]
        /// Rolling rate samples used to compute a stable median (resists single-poll spikes).
        var rateHistory: [Double] = []
        /// Latest known admin-API billing total. Sticky between polls.
        var billedMonthUSD: Double?
        /// Latest billing status string surfaced into the popover footer (rate-limited, auth
        /// failure, transport error, etc). Cleared on successful fetch.
        var billingStatusMessage: String?
        // Tunable spike thresholds. Updated when the user saves settings.
        var spikeMultiplier: Double = BurnTracker.spikeMultiplierDefault
        var spikeMinimumRate: Double = BurnTracker.spikeMinimumRateDefault
        /// Tail-read offsets per file. Seeded at file size when live tracking starts so the live
        /// view shows only activity that occurs while the popover is open.
        var liveOffsets: [URL: UInt64] = [:]
        /// Rolling 60s window of new entries observed since live tracking started. Trimmed on
        /// every tick. Empty when popover is closed.
        var liveSamples: [UsageEntry] = []
        /// Toast threshold tunables, mirrored from `Preferences` on apply.
        var toastEnabled: Bool = false
        var toastCostThreshold: Double = 8
        var toastSustainedSeconds: Double = 30
        var toastPeakAlertEnabled: Bool = true
        var toastPeakMinimumUSDPerHour: Double = 5
        var notificationCooldownSeconds: Double = 600
        /// Highest delta-derived $/hr we've already announced for the current local day. Reset on
        /// day rollover. Prevents repeated peak toasts when the same sample is read multiple times.
        var lastAnnouncedPeakUSDPerHour: Double = 0
        var lastPeakDay: String = ""
        /// First moment the live rate exceeded `toastCostThreshold` in the current breach window.
        /// Reset whenever the rate drops back below. Once `now - firstBreach >= sustained`, the
        /// `onToast` callback fires and `lastToastFiredAt` advances to enforce cooldown.
        var firstBreachAt: Date?
        var lastToastFiredAt: Date?
        /// Timestamp of the last actual poll() execution. Watcher-triggered polls within 2s of
        /// the previous one short-circuit; timer + force triggers always proceed.
        var lastPollAt: Date?
        /// Per-file mtime fingerprint of the prior successful poll. When the fingerprint matches
        /// the new sweep, the tree hasn't changed and a watcher tick can skip the entire merge /
        /// dedup / sort / aggregate pipeline — the prior `lastSnapshot` is still authoritative.
        var lastFileFingerprint: UInt64 = 0
        /// Last time the file-cache was persisted to disk. Throttles the ~30-60 MB binary-plist
        /// write to once per `entriesPersistInterval`.
        var lastEntriesPersistedAt: Date?
    }

    func applyPreferences(_ prefs: Preferences) {
        state.withLock {
            $0.spikeMultiplier = prefs.spikeMultiplier
            $0.spikeMinimumRate = prefs.spikeMinimumRate
            $0.toastEnabled = prefs.toastEnabled
            $0.toastCostThreshold = prefs.toastCostThresholdUSDPerHour
            $0.toastSustainedSeconds = prefs.toastSustainedSeconds
            $0.toastPeakAlertEnabled = prefs.toastPeakAlertEnabled
            $0.toastPeakMinimumUSDPerHour = prefs.toastPeakMinimumUSDPerHour
            $0.notificationCooldownSeconds = prefs.notificationCooldownSeconds
            // Threshold or enabled flag changed — reset the breach tracker so the next breach
            // starts fresh rather than firing on stale state.
            $0.firstBreachAt = nil
        }
        if let billingService {
            Task { await billingService.setPollInterval(minutes: prefs.oauthRefreshMinutes) }
        }
    }

    static let rateHistoryDepth = 30

    private struct CachedFile {
        let modifiedAt: Date
        let entries: [UsageEntry]
    }

    init(
        loader: JSONLLoader = JSONLLoader(),
        pricingService: PricingService,
        billingService: BillingService? = nil,
        cache: DiskCache,
        sampleStore: BillingSampleStore = BillingSampleStore()
    ) {
        self.loader = loader
        self.pricingService = pricingService
        self.billingService = billingService
        self.cache = cache
        self.sampleStore = sampleStore
    }

    /// Records the active mode for the next poll cycle. The view layer renders the new mode
    /// instantly from the snapshot it already holds — re-emitting from here would cause a
    /// redundant full UI rebuild on the main thread, which is the dominant lag source.
    func setMode(_ mode: ViewMode) {
        state.withLock { $0.activeMode = mode }
    }

    func bootstrapFromCache() -> TrackerSnapshot? {
        guard let cached = cache.load() else { return nil }
        let mode = ViewMode(rawValue: cached.mode) ?? .day

        var bucketsByMode: [ViewMode: [AggregateBucket]] = [:]
        if let map = cached.bucketsByMode {
            for (key, buckets) in map {
                guard let m = ViewMode(rawValue: key) else { continue }
                bucketsByMode[m] = buckets.map { $0.toAggregateBucket() }
            }
        } else {
            bucketsByMode[mode] = cached.buckets.map { $0.toAggregateBucket() }
        }

        var timelinesByMode: [ViewMode: [TimelinePoint]] = [:]
        if let map = cached.timelinesByMode {
            for (key, points) in map {
                guard let m = ViewMode(rawValue: key) else { continue }
                timelinesByMode[m] = points.map { $0.toTimelinePoint() }
            }
        }

        let snapshot = TrackerSnapshot(
            mode: mode,
            bucketsByMode: bucketsByMode,
            timelinesByMode: timelinesByMode,
            tokensPerMinute: cached.burnRatePerMinute,
            medianTokensPerMinute: cached.medianTokensPerMinute ?? cached.burnRatePerMinute,
            previousTokensPerMinute: cached.burnRatePerMinute,
            costPerHour: cached.costPerHour ?? 0,
            todayTokens: cached.todayTokens ?? 0,
            todayCostUSD: cached.todayCostUSD ?? 0,
            weekTokens: cached.weekTokens ?? 0,
            weekCostUSD: cached.weekCostUSD ?? 0,
            monthTokens: cached.monthTokens ?? 0,
            monthCostUSD: cached.monthCostUSD ?? 0,
            updatedAt: cached.savedAt,
            spikeDetected: cached.recentSpike,
            // Stale only when the cached snapshot is older than two poll cycles. Fresh caches
            // already carry per-mode buckets + timelines, so we should render them immediately
            // instead of forcing the popover into a "loading…" state on every relaunch.
            stale: Date().timeIntervalSince(cached.savedAt) > Self.pollInterval * 2,
            billedMonthUSD: cached.billedMonthUSD,
            billingStatusMessage: nil,
            // Recomputed from the billing sample series on the next poll/fetch; not persisted.
            oauthTodayUSD: nil,
            oauthWeekUSD: nil
        )
        state.withLock {
            $0.lastSnapshot = snapshot
            $0.billedMonthUSD = cached.billedMonthUSD
        }

        // Seed `fileCache` from the persisted entries cache. Without this, every launch
        // re-parses ~2500 jsonl files (~30-60s, 5-core burn). With it, the next poll only
        // reparses files whose mtime has advanced since the cache was written — typically zero.
        if let persisted = DiskCache.loadPersistedEntries() {
            var seeded: [URL: CachedFile] = [:]
            seeded.reserveCapacity(persisted.files.count)
            for file in persisted.files {
                let url = URL(fileURLWithPath: file.path)
                seeded[url] = CachedFile(modifiedAt: file.modifiedAt, entries: file.entries)
            }
            let snapshot = seeded
            state.withLock { $0.fileCache = snapshot }
            Log.info(
                Log.tracker,
                "Bootstrap loaded \(snapshot.count) cached file entries (age \(Int(Date().timeIntervalSince(persisted.savedAt)))s)"
            )
        }

        if let billingService {
            Task { [weak self, billingService] in
                let health = await billingService.currentHealth()
                self?.onBillingHealth?(health)
            }
        }
        return snapshot
    }

    func start() {
        Log.info(Log.tracker, "Tracker starting (poll=\(Self.pollInterval)s, window=\(Self.burnWindowSeconds)s)")
        Task { [pricingService, state, queue] in
            await pricingService.ensureLoaded()
            let table = await pricingService.currentTable()
            state.withLock { $0.pricingTable = table }
            Log.info(Log.tracker, "Pricing table loaded: \(table.count) models")
            queue.async { [weak self] in self?.poll(trigger: .timer) }
            queue.async { [weak self] in self?.fetchBilling() }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll(trigger: .timer) }
        timer.resume()
        self.timer = timer

        let watcher = SessionFileWatcher(roots: loader.claudeRoots()) { [weak self] in
            guard let self else { return }
            // Don't invalidate the transcript-list cache here. While the user is actively coding,
            // FSEvents fires many times per second; invalidating the cache each fire defeats the
            // 30s TTL and lets `liveTick` rewalk 2k+ files on every iteration. Existing sessions
            // are tail-read by liveTick directly; new sessions will appear after the next TTL
            // expiry (≤30s lag) — acceptable for menu-bar use.
            queue.async { [weak self] in self?.poll(trigger: .watcher) }
        }
        watcher.start()
        fileWatcher = watcher
        Log.info(Log.tracker, "SessionFileWatcher started over \(loader.claudeRoots().count) root(s)")

        if billingService != nil {
            let bt = DispatchSource.makeTimerSource(queue: queue)
            // Independent billing tick. BillingService's own throttle gates the upstream HTTP
            // call to the user-configured `oauthRefreshMinutes`; the per-minute fire here just
            // ensures the credential refresh / status string surfaces promptly when the throttle
            // window opens.
            bt.schedule(deadline: .now() + Self.billingTickInterval, repeating: Self.billingTickInterval)
            bt.setEventHandler { [weak self] in self?.fetchBilling() }
            bt.resume()
            billingTimer = bt
        }
    }

    /// Force a poll right now and treat every JSONL on disk as stale so the file mtime cache is
    /// rebuilt from scratch. Also clears the BillingService throttle so the next poll re-hits
    /// `/api/oauth/usage`. Safe to call from any thread.
    func forceRefresh() {
        Log.info(Log.tracker, "Force refresh requested — clearing file cache + billing throttle")
        state.withLock { $0.fileCache = [:] }
        if let billingService {
            Task { await billingService.invalidate() }
        }
        queue.async { [weak self] in self?.poll(trigger: .force) }
        queue.async { [weak self] in self?.fetchBilling() }
    }

    /// Starts the 2s live ticker. Tail-reads only new JSONL bytes; rolling 60s window. Cheap
    /// because it walks file sizes without parsing existing content. Caller (status bar) invokes
    /// this on popover-open and pairs it with `stopLiveTracking()` on close.
    /// Seed offsets + start the 2s timer. Runs synchronously on the caller's thread (main, when
    /// invoked from the popover-open path). Earlier versions bounced between `liveQueue.async`
    /// and `DispatchQueue.main.async`, which crashed under Swift 6 strict-concurrency isolation
    /// checks when called from a `@MainActor` context.
    func startLiveTracking() {
        let files = loader.transcriptFiles()
        let seeded: [URL: UInt64] = files.reduce(into: [:]) { acc, url in
            acc[url] = loader.currentSize(of: url)
        }
        state.withLock { state in
            state.liveOffsets = seeded
            state.liveSamples = []
            state.firstBreachAt = nil
        }

        liveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: liveQueue)
        timer.schedule(
            deadline: .now() + Self.liveTickInterval,
            repeating: Self.liveTickInterval
        )
        timer.setEventHandler { [weak self] in self?.liveTick() }
        timer.resume()
        liveTimer = timer
    }

    func stopLiveTracking() {
        liveTimer?.cancel()
        liveTimer = nil
        state.withLock { state in
            state.liveOffsets = [:]
            state.liveSamples = []
            state.firstBreachAt = nil
        }
    }

    private func liveTick() {
        let cutoff = Date().addingTimeInterval(-Self.liveWindowSeconds)
        let snapshot = state.withLock { state in
            (state.liveOffsets, state.pricingTable)
        }
        let offsets = snapshot.0
        let table = snapshot.1

        // Discover new files that appeared since the popover opened — seed those at their current
        // size so we don't accidentally back-fill historical content.
        let currentFiles = loader.transcriptFiles()
        var nextOffsets = offsets
        var newEntries: [UsageEntry] = []
        for url in currentFiles {
            if let priorOffset = offsets[url] {
                let (entries, advanced) = loader.loadIncremental(from: url, fromOffset: priorOffset)
                nextOffsets[url] = advanced
                newEntries.append(contentsOf: entries)
            } else {
                nextOffsets[url] = loader.currentSize(of: url)
            }
        }

        let appended = newEntries
        let nextOffsetsFinal = nextOffsets
        let now = Date()
        let (live, toastEvent) = state.withLock { state -> (LiveSnapshot, ToastEvent?) in
            // Append, trim, then aggregate. Cheap because the live buffer caps at 60s of activity.
            state.liveSamples.append(contentsOf: appended)
            state.liveSamples.removeAll { $0.timestamp < cutoff }
            state.liveOffsets = nextOffsetsFinal
            let snapshot = Self.computeLive(samples: state.liveSamples, table: table, now: now)

            // Threshold tracker: only meaningful while toast alerts are enabled and we have at
            // least one sample in the rolling window — empty windows produce a 0 rate that would
            // otherwise reset breach state every tick.
            guard state.toastEnabled, !state.liveSamples.isEmpty else {
                state.firstBreachAt = nil
                return (snapshot, nil)
            }
            if snapshot.costPerHour >= state.toastCostThreshold {
                let firstBreach = state.firstBreachAt ?? now
                state.firstBreachAt = firstBreach
                let sustainedFor = now.timeIntervalSince(firstBreach)
                let cooldownOK: Bool = if let last = state.lastToastFiredAt {
                    now.timeIntervalSince(last) >= state.notificationCooldownSeconds
                } else {
                    true
                }
                if sustainedFor >= state.toastSustainedSeconds, cooldownOK {
                    state.lastToastFiredAt = now
                    let event = ToastEvent(
                        kind: .threshold,
                        costPerHour: snapshot.costPerHour,
                        thresholdUSDPerHour: state.toastCostThreshold,
                        topSession: snapshot.perSession.first,
                        firstBreachAt: firstBreach,
                        previousPeakUSDPerHour: nil,
                        todayCostUSD: state.lastSnapshot?.displayTodayCostUSD ?? 0
                    )
                    return (snapshot, event)
                }
                return (snapshot, nil)
            } else {
                state.firstBreachAt = nil
                return (snapshot, nil)
            }
        }
        onLiveUpdate?(live)
        if let toastEvent { onToast?(toastEvent) }
    }

    private static func liveCost(for entry: UsageEntry, table: [String: ModelPricing]) -> Double {
        if let cost = entry.costUSD { return cost }
        return PricingResolver.resolve(model: entry.model, table: table)?.cost(for: entry) ?? 0
    }

    /// Pure aggregation: rolling-window samples → tokens/min + USD/hr + per-session ranking.
    /// Pulled out so it stays unit-testable without spinning up the timer.
    private static func computeLive(
        samples: [UsageEntry],
        table: [String: ModelPricing],
        now: Date
    ) -> LiveSnapshot {
        guard !samples.isEmpty else {
            return LiveSnapshot(updatedAt: now, tokensPerMinute: 0, costPerHour: 0, perSession: [])
        }

        let totalTokens = samples.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens + $1.cacheCreationTokens + $1.cacheReadTokens
        }
        let totalCost = samples.reduce(0.0) {
            $0 + Self.liveCost(for: $1, table: table)
        }
        let windowMinutes = liveWindowSeconds / 60.0
        let tpm = Double(totalTokens) / windowMinutes
        let cph = totalCost / windowMinutes * 60

        struct Bucket {
            var tokens = 0
            var cost = 0.0
            var lastSampleAt: Date = .distantPast
        }
        var perSession: [String: Bucket] = [:]
        for entry in samples {
            let project = entry.projectPath ?? "?"
            let session = entry.sessionId ?? "?"
            let key = "\(project)\u{0}\(session)"
            var bucket = perSession[key] ?? Bucket()
            bucket.tokens += entry.inputTokens + entry.outputTokens
                + entry.cacheCreationTokens + entry.cacheReadTokens
            bucket.cost += Self.liveCost(for: entry, table: table)
            if entry.timestamp > bucket.lastSampleAt { bucket.lastSampleAt = entry.timestamp }
            perSession[key] = bucket
        }

        let velocities = perSession.compactMap { key, bucket -> SessionVelocity? in
            let parts = key.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return SessionVelocity(
                projectPath: String(parts[0]),
                sessionId: String(parts[1]),
                tokensPerMinute: Double(bucket.tokens) / windowMinutes,
                costPerHour: bucket.cost / windowMinutes * 60,
                lastSampleAt: bucket.lastSampleAt
            )
        }
        .sorted { $0.tokensPerMinute > $1.tokensPerMinute }

        return LiveSnapshot(updatedAt: now, tokensPerMinute: tpm, costPerHour: cph, perSession: velocities)
    }

    /// Async billing fetch decoupled from the session poll. Updates the snapshot in place so the
    /// popover footer / monthly tile reflect upstream `extra_used_usd` independently of the
    /// (much slower) JSONL aggregation cycle.
    private func fetchBilling() {
        guard let billingService else { return }
        Task { [weak self] in
            let total = await billingService.currentMonthBilledUSD()
            let status = await billingService.currentStatusMessage()
            let health = await billingService.currentHealth()
            guard let self else { return }
            // currentMonthBilledUSD just appended a fresh sample; recompute the OAuth deltas off
            // the updated series so the headline reflects the latest billed truth immediately.
            let now = Date()
            let billingSamples = sampleStore.load()
            let oauthToday = Self.oauthTodayUSD(samples: billingSamples, now: now, calendar: .current)
            let oauthWeek = Self.oauthWeekUSD(samples: billingSamples, now: now, calendar: .current)
            let updated = state.withLock { state -> TrackerSnapshot? in
                state.billedMonthUSD = total
                state.billingStatusMessage = status
                guard let last = state.lastSnapshot else { return nil }
                let next = last.with(
                    billedMonthUSD: total,
                    billingStatusMessage: status,
                    oauthTodayUSD: .some(oauthToday),
                    oauthWeekUSD: .some(oauthWeek)
                )
                state.lastSnapshot = next
                return next
            }
            if let updated { onUpdate?(updated) }
            onBillingHealth?(health)
            checkDailyPeak()
        }
    }

    /// Spend over `[since, now]` derived from the OAuth `extra_used_usd` month-to-date series.
    /// Sums only the positive step between consecutive samples, so a billing-cycle reset (MTD
    /// collapses to ~0 at the month boundary) or a transient upstream trough contributes nothing
    /// instead of a spurious negative — the post-reset climb is still captured by the steps after
    /// it. Anchored on the last sample before `since` so spend that landed right at the boundary
    /// isn't dropped. (`BillingSampleStore.load` already strips recovered troughs; this guard
    /// covers genuine resets and any trailing, not-yet-recovered trough.)
    ///
    /// Returns nil when no two-point delta is computable so callers fall back to the JSONL
    /// estimate instead of showing a misleading $0.
    static func oauthSpend(samples: [BillingSample], since: Date, now: Date) -> Double? {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var window = sorted.filter { $0.timestamp >= since && $0.timestamp <= now }
        if let anchor = sorted.last(where: { $0.timestamp < since }) {
            window.insert(anchor, at: 0)
        }
        guard window.count >= 2 else { return nil }
        var total = 0.0
        for i in 1 ..< window.count {
            let step = window[i].totalUSD - window[i - 1].totalUSD
            if step > 0 { total += step }
        }
        return total
    }

    /// OAuth-billed spend since local midnight.
    static func oauthTodayUSD(samples: [BillingSample], now: Date, calendar: Calendar) -> Double? {
        oauthSpend(samples: samples, since: calendar.startOfDay(for: now), now: now)
    }

    /// OAuth-billed spend since the start of the current week (Sunday — matches the JSONL week
    /// bucket lookup, `weekStart: 1`).
    static func oauthWeekUSD(samples: [BillingSample], now: Date, calendar: Calendar) -> Double? {
        var cal = calendar
        cal.firstWeekday = 1
        let weekday = cal.component(.weekday, from: now)
        let offset = (weekday - cal.firstWeekday + 7) % 7
        let weekStart = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now)) ?? now
        return oauthSpend(samples: samples, since: weekStart, now: now)
    }

    /// Inspect today's OAuth billing samples for a new local peak in per-interval $/hr. Fires
    /// `onToast` when today's latest delta beats every prior delta we've seen today. Idempotent —
    /// re-reading the same sample won't re-fire (we track the last-announced peak in state).
    private func checkDailyPeak() {
        let calendar = Calendar.current
        let today = Aggregator.dayKey(for: Date(), calendar: calendar)
        let samples = sampleStore.load()
            .filter { calendar.isDateInToday($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
        guard samples.count >= 2 else { return }

        struct Pair { let rate: Double; let amount: Double; let at: Date }
        var pairs: [Pair] = []
        pairs.reserveCapacity(samples.count - 1)
        // OAuth `extra_used_usd` updates on minute-ish cadence with billing-period resets.
        // Pairs whose sample gap is under 60s (force-refresh racing a regular tick) divide a
        // real-but-stale delta by a tiny denominator and produce six-figure $/hr ghosts.
        // Skip them entirely.
        let minIntervalSeconds: TimeInterval = 60
        for index in 1 ..< samples.count {
            let prior = samples[index - 1]
            let current = samples[index]
            let elapsed = current.timestamp.timeIntervalSince(prior.timestamp)
            guard elapsed >= minIntervalSeconds else { continue }
            let amount = max(0, current.totalUSD - prior.totalUSD)
            let rate = amount / elapsed * 3600
            pairs.append(Pair(rate: rate, amount: amount, at: current.timestamp))
        }
        guard let latest = pairs.last, latest.amount > 0 else { return }
        let priorMaxRate = pairs.dropLast().map(\.rate).max() ?? 0

        let live = state.withLock { state -> LiveSnapshot? in
            // Compute a fresh live snapshot for top-session annotation. Cheap because the buffer
            // caps at the rolling 60s window.
            Self.computeLive(samples: state.liveSamples, table: state.pricingTable, now: Date())
        }
        let now = Date()
        let event = state.withLock { state -> ToastEvent? in
            // Day rolled over: clear the tracker so the first peak of the new day fires.
            if state.lastPeakDay != today {
                state.lastPeakDay = today
                state.lastAnnouncedPeakUSDPerHour = 0
            }
            guard state.toastPeakAlertEnabled else { return nil }
            // A new daily max must also clear the floor — otherwise a tiny first-of-day blip
            // ($0.40/hr beating $0.10/hr) would fire a "peak" toast every morning.
            guard latest.rate >= state.toastPeakMinimumUSDPerHour else { return nil }
            guard latest.rate > priorMaxRate, latest.rate > state.lastAnnouncedPeakUSDPerHour else {
                return nil
            }
            let cooldownOK: Bool = if let last = state.lastToastFiredAt {
                now.timeIntervalSince(last) >= state.notificationCooldownSeconds
            } else {
                true
            }
            guard cooldownOK else { return nil }
            state.lastAnnouncedPeakUSDPerHour = latest.rate
            state.lastToastFiredAt = now
            return ToastEvent(
                kind: .dailyPeak,
                costPerHour: latest.rate,
                thresholdUSDPerHour: priorMaxRate,
                topSession: live?.perSession.first,
                firstBreachAt: latest.at,
                previousPeakUSDPerHour: priorMaxRate,
                todayCostUSD: state.lastSnapshot?.displayTodayCostUSD ?? 0
            )
        }
        if let event {
            Log.info(
                Log.tracker,
                String(
                    format: "Daily peak alert: $%.2f/hr (prior peak $%.2f/hr)",
                    event.costPerHour, event.previousPeakUSDPerHour ?? 0
                )
            )
            onToast?(event)
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        billingTimer?.cancel()
        billingTimer = nil
        fileWatcher?.stop()
        fileWatcher = nil
    }

    /// Load all entries, reparsing only files whose modification time differs from the cache.
    /// Stale files are parsed in parallel via `DispatchQueue.concurrentPerform` — the first poll
    /// after launch is the only expensive one (1.8k files / multi-GB), and parallel I/O cuts it
    /// from ~5 min to ~30 s on a typical SSD.
    ///
    /// Returns `nil` from `entries` when the per-file mtime fingerprint matches the cached one
    /// AND the prior merged buffer is reusable — callers MUST then keep using their prior
    /// `merged` array. Skipping the merge / dedup / sort over 250k+ entries cuts watcher-tick
    /// CPU from "burning 5 cores" to a no-op.
    private func loadEntries(
        using cache: [URL: CachedFile],
        priorFingerprint: UInt64
    ) -> (entries: [UsageEntry]?, cache: [URL: CachedFile], fingerprint: UInt64) {
        let files = loader.transcriptFiles()
        var staleEntries: [URL] = []
        var nextCache: [URL: CachedFile] = [:]
        nextCache.reserveCapacity(files.count)
        var reused = 0
        var fingerprint = UInt64(files.count) &* 1_469_598_103_934_665_603

        for url in files {
            let mtime = loader.modificationDate(for: url)
            // FNV-like rolling hash over (path, mtime). Order-independent across files.
            let bits = UInt64(bitPattern: Int64(mtime.timeIntervalSince1970 * 1000))
            fingerprint ^= UInt64(truncatingIfNeeded: url.path.hashValue) &* 1_099_511_628_211
            fingerprint ^= bits &* 1_099_511_628_211
            if let cached = cache[url], cached.modifiedAt == mtime {
                nextCache[url] = cached
                reused += 1
            } else {
                staleEntries.append(url)
            }
        }

        if staleEntries.isEmpty, fingerprint == priorFingerprint {
            Log.debug(Log.tracker, "Load short-circuit: fingerprint matched, reused=\(reused)")
            return (nil, nextCache, fingerprint)
        }

        if !staleEntries.isEmpty {
            let lock = NSLock()
            let parsed = UnsafeMutableBufferPointer<CachedFile?>.allocate(capacity: staleEntries.count)
            parsed.initialize(repeating: nil)
            DispatchQueue.concurrentPerform(iterations: staleEntries.count) { index in
                let url = staleEntries[index]
                let mtime = loader.modificationDate(for: url)
                let entries = loader.loadAllEntries(from: url)
                parsed[index] = CachedFile(modifiedAt: mtime, entries: entries)
            }
            lock.lock()
            for (index, url) in staleEntries.enumerated() {
                if let cached = parsed[index] { nextCache[url] = cached }
            }
            lock.unlock()
            parsed.deinitialize()
            parsed.deallocate()
        }
        let reparsed = staleEntries.count

        // Merge with cross-file dedup. Claude Code can write multiple JSONL rows per
        // (messageId, requestId) — streaming-delta snapshots where output_tokens grows
        // monotonically across writes. Keep the row with the highest totalTokens per key
        // so cost reflects the final completion rather than an intermediate partial.
        // Entries missing either id half are kept as-is (no dedup possible).
        var byKey: [String: UsageEntry] = [:]
        var unkeyed: [UsageEntry] = []
        for cached in nextCache.values {
            for entry in cached.entries {
                guard let key = entry.dedupKey else { unkeyed.append(entry); continue }
                if let existing = byKey[key], existing.totalTokens >= entry.totalTokens { continue }
                byKey[key] = entry
            }
        }
        var merged = Array(byKey.values)
        merged.append(contentsOf: unkeyed)
        merged.sort { $0.timestamp < $1.timestamp }
        Log.info(Log.tracker, "Load reparsed=\(reparsed) reused=\(reused) merged=\(merged.count)")
        return (merged, nextCache, fingerprint)
    }

    /// Serialize the in-memory `fileCache` to disk so the next launch skips the cold reparse.
    /// Runs on the tracker queue; binary-plist encode of ~250k `UsageEntry`s takes a few hundred
    /// ms on modern Apple Silicon and is throttled by `entriesPersistInterval`.
    private func persistFileCache(_ cache: [URL: CachedFile]) {
        let files = cache.map { url, cached in
            PersistedEntriesCache.PersistedFile(
                path: url.path,
                modifiedAt: cached.modifiedAt,
                byteSize: 0,
                entries: cached.entries
            )
        }
        let payload = PersistedEntriesCache(
            version: PersistedEntriesCache.currentVersion,
            savedAt: Date(),
            files: files
        )
        DiskCache.savePersistedEntries(payload)
        Log.info(Log.tracker, "Persisted \(files.count) cached files to entries.plist")
    }

    private static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private func poll(trigger: Trigger = .timer) {
        if trigger == .watcher {
            let lastPollAt = state.withLock { $0.lastPollAt }
            // Watcher-triggered polls are expensive (merge + dedup + 4× aggregate over the full
            // entry set) and an active Claude Code session writes JSONL many times per second.
            // The 2s live tick keeps the menu-bar tooltip + headline rate fresh; tile totals
            // can wait. Hard-floor watcher polls at 20s. The 60s safety timer still ticks.
            if let last = lastPollAt, Date().timeIntervalSince(last) < 20 {
                Log.debug(Log.tracker, "Poll skipped (watcher within 20s of last poll)")
                return
            }
        }
        state.withLock { $0.lastPollAt = Date() }

        let (
            mode,
            table,
            previous,
            fileCacheSnapshot,
            history,
            spikeMultiplier,
            spikeMinimumRate,
            priorFingerprint
        ) = state
            .withLock { state -> (
                ViewMode,
                [String: ModelPricing],
                Double,
                [URL: CachedFile],
                [Double],
                Double,
                Double,
                UInt64
            ) in
                (
                    state.activeMode,
                    state.pricingTable,
                    state.previousRate,
                    state.fileCache,
                    state.rateHistory,
                    state.spikeMultiplier,
                    state.spikeMinimumRate,
                    state.lastFileFingerprint
                )
            }

        let isCold = fileCacheSnapshot.isEmpty
        let startMessage = isCold
            ? "First load — parsing transcripts (this can take a couple minutes)"
            : "Refreshing transcripts"
        onRefreshStateChanged?(RefreshState(isRefreshing: true, message: startMessage))

        let now = Date()
        let (maybeEntries, updatedCache, fingerprint) = loadEntries(
            using: fileCacheSnapshot,
            priorFingerprint: priorFingerprint
        )
        // Fingerprint matched → tree unchanged → the prior snapshot is still authoritative.
        // Re-emit it (so subscribers can refresh timestamps) but skip merge / aggregation.
        if let last = state.withLock({ $0.lastSnapshot }), maybeEntries == nil {
            state.withLock { $0.fileCache = updatedCache }
            onUpdate?(last)
            onRefreshStateChanged?(RefreshState(isRefreshing: false, message: ""))
            return
        }
        guard let entries = maybeEntries else {
            // No prior snapshot to fall back on (cold launch with empty fileCache but matched
            // fingerprint — shouldn't happen in practice). Force a real load via loadAll.
            onRefreshStateChanged?(RefreshState(isRefreshing: false, message: ""))
            return
        }
        Log.info(
            Log.tracker,
            "Poll mode=\(mode.rawValue) entries=\(entries.count) cachedFiles=\(updatedCache.count) pricing=\(table.count)"
        )

        let aggregator = Aggregator(pricing: table)

        // Pre-aggregate every view mode so segmented-control switching is instant.
        var bucketsByMode: [ViewMode: [AggregateBucket]] = [:]
        var timelinesByMode: [ViewMode: [TimelinePoint]] = [:]
        for viewMode in ViewMode.allCases {
            let aggregated = aggregator.aggregate(entries: entries, mode: viewMode, now: now)
            bucketsByMode[viewMode] = aggregated
            timelinesByMode[viewMode] = aggregator.timeline(entries: entries, mode: viewMode, now: now)
        }

        let cutoff = now.addingTimeInterval(-Self.burnWindowSeconds)
        let recent = entries.filter { $0.timestamp >= cutoff }
        let recentTokens = recent.reduce(0) { $0 + $1.totalTokens }
        let tokensPerMinute = Double(recentTokens) / (Self.burnWindowSeconds / 60)

        let recentCost = recent.reduce(0.0) { $0 + aggregator.cost(of: $1) }
        let costPerHour = recentCost * (3600.0 / Self.burnWindowSeconds)

        // Hero stats — always present, independent of selected mode.
        let dailyBuckets = bucketsByMode[.day] ?? []
        let weeklyBuckets = bucketsByMode[.week] ?? []
        let monthlyBuckets = bucketsByMode[.month] ?? []
        let todayBucket = dailyBuckets.first { Aggregator.dayKey(for: now, calendar: .current) == $0.id }
        let weekBucket = weeklyBuckets.first { Aggregator.weekKey(for: now, calendar: .current, weekStart: 1) == $0.id }
        let monthBucket = monthlyBuckets.first { Aggregator.monthKey(for: now, calendar: .current) == $0.id }

        // Rolling median over the last 30 polls (~30 min) for a stable headline rate.
        let nextHistory: [Double] = {
            var out = history
            out.append(tokensPerMinute)
            if out.count > Self.rateHistoryDepth {
                out.removeFirst(out.count - Self.rateHistoryDepth)
            }
            return out
        }()
        let median = Self.median(of: nextHistory)

        let spike = previous > 0 && tokensPerMinute > previous * spikeMultiplier && tokensPerMinute > spikeMinimumRate

        let (billedSoFar, billingStatusSoFar) = state.withLock {
            ($0.billedMonthUSD, $0.billingStatusMessage)
        }
        let billingSamples = sampleStore.load()
        let oauthToday = Self.oauthTodayUSD(samples: billingSamples, now: now, calendar: .current)
        let oauthWeek = Self.oauthWeekUSD(samples: billingSamples, now: now, calendar: .current)
        let snapshot = TrackerSnapshot(
            mode: mode,
            bucketsByMode: bucketsByMode,
            timelinesByMode: timelinesByMode,
            tokensPerMinute: tokensPerMinute,
            medianTokensPerMinute: median,
            previousTokensPerMinute: previous,
            costPerHour: costPerHour,
            todayTokens: todayBucket?.totalTokens ?? 0,
            todayCostUSD: todayBucket?.costUSD ?? 0,
            weekTokens: weekBucket?.totalTokens ?? 0,
            weekCostUSD: weekBucket?.costUSD ?? 0,
            monthTokens: monthBucket?.totalTokens ?? 0,
            monthCostUSD: monthBucket?.costUSD ?? 0,
            updatedAt: now,
            spikeDetected: spike,
            stale: false,
            billedMonthUSD: billedSoFar,
            billingStatusMessage: billingStatusSoFar,
            oauthTodayUSD: oauthToday,
            oauthWeekUSD: oauthWeek
        )

        state.withLock {
            $0.previousRate = tokensPerMinute
            $0.lastSnapshot = snapshot
            $0.fileCache = updatedCache
            $0.rateHistory = nextHistory
            $0.lastFileFingerprint = fingerprint
        }

        // Persist parsed entries so the next launch can skip the cold reparse. Throttled to
        // once per `entriesPersistInterval` to amortize the binary-plist write (~30-60 MB) over
        // multiple polls. The serialization itself runs on the background `queue` already.
        let shouldPersist: Bool = state.withLock { state in
            if let last = state.lastEntriesPersistedAt,
               Date().timeIntervalSince(last) < Self.entriesPersistInterval
            {
                return false
            }
            state.lastEntriesPersistedAt = Date()
            return true
        }
        if shouldPersist {
            persistFileCache(updatedCache)
        }

        let activeBuckets = bucketsByMode[mode] ?? []
        var encodedBuckets: [String: [CachedSnapshot.CachedBucket]] = [:]
        for (m, buckets) in bucketsByMode {
            encodedBuckets[m.rawValue] = buckets.map(CachedSnapshot.CachedBucket.init)
        }
        var encodedTimelines: [String: [CachedSnapshot.CachedTimelinePoint]] = [:]
        for (m, points) in timelinesByMode {
            encodedTimelines[m.rawValue] = points.map(CachedSnapshot.CachedTimelinePoint.init)
        }
        let activeBucketSnapshots: [CachedSnapshot.CachedBucket] = activeBuckets
            .map(CachedSnapshot.CachedBucket.init)
        let todayTokens: Int = todayBucket?.totalTokens ?? 0
        let todayCost: Double = todayBucket?.costUSD ?? 0
        let weekTokens: Int = weekBucket?.totalTokens ?? 0
        let weekCost: Double = weekBucket?.costUSD ?? 0
        let monthTokens: Int = monthBucket?.totalTokens ?? 0
        let monthCost: Double = monthBucket?.costUSD ?? 0
        let cached = CachedSnapshot(
            savedAt: now,
            buckets: activeBucketSnapshots,
            mode: mode.rawValue,
            burnRatePerMinute: tokensPerMinute,
            recentSpike: spike,
            bucketsByMode: encodedBuckets,
            timelinesByMode: encodedTimelines,
            medianTokensPerMinute: median,
            costPerHour: costPerHour,
            todayTokens: todayTokens,
            todayCostUSD: todayCost,
            weekTokens: weekTokens,
            weekCostUSD: weekCost,
            monthTokens: monthTokens,
            monthCostUSD: monthCost,
            billedMonthUSD: billedSoFar
        )
        cache.save(cached)

        let totalCost = activeBuckets.reduce(0.0) { $0 + $1.costUSD }
        Log.info(
            Log.tracker,
            String(
                format: "Snapshot buckets=%d tok/min=%.1f $/hr=%.2f total$=%.2f spike=%@",
                activeBuckets.count,
                tokensPerMinute,
                costPerHour,
                totalCost,
                spike ? "YES" : "no"
            )
        )

        onUpdate?(snapshot)
        onRefreshStateChanged?(RefreshState(isRefreshing: false, message: ""))
        if spike {
            Log.info(Log.tracker, "Spike detected — notifying")
            onSpike?(snapshot)
        }

        // Billing fetch runs on its own timer (see `billingTimer` / `fetchBilling`) so the
        // OAuth call doesn't block on the JSONL aggregation cycle and surfaces refreshed
        // numbers as soon as the throttle window opens.
    }
}

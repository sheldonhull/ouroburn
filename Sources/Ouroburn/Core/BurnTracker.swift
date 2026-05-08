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

    func with(billedMonthUSD: Double?, billingStatusMessage: String? = nil) -> TrackerSnapshot {
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
            billingStatusMessage: billingStatusMessage
        )
    }
}

/// Orchestrator: every 60 seconds, reload all transcripts, recompute aggregates for the active
/// view mode, and emit a snapshot. Burn rate is the trailing 5-minute token sum projected to a
/// per-minute number — independent of the chosen view mode.
final class BurnTracker: @unchecked Sendable {
    var onUpdate: ((TrackerSnapshot) -> Void)?
    var onSpike: ((TrackerSnapshot) -> Void)?
    var onRefreshStateChanged: ((RefreshState) -> Void)?

    static let pollInterval: TimeInterval = 60
    static let burnWindowSeconds: TimeInterval = 5 * 60
    static let billingTickInterval: TimeInterval = 30
    static let spikeMultiplierDefault: Double = 2.0
    static let spikeMinimumRateDefault: Double = 500

    private let loader: JSONLLoader
    private let pricingService: PricingService
    private let billingService: BillingService?
    private let cache: DiskCache
    private let queue = DispatchQueue(label: "ouroburn.burn-tracker", qos: .utility)
    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private var timer: DispatchSourceTimer?
    private var billingTimer: DispatchSourceTimer?

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
    }

    func applyPreferences(_ prefs: Preferences) {
        state.withLock {
            $0.spikeMultiplier = prefs.spikeMultiplier
            $0.spikeMinimumRate = prefs.spikeMinimumRate
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
        cache: DiskCache
    ) {
        self.loader = loader
        self.pricingService = pricingService
        self.billingService = billingService
        self.cache = cache
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
            stale: true,
            billedMonthUSD: cached.billedMonthUSD,
            billingStatusMessage: nil
        )
        state.withLock {
            $0.lastSnapshot = snapshot
            $0.billedMonthUSD = cached.billedMonthUSD
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
            queue.async { [weak self] in self?.poll() }
            queue.async { [weak self] in self?.fetchBilling() }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer

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
        queue.async { [weak self] in self?.poll() }
        queue.async { [weak self] in self?.fetchBilling() }
    }

    /// Async billing fetch decoupled from the session poll. Updates the snapshot in place so the
    /// popover footer / monthly tile reflect upstream `extra_used_usd` independently of the
    /// (much slower) JSONL aggregation cycle.
    private func fetchBilling() {
        guard let billingService else { return }
        Task { [weak self] in
            let total = await billingService.currentMonthBilledUSD()
            let status = await billingService.currentStatusMessage()
            guard let self else { return }
            let updated = state.withLock { state -> TrackerSnapshot? in
                state.billedMonthUSD = total
                state.billingStatusMessage = status
                guard let last = state.lastSnapshot else { return nil }
                let next = last.with(billedMonthUSD: total, billingStatusMessage: status)
                state.lastSnapshot = next
                return next
            }
            if let updated { onUpdate?(updated) }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        billingTimer?.cancel()
        billingTimer = nil
    }

    /// Load all entries, reparsing only files whose modification time differs from the cache.
    /// Stale files are parsed in parallel via `DispatchQueue.concurrentPerform` — the first poll
    /// after launch is the only expensive one (1.8k files / multi-GB), and parallel I/O cuts it
    /// from ~5 min to ~30 s on a typical SSD.
    private func loadEntries(using cache: [URL: CachedFile]) -> (entries: [UsageEntry], cache: [URL: CachedFile]) {
        let files = loader.transcriptFiles()
        var staleEntries: [URL] = []
        var nextCache: [URL: CachedFile] = [:]
        nextCache.reserveCapacity(files.count)
        var reused = 0

        for url in files {
            let mtime = loader.modificationDate(for: url)
            if let cached = cache[url], cached.modifiedAt == mtime {
                nextCache[url] = cached
                reused += 1
            } else {
                staleEntries.append(url)
            }
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

        // Merge with cross-file dedup (mirrors ccusage `data-loader.ts:530`).
        var seen = Set<String>()
        var merged: [UsageEntry] = []
        for cached in nextCache.values {
            for entry in cached.entries {
                if let key = entry.dedupKey {
                    if seen.contains(key) { continue }
                    seen.insert(key)
                }
                merged.append(entry)
            }
        }
        merged.sort { $0.timestamp < $1.timestamp }
        Log.info(Log.tracker, "Load reparsed=\(reparsed) reused=\(reused) merged=\(merged.count)")
        return (merged, nextCache)
    }

    private static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private func poll() {
        let (mode, table, previous, fileCacheSnapshot, history, spikeMultiplier, spikeMinimumRate) = state
            .withLock { state -> (
                ViewMode,
                [String: ModelPricing],
                Double,
                [URL: CachedFile],
                [Double],
                Double,
                Double
            ) in
                (
                    state.activeMode,
                    state.pricingTable,
                    state.previousRate,
                    state.fileCache,
                    state.rateHistory,
                    state.spikeMultiplier,
                    state.spikeMinimumRate
                )
            }

        let isCold = fileCacheSnapshot.isEmpty
        let startMessage = isCold
            ? "First load — parsing transcripts (this can take a couple minutes)"
            : "Refreshing transcripts"
        onRefreshStateChanged?(RefreshState(isRefreshing: true, message: startMessage))

        let now = Date()
        let (entries, updatedCache) = loadEntries(using: fileCacheSnapshot)
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
            billingStatusMessage: billingStatusSoFar
        )

        state.withLock {
            $0.previousRate = tokensPerMinute
            $0.lastSnapshot = snapshot
            $0.fileCache = updatedCache
            $0.rateHistory = nextHistory
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

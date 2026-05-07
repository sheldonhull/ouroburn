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

    var buckets: [AggregateBucket] { bucketsByMode[mode] ?? [] }
    var timeline: [TimelinePoint] { timelinesByMode[mode] ?? [] }
    var totalTokens: Int { buckets.reduce(0) { $0 + $1.totalTokens } }
    var totalCostUSD: Double { buckets.reduce(0.0) { $0 + $1.costUSD } }

    func with(billedMonthUSD: Double?) -> TrackerSnapshot {
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
            billedMonthUSD: billedMonthUSD
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
    static let spikeMultiplierDefault: Double = 2.0
    static let spikeMinimumRateDefault: Double = 500

    private let loader: JSONLLoader
    private let pricingService: PricingService
    private let billingService: BillingService?
    private let cache: DiskCache
    private let queue = DispatchQueue(label: "ouroburn.burn-tracker", qos: .utility)
    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private var timer: DispatchSourceTimer?

    private struct State {
        var pricingTable: [String: ModelPricing] = [:]
        var activeMode: ViewMode = .day
        var previousRate: Double = 0
        var lastSnapshot: TrackerSnapshot?
        // mtime-keyed cache: avoids reparsing files that haven't changed.
        var fileCache: [URL: CachedFile] = [:]
        // Rolling rate samples used to compute a stable median (resists single-poll spikes).
        var rateHistory: [Double] = []
        // Latest known admin-API billing total. Sticky between polls.
        var billedMonthUSD: Double?
        // Tunable spike thresholds. Updated when the user saves settings.
        var spikeMultiplier: Double = BurnTracker.spikeMultiplierDefault
        var spikeMinimumRate: Double = BurnTracker.spikeMinimumRateDefault
    }

    func applyPreferences(_ prefs: Preferences) {
        state.withLock {
            $0.spikeMultiplier = prefs.spikeMultiplier
            $0.spikeMinimumRate = prefs.spikeMinimumRate
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
        let buckets = cached.buckets.map { $0.toAggregateBucket() }
        let mode = ViewMode(rawValue: cached.mode) ?? .day
        let snapshot = TrackerSnapshot(
            mode: mode,
            bucketsByMode: [mode: buckets],
            timelinesByMode: [:],
            tokensPerMinute: cached.burnRatePerMinute,
            medianTokensPerMinute: cached.burnRatePerMinute,
            previousTokensPerMinute: cached.burnRatePerMinute,
            costPerHour: 0,
            todayTokens: 0,
            todayCostUSD: 0,
            weekTokens: 0,
            weekCostUSD: 0,
            monthTokens: 0,
            monthCostUSD: 0,
            updatedAt: cached.savedAt,
            spikeDetected: cached.recentSpike,
            stale: true,
            billedMonthUSD: nil
        )
        state.withLock { $0.lastSnapshot = snapshot }
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
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
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
        let (mode, table, previous, fileCacheSnapshot, history, spikeMultiplier, spikeMinimumRate) = state.withLock { state -> (ViewMode, [String: ModelPricing], Double, [URL: CachedFile], [Double], Double, Double) in
            (state.activeMode, state.pricingTable, state.previousRate, state.fileCache, state.rateHistory, state.spikeMultiplier, state.spikeMinimumRate)
        }

        let isCold = fileCacheSnapshot.isEmpty
        let startMessage = isCold
            ? "First load — parsing transcripts (this can take a couple minutes)"
            : "Refreshing transcripts"
        onRefreshStateChanged?(RefreshState(isRefreshing: true, message: startMessage))

        let now = Date()
        let (entries, updatedCache) = loadEntries(using: fileCacheSnapshot)
        Log.info(Log.tracker, "Poll mode=\(mode.rawValue) entries=\(entries.count) cachedFiles=\(updatedCache.count) pricing=\(table.count)")

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

        let billedSoFar = state.withLock { $0.billedMonthUSD }
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
            billedMonthUSD: billedSoFar
        )

        state.withLock {
            $0.previousRate = tokensPerMinute
            $0.lastSnapshot = snapshot
            $0.fileCache = updatedCache
            $0.rateHistory = nextHistory
        }

        let activeBuckets = bucketsByMode[mode] ?? []
        cache.save(CachedSnapshot(
            savedAt: now,
            buckets: activeBuckets.map(CachedSnapshot.CachedBucket.init),
            mode: mode.rawValue,
            burnRatePerMinute: tokensPerMinute,
            recentSpike: spike
        ))

        let totalCost = activeBuckets.reduce(0.0) { $0 + $1.costUSD }
        Log.info(Log.tracker,
                 String(format: "Snapshot buckets=%d tok/min=%.1f $/hr=%.2f total$=%.2f spike=%@",
                        activeBuckets.count, tokensPerMinute, costPerHour, totalCost, spike ? "YES" : "no"))

        onUpdate?(snapshot)
        onRefreshStateChanged?(RefreshState(isRefreshing: false, message: ""))
        if spike {
            Log.info(Log.tracker, "Spike detected — notifying")
            onSpike?(snapshot)
        }

        // Optional admin-API billing fetch. Throttled to once per hour internally; this just
        // kicks the actor and updates the snapshot whenever a fresh value arrives.
        if let billingService {
            Task { [weak self] in
                let total = await billingService.currentMonthBilledUSD()
                guard let self else { return }
                let updated = state.withLock { state -> TrackerSnapshot? in
                    state.billedMonthUSD = total
                    guard let last = state.lastSnapshot else { return nil }
                    let next = last.with(billedMonthUSD: total)
                    state.lastSnapshot = next
                    return next
                }
                if let updated { self.onUpdate?(updated) }
            }
        }
    }
}

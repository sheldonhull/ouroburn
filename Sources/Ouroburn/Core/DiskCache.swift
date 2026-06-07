import Foundation

/// JSON-on-disk cache so the popover has data to show before the first poll completes —
/// essential when running offline or right after launch.
///
/// Schema-tolerant: optional fields are nil on cache files written by older builds; the boot
/// path falls back to legacy `buckets`/`mode` when the per-mode dictionary is absent.
struct CachedSnapshot: Codable, Sendable {
    let savedAt: Date
    let buckets: [CachedBucket]
    let mode: String
    let burnRatePerMinute: Double
    let recentSpike: Bool

    // Added in schema v2 — all optional so older cache files still decode and call sites that
    // don't yet supply the richer fields keep compiling. Declared `var` so the synthesized
    // memberwise initializer treats them as defaulted parameters (a `let` with an inline default
    // is excluded from the memberwise init entirely).
    var bucketsByMode: [String: [CachedBucket]]? = nil
    var timelinesByMode: [String: [CachedTimelinePoint]]? = nil
    var medianTokensPerMinute: Double? = nil
    var costPerHour: Double? = nil
    var todayTokens: Int? = nil
    var todayCostUSD: Double? = nil
    var weekTokens: Int? = nil
    var weekCostUSD: Double? = nil
    var monthTokens: Int? = nil
    var monthCostUSD: Double? = nil
    var billedMonthUSD: Double? = nil

    struct CachedBucket: Codable, Sendable {
        let id: String
        let key: String
        let start: Date?
        let end: Date?
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let costUSD: Double
        let models: [CachedModel]
        let isActive: Bool
        let isGap: Bool
        // Added after the initial schema — optional so older snapshot files still decode.
        var cwd: String? = nil
    }

    struct CachedModel: Codable, Sendable {
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let costUSD: Double
    }

    struct CachedTimelinePoint: Codable, Sendable {
        let timestamp: Date
        let label: String
        let tokens: Int
        let costUSD: Double
        let topSession: String?
        let topSessionTokens: Int
    }
}

extension CachedSnapshot.CachedTimelinePoint {
    init(_ point: TimelinePoint) {
        self.init(
            timestamp: point.timestamp,
            label: point.label,
            tokens: point.tokens,
            costUSD: point.costUSD,
            topSession: point.topSession,
            topSessionTokens: point.topSessionTokens
        )
    }

    func toTimelinePoint() -> TimelinePoint {
        TimelinePoint(
            timestamp: timestamp,
            label: label,
            tokens: tokens,
            costUSD: costUSD,
            topSession: topSession,
            topSessionTokens: topSessionTokens
        )
    }
}

extension CachedSnapshot.CachedModel {
    init(_ model: ModelBreakdown) {
        self.init(
            model: model.model,
            inputTokens: model.inputTokens,
            outputTokens: model.outputTokens,
            cacheCreationTokens: model.cacheCreationTokens,
            cacheReadTokens: model.cacheReadTokens,
            costUSD: model.costUSD
        )
    }

    func toModelBreakdown() -> ModelBreakdown {
        ModelBreakdown(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: costUSD
        )
    }
}

extension CachedSnapshot.CachedBucket {
    init(_ bucket: AggregateBucket) {
        self.init(
            id: bucket.id,
            key: bucket.key,
            start: bucket.start,
            end: bucket.end,
            inputTokens: bucket.inputTokens,
            outputTokens: bucket.outputTokens,
            cacheCreationTokens: bucket.cacheCreationTokens,
            cacheReadTokens: bucket.cacheReadTokens,
            costUSD: bucket.costUSD,
            models: bucket.models.map(CachedSnapshot.CachedModel.init),
            isActive: bucket.isActive,
            isGap: bucket.isGap,
            cwd: bucket.cwd
        )
    }

    func toAggregateBucket() -> AggregateBucket {
        AggregateBucket(
            id: id,
            key: key,
            start: start,
            end: end,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: costUSD,
            models: models.map { $0.toModelBreakdown() },
            isActive: isActive,
            isGap: isGap,
            cwd: cwd
        )
    }
}

struct DiskCache {
    let url: URL

    func load() -> CachedSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedSnapshot.self, from: data)
    }

    func save(_ snapshot: CachedSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ouroburn", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }

    static func defaultPricingURL() -> URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ouroburn", isDirectory: true)
            .appendingPathComponent("pricing.json")
    }

    static func defaultBillingURL() -> URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ouroburn", isDirectory: true)
            .appendingPathComponent("billing.json")
    }

    static func defaultEntriesURL() -> URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ouroburn", isDirectory: true)
            .appendingPathComponent("entries.plist")
    }
}

/// Persisted form of `BurnTracker.fileCache` so relaunches skip the multi-GB JSONL reparse.
/// Encoded as binary property list (faster + denser than JSON for ~250k `UsageEntry`s).
/// Schema is version-tagged; bumping `currentVersion` invalidates older caches without
/// throwing — the loader simply returns nil and the tracker falls back to a cold parse.
struct PersistedEntriesCache: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let savedAt: Date
    let files: [PersistedFile]

    struct PersistedFile: Codable, Sendable {
        let path: String
        let modifiedAt: Date
        let byteSize: UInt64
        let entries: [UsageEntry]
    }
}

extension DiskCache {
    static func loadPersistedEntries(at url: URL = DiskCache.defaultEntriesURL()) -> PersistedEntriesCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = PropertyListDecoder()
        guard let cache = try? decoder.decode(PersistedEntriesCache.self, from: data) else {
            return nil
        }
        guard cache.version == PersistedEntriesCache.currentVersion else { return nil }
        return cache
    }

    static func savePersistedEntries(
        _ cache: PersistedEntriesCache,
        at url: URL = DiskCache.defaultEntriesURL()
    ) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

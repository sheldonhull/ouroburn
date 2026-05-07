import Foundation

/// JSON-on-disk cache so the popover has data to show before the first poll completes —
/// essential when running offline or right after launch.
struct CachedSnapshot: Codable, Sendable {
    let savedAt: Date
    let buckets: [CachedBucket]
    let mode: String
    let burnRatePerMinute: Double
    let recentSpike: Bool

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
    }

    struct CachedModel: Codable, Sendable {
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let costUSD: Double
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
            isGap: bucket.isGap
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
            isGap: isGap
        )
    }
}

struct DiskCache {
    let url: URL

    init(url: URL) { self.url = url }

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
}

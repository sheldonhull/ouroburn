import Foundation

/// One observed pricing snapshot for the Anthropic (Claude) models, valid over a date range.
/// `effectiveTo == nil` means "still current". Stored so historical usage is costed at the rate
/// that was in effect when it happened — not whatever the feed reports today. We persist only the
/// Anthropic subset (the models this app tracks), not the full ~6.5k-model feed.
struct PricingVersion: Codable, Sendable, Equatable {
    var effectiveFrom: Date
    var effectiveTo: Date?
    var table: [String: ModelPricing]
}

/// Date-aware pricing lookup. Anthropic models resolve against the version effective at the usage
/// timestamp; everything else (and any date the history doesn't cover) falls back to the current
/// full feed table, so non-Claude models still price at today's rate.
struct DatedPricingTable: Sendable {
    /// Ascending by `effectiveFrom`.
    var versions: [PricingVersion]
    var current: [String: ModelPricing]

    func resolve(model: String?, at date: Date) -> ModelPricing? {
        guard let model, !model.isEmpty else { return nil }
        if let version = version(at: date), let hit = Self.lookup(model, in: version.table) {
            return hit
        }
        return Self.lookup(model, in: current)
    }

    /// Latest version that had started by `date` and hadn't yet expired. Dates before the earliest
    /// version use the earliest (we can't reconstruct rates from before ouroburn first observed one).
    private func version(at date: Date) -> PricingVersion? {
        var match: PricingVersion?
        for version in versions where version.effectiveFrom <= date {
            if let expiry = version.effectiveTo, date >= expiry { continue }
            match = version
        }
        return match ?? versions.first
    }

    static func lookup(_ name: String, in table: [String: ModelPricing]) -> ModelPricing? {
        let normalized = PricingService.normalizeModelName(name)
        for prefix in PricingService.prefixCandidates {
            if let hit = table[prefix + normalized] { return hit }
        }
        return PricingService.fuzzyMatch(normalized, in: table)
    }
}

/// Append-only history of Anthropic pricing observations, persisted to disk. Each successful feed
/// fetch records a version; an unchanged fetch is a no-op, a changed rate closes the open version
/// and opens a new one.
struct PricingHistoryStore {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func load() -> [PricingVersion] {
        guard let data = try? Data(contentsOf: url),
              let versions = try? JSONDecoder().decode([PricingVersion].self, from: data) else { return [] }
        return versions.sorted { $0.effectiveFrom < $1.effectiveFrom }
    }

    /// Fold a fresh feed observation into the history. Returns the updated, persisted versions.
    func record(
        fullTable: [String: ModelPricing],
        observedAt: Date,
        into existing: [PricingVersion]
    ) -> [PricingVersion] {
        let subset = Self.anthropicSubset(of: fullTable)
        guard !subset.isEmpty else { return existing }
        var versions = existing
        if let lastIndex = versions.indices.last, versions[lastIndex].effectiveTo == nil {
            if versions[lastIndex].table == subset { return existing } // rates unchanged
            versions[lastIndex].effectiveTo = observedAt
            versions.append(PricingVersion(effectiveFrom: observedAt, effectiveTo: nil, table: subset))
        } else {
            // First observation ever — cover all prior usage with this rate.
            versions.append(PricingVersion(effectiveFrom: .distantPast, effectiveTo: nil, table: subset))
        }
        persist(versions)
        return versions
    }

    /// Keys whose bare id is a Claude model — the Anthropic subset, across all provider prefixes.
    static func anthropicSubset(of table: [String: ModelPricing]) -> [String: ModelPricing] {
        table.filter { key, _ in
            let bare = key.lowercased().split(separator: "/").last.map(String.init) ?? key.lowercased()
            return bare.hasPrefix("claude")
        }
    }

    private func persist(_ versions: [PricingVersion]) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(versions) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

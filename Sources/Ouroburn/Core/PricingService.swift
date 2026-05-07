import Foundation

/// Per-token pricing table sourced from LiteLLM's open price feed.
///
/// Source: ccusage `_pricing-fetcher.ts` and `packages/internal/src/pricing.ts:4`.
/// Prices are PER TOKEN (not per million); see `pricing.ts:267` for the formula.
struct ModelPricing: Sendable, Equatable {
    let inputCostPerToken: Double
    let outputCostPerToken: Double
    let cacheCreationCostPerToken: Double
    let cacheReadCostPerToken: Double
}

actor PricingService {
    static let feedURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    static let prefixCandidates = ["", "anthropic/", "claude-3-5-", "claude-3-", "claude-", "openrouter/openai/"]
    static let cacheTTL: TimeInterval = 24 * 60 * 60

    private let cacheURL: URL
    private let session: URLSession
    private var table: [String: ModelPricing] = [:]
    private var loadedAt: Date?

    init(cacheURL: URL, session: URLSession = .shared) {
        self.cacheURL = cacheURL
        self.session = session
    }

    /// Returns pricing for `modelName`, loading and caching the feed on first use.
    /// Falls back to disk cache when the network is unavailable.
    func pricing(for modelName: String?) async -> ModelPricing? {
        guard let modelName, !modelName.isEmpty else { return nil }
        if loadedAt == nil { await load() }
        return lookup(modelName)
    }

    /// Synchronous variant for callers already holding the resolved table — used by the
    /// aggregator's hot path to avoid awaiting per entry.
    func currentTable() -> [String: ModelPricing] { table }

    func ensureLoaded() async { if loadedAt == nil { await load() } }

    private func load() async {
        if let disk = readDiskCache(), Date().timeIntervalSince(disk.loadedAt) < Self.cacheTTL {
            table = disk.table
            loadedAt = disk.loadedAt
            Log.info(Log.pricing, "Loaded \(disk.table.count) entries from disk cache (age \(Int(Date().timeIntervalSince(disk.loadedAt)))s)")
            return
        }
        do {
            let fresh = try await fetchRemote()
            table = fresh
            loadedAt = Date()
            writeDiskCache(table: fresh, loadedAt: loadedAt!)
            Log.info(Log.pricing, "Fetched \(fresh.count) entries from LiteLLM feed")
            return
        } catch {
            Log.error(Log.pricing, "Remote fetch failed: \(error.localizedDescription); falling back to disk cache")
        }
        if let disk = readDiskCache() {
            table = disk.table
            loadedAt = disk.loadedAt
            Log.info(Log.pricing, "Using stale disk cache: \(disk.table.count) entries")
        } else {
            Log.error(Log.pricing, "No pricing data available — costs will be \\$0")
        }
    }

    private func fetchRemote() async throws -> [String: ModelPricing] {
        let (data, response) = try await session.data(from: Self.feedURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return Self.decode(feed: data)
    }

    private func lookup(_ name: String) -> ModelPricing? {
        for prefix in Self.prefixCandidates {
            if let hit = table[prefix + name] { return hit }
        }
        let lower = name.lowercased()
        if let hit = table.first(where: {
            let key = $0.key.lowercased()
            return key.contains(lower) || lower.contains(key)
        }) {
            return hit.value
        }
        return nil
    }

    static func decode(feed data: Data) -> [String: ModelPricing] {
        guard let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: ModelPricing] = [:]
        for (key, value) in any {
            guard let dict = value as? [String: Any] else { continue }
            let pricing = ModelPricing(
                inputCostPerToken: (dict["input_cost_per_token"] as? Double) ?? 0,
                outputCostPerToken: (dict["output_cost_per_token"] as? Double) ?? 0,
                cacheCreationCostPerToken: (dict["cache_creation_input_token_cost"] as? Double) ?? 0,
                cacheReadCostPerToken: (dict["cache_read_input_token_cost"] as? Double) ?? 0
            )
            // Skip rows with no Claude-style fields populated.
            if pricing.inputCostPerToken == 0, pricing.outputCostPerToken == 0,
               pricing.cacheCreationCostPerToken == 0, pricing.cacheReadCostPerToken == 0 { continue }
            out[key] = pricing
        }
        return out
    }

    private func readDiskCache() -> (table: [String: ModelPricing], loadedAt: Date)? {
        guard let data = try? Data(contentsOf: cacheURL),
              let envelope = try? JSONDecoder().decode(DiskEnvelope.self, from: data) else { return nil }
        let table = envelope.entries.reduce(into: [String: ModelPricing]()) {
            $0[$1.key] = ModelPricing(
                inputCostPerToken: $1.input,
                outputCostPerToken: $1.output,
                cacheCreationCostPerToken: $1.cacheCreation,
                cacheReadCostPerToken: $1.cacheRead
            )
        }
        return (table, envelope.loadedAt)
    }

    private func writeDiskCache(table: [String: ModelPricing], loadedAt: Date) {
        let entries = table.map {
            DiskEnvelope.Entry(
                key: $0.key,
                input: $0.value.inputCostPerToken,
                output: $0.value.outputCostPerToken,
                cacheCreation: $0.value.cacheCreationCostPerToken,
                cacheRead: $0.value.cacheReadCostPerToken
            )
        }
        let envelope = DiskEnvelope(loadedAt: loadedAt, entries: entries)
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(envelope) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private struct DiskEnvelope: Codable {
        let loadedAt: Date
        let entries: [Entry]
        struct Entry: Codable {
            let key: String
            let input: Double
            let output: Double
            let cacheCreation: Double
            let cacheRead: Double
        }
    }
}

extension ModelPricing {
    /// Cost of an entry under this pricing. ccusage `pricing.ts:267-343` (no tiered pricing
    /// support — adequate for current Claude/Sonnet entries; revisit if 200k tiers diverge).
    func cost(for entry: UsageEntry) -> Double {
        Double(entry.inputTokens) * inputCostPerToken
            + Double(entry.outputTokens) * outputCostPerToken
            + Double(entry.cacheCreationTokens) * cacheCreationCostPerToken
            + Double(entry.cacheReadTokens) * cacheReadCostPerToken
    }
}

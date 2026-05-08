import Foundation
@testable import Ouroburn
import Testing

@Suite("Pricing")
struct PricingServiceTests {
    @Test func decodeFiltersOutModelsWithoutClaudeFields() {
        let json = """
        {
          "claude-sonnet-4-20250514": {"input_cost_per_token": 0.000003, "output_cost_per_token": 0.000015},
          "useless-model": {"unrelated_field": 1.0},
          "claude-opus-4-20250620": {"input_cost_per_token": 0.000015}
        }
        """.data(using: .utf8)!
        let table = PricingService.decode(feed: json)
        #expect(table.count == 2)
        #expect(table["claude-sonnet-4-20250514"] != nil)
        #expect(table["useless-model"] == nil)
    }

    @Test func costFormulaUsesPerTokenRates() {
        let pricing = ModelPricing(
            inputCostPerToken: 0.000003,
            outputCostPerToken: 0.000015,
            cacheCreationCostPerToken: 0.00000375,
            cacheReadCostPerToken: 0.0000003
        )
        let entry = UsageEntry(
            timestamp: Date(),
            model: "m",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            messageId: "a",
            requestId: "b",
            costUSD: nil,
            projectPath: "p",
            sessionId: "s"
        )
        #expect(abs(pricing.cost(for: entry) - 18.0) < 0.0001)
    }

    @Test func resolverHonorsPrefixCandidates() {
        let table: [String: ModelPricing] = [
            "anthropic/claude-haiku-4-5": ModelPricing(
                inputCostPerToken: 0.000001,
                outputCostPerToken: 0.000005,
                cacheCreationCostPerToken: 0,
                cacheReadCostPerToken: 0
            )
        ]
        #expect(PricingResolver.resolve(model: "claude-haiku-4-5", table: table) != nil)
        #expect(PricingResolver.resolve(model: "anthropic/claude-haiku-4-5", table: table) != nil)
    }

    @Test func resolverFallsBackToCaseInsensitiveSubstring() {
        let table: [String: ModelPricing] = [
            "claude-sonnet-4-20250514": ModelPricing(
                inputCostPerToken: 0.000003,
                outputCostPerToken: 0.000015,
                cacheCreationCostPerToken: 0,
                cacheReadCostPerToken: 0
            )
        ]
        #expect(PricingResolver.resolve(model: "CLAUDE-SONNET-4-20250514", table: table) != nil)
    }

    @Test func resolverMissReturnsNil() {
        #expect(PricingResolver.resolve(model: "gpt-9000", table: [:]) == nil)
    }

    @Test func diskCacheRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ouroburn-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = DiskCache(url: dir.appendingPathComponent("snap.json"))
        let bucket = AggregateBucket(
            id: "2026-05-06",
            key: "2026-05-06",
            start: Date(timeIntervalSince1970: 1_780_000_000),
            end: Date(timeIntervalSince1970: 1_780_086_400),
            inputTokens: 100,
            outputTokens: 200,
            cacheCreationTokens: 0,
            cacheReadTokens: 50,
            costUSD: 0.42,
            models: [ModelBreakdown(
                model: "claude-sonnet-4",
                inputTokens: 100,
                outputTokens: 200,
                cacheCreationTokens: 0,
                cacheReadTokens: 50,
                costUSD: 0.42
            )],
            isActive: true,
            isGap: false
        )
        cache.save(CachedSnapshot(
            savedAt: Date(timeIntervalSince1970: 1_780_086_500),
            buckets: [.init(bucket)],
            mode: ViewMode.day.rawValue,
            burnRatePerMinute: 42.0,
            recentSpike: false
        ))
        let loaded = cache.load()
        #expect(loaded?.buckets.first?.id == "2026-05-06")
        #expect(loaded?.buckets.first?.models.first?.model == "claude-sonnet-4")
        #expect(loaded?.burnRatePerMinute == 42.0)
    }
}

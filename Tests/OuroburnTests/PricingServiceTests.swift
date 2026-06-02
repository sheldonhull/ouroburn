import Foundation
@testable import Ouroburn
import Testing

@Suite("Pricing")
struct PricingServiceTests {
    @Test func decodeFlattensModelsDevProviders() throws {
        let json = """
        {
          "anthropic": {
            "models": {
              "claude-opus-4-7": {
                "cost": {"input": 5, "output": 25, "cache_read": 0.5, "cache_write": 6.25}
              },
              "missing-cost": {}
            }
          },
          "openai": {
            "models": {
              "gpt-9000": {
                "cost": {"input": 10, "output": 30}
              }
            }
          },
          "junk-provider": {"no_models_key": true}
        }
        """.data(using: .utf8)!
        let table = PricingService.decode(feed: json)
        let opus = try #require(table["claude-opus-4-7"])
        #expect(abs(opus.inputCostPerToken - 0.000005) < 1e-12)
        #expect(abs(opus.outputCostPerToken - 0.000025) < 1e-12)
        #expect(abs(opus.cacheReadCostPerToken - 0.0000005) < 1e-12)
        #expect(abs(opus.cacheCreationCostPerToken - 0.00000625) < 1e-12)
        #expect(table["anthropic/claude-opus-4-7"] != nil)
        #expect(table["gpt-9000"] != nil)
        #expect(table["openai/gpt-9000"] != nil)
        #expect(table["missing-cost"] == nil)
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

    /// Regression: a newer model must never resolve to an older one's (higher) rate. Before the
    /// fuzzy matcher was hardened, `claude-opus-4-8` matched `claude-opus-4` and billed 3x.
    @Test func resolverNeverDowngradesToOlderModel() {
        let legacy = ModelPricing(
            inputCostPerToken: 0.000015, outputCostPerToken: 0.000075,
            cacheCreationCostPerToken: 0.00001875, cacheReadCostPerToken: 0.0000015
        )
        let current = ModelPricing(
            inputCostPerToken: 0.000005, outputCostPerToken: 0.000025,
            cacheCreationCostPerToken: 0.00000625, cacheReadCostPerToken: 0.0000005
        )
        let venice = ModelPricing(
            inputCostPerToken: 0.000006, outputCostPerToken: 0.000030,
            cacheCreationCostPerToken: 0.0000075, cacheReadCostPerToken: 0.0000006
        )
        let table: [String: ModelPricing] = [
            "anthropic/claude-opus-4": legacy,
            "claude-opus-4": legacy,
            "anthropic/claude-opus-4-8": current,
            "claude-opus-4-8": venice // bare id is last-writer-wins from a non-anthropic provider
        ]
        // Resolves to the anthropic 4-8 rate ($5 in), not legacy 4 ($15) nor venice ($6).
        #expect(PricingResolver.resolve(model: "claude-opus-4-8", table: table)?.inputCostPerToken == 0.000005)
    }

    /// When only the older model is in the table, the newer query must miss (cost $0, visibly
    /// wrong) rather than silently borrow legacy pricing.
    @Test func resolverMissesRatherThanDowngrade() {
        let legacy = ModelPricing(
            inputCostPerToken: 0.000015, outputCostPerToken: 0.000075,
            cacheCreationCostPerToken: 0, cacheReadCostPerToken: 0
        )
        let table: [String: ModelPricing] = ["anthropic/claude-opus-4": legacy]
        #expect(PricingResolver.resolve(model: "claude-opus-4-8", table: table) == nil)
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

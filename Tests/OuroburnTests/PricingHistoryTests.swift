import Foundation
@testable import Ouroburn
import Testing

@Suite("PricingHistory")
struct PricingHistoryTests {
    private func pricing(_ input: Double) -> ModelPricing {
        ModelPricing(
            inputCostPerToken: input,
            outputCostPerToken: input * 5,
            cacheCreationCostPerToken: input * 1.25,
            cacheReadCostPerToken: input * 0.1
        )
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601.parse(value))
    }

    private func entry(model: String, ts: String, input: Int) throws -> UsageEntry {
        try UsageEntry(
            timestamp: date(ts),
            model: model,
            inputTokens: input,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            messageId: UUID().uuidString,
            requestId: UUID().uuidString,
            costUSD: nil,
            projectPath: "p",
            sessionId: "s"
        )
    }

    @Test("normalizeModelName strips the [1m] context-window tier")
    func normalizeStripsBracketTier() {
        #expect(PricingService.normalizeModelName("claude-opus-4-8[1m]") == "claude-opus-4-8")
        #expect(PricingService.normalizeModelName("claude-opus-4-8") == "claude-opus-4-8")
        #expect(PricingService.normalizeModelName(" claude-sonnet-4-6 [200k] ") == "claude-sonnet-4-6")
    }

    @Test("[1m]-tagged model resolves to its base-model rate")
    func bracketModelResolvesToBase() {
        let table = DatedPricingTable(versions: [], current: ["claude-opus-4-8": pricing(0.000005)])
        let hit = table.resolve(model: "claude-opus-4-8[1m]", at: Date())
        #expect(hit?.inputCostPerToken == 0.000005)
    }

    @Test("Dated lookup costs each entry at the rate effective when it ran")
    func datedLookupPicksVersionByTimestamp() throws {
        let mar = try date("2026-03-15T00:00:00Z")
        let versions = [
            PricingVersion(
                effectiveFrom: .distantPast,
                effectiveTo: mar,
                table: ["claude-opus-4-8": pricing(0.000005)]
            ),
            PricingVersion(
                effectiveFrom: mar,
                effectiveTo: nil,
                table: ["claude-opus-4-8": pricing(0.000010)]
            )
        ]
        let table = DatedPricingTable(versions: versions, current: ["claude-opus-4-8": pricing(0.000010)])

        let early = try entry(model: "claude-opus-4-8", ts: "2026-02-01T00:00:00Z", input: 1_000_000)
        let late = try entry(model: "claude-opus-4-8", ts: "2026-04-01T00:00:00Z", input: 1_000_000)
        // 1M input tokens → cost == per-token rate × 1e6.
        #expect(table.resolve(model: early.model, at: early.timestamp)?.cost(for: early) == 5)
        #expect(table.resolve(model: late.model, at: late.timestamp)?.cost(for: late) == 10)
    }

    @Test("Non-Anthropic models fall back to the current table")
    func nonAnthropicUsesCurrent() {
        let versions = [PricingVersion(
            effectiveFrom: .distantPast,
            effectiveTo: nil,
            table: ["claude-opus-4-8": pricing(0.000005)]
        )]
        let table = DatedPricingTable(versions: versions, current: ["gpt-5.5": pricing(0.000002)])
        let hit = table.resolve(model: "gpt-5.5", at: Date())
        #expect(hit?.inputCostPerToken == 0.000002)
    }

    @Test("History records only Anthropic models and versions on rate change")
    func historyRecordsAndVersions() throws {
        let store = PricingHistoryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("ouroburn-test-\(UUID().uuidString).json"))
        let feedV1: [String: ModelPricing] = [
            "claude-opus-4-8": pricing(0.000005),
            "anthropic/claude-opus-4-8": pricing(0.000005),
            "gpt-5.5": pricing(0.000002) // must be dropped from the Anthropic subset
        ]
        let t1 = try date("2026-03-01T00:00:00Z")
        var versions = store.record(fullTable: feedV1, observedAt: t1, into: [])
        #expect(versions.count == 1)
        #expect(versions[0].table["gpt-5.5"] == nil)
        #expect(versions[0].table["claude-opus-4-8"] != nil)

        // Unchanged feed → no new version.
        versions = try store.record(fullTable: feedV1, observedAt: date("2026-03-02T00:00:00Z"), into: versions)
        #expect(versions.count == 1)

        // Changed rate → prior version expires, new one opens.
        let feedV2: [String: ModelPricing] = ["claude-opus-4-8": pricing(0.000010)]
        let t2 = try date("2026-04-01T00:00:00Z")
        versions = store.record(fullTable: feedV2, observedAt: t2, into: versions)
        #expect(versions.count == 2)
        #expect(versions[0].effectiveTo == t2)
        #expect(versions[1].effectiveFrom == t2)
        #expect(versions[1].effectiveTo == nil)
    }
}

@Suite("SubagentAttribution")
struct SubagentAttributionTests {
    @Test("Subagent transcript folds into its parent project and session")
    func subagentFoldsToParent() {
        let url = URL(fileURLWithPath:
            "/root/projects/-Users-me-repo/abc-123-session/subagents/agent-deadbeef.jsonl")
        let (project, session) = JSONLLoader.deriveProjectAndSession(from: url)
        #expect(project == "-Users-me-repo")
        #expect(session == "abc-123-session")
    }

    @Test("Normal transcript keeps project and file-stem session")
    func normalTranscriptUnchanged() {
        let url = URL(fileURLWithPath: "/root/projects/-Users-me-repo/abc-123-session.jsonl")
        let (project, session) = JSONLLoader.deriveProjectAndSession(from: url)
        #expect(project == "-Users-me-repo")
        #expect(session == "abc-123-session")
    }
}

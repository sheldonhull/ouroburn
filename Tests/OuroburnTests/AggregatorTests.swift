import Foundation
import Testing
@testable import Ouroburn

@Suite("Aggregator")
struct AggregatorTests {
    private let pricing: [String: ModelPricing] = [
        "claude-sonnet-4-20250514": ModelPricing(
            inputCostPerToken: 0.000003,
            outputCostPerToken: 0.000015,
            cacheCreationCostPerToken: 0.00000375,
            cacheReadCostPerToken: 0.0000003
        ),
        "claude-opus-4-20250620": ModelPricing(
            inputCostPerToken: 0.000015,
            outputCostPerToken: 0.000075,
            cacheCreationCostPerToken: 0.00001875,
            cacheReadCostPerToken: 0.0000015
        ),
    ]

    private func makeEntry(
        ts: String,
        model: String,
        input: Int,
        output: Int,
        cacheCreate: Int = 0,
        cacheRead: Int = 0,
        project: String = "demo",
        session: String = "session-A",
        msgId: String = UUID().uuidString,
        reqId: String = UUID().uuidString,
        cost: Double? = nil
    ) -> UsageEntry {
        UsageEntry(
            timestamp: ISO8601.parse(ts)!,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            messageId: msgId,
            requestId: reqId,
            costUSD: cost,
            projectPath: project,
            sessionId: session
        )
    }

    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    @Test func dailyAggregationGroupsByLocalDay() {
        let aggregator = Aggregator(pricing: pricing, calendar: utcCalendar(), weekStart: 1)
        let entries = [
            makeEntry(ts: "2026-05-06T10:00:00.000Z", model: "claude-sonnet-4-20250514", input: 100, output: 200),
            makeEntry(ts: "2026-05-06T22:00:00.000Z", model: "claude-sonnet-4-20250514", input: 50, output: 50),
            makeEntry(ts: "2026-05-07T08:00:00.000Z", model: "claude-sonnet-4-20250514", input: 25, output: 25),
        ]
        let buckets = aggregator.aggregate(entries: entries, mode: .day)
        #expect(buckets.count == 2)
        #expect(buckets[0].id == "2026-05-07")
        #expect(buckets[1].id == "2026-05-06")
        #expect(buckets[1].totalTokens == 400)
    }

    @Test func monthlyAggregation() {
        let aggregator = Aggregator(pricing: pricing, calendar: utcCalendar(), weekStart: 1)
        let entries = [
            makeEntry(ts: "2026-05-06T10:00:00.000Z", model: "claude-sonnet-4-20250514", input: 1, output: 1),
            makeEntry(ts: "2026-05-31T10:00:00.000Z", model: "claude-sonnet-4-20250514", input: 1, output: 1),
            makeEntry(ts: "2026-06-01T10:00:00.000Z", model: "claude-sonnet-4-20250514", input: 1, output: 1),
        ]
        let buckets = aggregator.aggregate(entries: entries, mode: .month)
        #expect(buckets.map(\.id) == ["2026-06", "2026-05"])
        #expect(buckets.last?.totalTokens == 4)
    }

    @Test func costUsesEntryCostWhenPresent() {
        let aggregator = Aggregator(pricing: pricing)
        let entry = makeEntry(
            ts: "2026-05-06T10:00:00.000Z",
            model: "claude-sonnet-4-20250514",
            input: 1_000, output: 1_000,
            cost: 99.99
        )
        #expect(abs(aggregator.cost(of: entry) - 99.99) < 0.0001)
    }

    @Test func costFallsBackToPricingTable() {
        let aggregator = Aggregator(pricing: pricing)
        let entry = makeEntry(
            ts: "2026-05-06T10:00:00.000Z",
            model: "claude-sonnet-4-20250514",
            input: 1_000_000, output: 1_000_000
        )
        // 1M * 0.000003 + 1M * 0.000015 = 18.0
        #expect(abs(aggregator.cost(of: entry) - 18.0) < 0.001)
    }

    @Test func modelBreakdownAggregatesPerModel() {
        let aggregator = Aggregator(pricing: pricing, calendar: utcCalendar(), weekStart: 1)
        let entries = [
            makeEntry(ts: "2026-05-06T10:00:00.000Z", model: "claude-sonnet-4-20250514", input: 100, output: 100),
            makeEntry(ts: "2026-05-06T10:00:00.000Z", model: "claude-opus-4-20250620", input: 200, output: 200),
            makeEntry(ts: "2026-05-06T11:00:00.000Z", model: "claude-sonnet-4-20250514", input: 50, output: 50),
        ]
        let buckets = aggregator.aggregate(entries: entries, mode: .day)
        #expect(buckets.count == 1)
        let bucket = buckets[0]
        #expect(bucket.models.count == 2)
        let opus = bucket.models.first { $0.model == "claude-opus-4-20250620" }
        let sonnet = bucket.models.first { $0.model == "claude-sonnet-4-20250514" }
        #expect(opus?.totalTokens == 400)
        #expect(sonnet?.totalTokens == 300)
        #expect(bucket.models.first?.model == "claude-opus-4-20250620")
    }

    @Test func sessionGroupingByProjectAndSessionId() {
        let aggregator = Aggregator(pricing: pricing)
        let entries = [
            makeEntry(ts: "2026-05-06T10:00:00.000Z", model: "claude-sonnet-4-20250514",
                      input: 100, output: 100, project: "alpha", session: "S1"),
            makeEntry(ts: "2026-05-06T10:05:00.000Z", model: "claude-sonnet-4-20250514",
                      input: 100, output: 100, project: "alpha", session: "S1"),
            makeEntry(ts: "2026-05-06T11:00:00.000Z", model: "claude-sonnet-4-20250514",
                      input: 100, output: 100, project: "beta", session: "S2"),
        ]
        let buckets = aggregator.aggregate(entries: entries, mode: .session)
        #expect(buckets.count == 2)
        let alpha = buckets.first { $0.id == "alpha/S1" }
        #expect(alpha?.totalTokens == 400)
    }

    @Test func weeklyAggregationGroupsBySundayStart() {
        let aggregator = Aggregator(pricing: pricing, calendar: utcCalendar(), weekStart: 1)
        let entries = [
            makeEntry(ts: "2026-05-04T10:00:00.000Z", model: "claude-sonnet-4-20250514", input: 1, output: 1),
            makeEntry(ts: "2026-05-08T10:00:00.000Z", model: "claude-sonnet-4-20250514", input: 1, output: 1),
        ]
        let buckets = aggregator.aggregate(entries: entries, mode: .week)
        #expect(buckets.count == 1)
    }
}

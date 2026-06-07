import Foundation
@testable import Ouroburn
import Testing

/// Covers the additions made for the cost-panel rework: the "Other" reconciliation figure, the
/// working-directory display-name resolution, and `cwd` propagation through aggregation.
@Suite("ReconciliationAndLabels")
struct ReconciliationAndLabelsTests {
    // MARK: - ProjectPath.directoryLeaf

    @Test("Working directory wins over the lossy decoded project key")
    func directoryLeafPrefersCwd() {
        // The encoded project key mangles the hyphen in "claude-code"; the real cwd does not.
        let project = "-Users-foo-git-claude-code"
        #expect(ProjectPath.directoryLeaf(cwd: "/Users/foo/git/claude-code", project: project) == "claude-code")
    }

    @Test("Falls back to the decoded project leaf when cwd is absent")
    func directoryLeafFallsBack() {
        #expect(ProjectPath.directoryLeaf(cwd: nil, project: "-Users-foo-ouroburn") == "ouroburn")
        #expect(ProjectPath.directoryLeaf(cwd: "", project: "-Users-foo-ouroburn") == "ouroburn")
    }

    @Test("Trailing-slash cwd ignores the empty leaf and uses the project key")
    func directoryLeafIgnoresTrailingSlash() {
        #expect(ProjectPath.directoryLeaf(cwd: "/", project: "-srv-app") == "app")
    }

    // MARK: - cwd propagation through the aggregator

    @Test("Session bucket carries the latest entry's cwd")
    func sessionBucketCarriesLatestCwd() {
        let aggregator = Aggregator(pricing: [:])
        let early = UsageEntry(
            timestamp: ISO8601.parse("2026-05-06T10:00:00.000Z")!,
            model: "claude-sonnet-4-20250514",
            inputTokens: 10, outputTokens: 10, cacheCreationTokens: 0, cacheReadTokens: 0,
            messageId: "m1", requestId: "r1", costUSD: nil,
            projectPath: "proj", sessionId: "sess", cwd: "/Users/foo/old"
        )
        let late = UsageEntry(
            timestamp: ISO8601.parse("2026-05-06T12:00:00.000Z")!,
            model: "claude-sonnet-4-20250514",
            inputTokens: 10, outputTokens: 10, cacheCreationTokens: 0, cacheReadTokens: 0,
            messageId: "m2", requestId: "r2", costUSD: nil,
            projectPath: "proj", sessionId: "sess", cwd: "/Users/foo/new"
        )
        // Feed out of order to prove "latest timestamp wins", not "last seen".
        let buckets = aggregator.aggregate(entries: [late, early], mode: .session)
        #expect(buckets.count == 1)
        #expect(buckets[0].cwd == "/Users/foo/new")
    }

    // MARK: - TrackerSnapshot.otherMonthUSD

    private func snapshot(billedMonthUSD: Double?, monthCostUSD: Double) -> TrackerSnapshot {
        TrackerSnapshot(
            mode: .session,
            bucketsByMode: [:],
            timelinesByMode: [:],
            tokensPerMinute: 0,
            medianTokensPerMinute: 0,
            previousTokensPerMinute: 0,
            costPerHour: 0,
            todayTokens: 0,
            todayCostUSD: 0,
            weekTokens: 0,
            weekCostUSD: 0,
            monthTokens: 0,
            monthCostUSD: monthCostUSD,
            updatedAt: Date(),
            spikeDetected: false,
            stale: false,
            billedMonthUSD: billedMonthUSD,
            billingStatusMessage: nil,
            oauthTodayUSD: nil,
            oauthWeekUSD: nil,
            oauthBurnUSDPerHour: 0,
            oauthMedianBurnUSDPerHour: 0
        )
    }

    @Test("Other = OAuth-billed month minus local estimate (positive)")
    func otherMonthPositive() {
        let snap = snapshot(billedMonthUSD: 50, monthCostUSD: 30)
        #expect(snap.otherMonthUSD == 20)
    }

    @Test("Other is negative when the local estimate exceeds billed spend")
    func otherMonthNegative() {
        let snap = snapshot(billedMonthUSD: 10, monthCostUSD: 42)
        #expect(snap.otherMonthUSD == -32)
    }

    @Test("Other is nil until an OAuth month figure exists")
    func otherMonthNil() {
        #expect(snapshot(billedMonthUSD: nil, monthCostUSD: 30).otherMonthUSD == nil)
    }
}

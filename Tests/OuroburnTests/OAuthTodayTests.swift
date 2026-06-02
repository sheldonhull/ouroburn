import Foundation
@testable import Ouroburn
import Testing

/// `BurnTracker.oauthTodayUSD` turns the OAuth month-to-date running total into a local-day
/// figure by subtracting the reading at the last sample before midnight.
@Suite("OAuthToday")
struct OAuthTodayTests {
    private let calendar = Calendar.current

    private func sample(_ offset: TimeInterval, _ usd: Double, from now: Date) -> BillingSample {
        BillingSample(timestamp: now.addingTimeInterval(offset), totalUSD: usd, source: "test")
    }

    @Test("Pre-midnight anchor yields the full day delta")
    func preMidnightAnchorDelta() {
        let now = Date()
        let beforeMidnight = calendar.startOfDay(for: now).addingTimeInterval(-600)
        let samples = [
            BillingSample(timestamp: beforeMidnight, totalUSD: 100, source: "test"),
            sample(-3600, 112, from: now),
            sample(-60, 118.5, from: now)
        ]
        #expect(BurnTracker.oauthTodayUSD(samples: samples, now: now, calendar: calendar) == 18.5)
    }

    @Test("No pre-midnight anchor baselines on the first today sample")
    func firstTodayBaseline() {
        let now = Date()
        let samples = [sample(-7200, 100, from: now), sample(-60, 115, from: now)]
        #expect(BurnTracker.oauthTodayUSD(samples: samples, now: now, calendar: calendar) == 15)
    }

    @Test("Single sample is not a computable delta")
    func singleSampleNil() {
        let now = Date()
        #expect(BurnTracker.oauthTodayUSD(samples: [sample(-60, 100, from: now)], now: now, calendar: calendar) == nil)
    }

    @Test("Empty series returns nil")
    func emptyNil() {
        #expect(BurnTracker.oauthTodayUSD(samples: [], now: Date(), calendar: calendar) == nil)
    }

    @Test("Anchor before midnight with no today activity returns nil")
    func staleAnchorNil() {
        let now = Date()
        let beforeMidnight = calendar.startOfDay(for: now).addingTimeInterval(-600)
        let samples = [BillingSample(timestamp: beforeMidnight, totalUSD: 100, source: "test")]
        #expect(BurnTracker.oauthTodayUSD(samples: samples, now: now, calendar: calendar) == nil)
    }

    @Test("Month rollover: pre-midnight MTD reset is skipped, only post-reset climb counts")
    func monthRolloverSkipsResetStep() {
        let now = Date()
        let beforeMidnight = calendar.startOfDay(for: now).addingTimeInterval(-600)
        // Anchor is last month's high MTD ($11926); after midnight MTD reset to ~$0 then climbed.
        let samples = [
            BillingSample(timestamp: beforeMidnight, totalUSD: 11926, source: "test"),
            sample(-3600, 0, from: now),
            sample(-1800, 5, from: now),
            sample(-60, 8, from: now)
        ]
        // The -11926 reset step is dropped; today = 5 + 3 = $8 (not $0, not negative).
        #expect(BurnTracker.oauthTodayUSD(samples: samples, now: now, calendar: calendar) == 8)
    }

    @Test("Trailing trough is ignored — today holds at the peak climb")
    func trailingTroughIgnored() {
        let now = Date()
        // Healthy climb 10→200, then a not-yet-recovered glitch trough down to 12.
        let samples = [sample(-7200, 10, from: now), sample(-3600, 200, from: now), sample(-60, 12, from: now)]
        // +190 then -188 (skipped) → $190, not 190-188+… nonsense.
        #expect(BurnTracker.oauthTodayUSD(samples: samples, now: now, calendar: calendar) == 190)
    }

    @Test("Week sums spend since the start of week, reset-aware")
    func weekWindowSum() throws {
        let now = Date()
        var cal = calendar
        cal.firstWeekday = 1
        let weekday = cal.component(.weekday, from: now)
        let offset = (weekday - cal.firstWeekday + 7) % 7
        let weekStart = try #require(cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now)))
        // One sample just before week start (anchor), then climbs inside the week.
        let samples = [
            BillingSample(timestamp: weekStart.addingTimeInterval(-3600), totalUSD: 50, source: "test"),
            BillingSample(timestamp: weekStart.addingTimeInterval(3600), totalUSD: 70, source: "test"),
            BillingSample(timestamp: now.addingTimeInterval(-60), totalUSD: 95, source: "test")
        ]
        // (70-50) + (95-70) = $45 over the week.
        #expect(BurnTracker.oauthWeekUSD(samples: samples, now: now, calendar: calendar) == 45)
    }
}

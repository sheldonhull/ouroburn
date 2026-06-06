import Foundation
@testable import Ouroburn
import Testing

/// `BurnTracker.oauthBurnRates` feeds the menu-bar spinner: `current` (last sample block, drives
/// spin speed) and `median` (month's active-interval pace, drives color). Both come purely from
/// the OAuth `extra_used_usd` series so a non-billed session reads as idle.
@Suite("OAuthBurnRate")
struct OAuthBurnRateTests {
    private let calendar = Calendar.current

    private func sample(_ offset: TimeInterval, _ usd: Double, from now: Date) -> BillingSample {
        BillingSample(timestamp: now.addingTimeInterval(offset), totalUSD: usd, source: "test")
    }

    @Test("Last block with spend yields a positive current rate")
    func currentFromLastBlock() {
        let now = Date()
        // $1 over the last 5 min → $12/hr.
        let samples = [sample(-600, 10, from: now), sample(-300, 11, from: now), sample(0, 12, from: now)]
        let rates = BurnTracker.oauthBurnRates(samples: samples, now: now, calendar: calendar)
        #expect(abs(rates.current - 12) < 0.001)
    }

    @Test("No spend in the last block → current 0 (spinner stops)")
    func idleWhenLastBlockFlat() {
        let now = Date()
        let samples = [sample(-600, 50, from: now), sample(-300, 50, from: now), sample(0, 50, from: now)]
        #expect(BurnTracker.oauthBurnRates(samples: samples, now: now, calendar: calendar).current == 0)
    }

    @Test("Stale newest sample → current 0")
    func staleSeriesIsIdle() {
        let now = Date()
        // Newest sample is 30 min old (> staleness window); even with a delta, treat as idle.
        let samples = [sample(-2100, 10, from: now), sample(-1800, 20, from: now)]
        #expect(BurnTracker.oauthBurnRates(samples: samples, now: now, calendar: calendar).current == 0)
    }

    @Test("Sub-minute pair is skipped; falls back to the prior real interval")
    func skipsTinyDenominatorPair() {
        let now = Date()
        // Last pair is 10s apart (force-refresh race). Prior interval is 5 min for $1 → $12/hr.
        let samples = [
            sample(-310, 10, from: now),
            sample(-10, 11, from: now),
            sample(0, 11.5, from: now)
        ]
        let rates = BurnTracker.oauthBurnRates(samples: samples, now: now, calendar: calendar)
        #expect(abs(rates.current - 12) < 0.001)
    }

    @Test("Median is the typical active-interval rate, ignoring flat intervals")
    func medianOverActiveIntervals() {
        let now = Date()
        // Three active 5-min intervals at $6/hr, $12/hr, $18/hr and one flat interval.
        let samples = [
            sample(-1500, 0, from: now),
            sample(-1200, 0.5, from: now), // $6/hr
            sample(-900, 0.5, from: now), // flat → excluded
            sample(-600, 1.5, from: now), // $12/hr
            sample(-300, 1.5, from: now), // flat → excluded
            sample(0, 3.0, from: now) // $18/hr
        ]
        let rates = BurnTracker.oauthBurnRates(samples: samples, now: now, calendar: calendar)
        // Active rates {6,12,18} → median 12.
        #expect(abs(rates.median - 12) < 0.001)
    }

    @Test("Empty series is fully idle")
    func emptyIsIdle() {
        let rates = BurnTracker.oauthBurnRates(samples: [], now: Date(), calendar: calendar)
        #expect(rates.current == 0)
        #expect(rates.median == 0)
    }
}

import Foundation
@testable import Ouroburn
import Testing

/// Gating for the month-end projection toast (`BurnTracker.shouldFireProjectionAlert`). The alert
/// must stay quiet unless it's enabled, the projection clears the budget ceiling, today's spend has
/// passed the noise floor, and it hasn't already fired today.
@Suite("ProjectionAlert")
struct ProjectionAlertTests {
    private func decide(
        projected: Double = 8000,
        today: Double = 250,
        threshold: Double = 7000,
        minToday: Double = 200,
        enabled: Bool = true,
        lastAlertDay: String = "2026-06-08",
        todayKey: String = "2026-06-09"
    ) -> Bool {
        BurnTracker.shouldFireProjectionAlert(
            projectedUSD: projected,
            todayCostUSD: today,
            thresholdUSD: threshold,
            minTodayUSD: minToday,
            enabled: enabled,
            lastAlertDay: lastAlertDay,
            today: todayKey
        )
    }

    @Test("Fires when over budget, busy enough, and not yet fired today")
    func firesWhenAllConditionsMet() {
        #expect(decide() == true)
    }

    @Test("Silent when disabled")
    func silentWhenDisabled() {
        #expect(decide(enabled: false) == false)
    }

    @Test("Silent when projection is at or below the threshold")
    func silentBelowThreshold() {
        #expect(decide(projected: 7000) == false) // strictly greater required
        #expect(decide(projected: 6500) == false)
    }

    @Test("Silent until today's spend passes the noise floor")
    func silentUntilBusy() {
        #expect(decide(today: 200) == false) // strictly greater required
        #expect(decide(today: 150) == false)
    }

    @Test("At most once per day — silent if already fired today")
    func silentWhenAlreadyFiredToday() {
        #expect(decide(lastAlertDay: "2026-06-09", todayKey: "2026-06-09") == false)
    }

    @Test("Fires again after the day rolls over")
    func firesAfterDayRollover() {
        #expect(decide(lastAlertDay: "2026-06-09", todayKey: "2026-06-10") == true)
    }
}

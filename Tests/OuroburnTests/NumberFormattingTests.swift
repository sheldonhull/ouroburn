import Foundation
@testable import Ouroburn
import Testing

@Suite("NumberFormatting")
struct NumberFormattingTests {
    // MARK: compactTokens(Int)

    @Test func compactTokensIntZero() {
        #expect(NumberFormatting.compactTokens(0) == "0")
    }

    @Test func compactTokensIntUnderThousand() {
        #expect(NumberFormatting.compactTokens(999) == "999")
    }

    @Test func compactTokensIntKBoundary() {
        #expect(NumberFormatting.compactTokens(1000) == "1.0k")
    }

    @Test func compactTokensIntKRoundsHalfUp() {
        // 1499 / 1000 = 1.499 → %.1f → "1.5"
        #expect(NumberFormatting.compactTokens(1499) == "1.5k")
    }

    @Test func compactTokensIntKUpperBoundary() {
        // 999_999 / 1000 = 999.999 → %.1f → "1000.0" (rolls over but stays in k bucket)
        #expect(NumberFormatting.compactTokens(999_999) == "1000.0k")
    }

    @Test func compactTokensIntMBoundary() {
        #expect(NumberFormatting.compactTokens(1_000_000) == "1.00m")
    }

    @Test func compactTokensIntMTypical() {
        // 1_432_000 / 1_000_000 = 1.432 → %.2f → "1.43"
        #expect(NumberFormatting.compactTokens(1_432_000) == "1.43m")
    }

    @Test func compactTokensIntMUpperBoundary() {
        // 999_999_999 / 1_000_000 = 999.999999 → %.2f → "1000.00"
        #expect(NumberFormatting.compactTokens(999_999_999) == "1000.00m")
    }

    @Test func compactTokensIntBBoundary() {
        #expect(NumberFormatting.compactTokens(1_000_000_000) == "1.00b")
    }

    @Test func compactTokensIntNegative() {
        #expect(NumberFormatting.compactTokens(-1500) == "-1.5k")
    }

    // MARK: compactTokens(Double)

    @Test func compactTokensDoubleMatchesInt() {
        #expect(NumberFormatting.compactTokens(1_432_000.7) == "1.43m")
    }

    @Test func compactTokensDoubleNaN() {
        #expect(NumberFormatting.compactTokens(Double.nan) == "—")
    }

    @Test func compactTokensDoubleInfinity() {
        #expect(NumberFormatting.compactTokens(Double.infinity) == "—")
    }

    @Test func compactTokensDoubleNegativeInfinity() {
        #expect(NumberFormatting.compactTokens(-Double.infinity) == "—")
    }

    @Test func compactTokensDoubleSubThousandRounds() {
        // Double overload at <1000 returns Int(rounded()).
        #expect(NumberFormatting.compactTokens(42.7) == "43")
    }

    // MARK: compactDollars

    @Test func compactDollarsZero() {
        #expect(NumberFormatting.compactDollars(0) == "$0.00")
    }

    @Test func compactDollarsCents() {
        #expect(NumberFormatting.compactDollars(0.5) == "$0.50")
    }

    @Test func compactDollarsJustUnderTen() {
        #expect(NumberFormatting.compactDollars(9.99) == "$9.99")
    }

    @Test func compactDollarsTenBoundary() {
        // At $10 we cross into %.0f bucket — no decimal places.
        #expect(NumberFormatting.compactDollars(10) == "$10")
    }

    @Test func compactDollarsHundreds() {
        #expect(NumberFormatting.compactDollars(142) == "$142")
    }

    @Test func compactDollarsJustUnderThousand() {
        #expect(NumberFormatting.compactDollars(999) == "$999")
    }

    @Test func compactDollarsKBoundary() {
        #expect(NumberFormatting.compactDollars(1000) == "$1.00k")
    }

    @Test func compactDollarsKTypical() {
        #expect(NumberFormatting.compactDollars(1420) == "$1.42k")
    }

    @Test func compactDollarsMBoundary() {
        #expect(NumberFormatting.compactDollars(1_000_000) == "$1.00m")
    }

    @Test func compactDollarsNegative() {
        // -$42.5 abs falls in <$1000 bucket → "$42" (rounds to even with %.0f) → "-$42".
        #expect(NumberFormatting.compactDollars(-42.5) == "-$42")
    }

    @Test func compactDollarsNegativeUnderTen() {
        #expect(NumberFormatting.compactDollars(-3.14) == "-$3.14")
    }

    @Test func compactDollarsNaN() {
        #expect(NumberFormatting.compactDollars(Double.nan) == "—")
    }

    @Test func compactDollarsInfinity() {
        #expect(NumberFormatting.compactDollars(Double.infinity) == "—")
    }

    // MARK: compactRate

    @Test func compactRateTokensPerMinute() {
        #expect(NumberFormatting.compactRate(tokensPerMinute: 1_432_000) == "1.43m tk/m")
    }

    @Test func compactRateTokensPerMinuteSmall() {
        #expect(NumberFormatting.compactRate(tokensPerMinute: 42) == "42 tk/m")
    }

    @Test func compactRateTokensPerMinuteNaN() {
        #expect(NumberFormatting.compactRate(tokensPerMinute: Double.nan) == "—")
    }

    @Test func compactRateDollarsPerHour() {
        #expect(NumberFormatting.compactRate(dollarsPerHour: 1420) == "$1.42k/hr")
    }

    @Test func compactRateDollarsPerHourCents() {
        #expect(NumberFormatting.compactRate(dollarsPerHour: 3.14) == "$3.14/hr")
    }

    @Test func compactRateDollarsPerHourNaN() {
        #expect(NumberFormatting.compactRate(dollarsPerHour: Double.nan) == "—")
    }
}

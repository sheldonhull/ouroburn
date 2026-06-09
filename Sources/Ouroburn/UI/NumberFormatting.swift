import Foundation

/// Shared compact formatters for menu-bar / popover surfaces. Lowercase suffixes (`k`, `m`, `b`)
/// keep menu-bar width predictable and read better than raw `$%.2f`. Locale-independent —
/// `String(format:)` is C locale, so `1234.5` renders as `1234.5` everywhere.
///
/// Non-finite inputs (NaN, ±infinity) render as `"—"` rather than crashing.
enum NumberFormatting {
    static func compactTokens(_ count: Int) -> String {
        if count < 0 { return "-" + compactTokens(-count) }
        switch count {
        case ..<1000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fk", Double(count) / 1000)
        case ..<1_000_000_000: return String(format: "%.2fm", Double(count) / 1_000_000)
        default: return String(format: "%.2fb", Double(count) / 1_000_000_000)
        }
    }

    static func compactTokens(_ count: Double) -> String {
        if !count.isFinite { return "—" }
        if count < 0 { return "-" + compactTokens(-count) }
        switch count {
        case ..<1000: return "\(Int(count.rounded()))"
        case ..<1_000_000: return String(format: "%.1fk", count / 1000)
        case ..<1_000_000_000: return String(format: "%.2fm", count / 1_000_000)
        default: return String(format: "%.2fb", count / 1_000_000_000)
        }
    }

    /// Full dollar amount with comma thousands separators (e.g. `$2,091`). Cents kept only under
    /// $10 where they matter; everything else rounds to whole dollars. No `k`/`m` suffix — the
    /// abbreviated form read ambiguously (`$2.09k` vs `2090`?), so the full number is shown.
    static func compactDollars(_ amount: Double) -> String {
        if !amount.isFinite { return "—" }
        if amount < 0 { return "-" + compactDollars(-amount) }
        if amount < 10 { return String(format: "$%.2f", amount) }
        return "$" + grouped(Int(amount.rounded()))
    }

    /// Non-negative integer with comma thousands separators. Locale-independent (manual grouping)
    /// to match the rest of this file's C-locale formatting.
    static func grouped(_ value: Int) -> String {
        let digits = String(value)
        guard digits.count > 3 else { return digits }
        var out = ""
        for (offset, ch) in digits.reversed().enumerated() {
            if offset > 0, offset.isMultiple(of: 3) { out.append(",") }
            out.append(ch)
        }
        return String(out.reversed())
    }

    /// Coarse human-readable duration for alert copy: `45s`, `6 min`, `1h 5m`. Rounds to the
    /// nearest second; sub-second and non-finite inputs render as `0s`. Used to describe the
    /// sample period a peak-spend reading covers, not for precise timing.
    static func humanizedDuration(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if total < 3600 { return "\(minutes) min" }
        let hours = total / 3600
        let remMinutes = (total % 3600) / 60
        return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
    }

    static func compactRate(tokensPerMinute value: Double) -> String {
        if !value.isFinite { return "—" }
        return "\(compactTokens(Int(value.rounded()))) tk/m"
    }

    static func compactRate(dollarsPerHour value: Double) -> String {
        if !value.isFinite { return "—" }
        return "\(compactDollars(value))/hr"
    }
}

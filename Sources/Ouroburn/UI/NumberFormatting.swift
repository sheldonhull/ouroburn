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

    static func compactDollars(_ amount: Double) -> String {
        if !amount.isFinite { return "—" }
        if amount < 0 { return "-" + compactDollars(-amount) }
        switch amount {
        case ..<10: return String(format: "$%.2f", amount)
        case ..<1000: return String(format: "$%.0f", amount)
        case ..<1_000_000: return String(format: "$%.2fk", amount / 1000)
        default: return String(format: "$%.2fm", amount / 1_000_000)
        }
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

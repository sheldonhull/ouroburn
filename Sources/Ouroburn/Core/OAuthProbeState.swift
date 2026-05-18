import Foundation

/// Sidecar JSON persisted next to the billing cache so the `/api/oauth/usage` indicator
/// survives app restarts. Loaded at `BillingService.init` and rewritten on every
/// success/failure classification + 429 cooldown.
struct OAuthProbeState: Codable, Sendable {
    var backoffUntil: Date?
    var lastHealth: BillingHealth
    var lastStatusMessage: String?
    var consecutiveFailures: Int
    var updatedAt: Date
}

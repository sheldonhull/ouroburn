import Foundation

/// A unified row used by every view mode. The `key` is human-readable in the bucket's natural
/// format (date string, session id, etc.). `start`/`end` give a true time range, when meaningful.
struct AggregateBucket: Equatable, Sendable, Identifiable {
    let id: String
    let key: String
    let start: Date?
    let end: Date?
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let costUSD: Double
    let models: [ModelBreakdown]
    let isActive: Bool
    let isGap: Bool

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }
}

import Foundation

/// Normalized record of a single Claude Code transcript line.
///
/// Source schema documented in ccusage `data-loader.ts:167-193`. Optional fields are missing
/// or null in the raw JSONL; tokens default to zero so downstream math stays clean.
struct UsageEntry: Equatable, Sendable {
    let timestamp: Date
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let messageId: String?
    let requestId: String?
    let costUSD: Double?
    let projectPath: String
    let sessionId: String

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    /// Dedup key per ccusage `createUniqueHash` (`data-loader.ts:530`). Returns nil when either
    /// half is absent — entries without both halves are kept in-stream rather than deduped.
    var dedupKey: String? {
        guard let messageId, let requestId else { return nil }
        return "\(messageId):\(requestId)"
    }
}

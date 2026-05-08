import Foundation

/// Single OAuth-spend observation. The diff between consecutive samples gives the actual
/// burn rate visible to Anthropic, distinct from the local-pricing aggregate the rest of the
/// app shows.
struct BillingSample: Codable, Sendable, Equatable {
    let timestamp: Date
    let totalUSD: Double
    /// Source identifier so a future Admin / Enterprise sample can coexist in the same log.
    let source: String

    init(timestamp: Date = Date(), totalUSD: Double, source: String = "claude_code_oauth") {
        self.timestamp = timestamp
        self.totalUSD = totalUSD
        self.source = source
    }
}

/// Append-only JSONL of `BillingSample`s, capped at `maxRows` (oldest dropped on write). A
/// row per fetch is small (~120 B); a 30-day month at one-per-minute is ~5 MB worst case but
/// in practice we throttle to once per `oauthRefreshMinutes`, so the file stays well under a
/// MB even with aggressive settings.
struct BillingSampleStore {
    let url: URL
    let maxRows: Int

    init(url: URL = BillingSampleStore.defaultURL(), maxRows: Int = 50_000) {
        self.url = url
        self.maxRows = maxRows
    }

    func append(_ sample: BillingSample) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload: [String: Any] = [
            "timestamp": formatter.string(from: sample.timestamp),
            "total_usd": sample.totalUSD,
            "source": sample.source
        ]
        guard let line = try? JSONSerialization.data(withJSONObject: payload),
              let lineString = String(data: line, encoding: .utf8) else { return }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data((lineString + "\n").utf8))
            }
        } else {
            try? Data((lineString + "\n").utf8).write(to: url, options: .atomic)
        }

        trimIfNeeded()
    }

    func load() -> [BillingSample] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        var out: [BillingSample] = []
        out.reserveCapacity(1024)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = raw.data(using: .utf8),
                  let any = try? JSONSerialization.jsonObject(with: lineData),
                  let dict = any as? [String: Any],
                  let ts = dict["timestamp"] as? String,
                  let total = dict["total_usd"] as? Double else { continue }
            let parsed = formatter.date(from: ts) ?? fallback.date(from: ts) ?? Date()
            let source = (dict["source"] as? String) ?? "unknown"
            out.append(BillingSample(timestamp: parsed, totalUSD: total, source: source))
        }
        return out
    }

    private func trimIfNeeded() {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maxRows else { return }
        let kept = lines.suffix(maxRows)
        let rewritten = kept.joined(separator: "\n") + "\n"
        try? Data(rewritten.utf8).write(to: url, options: .atomic)
    }

    static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ouroburn", isDirectory: true)
            .appendingPathComponent("billing-samples.jsonl")
    }
}

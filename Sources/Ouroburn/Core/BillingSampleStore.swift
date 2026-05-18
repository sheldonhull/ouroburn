import Foundation
import os

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
///
/// Loads are mtime-cached process-wide: three call-sites (BurnTracker.checkDailyPeak,
/// BillingHistoryWindowController, MetricsViewController.renderHeartbeat) all read the same
/// file on every snapshot tick. Without caching, ISO8601 parsing of 3k+ samples on every poll
/// burns ~70% of main-thread CPU (sampled). The cache is invalidated automatically when the
/// file's mtime advances (via `append`).
struct BillingSampleStore {
    let url: URL
    let maxRows: Int

    init(url: URL = BillingSampleStore.defaultURL(), maxRows: Int = 50000) {
        self.url = url
        self.maxRows = maxRows
    }

    func append(_ sample: BillingSample) {
        let payload: [String: Any] = [
            "timestamp": Self.dateFormatter.string(from: sample.timestamp),
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

        Self.invalidateCache(for: url)
        trimIfNeeded()
    }

    func load() -> [BillingSample] {
        let mtime = Self.modificationDate(of: url)
        if let cached = Self.cachedSamples(for: url, mtime: mtime) {
            return cached
        }
        let parsed = Self.parseFromDisk(at: url)
        Self.storeCache(for: url, samples: parsed, mtime: mtime)
        return parsed
    }

    private static func parseFromDisk(at url: URL) -> [BillingSample] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [BillingSample] = []
        out.reserveCapacity(1024)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = raw.data(using: .utf8),
                  let any = try? JSONSerialization.jsonObject(with: lineData),
                  let dict = any as? [String: Any],
                  let ts = dict["timestamp"] as? String,
                  let total = dict["total_usd"] as? Double else { continue }
            let parsed = dateFormatter.date(from: ts) ?? fallbackDateFormatter.date(from: ts) ?? Date()
            let source = (dict["source"] as? String) ?? "unknown"
            out.append(BillingSample(timestamp: parsed, totalUSD: total, source: source))
        }
        out.sort { $0.timestamp < $1.timestamp }
        return Self.filterTransientTroughs(out)
    }

    /// Drop "trough" runs where Anthropic's `extra_used_usd` collapsed and then recovered. Real
    /// billing-period resets stay (they don't recover within the same observable history). The
    /// transient bug pattern we see in production is: a healthy ~$N value → drops to a tiny
    /// value (often $12 or similar) for one or more polls → springs back to ~$N. Without this
    /// filter the table renders a -$N delta on the drop and a +$N delta on the recovery, both
    /// at six-figure-per-hour rates that are obviously wrong.
    ///
    /// Heuristic: a sample is a transient trough if it is < 50% of both its prior (within 30
    /// min) and a later sample (within 30 min). We drop those trough samples from the visible
    /// series; the on-disk JSONL is untouched so we can re-tune later.
    private static func filterTransientTroughs(_ samples: [BillingSample]) -> [BillingSample] {
        guard samples.count >= 3 else { return samples }
        let recoveryWindow: TimeInterval = 30 * 60
        let dropRatio = 0.5
        let minBaseline = 1.0 // $1 — below this any tiny absolute value is noise, skip filtering

        var keep = [Bool](repeating: true, count: samples.count)
        var i = 0
        while i < samples.count {
            // Find the prior kept sample within the recovery window.
            var priorIdx: Int? = nil
            var j = i - 1
            while j >= 0 {
                if keep[j], samples[i].timestamp.timeIntervalSince(samples[j].timestamp) <= recoveryWindow {
                    priorIdx = j
                    break
                }
                j -= 1
            }
            guard let pi = priorIdx, samples[pi].totalUSD >= minBaseline else { i += 1; continue }
            let prior = samples[pi]
            let here = samples[i]
            // Must be a meaningful drop relative to the prior.
            guard here.totalUSD < prior.totalUSD * dropRatio else { i += 1; continue }
            // Look ahead for a recovery sample within the window.
            var recoveredAt: Int? = nil
            var k = i + 1
            while k < samples.count, samples[k].timestamp.timeIntervalSince(here.timestamp) <= recoveryWindow {
                if samples[k].totalUSD >= prior.totalUSD * dropRatio {
                    recoveredAt = k
                    break
                }
                k += 1
            }
            if recoveredAt != nil {
                // Mark every sample from `i` up to (but not including) the recovery as trough.
                for t in i ..< (recoveredAt ?? samples.count) {
                    keep[t] = false
                }
                i = recoveredAt ?? samples.count
            } else {
                // No recovery — looks like a genuine reset. Leave it in place.
                i += 1
            }
        }
        return zip(samples, keep).compactMap { $1 ? $0 : nil }
    }

    private func trimIfNeeded() {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maxRows else { return }
        let kept = lines.suffix(maxRows)
        let rewritten = kept.joined(separator: "\n") + "\n"
        try? Data(rewritten.utf8).write(to: url, options: .atomic)
        Self.invalidateCache(for: url)
    }

    static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ouroburn", isDirectory: true)
            .appendingPathComponent("billing-samples.jsonl")
    }

    // MARK: - Shared formatters

    nonisolated(unsafe) static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let fallbackDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Cache (keyed by file URL + mtime)

    private struct CacheEntry {
        let mtime: Date?
        let samples: [BillingSample]
    }

    private static let cacheLock = OSAllocatedUnfairLock<[URL: CacheEntry]>(initialState: [:])

    private static func modificationDate(of url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    private static func cachedSamples(for url: URL, mtime: Date?) -> [BillingSample]? {
        cacheLock.withLock { cache in
            guard let entry = cache[url] else { return nil }
            // Cache hit only when the on-disk mtime matches the cached snapshot; otherwise the
            // file was rewritten (by `append` from another process or test) and we need to reparse.
            guard entry.mtime == mtime else { return nil }
            return entry.samples
        }
    }

    private static func storeCache(for url: URL, samples: [BillingSample], mtime: Date?) {
        cacheLock.withLock { cache in
            cache[url] = CacheEntry(mtime: mtime, samples: samples)
        }
    }

    private static func invalidateCache(for url: URL) {
        cacheLock.withLock { cache in
            cache[url] = nil
        }
    }
}

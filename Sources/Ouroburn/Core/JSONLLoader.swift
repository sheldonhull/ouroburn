import Foundation
import os

/// Loads UsageEntry records from Claude Code transcripts.
///
/// Replicates ccusage `getClaudePaths` (`data-loader.ts:78`) and the streaming JSONL ingest
/// (`data-loader.ts:716`+). Reads are line-oriented and tolerant of malformed lines.
struct JSONLLoader {
    let fileManager: FileManager
    let environment: [String: String]
    let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    /// Mirrors ccusage `getClaudePaths`: honors $CLAUDE_CONFIG_DIR (comma-separated) when set,
    /// otherwise falls back to $XDG_CONFIG_HOME/claude and ~/.claude. Only paths whose `projects`
    /// subdirectory exists are returned.
    func claudeRoots() -> [URL] {
        if let env = environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            let candidates = env.split(separator: ",").map {
                URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)).standardizedFileURL
            }
            return candidates.filter { hasProjectsDir($0) }
        }
        let xdg = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? homeDirectory.appendingPathComponent(".config")
        return [xdg.appendingPathComponent("claude"), homeDirectory.appendingPathComponent(".claude")]
            .filter { hasProjectsDir($0) }
    }

    /// All `*.jsonl` files under each root's `projects/` directory. Cached for
    /// `transcriptCacheTTL` seconds — the 2s live tick and 60s poll both walked the tree on
    /// every call previously, which on a busy account (2.5k+ sessions) was ~100 ms of
    /// `FileManager.enumerator` work every 2s. New sessions are still picked up well within
    /// the TTL because the FSEvents-based `SessionFileWatcher` invalidates this cache.
    func transcriptFiles() -> [URL] {
        let now = Date()
        if let cached = Self.transcriptCache.withLock({ $0 }),
           now.timeIntervalSince(cached.cachedAt) < Self.transcriptCacheTTL
        {
            return cached.files
        }
        var files: [URL] = []
        let roots = claudeRoots()
        for root in roots {
            let projects = root.appendingPathComponent("projects")
            guard let enumerator = fileManager.enumerator(
                at: projects,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else {
                Log.error(Log.loader, "Could not enumerate \(projects.path)")
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                files.append(url)
            }
        }
        Log.debug(Log.loader, "Discovered \(files.count) transcript files (refreshed cache)")
        let snapshot = files
        Self.transcriptCache.withLock { $0 = TranscriptCacheEntry(cachedAt: now, files: snapshot) }
        return snapshot
    }

    /// Drop the cached transcript list so the next call re-walks. Hook for the FS watcher to
    /// call whenever a structural change (new project dir, new session) is observed.
    static func invalidateTranscriptCache() {
        transcriptCache.withLock { $0 = nil }
    }

    private static let transcriptCacheTTL: TimeInterval = 30
    private struct TranscriptCacheEntry {
        let cachedAt: Date
        let files: [URL]
    }

    private static let transcriptCache = OSAllocatedUnfairLock<TranscriptCacheEntry?>(initialState: nil)

    /// Reads one transcript file end to end, normalizing each valid line into a UsageEntry.
    /// `seenKeys` is mutated to track dedup state across files within the same load pass.
    func load(
        from url: URL,
        seenKeys: inout Set<String>,
        sinceTimestamp: Date? = nil
    ) -> [UsageEntry] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else { return [] }

        let (project, session) = Self.deriveProjectAndSession(from: url)
        var out: [UsageEntry] = []
        out.reserveCapacity(64)

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let entry = parseLine(raw, project: project, session: session) else { continue }
            if let cutoff = sinceTimestamp, entry.timestamp < cutoff { continue }
            if let key = entry.dedupKey {
                if seenKeys.contains(key) { continue }
                seenKeys.insert(key)
            }
            out.append(entry)
        }
        return out
    }

    /// Convenience: load all roots in one pass, optionally filtering by timestamp.
    func loadAll(sinceTimestamp: Date? = nil) -> [UsageEntry] {
        var seen = Set<String>()
        var out: [UsageEntry] = []
        for url in transcriptFiles() {
            out.append(contentsOf: load(from: url, seenKeys: &seen, sinceTimestamp: sinceTimestamp))
        }
        out.sort { $0.timestamp < $1.timestamp }
        return out
    }

    /// Returns the file's modification date, or `.distantPast` if unavailable.
    func modificationDate(for url: URL) -> Date {
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date ?? .distantPast
    }

    /// Tail-read: returns only entries appended since `fromOffset`, plus the offset just past the
    /// last complete line consumed. Caller persists `newOffset` per-URL to keep deltas cheap on
    /// the next tick. Partial last lines are deliberately not consumed — they're picked up on the
    /// following tick once the writer has flushed the newline.
    func loadIncremental(
        from url: URL,
        fromOffset: UInt64
    ) -> (entries: [UsageEntry], newOffset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ([], fromOffset)
        }
        defer { try? handle.close() }

        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            return ([], fromOffset)
        }
        if fileSize <= fromOffset { return ([], fromOffset) }

        do {
            try handle.seek(toOffset: fromOffset)
        } catch {
            return ([], fromOffset)
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return ([], fileSize)
        }

        // Find offset of last newline so we don't consume a partial trailing line.
        let newlineByte = UInt8(ascii: "\n")
        var lastNewlineIdx: Int? = nil
        for idx in stride(from: data.count - 1, through: 0, by: -1) where data[idx] == newlineByte {
            lastNewlineIdx = idx
            break
        }
        let consumeUpTo: Int
        let advanced: UInt64
        if let lastIdx = lastNewlineIdx {
            consumeUpTo = lastIdx + 1
            advanced = fromOffset + UInt64(consumeUpTo)
        } else {
            // No newline yet — wait for the writer to flush. Don't advance offset.
            return ([], fromOffset)
        }

        let consumable = data.prefix(consumeUpTo)
        guard let text = String(data: consumable, encoding: .utf8) else {
            return ([], advanced)
        }
        let (project, session) = Self.deriveProjectAndSession(from: url)
        var out: [UsageEntry] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = parseLine(raw, project: project, session: session) {
                out.append(entry)
            }
        }
        return (out, advanced)
    }

    /// Returns the current file size (used to seed tail-read offsets without consuming history).
    func currentSize(of url: URL) -> UInt64 {
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Reads a file fresh and returns its parsed entries (no dedup tracking — caller dedupes
    /// across the merged stream). Used by the tracker's mtime cache.
    func loadAllEntries(from url: URL) -> [UsageEntry] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let (project, session) = Self.deriveProjectAndSession(from: url)
        var out: [UsageEntry] = []
        out.reserveCapacity(64)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = parseLine(raw, project: project, session: session) {
                out.append(entry)
            }
        }
        return out
    }

    func parseLine(_ raw: some StringProtocol, project: String, session: String) -> UsageEntry? {
        guard let data = raw.data(using: .utf8) else { return nil }
        guard let line = try? JSONDecoder().decode(RawLine.self, from: data) else { return nil }
        guard let timestamp = line.parsedTimestamp,
              let usage = line.message?.usage else { return nil }
        // Synthetic model lines are excluded from breakdowns (ccusage `data-loader.ts:524`).
        if line.message?.model == "<synthetic>" { return nil }

        return UsageEntry(
            timestamp: timestamp,
            model: line.message?.model,
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            cacheCreationTokens: usage.cache_creation_input_tokens ?? 0,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0,
            messageId: line.message?.id,
            requestId: line.requestId,
            costUSD: line.costUSD,
            projectPath: project,
            sessionId: session,
            cwd: line.cwd
        )
    }

    private func hasProjectsDir(_ root: URL) -> Bool {
        var isDir: ObjCBool = false
        let projects = root.appendingPathComponent("projects").path
        return fileManager.fileExists(atPath: projects, isDirectory: &isDir) && isDir.boolValue
    }

    /// `<root>/projects/<project>/<session>.jsonl` → (project, sessionId).
    static func deriveProjectAndSession(from url: URL) -> (project: String, session: String) {
        let session = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()
        let parents = parent.pathComponents
        if let idx = parents.lastIndex(of: "projects"), idx + 1 < parents.count {
            let project = parents[(idx + 1)...].joined(separator: "/")
            return (project.isEmpty ? "Unknown Project" : project, session)
        }
        return (parent.lastPathComponent.isEmpty ? "Unknown Project" : parent.lastPathComponent, session)
    }
}

private struct RawLine: Decodable {
    let timestamp: String?
    let requestId: String?
    let costUSD: Double?
    let cwd: String?
    let message: Message?

    var parsedTimestamp: Date? {
        timestamp.flatMap(ISO8601.parse)
    }

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    // swiftlint:disable identifier_name
    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }
    // swiftlint:enable identifier_name
}

enum ISO8601 {
    private nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ value: String) -> Date? {
        withFraction.date(from: value) ?? plain.date(from: value)
    }
}

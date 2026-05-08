import Foundation

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

    /// All `*.jsonl` files under each root's `projects/` directory.
    func transcriptFiles() -> [URL] {
        var files: [URL] = []
        let roots = claudeRoots()
        Log.info(Log.loader, "Claude roots: \(roots.map(\.path).joined(separator: ", "))")
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
        Log.info(Log.loader, "Discovered \(files.count) transcript files")
        return files
    }

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
            sessionId: session
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

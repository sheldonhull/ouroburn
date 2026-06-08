import Foundation

/// Decode Claude Code's `-`-encoded project keys (e.g. `-Users-Foo-git-repo`) and compute the
/// longest common leading prefix across a set of session paths so the popover can collapse the
/// shared portion into a single header instead of repeating it on every row.
enum ProjectPath {
    static func segments(_ encoded: String) -> [String] {
        encoded.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
    }

    static func displayPath(_ segments: [String]) -> String {
        segments.isEmpty ? "/" : "/" + segments.joined(separator: "/")
    }

    static func commonPrefix(_ paths: [[String]]) -> [String] {
        guard let first = paths.first else { return [] }
        var common = first
        for path in paths.dropFirst() {
            let limit = min(common.count, path.count)
            var i = 0
            while i < limit, common[i] == path[i] {
                i += 1
            }
            common = Array(common.prefix(i))
            if common.isEmpty { break }
        }
        return common
    }

    /// Common prefix capped so every input keeps at least one trailing segment to display under
    /// the prefix header. Without the cap a uniform set of sessions on one repo would collapse
    /// to nothing visible per row.
    static func commonPrefixLeavingTail(_ paths: [[String]]) -> [String] {
        let common = commonPrefix(paths)
        guard let shortest = paths.map(\.count).min(), shortest > 0 else { return [] }
        return Array(common.prefix(max(0, shortest - 1)))
    }

    /// Human-readable directory leaf for a session/project. Prefers the transcript's recorded
    /// `cwd` (accurate even when a directory name contains hyphens) and falls back to the last
    /// segment of the `-`-decoded project key. Returns nil only when neither yields a name.
    static func directoryLeaf(cwd: String?, project: String) -> String? {
        if let cwd, !cwd.isEmpty {
            let leaf = (cwd as NSString).lastPathComponent
            if !leaf.isEmpty, leaf != "/" { return leaf }
        }
        return segments(project).last
    }

    /// Splits `<projectKey>/<sessionId>` produced by `Aggregator.groupBySession`.
    static func splitSessionBucketID(_ id: String) -> (project: String, session: String)? {
        guard let slash = id.lastIndex(of: "/") else { return nil }
        let project = String(id[..<slash])
        let session = String(id[id.index(after: slash)...])
        guard !project.isEmpty, !session.isEmpty else { return nil }
        return (project, session)
    }
}

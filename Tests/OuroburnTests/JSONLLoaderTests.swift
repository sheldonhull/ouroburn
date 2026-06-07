import Foundation
@testable import Ouroburn
import Testing

@Suite("JSONLLoader")
struct JSONLLoaderTests {
    @Test func parsesValidLine() throws {
        let line = #"{"timestamp":"2026-05-06T10:00:00.000Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":7}}}"#
        let entry = try #require(JSONLLoader().parseLine(line, project: "p", session: "s"))
        #expect(entry.inputTokens == 10)
        #expect(entry.outputTokens == 20)
        #expect(entry.cacheCreationTokens == 5)
        #expect(entry.cacheReadTokens == 7)
        #expect(entry.totalTokens == 42)
        #expect(entry.model == "claude-sonnet-4")
        #expect(entry.dedupKey == "m1:r1")
        #expect(entry.projectPath == "p")
        #expect(entry.sessionId == "s")
        #expect(entry.cwd == nil)
    }

    @Test func parsesCwd() throws {
        let line = #"{"timestamp":"2026-05-06T10:00:00.000Z","requestId":"r1","cwd":"/Users/foo/git/claude-code","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":1,"output_tokens":1}}}"#
        let entry = try #require(JSONLLoader().parseLine(line, project: "p", session: "s"))
        #expect(entry.cwd == "/Users/foo/git/claude-code")
    }

    @Test func rejectsMalformedJson() {
        #expect(JSONLLoader().parseLine("not json", project: "p", session: "s") == nil)
    }

    @Test func rejectsLineWithoutUsage() {
        let line = #"{"timestamp":"2026-05-06T10:00:00.000Z","message":{"model":"claude-sonnet-4"}}"#
        #expect(JSONLLoader().parseLine(line, project: "p", session: "s") == nil)
    }

    @Test func rejectsSyntheticModel() {
        let line = #"{"timestamp":"2026-05-06T10:00:00.000Z","message":{"model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":1}}}"#
        #expect(JSONLLoader().parseLine(line, project: "p", session: "s") == nil)
    }

    @Test func dedupKeyNilWhenIdentifiersMissing() {
        let line = #"{"timestamp":"2026-05-06T10:00:00.000Z","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":1}}}"#
        let entry = JSONLLoader().parseLine(line, project: "p", session: "s")
        #expect(entry?.dedupKey == nil)
    }

    @Test func deduplicatesAcrossLines() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("fixture.jsonl")
        let content = """
        {"timestamp":"2026-05-06T10:00:00.000Z","requestId":"r1","message":{"id":"m1","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}
        {"timestamp":"2026-05-06T10:01:00.000Z","requestId":"r1","message":{"id":"m1","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}
        {"timestamp":"2026-05-06T10:02:00.000Z","requestId":"r2","message":{"id":"m2","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}
        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        var seen = Set<String>()
        let entries = JSONLLoader().load(from: url, seenKeys: &seen)
        #expect(entries.count == 2)
        #expect(seen.count == 2)
    }

    @Test func honorsTimestampCutoff() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("cutoff.jsonl")
        let content = """
        {"timestamp":"2026-05-06T09:00:00.000Z","requestId":"r1","message":{"id":"m1","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}
        {"timestamp":"2026-05-06T10:30:00.000Z","requestId":"r2","message":{"id":"m2","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}
        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        let cutoff = try #require(ISO8601.parse("2026-05-06T10:00:00.000Z"))
        var seen = Set<String>()
        let entries = JSONLLoader().load(from: url, seenKeys: &seen, sinceTimestamp: cutoff)
        #expect(entries.count == 1)
        #expect(entries.first?.messageId == "m2")
    }

    @Test func projectAndSessionDerivation() {
        let url = URL(fileURLWithPath: "/tmp/projects/myproj/abc-123.jsonl")
        let derived = JSONLLoader.deriveProjectAndSession(from: url)
        #expect(derived.project == "myproj")
        #expect(derived.session == "abc-123")
    }

    @Test func claudeRootsHonorsExplicitConfigDir() throws {
        let tempRoot = try makeTempDir()
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("projects"),
            withIntermediateDirectories: true
        )
        let loader = JSONLLoader(
            environment: ["CLAUDE_CONFIG_DIR": tempRoot.path],
            homeDirectory: URL(fileURLWithPath: "/no/such/home")
        )
        #expect(loader.claudeRoots().map(\.path) == [tempRoot.standardizedFileURL.path])
    }

    @Test func claudeRootsFallsBackToXdgAndHomeWhenEnvUnset() throws {
        let tempHome = try makeTempDir()
        try FileManager.default.createDirectory(
            at: tempHome.appendingPathComponent(".claude/projects"),
            withIntermediateDirectories: true
        )
        let loader = JSONLLoader(environment: [:], homeDirectory: tempHome)
        let roots = loader.claudeRoots().map(\.lastPathComponent)
        #expect(roots.contains(".claude"))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

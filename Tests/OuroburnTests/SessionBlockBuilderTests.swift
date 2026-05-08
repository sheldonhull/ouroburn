import Foundation
@testable import Ouroburn
import Testing

@Suite("SessionBlockBuilder")
struct SessionBlockBuilderTests {
    private func entry(at iso: String) -> UsageEntry {
        UsageEntry(
            timestamp: ISO8601.parse(iso)!,
            model: "m",
            inputTokens: 10,
            outputTokens: 10,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            messageId: UUID().uuidString,
            requestId: UUID().uuidString,
            costUSD: nil,
            projectPath: "p",
            sessionId: "s"
        )
    }

    @Test func emptyEntriesYieldEmptyBlocks() {
        #expect(SessionBlockBuilder().build(entries: []).isEmpty)
    }

    @Test func entriesWithinFiveHoursStayInOneBlock() throws {
        let entries = [
            entry(at: "2026-05-06T10:00:00.000Z"),
            entry(at: "2026-05-06T12:30:00.000Z"),
            entry(at: "2026-05-06T14:30:00.000Z")
        ]
        let now = try #require(ISO8601.parse("2026-05-06T20:00:00.000Z"))
        let blocks = SessionBlockBuilder().build(entries: entries, now: now)
        #expect(blocks.count == 1)
        #expect(blocks[0].entries.count == 3)
        #expect(!blocks[0].isGap)
        #expect(!blocks[0].isActive)
    }

    @Test func newBlockOpensWhenSinceStartExceedsFiveHours() throws {
        let entries = [
            entry(at: "2026-05-06T10:00:00.000Z"),
            entry(at: "2026-05-06T12:00:00.000Z"),
            entry(at: "2026-05-06T15:30:00.000Z")
        ]
        let now = try #require(ISO8601.parse("2026-05-06T16:00:00.000Z"))
        let blocks = SessionBlockBuilder().build(entries: entries, now: now)
        #expect(blocks.count == 2)
        #expect(blocks[0].entries.count == 2)
        #expect(blocks[1].entries.count == 1)
    }

    @Test func gapBlockEmittedWhenInactivityExceedsFiveHours() throws {
        let entries = [
            entry(at: "2026-05-06T10:00:00.000Z"),
            entry(at: "2026-05-06T11:00:00.000Z"),
            entry(at: "2026-05-06T19:00:00.000Z")
        ]
        let now = try #require(ISO8601.parse("2026-05-06T20:00:00.000Z"))
        let blocks = SessionBlockBuilder().build(entries: entries, now: now)
        #expect(blocks.count == 3)
        #expect(blocks[1].isGap)
        #expect(blocks[1].entries.isEmpty)
    }

    @Test func activeBlockWhenLastActivityWithinFiveHoursAndBlockNotEnded() throws {
        let entries = [entry(at: "2026-05-06T18:00:00.000Z")]
        let now = try #require(ISO8601.parse("2026-05-06T19:30:00.000Z"))
        let blocks = SessionBlockBuilder().build(entries: entries, now: now)
        #expect(blocks.count == 1)
        #expect(blocks[0].isActive)
    }

    @Test func startFloorsToUTCHour() throws {
        let entries = [entry(at: "2026-05-06T10:37:42.000Z")]
        let now = try #require(ISO8601.parse("2026-05-06T11:00:00.000Z"))
        let blocks = SessionBlockBuilder().build(entries: entries, now: now)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        #expect(formatter.string(from: blocks[0].start) == "2026-05-06T10:00:00Z")
    }
}
